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

-- Everyone watching sees every ghost; anyone else sees none of them.
---@param session table
function sessions.update_observers(session)
	local set = observer_set(session)
	for _, obj in pairs(session.ghosts) do
		deps.ghost.set_observers(obj, set)
	end
end

local function textures_of(json)
	if not json then return nil end
	local ok, data = pcall(core.parse_json, json)
	if ok and type(data) == "table" and type(data.textures) == "table" then
		return data.textures
	end
	return nil
end

local function remove_ghost(session, pid)
	local obj = session.ghosts[pid]
	if obj and obj.remove then obj:remove() end
	session.ghosts[pid] = nil
	session.cursors[pid] = nil
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
	local tick = deps.reader.tick_at(session.rec, T)
	session.event_last_id = deps.reader.last_event_id(session.rec, tick)
	session.events = {rows = {}, next = 1}
	session.reconstruct_dirty = false

	deps.reconstruct.seek(session.reconstruct, session.rec, tick)
	local rebuilt, rebuild_err = deps.reconstruct.write(session.reconstruct, session.offset)
	if not rebuilt then
		core.log("warning", "[replay] cannot rebuild the region: " .. tostring(rebuild_err))
	else
		-- A seek rewrites the whole region at once; the light of the blocks
		-- around it needs the same full pass as the arena itself.
		deps.arena.relight(session.arena)
	end

	local offset = session.offset
	local present = {}
	for _, ev in ipairs(deps.reader.join_leave_until(session.rec, tick)) do
		if ev.type == "join" and ev.subject_player then
			present[ev.subject_player] = {pos = ev.pos, data = ev.data}
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
				if row then deps.ghost.update(obj, row, offset) end
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
			end
		end
	elseif ev.type == "leave" and ev.subject_player then
		remove_ghost(session, ev.subject_player)
		session.joined[ev.subject_player] = nil
	elseif ev.type == "node_change" then
		-- The arrays are written to the map once per step, however many nodes
		-- changed in it; a step with no node changes touches nothing.
		if deps.reconstruct.change(session.reconstruct, ev.pos, ev.node, ev.param2) then
			session.reconstruct_dirty = true
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
			deps.ghost.update(obj, row, session.offset)
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
		arena = box,
		offset = deps.arena.offset(box, state.region),
		reconstruct = state,
		reconstruct_dirty = false,
		participants = {},
		ghosts = {},
		cursors = {},
		joined = {},
		events = {rows = {}, next = 1},
		event_last_id = 0,
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
			if session.reconstruct_dirty then
				session.reconstruct_dirty = false
				local written, err = deps.reconstruct.write(session.reconstruct, session.offset)
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
