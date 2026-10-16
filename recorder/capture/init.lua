-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- recorder – write down what happens on the server, in order, into SQLite.
--
-- One recording is one SQLite file holding the actions players perform, the
-- per-tick kinematics that go with them, and whatever metadata other mods
-- attach. The file is meant to be read back later: replaying it, analysing it
-- or just reading it with the sqlite3 shell. See README.md for the schema, the
-- recorded event types and the API.

local DEFAULT_NAME = "unnamed"
local FLUSH_DEFAULT = 2.0         -- seconds of server time between commits
local MAX_BUFFERED_DEFAULT = 20000
local MAX_FAILURES = 10           -- failed commits in a row before giving up
local NAME_MAX = 64
-- Everything the recorder writes about the recording itself lives under this
-- prefix, so mods cannot overwrite it by accident and the recorder knows which
-- keys are its own.
local META_PREFIX = "recorder."

-- The events that say what a recording is and where its holes are; switching
-- these off would leave a file that cannot be read for what it is.
local MANDATORY_EVENTS = {
	recording_start = true,
	recording_stop = true,
	write_error = true,
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

local state = {
	recording = false,
	name = nil,          -- sanitized recording name
	path = nil,          -- path of the SQLite file
	tick = 0,            -- server steps since the recording started
	elapsed = 0,         -- server seconds since the recording started
	last_flush = 0,
	flush_interval = FLUSH_DEFAULT,
	max_buffered = MAX_BUFFERED_DEFAULT,
	max_duration = 0,    -- server seconds; 0 = no limit
	max_size = 0,        -- bytes; 0 = no limit
	disabled = {},       -- event types not to record
	failures = 0,        -- failed commits in a row
	complaints = {},     -- what has already been reported, so it is said once
	player_errors = {},  -- players whose row could not be written (said once)
	troubles = {},       -- what to write down about them, for the file
	troubles_dirty = false,
	pending_start = false,   -- the opening state is taken at the next step
	prev = {},           -- player id -> last sample, for deriving acceleration
	written = {},        -- player id -> last sample written, to spot no-ops
	wield = {},          -- player id -> last wielded itemstring
	joined = {},         -- player ids that are in the recording as present
}

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

-- A position from the engine or from a mod, as three numbers or nothing.
local function position_of(pos)
	if type(pos) ~= "table" then return nil end
	local x, y, z = tonumber(pos.x), tonumber(pos.y), tonumber(pos.z)
	if not (x and y and z) then return nil end
	return x, y, z
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
	if state.disabled[ev.type] then return end
	local x, y, z = position_of(ev.pos)
	dbmanager.add_event({
		dbmanager.next_id(), state.tick, state.elapsed, ev.type,
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

-- A player enters the recording: either by joining the server while a
-- recording runs, or by being online when one is started (at_start), which is
-- the same thing from a reader's point of view.
local function on_join(player, last_login, at_start)
	local name = player_name(player)
	if not name then return end
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
	record_event({ type = "leave", subject = name, data = { timed_out = timed_out or nil } })
	local pid = dbmanager.player_id(name)
	if pid then
		-- Whatever the player does after rejoining has no relation to these,
		-- and the first sample after a rejoin has no previous velocity.
		state.prev[pid] = nil
		state.written[pid] = nil
		state.wield[pid] = nil
		state.joined[pid] = nil
	end
end

----------------------------------------------------------------------------
-- The recording file
----------------------------------------------------------------------------

local function recordings_dir()
	local dir = core.settings:get("recorder.directory")
	if dir and dir ~= "" then return dir end
	return core.get_worldpath() .. "/recordings"
end

-- A recording name ends up in a file name, so anything that is not plainly a
-- word character is replaced, and leading dots (which would walk out of the
-- recordings directory) are dropped.
local function sanitize_name(name)
	local clean = tostring(name or ""):gsub("[^%w%-%._]", "_"):gsub("^%.+", "")
	clean = clean:sub(1, NAME_MAX)
	if clean == "" then return DEFAULT_NAME end
	return clean
end

local function file_exists(path)
	local f = io.open(path, "rb")
	if not f then return false end
	f:close()
	return true
end

-- Never write into a file that is already there: opening an existing recording
-- would append to it, and a name is not worth that.
local function unique_path(dir, base)
	local path = dir .. "/" .. base .. ".sqlite"
	if not file_exists(path) then return path end
	for i = 2, 1000 do
		local candidate = string.format("%s/%s-%d.sqlite", dir, base, i)
		if not file_exists(candidate) then return candidate end
	end
	return nil
end

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
		state.failures = 0
		write_troubles()
		return
	end
	state.failures = state.failures + 1
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
	if state.failures >= MAX_FAILURES then
		log_error("giving up on the recording after repeated write failures")
		stop_recording("write_error")
	end
end

----------------------------------------------------------------------------
-- API
----------------------------------------------------------------------------

---@param record_name string?  -- used for the file name; "unnamed" if not given
---@return nil|string  -- nil on success, an error message on failure
recorder.start = function(record_name)
	if state.recording then
		return "a recording is already in progress: " .. tostring(state.path)
	end
	local name = sanitize_name(record_name)
	local dir = recordings_dir()
	local now = os.time()
	-- An already existing directory is not an error, and the open below is
	-- what actually decides whether the directory is usable.
	core.mkdir(dir)
	local path = unique_path(dir, name .. "-" .. os.date("!%Y%m%dT%H%M%SZ", now))
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

	state.recording = true
	state.name = name
	state.path = path
	state.tick = 0
	state.elapsed = 0
	state.last_flush = 0
	state.failures = 0
	state.complaints, state.player_errors = {}, {}
	state.troubles, state.troubles_dirty = {}, false
	state.prev, state.written, state.wield, state.joined = {}, {}, {}, {}

	-- The schema version is not repeated here: PRAGMA user_version is where the
	-- file keeps it, and it is the version of the file rather than of the mod.
	write_meta(META_PREFIX .. "name", name)
	write_meta(META_PREFIX .. "started_at", os.date("!%Y-%m-%dT%H:%M:%SZ", now))
	local version = core.get_version()
	write_meta(META_PREFIX .. "server_version", version and version.string or nil)
	local game = core.get_game_info()
	write_meta(META_PREFIX .. "game", game and game.id or nil)
	record_event({ type = "recording_start" })
	-- Who is online and what the world time is has to wait for the first server
	-- step: a mod is allowed to start a recording while it loads, and the
	-- engine refuses those questions before the server is running.
	state.pending_start = true
	local ok_stats, flush_err = dbmanager.flush()
	if not ok_stats then
		-- There is no point in carrying on if the very first write fails.
		dbmanager.close()
		state.recording = false
		state.pending_start = false
		state.name, state.path = nil, nil
		log_error(string.format("cannot write to %s: %s", path, tostring(flush_err)))
		return "cannot write to " .. path
	end
	core.log("action", "[recorder] recording " .. name .. " started, writing to " .. path)
	return nil
end

-- Stop the recording in progress. The optional reason is stored in the
-- recording (and is what the automatic stops use).
---@param reason string?
---@return nil|string  -- nil on success, an error message on failure
recorder.stop = function(reason)
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
	state.failures = 0
	state.pending_start = false
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
	return state.recording and state.name or nil
end

---@return string|nil  -- full path of the file being written
recorder.get_recording_path = function()
	return state.recording and state.path or nil
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

core.register_globalstep(function(dtime)
	if not state.recording then return end
	if state.pending_start then
		-- Still tick 0: this is the state the recording opens with, and it
		-- belongs with the marker start() already wrote. The flag is cleared
		-- afterwards, so players missed by a failure here are picked up by the
		-- next step instead of being lost for the rest of the recording.
		local gametime = core.get_gametime()
		write_meta(META_PREFIX .. "gametime", gametime and tostring(gametime) or nil)
		local players = core.get_connected_players()
		for i = 1, #players do
			local pid = player_id(players[i])
			-- Someone who joined in the moment between start() and this step is
			-- already in the recording and does not need joining again.
			if not (pid and state.joined[pid]) then
				guarded("record a join", on_join, players[i], nil, true)
			end
		end
		state.pending_start = false
	end
	state.tick = state.tick + 1
	state.elapsed = state.elapsed + dtime
	local players = core.get_connected_players()
	for i = 1, #players do
		guarded("sample a player", record_player, players[i], dtime)
	end
	maybe_flush()
end)

core.register_on_shutdown(function()
	if not state.recording then return end
	stop_recording("shutdown")
end)

----------------------------------------------------------------------------
-- Chat commands
----------------------------------------------------------------------------

local function status_string()
	if not state.recording then
		return "No recording in progress."
	end
	local stats = dbmanager.stats()
	local limit = ""
	if state.max_duration > 0 then
		limit = limit .. string.format(", stops at %d s", math.floor(state.max_duration))
	end
	if state.max_size > 0 then
		limit = limit .. string.format(", stops at %.1f MB", state.max_size / (1024 * 1024))
	end
	return string.format(
		"Recording '%s' to %s: %d s, tick %d, %d events, %d movement rows, " ..
		"%d buffered, %d dropped, %.1f MB on disk%s",
		state.name, state.path, math.floor(state.elapsed), state.tick,
		stats.events, stats.movement, stats.buffered, stats.dropped,
		recording_size(state.path) / (1024 * 1024), limit)
end

core.register_chatcommand("recorder", {
	description = "Control the action recorder",
	params = "[start [name] | stop | status | meta <key> <value>]",
	privs = { server = true },
	---@param name string
	---@param params string
	func = function(name, params)
		local command, rest = params:match("^(%S+)%s*(.-)%s*$")
		if command == nil or command == "" or command == "status" then
			return true, status_string()
		end
		if command == "start" then
			local err = recorder.start(rest ~= "" and rest or nil)
			if err then return false, err end
			return true, "Recording to " .. tostring(recorder.get_recording_path())
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
		return false, "Usage: /recorder [start [name] | stop | status | meta <key> <value>]"
	end,
})
