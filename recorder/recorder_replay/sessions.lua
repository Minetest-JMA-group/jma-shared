-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- Replay sessions: who is watching what, the clock, and the cursors that walk
-- the recording in step with it. A session owns a read-only connection, an
-- arena with the recording rebuilt inside it, a set of ghosts and a list of
-- participants; several can run at once.

local sessions = {}

local deps -- {reader, ghost, recovery, arena, reconstruct, sqlite}
local by_id = {}
local by_player = {}
local counter = 0

-- A recorded chat line is shown with this in front, so a watcher can tell it
-- from the replay server's own chat.
local CHAT_PREFIX = "[replay] "

-- A boolean setting whose default is on; get_bool() alone reads an unset
-- setting as off, which is the wrong default for these switches.
local function setting_on(name, default)
	local raw = core.settings:get(name)
	if raw == nil or raw == "" then return default end
	return core.settings:get_bool(name)
end

---@param dependencies table
function sessions.init(dependencies)
	deps = dependencies
end

local function new_id()
	counter = counter + 1
	return string.format("%08x%04x", os.time(), counter)
end

---@param id string?
---@return table|nil
function sessions.find(id)
	if not id then return nil end
	return by_id[id]
end

---@param name string
---@return table|nil
function sessions.for_player(name)
	return by_player[name]
end

