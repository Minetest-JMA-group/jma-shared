-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- recorder – write down what happens on the server, in order, into SQLite.
--
-- One recording is one SQLite file holding the actions players perform, the
-- per-tick kinematics that go with them, and whatever metadata other mods
-- attach. The file is meant to be read back later: replaying it, analysing it
-- or just reading it with the sqlite3 shell. See README.md for the schema, the
-- recorded event types and the API.

local FLUSH_DEFAULT = 2.0         -- seconds of server time between commits
local MAX_BUFFERED_DEFAULT = 20000
local MAX_FAILURES = 10           -- failed commits in a row before giving up
-- Everything the recorder writes about the recording itself lives under this
-- prefix, so mods cannot overwrite it by accident and the recorder knows which
-- keys are its own.
local META_PREFIX = "recorder."

-- The events a recording cannot be read for what it is without: where it starts
-- and stops, where its holes are, and the changes that keep its snapshot true.
local MANDATORY_EVENTS = {
	recording_start = true,
	recording_stop = true,
	write_error = true,
	node_change = true,
}

-- Events that describe the recording rather than the region, and that must not
-- be judged by a position: a leave has no position left to judge when the
-- player has already gone.
local REGION_EXEMPT = {
	recording_start = true,
	recording_stop = true,
	write_error = true,
	join = true,
	leave = true,
}

recorder = {}

local sqlite = algorithms.require("lsqlite3")
if not sqlite then
	local msg = "[recorder] lsqlite3 needed for operation. Make sure that the library is" ..
		" installed and recorder is added to secure.c_mods or secure.trusted_mods"
	core.log("error", msg)
	local unavailable = "recorder is unavailable: " .. msg
	---@param record_name string?
	recorder.start = function(record_name) return unavailable end
	---@param reason string?
	recorder.stop = function(reason) return unavailable end
	---@param key string
	---@param value string
	recorder.add_meta = function(key, value) return unavailable end
	---@param event_type string
	---@param fields table?
	recorder.log_event = function(event_type, fields) return unavailable end
	recorder.is_recording = function() return false end
	recorder.get_recording_name = function() return nil end
	recorder.get_recording_path = function() return nil end
	-- The command is registered all the same: an operator typing /recorder is
	-- owed the reason it does nothing, rather than "unknown command".
	core.register_chatcommand("recorder", {
		description = "Control the action recorder",
		params = "",
		privs = { server = true },
		func = function() return false, unavailable end,
	})
	return
end

local modpath = core.get_modpath(core.get_current_modname())
---@type DBManager
local dbmanager = dofile(modpath .. "/dbmanager.lua")
dbmanager.init(sqlite)
local snapshot_module = dofile(modpath .. "/snapshot.lua")
local region_module = recorder_common.region

local state = {
	recording = false,
	name = nil,          -- sanitized recording name
	path = nil,          -- path of the SQLite file
	started_at = nil,    -- os.time() when the recording was asked for
	tick = 0,            -- server steps since the recording started
	elapsed = 0,         -- server seconds since the recording started
	last_flush = 0,
	flush_interval = FLUSH_DEFAULT,
	max_buffered = MAX_BUFFERED_DEFAULT,
	max_duration = 0,    -- server seconds; 0 = no limit
	max_size = 0,        -- bytes; 0 = no limit
	disabled = {},       -- event types not to record
	complaints = {},     -- what has already been reported, so it is said once
	player_errors = {},  -- players whose row could not be written (said once)
	troubles = {},       -- what to write down about them, for the file
	troubles_dirty = false,
	pending_start = false,   -- the opening state is taken at the next step
	region = nil,        -- the cuboid this recording covers
	snapshot = nil,      -- the snapshot phase, while it runs
	snapshot_budget = 20000,  -- region nodes examined per step while snapshotting
	sampled = {},        -- player id -> name, from the last pass through the region
	known_ids = nil,     -- region flat index -> content id, what the recording knows
	known_param2 = nil,  -- and the param2 that goes with it
	pending_blocks = {}, -- mapblock changes waiting to be diffed, with their tick
	prev = {},           -- player id -> last sample, for deriving acceleration
	written = {},        -- player id -> last sample written, to spot no-ops
	wield = {},          -- player id -> last wielded itemstring
	joined = {},         -- player ids that are in the recording as present
}

-- Per-player region marks, kept between recordings. A mark dies with the
-- player's connection, so one that is forgotten cannot surprise the next person.
local marks = {}

-- Movement sample layout: what sample_state() produces, in order. The same
-- values go into the Movement table, with acceleration at 9-11 and the rest
-- packed around them.
local S_POS_X, S_POS_Y, S_POS_Z = 1, 2, 3
local S_PITCH, S_YAW = 4, 5
local S_VEL_X, S_VEL_Y, S_VEL_Z = 6, 7, 8
local S_ACC_X, S_ACC_Y, S_ACC_Z = 9, 10, 11
local S_SPEED, S_CONTROLS, S_MOVE_X, S_MOVE_Y = 12, 13, 14, 15
local S_COUNT = 15

-- The button bits of the controls column, in the order the engine documents
-- for ObjectRef:get_player_control_bits(), so the two can be compared.
local CONTROLS = { "up", "down", "left", "right", "jump", "aux1", "sneak", "dig", "place", "zoom" }
local CONTROL_BIT = { 1, 2, 4, 8, 16, 32, 64, 128, 256, 512 }

local function log_error(msg)
	core.log("error", "[recorder] " .. msg)
end

-- One report per kind of trouble per recording: a callback that fires every
-- tick must not turn a single problem into a log full of them.
local function complain(label, message)
	if state.complaints[label] then return end
	state.complaints[label] = true
	log_error(message)
end

-- Something the engine hands over can always turn out to be unreadable, and one
-- player that cannot be dealt with must not cost the rest of the recording.
local function guarded(label, func, ...)
	local ok, err = pcall(func, ...)
	if not ok then
		complain(label, "cannot " .. label .. ": " .. tostring(err))
	end
end

-- Declared here because the helpers below can end up wanting to write an event
-- of their own, while the event writer needs the players those helpers resolve.
local record_event

-- Players whose row could not be written: the recording would otherwise hold
-- events with no subject and nothing to explain them. This goes into the
-- metadata rather than into the event buffer, so that it does not share the
-- fate of a batch that fails later, and it is attempted again after every
-- commit that goes through in case the trouble stopped the note too.
local function write_troubles()
	if not state.troubles_dirty then return end
	local ok = dbmanager.set_meta(META_PREFIX .. "player_errors", table.concat(state.troubles, "; "))
	if ok then
		state.troubles_dirty = false
	end