---@return table[]  -- running sessions, oldest first
function sessions.list()
	local list = {}
	for _, session in pairs(by_id) do list[#list + 1] = session end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
end

local function observer_set(session)
	local set = {}
	for name in pairs(session.participants) do set[name] = true end
	return set
end

local function participant_count(session)
	local count = 0
	for _ in pairs(session.participants) do count = count + 1 end
	return count
end
sessions.participant_count = participant_count

local function remove_ghost(session, pid)
	local obj = session.ghosts[pid]
	if obj then
		-- A second removal, or one of an object the engine has already dropped,
		-- raises; it is not worth a server error either way.
		pcall(function()
			if obj.remove then obj:remove() end
		end)
	end
	session.ghosts[pid] = nil
	session.cursors[pid] = nil
	-- The next ghost of this player is posed by whatever the next animation
	-- event says, or by the movement heuristic before there is one.
	session.animations[pid] = nil
end

-- Everyone watching sees every ghost; anyone else sees none of them. A ghost
-- whose object has been invalidated (the arena's blocks unloaded, the game
-- cleared objects) is dropped here rather than raising.
---@param session table
function sessions.update_observers(session)
	local set = observer_set(session)
	for pid, obj in pairs(session.ghosts) do
		if not deps.ghost.set_observers(obj, set) then
			remove_ghost(session, pid)
		end
	end
end

local function textures_of(json)
	if not json then return nil end
	-- parse_json() reports malformed JSON in its return value, and logs the
	-- error itself; the join event simply has no textures to give.
	local data = core.parse_json(json)
	if type(data) == "table" and type(data.textures) == "table" then
		return data.textures
	end
	return nil
end

-- A recorded event's data, or nil when the row holds none or malformed JSON.
-- Recordings are files: a damaged row is skipped, not allowed to take the
-- replay loop down.
local function event_data(json)
	if not json then return nil end
	local data = core.parse_json(json)
	if type(data) ~= "table" then return nil end
	return data
end

-- One report per kind of trouble per session; a file with many damaged
-- particle rows must not turn into a log flood.
local function complain(session, label, message)
	session.complaints = session.complaints or {}
	if session.complaints[label] then return end
	session.complaints[label] = true
	core.log("warning", "[replay] " .. message)
end

-- A recorded animation event's data, or nil when the row does not describe one
-- (an old file with a hand-written event, or a damaged one). Nil means the
-- speed-and-dig guess keeps the pose.
local function animation_data(json)
	local data = event_data(json)
	if not data or type(data.frames) ~= "table" then return nil end
	return data
end

-- The engine accepts a position as a number (a uniform vector), a vector or a
-- table with min/max (a range); all three are kept in their shape and moved
-- into the arena.
local function translate_position(value, offset)
	if type(value) == "number" then
		return {x = value + offset.x, y = value + offset.y, z = value + offset.z}
	end
	if type(value) ~= "table" then return value end
	local x, y, z = tonumber(value.x), tonumber(value.y), tonumber(value.z)
	if x and y and z then
		return {x = x + offset.x, y = y + offset.y, z = z + offset.z}
	end
	if value.min ~= nil or value.max ~= nil then
		return {
			min = translate_position(value.min, offset),
			max = translate_position(value.max, offset),
			bias = value.bias,
		}
	end
	return value
end

-- A tween table's frames are positions; its style/reps/start keys are not.
local function translate_tween(tween, offset)
	local out = {}
	for key, value in pairs(tween) do out[key] = value end
	for i = 1, #tween do
		out[i] = translate_position(tween[i], offset)
	end
	return out
end

-- A recorded definition ready for this arena: positions move by the session's
-- offset, and a recorded player restriction is dropped - the watchers are not
-- that player, and the effect is shown to all of them.
local function translated_definition(definition, offset)
	local out = {}
	for key, value in pairs(definition) do out[key] = value end
	if out.pos ~= nil then out.pos = translate_position(out.pos, offset) end
	if out.minpos ~= nil then out.minpos = translate_position(out.minpos, offset) end
	if out.maxpos ~= nil then out.maxpos = translate_position(out.maxpos, offset) end
	if type(out.pos_tween) == "table" then
		out.pos_tween = translate_tween(out.pos_tween, offset)
	end
	local attract = out.attract
	if type(attract) == "table" then
		local moved = {}
		for key, value in pairs(attract) do moved[key] = value end
		if moved.origin ~= nil then
			moved.origin = translate_position(moved.origin, offset)
		end
		if type(moved.origin_tween) == "table" then
			moved.origin_tween = translate_tween(moved.origin_tween, offset)
		end
		out.attract = moved
	end
	out.playername = nil
	out.exclude_player = nil
	return out
end

-- Create a spawner in the arena and remember which replay id belongs to the
-- recorded one. A definition out of a file is treated as hostile: a shape the
-- engine refuses is a warning, not a lost step.
local function add_replay_spawner(session, recorded_id, definition)
	local ok, replay_id = pcall(core.add_particlespawner,
		translated_definition(definition, session.offset))
	if not ok then
		complain(session, "particlespawner",
			"cannot replay a particle spawner: " .. tostring(replay_id))
		return
	end
	if type(replay_id) == "number" and replay_id >= 0 then
		session.spawners[recorded_id] = replay_id
	end
end

-- Stop every spawner this session created. Particles themselves expire; a
-- spawner is the engine object that has to be cancelled explicitly.
local function clear_spawners(session)
	for _, replay_id in pairs(session.spawners) do
		core.delete_particlespawner(replay_id)
	end
	session.spawners = {}
end

-- The light values are recorded only when the file carries a light layer. The
-- session's mode also covers the time of day, which can be recorded on its
-- own; this is the mode a node/light write should use.
---@param session table
---@return string
local function light_write_mode(session)
	if session.reconstruct.has_light and session.light == "recorded" then
		return "recorded"
	end
	return "live"
end

-- Put every ghost back to where it was at a moment, rebuild the reconstructed
-- region for that moment, and every cursor to the rows that follow it.
---@param session table
---@param T number
function sessions.seek(session, T)
	T = math.max(0, math.min(tonumber(T) or 0, session.rec.duration))
	session.T = T
	for pid in pairs(session.ghosts) do remove_ghost(session, pid) end
	session.joined = {}
	session.animations = {}
	local tick = deps.reader.tick_at(session.rec, T)
	session.event_last_id = deps.reader.last_event_id(session.rec, tick)
	session.events = {rows = {}, next = 1}
	session.reconstruct_dirty = false

	-- Only the blocks whose content differs between the state last written and
	-- this one are written: the rows between the two ticks, plus the blocks
	-- forward playback has already moved on since the last seek.
	local previous_tick = session.reconstruct_tick
	local touched
	if previous_tick ~= nil then
		touched = deps.reconstruct.seek(
			session.reconstruct, session.rec, tick, session.offset, previous_tick)
		for key, block in pairs(session.state_blocks) do
			touched[key] = block
		end
		for key, block in pairs(session.dirty_blocks) do
			touched[key] = block
		end
	end
	if previous_tick == nil then
		deps.reconstruct.seek(session.reconstruct, session.rec, tick)
	end

	local mode = light_write_mode(session)
	local rebuilt, rebuild_err
	if touched and next(touched) == nil then
		rebuilt = true
	elseif touched then
		rebuilt, rebuild_err = deps.reconstruct.write_blocks(
			session.reconstruct, session.offset, touched, mode)
	else
		rebuilt, rebuild_err = deps.reconstruct.write(
			session.reconstruct, session.offset, mode)
	end
	session.reconstruct_tick = tick
	session.dirty_blocks = {}
	session.state_blocks = {}
	if not rebuilt then
		core.log("warning", "[replay] cannot rebuild the region: " .. tostring(rebuild_err))
	elseif previous_tick == nil and mode ~= "recorded" then
		-- The first write covers the whole region; live lighting needs the same
		-- full pass as the arena itself. Recorded lighting was just written and
		-- must not be recalculated.
		deps.arena.relight(session.arena)
	end
	session.light_last_id = deps.reader.last_light_id(session.rec, tick)
	session.light_events = {rows = {}, next = 1}

	-- Metadata is not part of the node write: the arena is wiped of it and
	-- then told everything the recording had up to this moment, so a seek
	-- backwards also undoes a container's later contents.
	deps.arena.clear_metadata(session.arena)
	for _, row in ipairs(deps.reader.node_metadata_until(session.rec, tick)) do
		deps.reconstruct.apply_metadata(session.offset, row)
	end
	session.metadata_last_id = deps.reader.last_metadata_id(session.rec, tick)
	session.metadata_events = {rows = {}, next = 1}

	local offset = session.offset
	local present = {}
	for _, ev in ipairs(deps.reader.join_leave_until(session.rec, tick)) do
		if ev.type == "join" and ev.subject_player then
			present[ev.subject_player] = {pos = ev.pos, data = ev.data, item = ev.item, id = ev.id}
		elseif ev.type == "leave" then
			present[ev.subject_player] = nil
		end
	end
	local observers = observer_set(session)
	for pid, presence in pairs(present) do
		local row = deps.reader.last_movement(session.rec, pid, tick)
		local pos = (row and row.pos) or presence.pos
		local name = session.rec.players[pid]
		if pos and name then
			local obj = deps.ghost.spawn(name, deps.arena.translate(pos, offset),
				textures_of(presence.data), observers)
			if obj then
				session.ghosts[pid] = obj
				session.joined[pid] = true
				session.cursors[pid] = {last_tick = tick, rows = {}, next = 1, done = false}
				-- A recorded pose at T is what the player was wearing, whatever
				-- the movement sample suggests; without one the heuristic in
				-- ghost.update() poses the ghost as before.
				local animation = animation_data(deps.reader.last_animation(session.rec, pid, tick))
				if animation then
					session.animations[pid] = animation
					deps.ghost.animate(obj, animation)
				end
				if row then
					deps.ghost.update(obj, row, offset, animation ~= nil)
				end
				-- What the player held at T: the last wield event since they
				-- joined, or the join's own item before they switched. A fresh
				-- ghost holds nothing, so an empty hand needs no call. The id
				-- decides when there is a wield from before a leave: the join
				-- that brought the player back already says what they hold.
				local wielded = deps.reader.last_wield(session.rec, pid, tick)
				local item
				if wielded and wielded.id > (presence.id or 0) then
					item = wielded.item
				else
					item = presence.item
				end
				if item then deps.ghost.wield(obj, item) end
			end
		end
	end

	-- Particle spawners are engine objects whose definitions cannot be read
	-- back, so the recording's spawner events up to T are replayed: creates
	-- that were not deleted, and not those whose own (finite) lifetime ended
	-- before T. Their timers restart, which is all a seek can do to an engine
	-- spawner; a one-off particle from before T was over long ago and is not
	-- replayed.
	clear_spawners(session)
	for _, ev in ipairs(deps.reader.spawner_events_until(session.rec, tick)) do
		local data = event_data(ev.data)
		-- The tick is the coarse unit; a row of that tick may still be after T.
		if ev.t <= T and ev.type == "particlespawner" then
			if data and type(data.definition) == "table" and type(data.id) == "number" then
				local time = tonumber(data.definition.time)
				if not time or time <= 0 or ev.t + time > T then
					add_replay_spawner(session, data.id, data.definition)
				end
			end
		elseif ev.t <= T and data and data.id ~= nil then
			local replay_id = session.spawners[data.id]
			if replay_id then
				session.spawners[data.id] = nil
				core.delete_particlespawner(replay_id)
			end
		end
	end
end

local function apply_event(session, ev)
	if ev.type == "join" and ev.subject_player and not session.ghosts[ev.subject_player] then
		local name = session.rec.players[ev.subject_player]
		if name and ev.pos then
			local obj = deps.ghost.spawn(name, deps.arena.translate(ev.pos, session.offset),
				textures_of(ev.data), observer_set(session))
			if obj then
				session.ghosts[ev.subject_player] = obj
				session.joined[ev.subject_player] = true
				session.cursors[ev.subject_player] = {
					last_tick = ev.tick, rows = {}, next = 1, done = false,
				}
				if ev.item then deps.ghost.wield(obj, ev.item) end
			end
		end
	elseif ev.type == "leave" and ev.subject_player then
		remove_ghost(session, ev.subject_player)
		session.joined[ev.subject_player] = nil
	elseif ev.type == "wield" and ev.subject_player then
		-- An empty item (NULL in the file) puts the ghost's hands down.
		local obj = session.ghosts[ev.subject_player]
		if obj then deps.ghost.wield(obj, ev.item) end
	elseif ev.type == "animation" and ev.subject_player then
		local animation = animation_data(ev.data)
		if animation then
			session.animations[ev.subject_player] = animation
			local obj = session.ghosts[ev.subject_player]
			if obj then deps.ghost.animate(obj, animation) end
		end
	elseif ev.type == "particle" then
		-- A single particle is gone in a moment, so it is replayed at the
		-- moment the clock reaches it and never rebuilt by a seek.
		local data = event_data(ev.data)
		if data and type(data.definition) == "table" then
			local ok, err = pcall(core.add_particle,
				translated_definition(data.definition, session.offset))
			if not ok then
				complain(session, "particle", "cannot replay a particle: " .. tostring(err))
			end
		end
	elseif ev.type == "particlespawner" then
		local data = event_data(ev.data)
		if data and type(data.definition) == "table" and type(data.id) == "number" then
			add_replay_spawner(session, data.id, data.definition)
		end
	elseif ev.type == "particlespawner_delete" then
		local data = event_data(ev.data)
		local replay_id = data and data.id ~= nil and session.spawners[data.id]
		if replay_id then
			session.spawners[data.id] = nil
			core.delete_particlespawner(replay_id)
		end
	elseif ev.type == "chat_final" then
		-- Chat is transient like a one-off particle: it is shown when the clock
		-- reaches it, and a seek does not replay the backlog.
		if not session.chat then return end
		local data = event_data(ev.data)
		if data and type(data.message) == "string" then
			for name in pairs(session.participants) do
				core.chat_send_player(name, CHAT_PREFIX .. data.message)
			end
		end
	elseif ev.type == "node_change" then
		-- The arrays are written to the map once per step, however many nodes
		-- changed in it; a step with no node changes touches nothing. Only the
		-- block of each changed node is written, not the whole region.
		if deps.reconstruct.change(session.reconstruct, ev.pos, ev.node, ev.param2) then
			session.reconstruct_dirty = true
			deps.reconstruct.add_block(session.dirty_blocks, ev.pos, session.offset)
		end
	end
end

local function advance_events(session)
	local buffer = session.events
	while true do
		while buffer.next <= #buffer.rows do
			local ev = buffer.rows[buffer.next]
			if ev.t > session.T then return end
			buffer.next = buffer.next + 1
			apply_event(session, ev)
		end
		local more = deps.reader.events_after(session.rec, session.event_last_id, 500)
		if #more == 0 then return end
		session.event_last_id = more[#more].id
		buffer.rows = more
		buffer.next = 1
	end
end

local function advance_player(session, pid, obj, cursor)
	while true do
		while cursor.next <= #cursor.rows do
			local row = cursor.rows[cursor.next]
			if row.t > session.T then return end
			cursor.next = cursor.next + 1
			cursor.last_tick = row.tick
			if not deps.ghost.update(obj, row, session.offset,
				session.animations[pid] ~= nil) then
				remove_ghost(session, pid)
				return
			end
		end
		local more = deps.reader.movement_after(session.rec, pid, cursor.last_tick, 200)
		if #more == 0 then
			-- Nothing after this point yet. For a recording still being made
			-- that may change, but a cursor that has run out is not asked again
			-- every step.
			cursor.done = true
			return
		end
		cursor.rows = more
		cursor.next = 1
	end
end

-- Apply the metadata rows the clock has reached. Metadata does not need a
-- world write; it goes straight into the node it belongs to.
local function advance_metadata(session)
	local buffer = session.metadata_events
	while true do
		while buffer.next <= #buffer.rows do
			local row = buffer.rows[buffer.next]
			if row.t > session.T then return end
			buffer.next = buffer.next + 1
			deps.reconstruct.apply_metadata(session.offset, row)
		end
		local more = deps.reader.node_metadata_after(session.rec, session.metadata_last_id, 200)
		if #more == 0 then return end
		session.metadata_last_id = more[#more].id
		buffer.rows = more
		buffer.next = 1
	end
end

-- Apply the light changes the clock has reached. Returns whether any row was
-- applied; the caller decides whether the world needs rewriting (recorded
-- lighting) or the engine's own write-time lighting is enough (live).
local function advance_light(session)
	if not session.reconstruct.has_light then return false end
	local applied = false
	local buffer = session.light_events
	while true do
		while buffer.next <= #buffer.rows do
			local row = buffer.rows[buffer.next]
			if row.t > session.T then return applied end
			buffer.next = buffer.next + 1
			local ok, entries = deps.reconstruct.apply_light(
				session.reconstruct, row.data, row.encoding)
			if ok then
				applied = true
				-- Recorded light is written like node changes are; live light is
				-- recalculated by the engine from the nodes that changed.
				if light_write_mode(session) == "recorded" then
					deps.reconstruct.add_light_blocks(session.dirty_blocks,
						session.reconstruct, entries, session.offset)
				end
			end
		end
		local more = deps.reader.light_after(session.rec, session.light_last_id, 200)
		if #more == 0 then return applied end
		session.light_last_id = more[#more].id
		buffer.rows = more
		buffer.next = 1
	end
end

-- Switch between the light the recording holds and the light the arena's
-- world would give the same nodes. Returns the new mode, or nil when the
-- recording has no light to show.
---@param session table
---@return string|nil
function sessions.toggle_light(session)
	-- The switch is about whichever of the two the file has: recorded light
	-- values, a recorded time of day, or both.
	if not session.reconstruct.has_light and not session.rec.timeofday then
		return nil
	end
	session.light = session.light == "recorded" and "live" or "recorded"
	if session.reconstruct.has_light then
		local mode = light_write_mode(session)
		local written, err = deps.reconstruct.write(
			session.reconstruct, session.offset, mode)
		if not written then
			core.log("warning", "[replay] cannot rewrite the region's light: " .. tostring(err))
		else
			if mode == "live" then
				deps.arena.relight(session.arena)
			end
			session.reconstruct_tick = deps.reader.tick_at(session.rec, session.T)
			session.dirty_blocks = {}
			session.state_blocks = {}
		end
	end
	-- A file without a light layer needs no map write for a time-only switch;
	-- the day/night override below is the whole change.
	for name in pairs(session.participants) do
		local player = core.get_player_by_name(name)
		if player then deps.recovery.apply_day_night(player, session) end
	end
	return session.light
end

-- Whether capture is still writing this file. Capture may not be loaded, in
-- which case no file can be known to be in progress.
---@param path string
---@return boolean
local function unfinished(path)
	if type(recorder) ~= "table" or not recorder.list then return false end
	for _, entry in ipairs(recorder.list()) do
		if entry.path == path then return true end
	end
	return false
end

---@param session table
function sessions.start(arg, player)
	local limit = tonumber(core.settings:get("replay.max_sessions")) or 4
	if limit > 0 then
		local running = 0
		for _ in pairs(by_id) do running = running + 1 end
		if running >= limit then
			return nil, string.format("too many replays are running (%d)", running)
		end
	end
	local starter = player:get_player_name()
	if by_player[starter] then
		return nil, "you are already watching a replay"
	end

	local path, path_err = deps.reader.resolve(arg)
	if not path then return nil, path_err end
	if unfinished(path) and not core.settings:get_bool("replay.allow_unfinished") then
		return nil, "that recording is still being made; wait until it is finished"
	end
	local rec, rec_err = deps.reader.open(path, deps.sqlite)
	if not rec then return nil, rec_err end

	-- What the arena has to hold and where it goes are both known before the
	-- session exists; a recording without a snapshot has nothing to rebuild.
	local state, state_err = deps.reconstruct.load(rec)
	if not state then
		deps.reader.close(rec)
		return nil, state_err
	end
	local box, box_err = deps.arena.resolve(starter, state.region)
	if not box then
		deps.reader.close(rec)
		return nil, box_err
	end

	local id = new_id()
	-- The flag goes down before the first node: if the server dies between here
	-- and the end of the session, this is what tells the next boot what to
	-- clear. The arena itself is not remembered anywhere else.
	deps.arena.save_flag(box, id)
	local prepared, prepare_err = deps.arena.prepare(box)
	if not prepared then
		deps.arena.clear_flag(id)
		deps.arena.clear(box)
		deps.reader.close(rec)
		return nil, prepare_err
	end

	local session = {
		id = id,
		rec = rec,
		path = path,
		name = rec.name,
		T = 0,
		speed = 1,
		paused = true,
		chat = setting_on("replay.chat", true),  -- show recorded chat lines
		arena = box,
		offset = deps.arena.offset(box, state.region),
		reconstruct = state,
		reconstruct_dirty = false,
		reconstruct_tick = nil, -- tick of the state the arena's world holds
		dirty_blocks = {},      -- blocks changed since the last write
		state_blocks = {},      -- blocks changed since the last seek
		day_night = {},         -- participant -> the override they had before
		light = (state.has_light or rec.timeofday ~= nil) and "recorded" or "live",
		light_last_id = 0,
		light_events = {rows = {}, next = 1},
		participants = {},
		ghosts = {},
		cursors = {},
		joined = {},
		animations = {},       -- pid -> the recorded pose in force, if any
		spawners = {},         -- recorded spawner id -> the id replay was given
		events = {rows = {}, next = 1},
		event_last_id = 0,
		metadata_events = {rows = {}, next = 1},
		metadata_last_id = 0,
	}
	by_id[session.id] = session
	local joined, join_err = sessions.join(session, player)
	if not joined then
		-- The arena is already prepared; finish() takes it down again.
		sessions.finish(session, "could not start")
		return nil, join_err
	end
	sessions.seek(session, 0)
	session.paused = false
	-- The marks were this arena; the session now owns it, so they are not
	-- left behind to look like another pending one.
	if deps.arena.has_marks(starter) then deps.arena.clear_marks(starter) end
	core.log("action", string.format("[replay] session %s watching %s (%s)",
		session.id, session.name, path))
	return session
end

---@param session table
---@param player ObjectRef
---@param already_stashed boolean?
---@return boolean|nil, string?
function sessions.join(session, player, already_stashed)
	local name = player:get_player_name()
	if by_player[name] then
		return nil, "you are already watching a replay"
	end
	session.participants[name] = true
	by_player[name] = session
	deps.recovery.enter(player, session, already_stashed)
	sessions.update_observers(session)
	return true
end

---@param session table
---@param player ObjectRef
---@param disconnected boolean?  -- keep their stash for when they come back
function sessions.leave(session, player, disconnected)
	local name = player:get_player_name()
	if by_player[name] ~= session then return end
	by_player[name] = nil
	session.participants[name] = nil
	if not disconnected then
		deps.recovery.leave(player, session)
	end
	sessions.update_observers(session)
	if participant_count(session) == 0 then
		sessions.finish(session, "everyone left")
	end
end

---@param session table
---@param reason string?
function sessions.finish(session, reason)
	if session.ended then return end
	session.ended = true
	for pid in pairs(session.ghosts) do remove_ghost(session, pid) end
	-- Spawners outlive the nodes they were born over; they are engine objects
	-- and have to be cancelled before the arena they emit into is gone.
	clear_spawners(session)
	-- The reconstruction shares the arena with the ghosts and the viewers, so
	-- it goes with them; wiping the box is enough to remove every node of it.
	deps.arena.clear(session.arena)
	for name in pairs(session.participants) do
		local player = core.get_player_by_name(name)
		if player then deps.recovery.leave(player, session) end
		by_player[name] = nil
	end
	session.participants = {}
	deps.arena.clear_flag(session.id)
	deps.reader.close(session.rec)
	by_id[session.id] = nil
	core.log("action", string.format("[replay] session %s ended: %s",
		session.id, tostring(reason)))
end

-- A participant who disconnects stays a participant: their stash waits for
-- them, and a rejoin puts them back in the session.
---@param player ObjectRef
function sessions.on_disconnect(player)
	local name = player:get_player_name()
	local session = by_player[name]
	if not session then return end
	sessions.leave(session, player, true)
end

---@param dtime number
function sessions.step_all(dtime)
	for _, session in pairs(by_id) do
		if not session.paused and participant_count(session) > 0 then
			session.T = session.T + dtime * session.speed
			if session.T >= session.rec.duration then
				session.T = session.rec.duration
				session.paused = true
			end
			advance_events(session)
			advance_metadata(session)
			if advance_light(session) and session.light == "recorded" then
				session.reconstruct_dirty = true
			end
			if session.reconstruct_dirty then
				session.reconstruct_dirty = false
				local written, err
				if next(session.dirty_blocks) then
					written, err = deps.reconstruct.write_blocks(
						session.reconstruct, session.offset, session.dirty_blocks,
						light_write_mode(session))
					-- Remember them until the next seek even if the write failed:
					-- the seek rewrites the union and can repair it.
					for key, block in pairs(session.dirty_blocks) do
						session.state_blocks[key] = block
					end
					session.dirty_blocks = {}
				else
					written = true
				end
				if not written then
					core.log("warning", "[replay] cannot apply a node change: " .. tostring(err))
				end
			end
			for pid, obj in pairs(session.ghosts) do
				local cursor = session.cursors[pid]
				if cursor and not cursor.done then
					advance_player(session, pid, obj, cursor)
				end
			end
		end
	end
end

return sessions