end

local function note_player_error(name, message)
	state.troubles[#state.troubles + 1] = string.format("%s (%s)", name, tostring(message))
	state.troubles_dirty = true
	write_troubles()
end

----------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------

-- The name a player ObjectRef carries, for the pcall below: everything else in
-- here is allowed to raise.
local function name_of(obj)
	if core.is_player(obj) then
		return obj:get_player_name()
	end
end

-- The name of a player ObjectRef, a player name, or nil for anything else
-- (a mob, an explosion, an already removed object).
---@param obj ObjectRef|string|nil
---@return string|nil
local function player_name(obj)
	if obj == nil then return nil end
	if type(obj) == "string" then return obj end
	local ok, name = pcall(name_of, obj)
	if ok then return name end
	return nil
end

-- Id of whoever this is, and a report the first time their row cannot be
-- written. It is asked again the next time they are seen, so a database that
-- was busy for a moment does not cost the recording a player for good.
---@return integer|nil
local function player_id(obj)
	local name = player_name(obj)
	if not name then return nil end
	local id, err = dbmanager.player_id(name)
	if not id and not state.player_errors[name] then
		state.player_errors[name] = true
		log_error(tostring(err))
		note_player_error(name, err)
	end
	return id
end

-- What an object that is not a player says it is, for the pcall below.
local function description_of(obj)
	local ent = obj:get_luaentity()
	if ent and ent.name then
		return "entity:" .. ent.name
	end
	return "object"
end

-- How to name an actor that is not a player, for data.actor.
local function describe_object(obj)
	local ok, desc = pcall(description_of, obj)
	if ok and desc then return desc end
	return "unknown"
end

-- Subject of an event performed by an object that may or may not be a player.
-- A player becomes subject_player; anything else has no Players row to point
-- at, so it is described in data.actor instead.
local function set_actor(ev, obj)
	if obj == nil then return end
	if player_name(obj) then
		ev.subject = obj
	else
		ev.data = ev.data or {}
		ev.data.actor = describe_object(obj)
	end
end

-- A position from the engine or from a mod, as three numbers or nothing.
local function position_of(pos)
	if type(pos) ~= "table" then return nil end
	local x, y, z = tonumber(pos.x), tonumber(pos.y), tonumber(pos.z)
	if not (x and y and z) then return nil end
	return x, y, z
end

-- Where an object is, if it can still be read. A name is looked up; an object
-- that has gone away answers nothing.
---@param obj ObjectRef|string|nil
---@return table|nil
local function position_of_object(obj)
	if obj == nil then return nil end
	if type(obj) == "string" then
		obj = core.get_player_by_name(obj)
		if not obj then return nil end
	end
	local ok, pos = pcall(function() return obj:get_pos() end)
	if ok then return pos end
	return nil
end

-- Does this event belong inside the region? The subject, and the object when
-- there is one, must be inside; an event with no player in it (a mob's dig, an
-- explosion) is judged by the position it is about. An event whose subject
-- cannot be read any more is left out rather than guessed at.
---@param ev table
---@return boolean
local function event_in_region(ev)
	local reg = state.region
	if not reg then return true end
	if ev.subject == nil and ev.object == nil then
		-- Nothing in it is a player. A position, when there is one, decides; an
		-- event with neither (a mod's own note about the match) says nothing
		-- that could lie outside the region.
		if ev.pos == nil then return true end
		local x, y, z = position_of(ev.pos)
		return x ~= nil and region_module.contains(reg, {x = x, y = y, z = z})
	end
	if ev.subject ~= nil then
		local pos = position_of_object(ev.subject)
		if not pos or not region_module.contains(reg, pos) then return false end
	end
	if ev.object ~= nil then
		local pos = position_of_object(ev.object)
		if not pos or not region_module.contains(reg, pos) then return false end
	end
	return true
end

-- The itemstring of a stack, for the pcall below.
local function itemstring_of(stack)
	return stack:to_string()
end

---@param obj ObjectRef|ItemStack|string|nil
---@return string|nil
local function stack_string(obj)
	if obj == nil then return nil end
	if type(obj) == "string" then
		return obj ~= "" and obj or nil
	end
	local ok, str = pcall(itemstring_of, obj)
	if ok and str and str ~= "" then return str end
	return nil
end

-- The itemstring of the stack an object is holding, or "" - the empty stack and
-- an object that holds nothing are the same thing here.
local function held_stack(obj)
	local stack = obj:get_wielded_item()
	return stack and stack:to_string() or ""
end

local function wielded(obj)
	if obj == nil then return "" end
	local ok, str = pcall(held_stack, obj)
	if ok and type(str) == "string" then return str end
	return ""
end

-- param2 is an INTEGER column, and SQLite refuses to put a fractional real in
-- one, so a value like that is rounded rather than allowed to cost the row.
local function param2_of(param2)
	local value = tonumber(param2)
	if not value then return nil end
	return math.floor(value)
end

local function vector_data(vec)
	if type(vec) ~= "table" then return nil end
	return { x = vec.x, y = vec.y, z = vec.z }
end

local function control_bits(controls)
	local bits = 0
	for i = 1, #CONTROLS do
		if controls[CONTROLS[i]] then
			bits = bits + CONTROL_BIT[i]
		end
	end
	return bits
end

-- Event data is a JSON object. A value that cannot be serialized must not cost
-- us the callback (and certainly not the action it describes), so the rest of
-- the fields are dropped rather than the whole event.
local function encode_data(data)
	if not next(data) then
		-- The engine writes an empty table as JSON null, which is not the
		-- object the column is documented to hold; no data means NULL.
		return nil
	end
	local ok, json, err = pcall(core.write_json, data)
	if not ok then
		log_error("cannot serialize event data: " .. tostring(json))
		return nil
	end
	if not json then
		log_error("cannot serialize event data: " .. tostring(err))
		return nil
	end
	return json
end

-- The HP change reason of a death or a damage event, with the ObjectRef in it
-- replaced by something a JSON file can hold.
local function describe_reason(reason)
	if type(reason) ~= "table" then return nil end
	local out = {
		type = reason.type,
		custom_type = reason.custom_type,
		from = reason.from,
		node = reason.node,
		node_pos = vector_data(reason.node_pos),
	}
	if reason.object ~= nil then
		out.object = player_name(reason.object) or describe_object(reason.object)
	end
	if not next(out) then return nil end
	return out
end

-- Every list of the player's inventory, as itemstrings, slot for slot; an
-- empty string is an empty slot. Game rules like "which flag does the player
-- carry" are only replayable if an inventory is known at least at the points
-- where the player enters the recording.
local function inventory_snapshot(player)
	local ok, result = pcall(function()
		local inv = player:get_inventory()
		if not inv then return nil end
		local lists = inv:get_lists()
		local out = {}
		for listname, list in pairs(lists) do
			local items = {}
			for i, stack in ipairs(list) do
				items[i] = stack_string(stack) or ""
			end
			out[listname] = items
		end
		if not next(out) then return nil end
		return out
	end)
	if ok then return result end
	return nil
end

----------------------------------------------------------------------------
-- Writing events
----------------------------------------------------------------------------

-- Everything in a row comes either from the engine or from a mod, so it is made
-- to fit the column it goes into right here: a value SQLite refuses would cost
-- not just this event but every row buffered beside it.
---@param ev table
record_event = function(ev)
	if not state.recording then return end
	if type(ev.type) ~= "string" or ev.type == "" then
		complain("event without a type", "cannot record an event whose type is not a name")
		return
	end
	if not REGION_EXEMPT[ev.type] and not event_in_region(ev) then return end
	if state.disabled[ev.type] then return end
	local x, y, z = position_of(ev.pos)
	dbmanager.add_event({
		dbmanager.next_id(), ev.tick or state.tick, ev.t or state.elapsed, ev.type,
		player_id(ev.subject), player_id(ev.object),
		x, y, z,
		type(ev.node) == "string" and ev.node or nil,
		param2_of(ev.param2), stack_string(ev.item),
		ev.data and encode_data(ev.data) or nil,
	})
end

----------------------------------------------------------------------------
-- Per-tick sampling
----------------------------------------------------------------------------

local function sample_state(player, pid, dtime)
	local pos = player:get_pos()
	if not pos then return nil end
	local vel = player:get_velocity() or { x = 0, y = 0, z = 0 }
	local prev = state.prev[pid]
	local acc_x, acc_y, acc_z
	if prev and dtime > 0 then
		acc_x = (vel.x - prev[S_VEL_X]) / dtime
		acc_y = (vel.y - prev[S_VEL_Y]) / dtime
		acc_z = (vel.z - prev[S_VEL_Z]) / dtime
	end
	local controls = player:get_player_control() or {}
	local sample = {
		pos.x, pos.y, pos.z,
		player:get_look_vertical() or 0,
		player:get_look_horizontal() or 0,
		vel.x, vel.y, vel.z,
		acc_x, acc_y, acc_z,
		math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z),
		control_bits(controls),
		controls.movement_x or 0,
		controls.movement_y or 0,
	}
	state.prev[pid] = sample
	return sample
end

local function same_state(a, b)
	for i = 1, S_COUNT do
		if a[i] ~= b[i] then return false end
	end
	return true
end

-- One player's sample for this tick. Samples identical to the last written one
-- are left out - a reader carries the previous row forward, and acceleration
-- is part of the comparison, so a sample only disappears when it says nothing
-- new. That is what keeps a recording from growing while players stand still.
local function record_player(player, dtime)
	local name = player_name(player)
	if not name then return end
	local pid = dbmanager.player_id(name)
	if not pid then return end
	local sample = sample_state(player, pid, dtime)
	if not sample then return end

	local wield = wielded(player)
	if state.wield[pid] ~= wield then
		state.wield[pid] = wield
		-- Tools wear out as they are used, so this is also where a degrading
		-- tool shows up.
		record_event({ type = "wield", subject = name, item = stack_string(wield) })
	end

	local last = state.written[pid]
	if last and same_state(sample, last) then return end
	state.written[pid] = sample
	dbmanager.add_movement({
		dbmanager.next_id(), state.tick, state.elapsed, dtime, pid,
		sample[S_POS_X], sample[S_POS_Y], sample[S_POS_Z],
		sample[S_PITCH], sample[S_YAW],
		sample[S_VEL_X], sample[S_VEL_Y], sample[S_VEL_Z],
		sample[S_ACC_X], sample[S_ACC_Y], sample[S_ACC_Z],
		sample[S_SPEED], sample[S_CONTROLS],
		sample[S_MOVE_X], sample[S_MOVE_Y],
	})
end

-- What can be read about a player at this moment. A player object that has
-- already gone away (which a join at the start of a recording can meet) is not
-- a reason to lose the join itself, let alone to fail whoever asked for the
-- recording.
local function player_snapshot(player)
	local ok, snapshot = pcall(function()
		return {
			pos = player:get_pos(),
			hp = player:get_hp(),
			breath = player:get_breath(),
			pitch = player:get_look_vertical(),
			yaw = player:get_look_horizontal(),
			inventory = inventory_snapshot(player),
		}
	end)
	if ok and snapshot then return snapshot end
	return {}
end

-- A player enters the recording: by joining the game inside the region, by
-- being online in it when the recording starts (at_start), or by walking into
-- it (reason "region").
local function on_join(player, last_login, at_start, reason)
	local name = player_name(player)
	if not name then return end
	-- A player who joins the game outside the region is not in the recording
	-- yet; the next pass through the region will join them there.
	local pos = position_of_object(player)
	if state.region and not (pos and region_module.contains(state.region, pos)) then
		return
	end
	local pid = dbmanager.player_id(name)
	local wield = wielded(player)
	if pid then
		-- The join event itself carries the wielded stack, so this only records
		-- the baseline that later changes are compared against.
		state.wield[pid] = wield
	end
	local snapshot = player_snapshot(player)
	if pid then
		state.joined[pid] = true
	end
	record_event({
		type = "join",
		subject = name,
		pos = snapshot.pos,
		item = stack_string(wield),
		data = {
			at_start = at_start or nil,
			last_login = last_login,
			reason = reason,
			hp = snapshot.hp,
			breath = snapshot.breath,
			pitch = snapshot.pitch,
			yaw = snapshot.yaw,
			inventory = snapshot.inventory,
		},
	})
end

local function on_leave(player, timed_out)
	local name = player_name(player)
	if not name then return end
	local pid = dbmanager.player_id(name)
	-- A player who was never in the recording (they stayed outside the region)
	-- has nothing to leave from.
	if not pid or not state.joined[pid] then return end
	-- Where they were when they left is what a reader following their trail
	-- has to end on. The engine is free to have let go of the object by now, so
	-- a player that cannot be read is recorded without a position.
	local read, pos = pcall(function() return player:get_pos() end)
	record_event({
		type = "leave",
		subject = name,
		pos = read and pos or nil,
		data = { timed_out = timed_out or nil },
	})
	-- Whatever the player does after rejoining has no relation to these,
	-- and the first sample after a rejoin has no previous velocity.
	state.prev[pid] = nil
	state.written[pid] = nil
	state.wield[pid] = nil
	state.joined[pid] = nil
end

-- One pass through the region: sample the players in it, and note who walked
-- in or out since the last pass. Everything in a recording is inside the
-- region, so a player who leaves it leaves the recording until they return.
local function observe_region(dtime)
	local reg = state.region
	local seen = {}
	for player in core.objects_in_area(reg.pos1, reg.pos2) do
		if core.is_player(player) then
			local name = player_name(player)
			if name then
				local pid = player_id(name)
				if pid then
					seen[pid] = name
					if not state.joined[pid] then
						-- They were outside when the recording started, or have
						-- walked in since; either way they enter the recording here.
						guarded("record a join", on_join, player, nil, false, "region")
					end
					-- A player who could not be joined is not sampled either: a
					-- movement trail that begins without a join would leave a
					-- reader without the state the trail starts from.
					if state.joined[pid] then
						guarded("sample a player", record_player, player, dtime)
					end
				end
			end
		end
	end
	for pid, name in pairs(state.sampled) do
		if not seen[pid] and state.joined[pid] then
			-- They are still in the game but out of the region: their trail
			-- ends where it was last sampled.
			local last = state.prev[pid]
			record_event({
				type = "leave",
				subject = name,
				pos = last and {x = last[S_POS_X], y = last[S_POS_Y], z = last[S_POS_Z]} or nil,
				data = { reason = "region" },
			})
			state.joined[pid] = nil
			state.prev[pid] = nil
			state.written[pid] = nil
			state.wield[pid] = nil
		end
	end
	state.sampled = seen
end

----------------------------------------------------------------------------
-- The recording file
----------------------------------------------------------------------------

-- Where recordings live, how they are named and how a reader opens one are
-- shared with the replay half; see recorder_common.

-- Size a reader would care about: the file plus the pages still in the
-- write-ahead log, since those are part of the recording too.
local function recording_size(path)
	local total = 0
	for _, suffix in ipairs({ "", "-wal" }) do
		local f = io.open(path .. suffix, "rb")
		if f then
			total = total + (f:seek("end") or 0)
			f:close()
		end
	end
	return total
end

local function write_meta(key, value)
	if value == nil then return end
	local ok, err = dbmanager.set_meta(key, value)
	if not ok then
		log_error(string.format("cannot write metadata %s: %s", key, tostring(err)))
	end
end

----------------------------------------------------------------------------
-- Committing
----------------------------------------------------------------------------

-- Assigned once the API exists; a stop triggered from inside the sampling can
-- reach it from here.
local stop_recording

-- Buffered rows are committed in batches: one transaction a couple of seconds
-- instead of one per action. The same rows end up on disk, but the server is
-- not made to wait for a disk synchronization for each of them.
local function maybe_flush()
	if state.max_duration > 0 and state.elapsed >= state.max_duration then
		stop_recording("limit_duration")
		return
	end
	if state.max_size > 0 and recording_size(state.path) >= state.max_size then
		stop_recording("limit_size")
		return
	end
	-- 0 means the interval alone decides when to commit
	local crowded = state.max_buffered > 0 and dbmanager.buffered() >= state.max_buffered
	if not crowded and (state.elapsed - state.last_flush) < state.flush_interval then
		return
	end
	state.last_flush = state.elapsed
	local ok, err, lost = dbmanager.flush()
	if ok then
		write_troubles()
		return
	end
	log_error(string.format("cannot write %d rows to %s: %s", lost or 0, tostring(state.path), tostring(err)))
	-- The rows are gone, so what was last written is no longer what a reader
	-- would carry forward: every player's next sample is written again rather
	-- than looking like a quiet tick, and a held item that changed in the lost
	-- rows is announced again instead of going unmentioned.
	state.written, state.wield = {}, {}
	record_event({
		type = "write_error",
		data = { dropped_rows = lost, message = err },
	})
	-- The database counts the failed commits itself, and clears the count on the
	-- first one that goes through, so there is one answer to "is this recording
	-- in trouble" rather than two that can drift apart.
	if dbmanager.stats().failed >= MAX_FAILURES then
		log_error("giving up on the recording after repeated write failures")
		stop_recording("write_error")
	end
end

----------------------------------------------------------------------------
-- API
----------------------------------------------------------------------------

-- Resolve the region a recording covers. A region handed in wins; otherwise the
-- game may provide one. Marks are resolved by the chat command, which knows who
-- asked.
---@param region_arg table?  -- {pos1 =, pos2 =}
---@return table|nil, string?
local function resolve_region(region_arg)
	if region_arg then
		return region_module.normalize(region_arg.pos1, region_arg.pos2)
	end
	local provider = recorder_common.game_hooks.region
	if provider then
		local ok, pos1, pos2 = pcall(provider)
		if ok and pos1 and pos2 then
			local normalized, err = region_module.normalize(pos1, pos2)
			if normalized then return normalized end
			return nil, err
		end
	end
	return nil, "a recording needs a region: mark two corners with /recorder pos1 and /recorder pos2," ..
		" or let the game provide one"
end

-- The recording did not become one: close the file and take it away, so a
-- failed start leaves nothing behind that looks like a recording.
---@param reason string
local function abort_start(reason)
	local path = state.path
	log_error(string.format("cannot start a recording in %s: %s", tostring(path), tostring(reason)))
	dbmanager.close()
	if path then
		os.remove(path)
		os.remove(path .. "-wal")
		os.remove(path .. "-shm")
	end
	state.recording = false
	state.snapshot = nil
	state.region = nil
	state.known_ids, state.known_param2 = nil, nil
	state.pending_blocks = {}
	state.name, state.path = nil, nil
end

-- The snapshot is done: the file can say what the world looked like, and the
-- recording proper begins.
---@param result table
local function finish_start(result)
	local ok, err = dbmanager.set_snapshot({
		tick = 0,
		t = 0,
		pos1 = state.region.pos1,
		size = region_module.size(state.region),
		names = table.concat(result.names, "\n"),
		encoding = result.encoding,
		data = result.data,
	})
	if not ok then
		abort_start(err)
		return
	end
	state.known_ids = result.ids
	state.known_param2 = result.param2

	-- The schema version is not repeated here: PRAGMA user_version is where the
	-- file keeps it, and it is the version of the file rather than of the mod.
	write_meta(META_PREFIX .. "name", state.name)
	write_meta(META_PREFIX .. "started_at", os.date("!%Y-%m-%dT%H:%M:%SZ", state.started_at))
	local version = core.get_version()
	write_meta(META_PREFIX .. "server_version", version and version.string or nil)
	local game = core.get_game_info()
	write_meta(META_PREFIX .. "game", game and game.id or nil)
	state.recording = true
	state.snapshot = nil
	record_event({ type = "recording_start" })
	-- Who is online and what the world time is has to wait for the first server
	-- step: a mod is allowed to start a recording while it loads, and the
	-- engine refuses those questions before the server is running.
	state.pending_start = true
	local flushed, flush_err = dbmanager.flush()
	if not flushed then
		abort_start(flush_err)
		return
	end
	core.log("action", "[recorder] recording " .. state.name .. " started, writing to " .. state.path)
end

-- One step of the snapshot phase. The recording is not active yet, so events
-- and samples are dropped by the same gate that drops them when nothing is
-- being recorded.
local function advance_snapshot()
	local snap = state.snapshot
	if not snap then return end
	local status, result = snapshot_module.step(snap, state.snapshot_budget)
	if status == "working" then return end
	if status == "failed" then
		snapshot_module.free(snap)
		state.snapshot = nil
		abort_start(result)
		return
	end
	state.snapshot = nil
	snapshot_module.free(snap)
	finish_start(result)
end

---@param record_name string?  -- used for the file name; "unnamed" if not given
---@param region_arg table?  -- {pos1 =, pos2 =}; the game may provide one instead
---@return nil|string  -- nil on success, an error message on failure
recorder.start = function(record_name, region_arg)
	if state.recording or state.snapshot then
		return "a recording is already in progress: " .. tostring(state.path)
	end
	local region, region_err = resolve_region(region_arg)
	if not region then
		return region_err
	end
	local name = recorder_common.sanitize_name(record_name)
	local dir = recorder_common.recordings_dir()
	local now = os.time()
	-- An already existing directory is not an error, and the open below is
	-- what actually decides whether the directory is usable.
	core.mkdir(dir)
	local path = recorder_common.unique_path(dir, name .. "-" .. os.date("!%Y%m%dT%H%M%SZ", now))
	if not path then
		return "too many recordings named " .. name .. " in " .. dir
	end
	local ok, err = dbmanager.open(path)
	if not ok then
		log_error(tostring(err))
		return err
	end

	-- Read here rather than at load time, so that a setting changed between two
	-- recordings applies to the next one.
	state.flush_interval = tonumber(core.settings:get("recorder.flush_interval")) or FLUSH_DEFAULT
	state.max_buffered = tonumber(core.settings:get("recorder.max_buffered")) or MAX_BUFFERED_DEFAULT
	state.max_duration = tonumber(core.settings:get("recorder.max_duration")) or 0
	state.max_size = (tonumber(core.settings:get("recorder.max_size_mb")) or 0) * 1024 * 1024
	state.disabled = {}
	for type_name in (core.settings:get("recorder.disabled_events") or ""):gmatch("[^,%s]+") do
		-- What the recording needs in order to explain itself - where it
		-- starts and stops, and where a gap is - is not a matter of taste.
		if MANDATORY_EVENTS[type_name] then
			log_error("the " .. type_name .. " event is always recorded; ignoring the setting for it")
		else
			state.disabled[type_name] = true
		end
	end

	-- The recording proper starts when the snapshot is done; until then
	-- state.recording stays false and the existing gate drops events.
	state.recording = false
	state.name = name
	state.path = path
	state.started_at = now
	state.region = region
	state.tick = 0
	state.elapsed = 0
	state.last_flush = 0
	state.complaints, state.player_errors = {}, {}
	state.troubles, state.troubles_dirty = {}, false
	state.prev, state.written, state.wield, state.joined = {}, {}, {}, {}
	state.sampled = {}
	state.known_ids, state.known_param2 = nil, nil
	state.pending_blocks = {}
	state.snapshot_budget = math.max(1,
		math.floor(tonumber(core.settings:get("recorder.snapshot_budget")) or 20000))

	local snap, snap_err = snapshot_module.new(region.pos1, region.pos2)
	if not snap then
		abort_start(snap_err)
		return snap_err
	end
	state.snapshot = snap
	core.log("action", string.format("[recorder] snapshotting %s .. %s for %s, writing to %s",
		core.pos_to_string(region.pos1), core.pos_to_string(region.pos2), name, path))
	return nil
end

-- Stop the recording in progress. The optional reason is stored in the
-- recording (and is what the automatic stops use).
---@param reason string?
---@return nil|string  -- nil on success, an error message on failure
recorder.stop = function(reason)
	if state.snapshot then
		-- The recording never became one: there is nothing to mark in the file,
		-- and a file that was never a recording should not be left behind.
		local path = state.path
		snapshot_module.free(state.snapshot)
		state.snapshot = nil
		dbmanager.close()
		if path then
			os.remove(path)
			os.remove(path .. "-wal")
			os.remove(path .. "-shm")
		end
		state.recording = false
		state.region = nil
		state.known_ids, state.known_param2 = nil, nil
		state.pending_blocks = {}
		state.sampled = {}
		state.name, state.path = nil, nil
		core.log("action", "[recorder] recording abandoned while snapshotting; the file is gone")
		return nil
	end
	if not state.recording then
		return "no recording is in progress"
	end
	record_event({ type = "recording_stop", data = { reason = reason or "api" } })
	local name, path = state.name, state.path
	state.recording = false
	-- The end marker and the last rows go out first, and the metadata only
	-- follows if they made it: a file whose events have no ending must not
	-- claim, in its own metadata, that it stopped cleanly.
	local ok, err = dbmanager.flush()
	if ok then
		write_meta(META_PREFIX .. "stopped_at", os.date("!%Y-%m-%dT%H:%M:%SZ", os.time()))
		write_meta(META_PREFIX .. "ticks", tostring(state.tick))
		write_meta(META_PREFIX .. "end_reason", reason or "api")
	end
	local closed, close_err = dbmanager.close()
	-- Counted after the last batch, so the numbers cover the whole recording
	local stats = dbmanager.stats()
	if ok and closed then
		core.log("action", string.format(
			"[recorder] recording %s stopped: %d events, %d movement rows, %d dropped (%s)",
			name, stats.events, stats.movement, stats.dropped, path))
	else
		err = err or close_err
		log_error(string.format("recording %s could not be written out completely: %s", name, tostring(err)))
	end
	state.name, state.path = nil, nil
	state.prev, state.written, state.wield, state.joined = {}, {}, {}, {}
	state.sampled = {}
	state.region = nil
	state.known_ids, state.known_param2 = nil, nil
	state.pending_start = false
	state.pending_blocks = {}
	if ok and closed then return nil end
	return tostring(err)
end

stop_recording = function(reason)
	local err = recorder.stop(reason)
	if err then
		log_error(err)
	end
end

-- Attach a key/value pair to the recording. Mods can use this to say what was
-- going on ("ctf:map" = "forge", "weather" = "storm", ...).
---@param key string
---@param value string
---@return nil|string
recorder.add_meta = function(key, value)
	if not state.recording then
		return "no recording is in progress"
	end
	if type(key) ~= "string" or type(value) ~= "string" then
		return "key and value must both be strings"
	end
	if key == "" then
		return "key must not be empty"
	end
	if key:sub(1, #META_PREFIX) == META_PREFIX then
		return "keys starting with '" .. META_PREFIX .. "' describe the recording itself"
	end
	local ok, err = dbmanager.set_meta(key, value)
	if not ok then
		log_error(string.format("cannot write metadata %s: %s", key, tostring(err)))
		return tostring(err)
	end
	return nil
end

-- Record an event of a mod's own making, e.g. a flag capture. Type names are
-- free-form; a "modname:what happened" shape keeps them out of the way of the
-- types the recorder writes itself (see README.md).
---@param event_type string
---@param fields table?  -- subject/object/pos/node/param2/item/data
---@return nil|string
recorder.log_event = function(event_type, fields)
	if not state.recording then
		return "no recording is in progress"
	end
	if type(event_type) ~= "string" or event_type == "" then
		return "event type must be a non-empty string"
	end
	if fields ~= nil and type(fields) ~= "table" then
		return "event fields must be a table"
	end
	if fields and fields.data ~= nil and type(fields.data) ~= "table" then
		return "event data must be a table"
	end
	if fields and fields.pos ~= nil and position_of(fields.pos) == nil then
		return "event position must be numbers: {x=, y=, z=}"
	end
	if fields and fields.node ~= nil and type(fields.node) ~= "string" then
		return "event node must be a node name"
	end
	if fields and fields.param2 ~= nil and tonumber(fields.param2) == nil then
		return "event param2 must be a number"
	end
	local ev = {
		type = event_type,
		subject = fields and fields.subject,
		object = fields and fields.object,
		pos = fields and fields.pos,
		item = fields and fields.item,
		node = fields and fields.node,
		param2 = fields and fields.param2,
		data = fields and fields.data,
	}
	record_event(ev)
	return nil
end

---@return boolean
recorder.is_recording = function()
	return state.recording
end

---@return string|nil  -- the name this recording was started with
recorder.get_recording_name = function()
	return (state.recording or state.snapshot) and state.name or nil
end

---@return string|nil  -- full path of the file being written
recorder.get_recording_path = function()
	return (state.recording or state.snapshot) and state.path or nil
end

----------------------------------------------------------------------------
-- Hooks
----------------------------------------------------------------------------

-- The wrapper never returns anything: several of these callbacks change what
-- the engine does when they return a value (a crafted stack, a disabled
-- respawn, an item not taken), and the recorder is a witness, not a
-- participant.
-- Each callback is registered as one try/catch. The engine hands over objects
-- that can turn out to be unreadable, and an error escaping into the engine is
-- a complaint in the log every time the action is repeated; here it is one
-- complaint, and the actions after it still get recorded. Inside a body, the
-- individual reads keep pcalls of their own: losing a field is better than
-- losing the event that carries it.
local function hook(label, register, func)
	if not register then return end
	register(function(...)
		if not state.recording then return end
		local ok, err = pcall(func, ...)
		if not ok then
			complain(label, "cannot record a " .. label .. ": " .. tostring(err))
		end
	end)
end

hook("join", core.register_on_joinplayer, function(player, last_login)
	on_join(player, last_login, false)
end)

hook("leave", core.register_on_leaveplayer, function(player, timed_out)
	on_leave(player, timed_out)
end)

hook("die", core.register_on_dieplayer, function(player, reason)
	record_event({ type = "die", subject = player, pos = player:get_pos(), data = { reason = describe_reason(reason) } })
end)

hook("respawn", core.register_on_respawnplayer, function(player)
	record_event({ type = "respawn", subject = player, pos = player:get_pos() })
end)

hook("hp_change", core.register_on_player_hpchange, function(player, hp_change, reason)
	record_event({
		type = "hp_change",
		subject = player,
		pos = player:get_pos(),
		data = { amount = hp_change, reason = describe_reason(reason) },
	})
end)

hook("punch_player", core.register_on_punchplayer, function(player, hitter, time_from_last_punch, tool_capabilities, dir, damage)
	local ev = {
		type = "punch_player",
		object = player,
		pos = player:get_pos(),
		data = {
			damage = damage,
			dir = vector_data(dir),
			time_from_last_punch = time_from_last_punch,
			tool = stack_string(hitter and wielded(hitter)),
		},
	}
	set_actor(ev, hitter)
	record_event(ev)
end)

hook("punch_node", core.register_on_punchnode, function(pos, node, puncher, pointed_thing)
	local ev = {
		type = "punch_node",
		pos = pos,
		node = node and node.name,
		param2 = node and node.param2,
		item = stack_string(wielded(puncher)),
	}
	set_actor(ev, puncher)
	record_event(ev)
end)

hook("dig", core.register_on_dignode, function(pos, oldnode, digger)
	local ev = {
		type = "dig",
		pos = pos,
		node = oldnode and oldnode.name,
		param2 = oldnode and oldnode.param2,
		item = stack_string(wielded(digger)),
	}
	set_actor(ev, digger)
	record_event(ev)
end)

hook("place", core.register_on_placenode, function(pos, newnode, placer, oldnode, itemstack, pointed_thing)
	local ev = {
		type = "place",
		pos = pos,
		node = newnode and newnode.name,
		param2 = newnode and newnode.param2,
		item = stack_string(itemstack),
		-- What the place replaced, so it can be undone.
		data = { old_node = oldnode and oldnode.name, old_param2 = oldnode and oldnode.param2 },
	}
	set_actor(ev, placer)
	record_event(ev)
end)

hook("rightclick_player", core.register_on_rightclickplayer, function(player, clicker)
	local ev = {
		type = "rightclick_player",
		object = player,
		pos = player:get_pos(),
		item = stack_string(wielded(clicker)),
	}
	set_actor(ev, clicker)
	record_event(ev)
end)

hook("craft", core.register_on_craft, function(itemstack, player, old_craft_grid, craft_inv)
	local grid = {}
	if type(old_craft_grid) == "table" then
		for i, stack in ipairs(old_craft_grid) do
			grid[i] = stack_string(stack) or ""
		end
	end
	record_event({
		type = "craft",
		subject = player,
		item = stack_string(itemstack),
		data = { grid = grid },
	})
end)

hook("item_eat", core.register_on_item_eat, function(hp_change, replace_with_item, itemstack, user, pointed_thing)
	local ev = {
		type = "item_eat",
		item = stack_string(itemstack),
		data = { hp_change = hp_change, replace_with = stack_string(replace_with_item) },
	}
	set_actor(ev, user)
	record_event(ev)
end)

hook("item_pickup", core.register_on_item_pickup, function(itemstack, picker, pointed_thing)
	local ev = { type = "item_pickup", item = stack_string(itemstack) }
	set_actor(ev, picker)
	record_event(ev)
end)

-- What an inventory action moved: a take and a put say so themselves, while a
-- move within one inventory carries no stack at all - what it left in the
-- destination slot is the closest thing to it, and the slot and the amount are
-- in the data either way.
local function moved_stack(action, inventory, info)
	if type(info) ~= "table" then return nil end
	if info.stack ~= nil then
		return stack_string(info.stack)
	end
	if action ~= "move" or not inventory then return nil end
	local ok, stack = pcall(function()
		return inventory:get_stack(info.to_list, info.to_index)
	end)
	if ok then return stack_string(stack) end
	return nil
end

hook("inventory action", core.register_on_player_inventory_action, function(player, action, inventory, inventory_info)
	local data = {}
	if type(inventory_info) == "table" then
		for key, value in pairs(inventory_info) do
			local value_type = type(value)
			if value_type == "string" or value_type == "number" or value_type == "boolean" then
				data[key] = value
			end
		end
	end
	local ev = {
		type = "inventory_" .. tostring(action),
		subject = player,
		item = moved_stack(action, inventory, inventory_info),
		data = data,
	}
	set_actor(ev, player)
	record_event(ev)
end)

hook("chat", core.register_on_chat_message, function(name, message)
	local player = core.get_player_by_name(name)
	record_event({
		type = "chat",
		subject = name,
		pos = player and player:get_pos() or nil,
		data = { message = message },
	})
end)

hook("chatcommand", core.register_on_chatcommand, function(name, command, params)
	local player = core.get_player_by_name(name)
	record_event({
		type = "chatcommand",
		subject = name,
		pos = player and player:get_pos() or nil,
		data = { command = command, params = params },
	})
end)

hook("protection_violation", core.register_on_protection_violation, function(pos, name)
	record_event({ type = "protection_violation", subject = name, pos = pos })
end)

hook("cheat", core.register_on_cheat, function(player, cheat)
	record_event({
		type = "cheat",
		subject = player,
		pos = player:get_pos(),
		data = { cheat = type(cheat) == "table" and cheat.type or nil },
	})
end)

----------------------------------------------------------------------------
-- Changes to the region's nodes
----------------------------------------------------------------------------

-- The engine calls this at most once per server step, with the mapblocks in
-- which anything changed. The changes are collected here and diffed against the
-- recording's known state in the next step: a node that differs becomes a
-- node_change row. This is what catches changes no callback announces - an
-- explosion, flowing water, an ABM, a mod's set_node - because it watches the
-- world instead of asking mods to report.
core.register_on_mapblocks_changed(function(modified_blocks, count)
	if not (state.recording or state.snapshot) then return end
	if not modified_blocks or not count or count == 0 then return end
	state.pending_blocks[#state.pending_blocks + 1] = {
		tick = state.tick,     -- the step the change belongs to, which may be
		t = state.elapsed,     -- one before the step that diffs it
		blocks = modified_blocks,
	}
end)

-- Read one mapblock back and compare it with what the recording last knew. Only
-- nodes that differ become rows; the block's nodes are addressed by arithmetic
-- rather than by building a position table for each of the 4096 of them.
local function diff_block(block, tick, t)
	local reg = state.region
	local size = region_module.size(reg)
	local p2 = {x = block.x + 15, y = block.y + 15, z = block.z + 15}
	local vm = core.get_voxel_manip(block, p2)
	if not vm then return end
	if not vm:read_from_map(block, p2) then
		vm:close()
		return
	end
	local emerged1, emerged2 = vm:get_emerged_area()
	local data = vm:get_data()
	local param2 = vm:get_param2_data()
	vm:close()
	local emerged_size = {
		x = emerged2.x - emerged1.x + 1,
		y = emerged2.y - emerged1.y + 1,
		z = emerged2.z - emerged1.z + 1,
	}

	for z = 0, 15 do
		local world_z = block.z + z
		local dz = world_z - reg.pos1.z
		if dz >= 0 and dz < size.z then
			for y = 0, 15 do
				local world_y = block.y + y
				local dy = world_y - reg.pos1.y
				if dy >= 0 and dy < size.y then
					local row = dz * size.y * size.x + dy * size.x
					for x = 0, 15 do
						local world_x = block.x + x
						local dx = world_x - reg.pos1.x
						if dx >= 0 and dx < size.x then
							local index = row + dx + 1
							local lvm_index = (world_z - emerged1.z) * emerged_size.y * emerged_size.x
								+ (world_y - emerged1.y) * emerged_size.x
								+ (world_x - emerged1.x) + 1
							local id = data[lvm_index]
							local value = param2[lvm_index]
							local old_id = state.known_ids[index]
							local old_param2 = state.known_param2[index]
							if id ~= old_id or value ~= old_param2 then
								state.known_ids[index] = id
								state.known_param2[index] = value
								record_event({
									type = "node_change",
									tick = tick,
									t = t,
									pos = {x = world_x, y = world_y, z = world_z},
									node = core.get_name_from_content_id(id),
									param2 = value,
									data = {
										old_node = core.get_name_from_content_id(old_id),
										old_param2 = old_param2,
									},
								})
							end
						end
					end
				end
			end
		end
	end
end

local function process_block_changes()
	local pending = state.pending_blocks
	if #pending == 0 then return end
	state.pending_blocks = {}
	local block_min, block_max = region_module.blocks(state.region)
	for _, entry in ipairs(pending) do
		for hash in pairs(entry.blocks) do
			local block = core.get_position_from_hash(hash)
			if block and block.x >= block_min.x and block.x <= block_max.x
				and block.y >= block_min.y and block.y <= block_max.y
				and block.z >= block_min.z and block.z <= block_max.z then
				diff_block(block, entry.tick, entry.t)
			end
		end
	end
end

-- A region marked by someone who has gone is theirs no more.
core.register_on_leaveplayer(function(player)
	local name = player_name(player)
	if name then marks[name] = nil end
end)

core.register_globalstep(function(dtime)
	if state.snapshot then
		advance_snapshot()
		-- Whether it is still running or only just finished, the recording's
		-- first step is the next one.
		return
	end
	if not state.recording then return end
	if state.pending_start then
		-- Still tick 0: this is the state the recording opens with, and it
		-- belongs with the marker start() already wrote. The flag is cleared
		-- afterwards, so players missed by a failure here are picked up by the
		-- next step instead of being lost for the rest of the recording.
		local gametime = core.get_gametime()
		write_meta(META_PREFIX .. "gametime", gametime and tostring(gametime) or nil)
		for player in core.objects_in_area(state.region.pos1, state.region.pos2) do
			if core.is_player(player) then
				local pid = player_id(player)
				-- Someone who joined in the moment between start() and this step
				-- is already in the recording and does not need joining again.
				if not (pid and state.joined[pid]) then
					guarded("record a join", on_join, player, nil, true)
				end
			end
		end
		state.pending_start = false
	end
	state.tick = state.tick + 1
	state.elapsed = state.elapsed + dtime
	observe_region(dtime)
	process_block_changes()
	maybe_flush()
end)

core.register_on_shutdown(function()
	if state.snapshot or state.recording then
		stop_recording("shutdown")
	end
end)

----------------------------------------------------------------------------
-- Chat commands
----------------------------------------------------------------------------

local function status_string()
	if state.snapshot then
		return string.format(
			"Snapshotting the region for '%s' into %s: %d%% (the recording starts when it is done)",
			state.name, state.path,
			math.floor(snapshot_module.progress(state.snapshot) * 100))
	end
	if not state.recording then
		return "No recording in progress."
	end
	local stats = dbmanager.stats()
	-- Commits that are failing right now are the difference between a recording
	-- that is whole and one whose last seconds are missing, so they are said out
	-- loud - and not said at all when there are none, which is the usual state.
	local failing = ""
	if stats.failed > 0 then
		failing = string.format(", %d failed write%s in a row", stats.failed, stats.failed == 1 and "" or "s")
	end
	local limit = ""
	if state.max_duration > 0 then
		limit = limit .. string.format(", stops at %d s", math.floor(state.max_duration))
	end
	if state.max_size > 0 then
		limit = limit .. string.format(", stops at %.1f MB", state.max_size / (1024 * 1024))
	end
	local size = region_module.size(state.region)
	return string.format(
		"Recording '%s' to %s: %d s, tick %d, %d events, %d movement rows, " ..
		"%d buffered, %d dropped%s, %.1f MB on disk, region %dx%dx%d%s",
		state.name, state.path, math.floor(state.elapsed), state.tick,
		stats.events, stats.movement, stats.buffered, stats.dropped,
		failing, recording_size(state.path) / (1024 * 1024),
		size.x, size.y, size.z, limit)
end

core.register_chatcommand("recorder", {
	description = "Control the action recorder",
	params = "[start [name] [x1,y1,z1 x2,y2,z2] | stop | status | pos1 | pos2 | unset | meta <key> <value>]",
	privs = { server = true },
	---@param name string
	---@param params string
	func = function(name, params)
		local command, rest = params:match("^(%S+)%s*(.-)%s*$")
		if command == nil or command == "" or command == "status" then
			return true, status_string()
		end
		if command == "pos1" or command == "pos2" then
			local player = core.get_player_by_name(name)
			if not player then return false, "no player" end
			local pos = player:get_pos()
			if not pos then return false, "cannot read your position" end
			local mark = marks[name] or {}
			mark[command] = {
				x = math.floor(pos.x), y = math.floor(pos.y), z = math.floor(pos.z),
			}
			marks[name] = mark
			return true, string.format("%s set to %s%s", command, core.pos_to_string(mark[command]),
				(mark.pos1 and mark.pos2) and "; /recorder start will use these corners" or "")
		end
		if command == "unset" then
			marks[name] = nil
			return true, "region marks cleared"
		end
		if command == "start" then
			-- An optional name, and optionally two coordinate triples; without
			-- them the caller's marks, then the game's provider, are used.
			local words = {}
			for word in rest:gmatch("%S+") do words[#words + 1] = word end
			local function coordinates(text)
				local x, y, z = text:match("^(-?%d+),(-?%d+),(-?%d+)$")
				if not x then return nil end
				return {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
			end
			local explicit
			if #words >= 2 then
				local p1 = coordinates(words[#words - 1])
				local p2 = coordinates(words[#words])
				if p1 and p2 then
					explicit = {pos1 = p1, pos2 = p2}
					table.remove(words)
					table.remove(words)
				end
			end
			local mark = marks[name]
			local region = explicit
				or ((mark and mark.pos1 and mark.pos2) and {pos1 = mark.pos1, pos2 = mark.pos2} or nil)
			local err = recorder.start(#words > 0 and table.concat(words, " ") or nil, region)
			if err then return false, err end
			return true, "Snapshotting the region; the recording starts when it is done " ..
				"(see /recorder status)"
		end
		if command == "stop" then
			local err = recorder.stop()
			if err then return false, err end
			return true, "Recording stopped."
		end
		if command == "meta" then
			local key, value = rest:match("^(%S+)%s+(.+)$")
			if not key then
				return false, "Usage: /recorder meta <key> <value>"
			end
			local err = recorder.add_meta(key, value)
			if err then return false, err end
			return true, string.format("Recorded metadata %s.", key)
		end
		return false, "Usage: /recorder [start [name] [x1,y1,z1 x2,y2,z2] | stop | status | " ..
			"pos1 | pos2 | unset | meta <key> <value>]"
	end,
})
