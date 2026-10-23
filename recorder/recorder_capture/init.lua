-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- recorder – write down what happens on the server, in order, into SQLite.
--
-- One recording is one SQLite file holding the actions players perform, the
-- per-tick kinematics that go with them, and whatever metadata other mods
-- attach. The file is meant to be read back later: replaying it, analysing it
-- or just reading it with the sqlite3 shell. See README.md for the schema, the
-- recorded event types and the API.
--
-- Several recordings can run at once, each over its own region and into its own
-- file: a game may record a match while someone records a practice area. Every
-- recording has an id; events are offered to all of them and each one keeps
-- what its own region says belongs to it.

local FLUSH_DEFAULT = 2.0         -- seconds of server time between commits
local MAX_BUFFERED_DEFAULT = 20000
local MAX_FAILURES = 10           -- failed commits in a row before giving up
local MAX_RECORDINGS_DEFAULT = 4  -- 0 = no limit
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
	recorder.start = function(record_name) return nil, unavailable end
	recorder.stop = function(id, reason) return unavailable end
	---@param key string
	---@param value string
	recorder.add_meta = function(key, value, id) return unavailable end
	---@param event_type string
	---@param fields table?
	recorder.log_event = function(event_type, fields) return unavailable end
	recorder.is_recording = function() return false end
	recorder.get_recording_name = function() return nil end
	recorder.get_recording_path = function() return nil end
	recorder.list = function() return {} end
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
local dbmanager = dofile(modpath .. "/dbmanager.lua")
local snapshot_module = dofile(modpath .. "/snapshot.lua")
local region_module = recorder_common.region
local light_codec = recorder_common.light
local snapshot_codec = recorder_common.snapshot

-- One recording's state. Everything below that takes a `rec` gets one of these;
-- nothing about a recording is module-level except the id counter and the
-- marks.
local function new_state()
	return {
		id = nil,            -- the handle the API and the commands use
		db = nil,            -- this recording's DBManager instance
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
		light_enabled = false, -- whether the region's light is recorded
		known_light = nil,   -- region flat index -> light byte, what the recording knows
		metadata_enabled = false, -- whether node metadata and inventories are recorded
		metadata_known = {}, -- position key -> serialized metadata the recording knows
		next_metadata_poll = 0,
		pending_blocks = {}, -- mapblock changes waiting to be diffed, with their tick
		prev = {},           -- player id -> last sample, for deriving acceleration
		written = {},        -- player id -> last sample written, to spot no-ops
		wield = {},          -- player id -> last wielded itemstring
		anim = {},           -- player id -> last animation the player was wearing
		joined = {},         -- player ids that are in the recording as present
	}
end

-- Recordings being written or snapshotted right now, by id.
local recordings = {}
local recording_counter = 0

local function new_recording_id()
	recording_counter = recording_counter + 1
	return string.format("%08x%04x", os.time(), recording_counter)
end

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

-- A boolean setting with a default. get_bool() on its own reads an unset
-- setting as false, and the features below default to on.
local function enabled_setting(name, default)
	local raw = core.settings:get(name)
	if raw == nil or raw == "" then return default end
	return core.settings:get_bool(name)
end

-- One report per kind of trouble per recording: a callback that fires every
-- tick must not turn a single problem into a log full of them.
local function complain(rec, label, message)
	if rec.complaints[label] then return end
	rec.complaints[label] = true
	log_error(message)
end

-- Something the engine hands over can always turn out to be unreadable, and one
-- player that cannot be dealt with must not cost the rest of the recording.
local function guarded(rec, label, func, ...)
	local ok, err = pcall(func, ...)
	if not ok then
		complain(rec, label, "cannot " .. label .. ": " .. tostring(err))
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
local function write_troubles(rec)
	if not rec.troubles_dirty then return end
	local ok = rec.db:set_meta(META_PREFIX .. "player_errors", table.concat(rec.troubles, "; "))
	if ok then
		rec.troubles_dirty = false
	end
end

local function note_player_error(rec, name, message)
	rec.troubles[#rec.troubles + 1] = string.format("%s (%s)", name, tostring(message))
	rec.troubles_dirty = true
	write_troubles(rec)
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
local function player_id(rec, obj)
	local name = player_name(obj)
	if not name then return nil end
	local id, err = rec.db:player_id(name)
	if not id and not rec.player_errors[name] then
		rec.player_errors[name] = true
		log_error(tostring(err))
		note_player_error(rec, name, err)
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
local function event_in_region(rec, ev)
	local reg = rec.region
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

---@param obj ObjectRef|ItemStack|string|nil
---@return string|nil
local function stack_string(obj)
	if obj == nil then return nil end
	if type(obj) == "string" then
		return obj ~= "" and obj or nil
	end
	-- The engine hands us ItemStack copies, which do not go invalid the way an
	-- ObjectRef does.
	local str = obj:to_string()
	if str ~= "" then return str end
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

-- The animation a player is wearing, in the four values the engine's old
-- animation interface owns. A pose like "lying down while dead" is not
-- derivable from speed and controls, so the recording keeps the engine's own
-- numbers instead of guessing at replay time. Some engine versions answer
-- nothing (or raise) for a player; that only means the recording has no pose
-- for them and replay falls back to its guess.
--
-- An animation the engine has never been given is reported as frames 1..1 at
-- 15 fps, no blend, looping. That is not a pose a game chose: recording it
-- would freeze the replay's own guess for the whole file, so it means "no
-- pose" here too.
---@param player ObjectRef
---@return table|nil  -- {frames = {x =, y =}, speed =, blend =, loop =}
local function animation_of(player)
	local ok, frames, speed, blend, loop = pcall(player.get_animation, player)
	if not ok or type(frames) ~= "table" then return nil end
	if frames.x == 1 and frames.y == 1 and speed == 15 and blend == 0 and loop == true then
		return nil
	end
	return {frames = {x = frames.x, y = frames.y}, speed = speed, blend = blend, loop = loop}
end

---@param a table?
---@param b table?
---@return boolean
local function same_animation(a, b)
	if not a or not b then return a == b end
	return a.frames.x == b.frames.x and a.frames.y == b.frames.y
		and a.speed == b.speed and a.blend == b.blend and a.loop == b.loop
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
	-- write_json() reports a value it cannot serialize in its return values
	-- rather than by raising; one bad event must not cost the callback.
	local json, err = core.write_json(data)
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
-- Node metadata
----------------------------------------------------------------------------

-- How often the region is scanned for metadata changes. Metadata has no engine
-- callback, and most changes happen where players are, so a second of
-- granularity is a good trade against scanning the region every step.
local METADATA_INTERVAL = 1.0

local function position_key(pos)
	return string.format("%d,%d,%d", math.floor(pos.x), math.floor(pos.y), math.floor(pos.z))
end

-- NodeMetaRef:to_table() is not quite storable: inventory slots are ItemStack
-- userdata, and an empty inventory is still a list of empty slots that says
-- how large the node's inventory is. Fields stay strings, stacks become the
-- itemstrings from_table() accepts, and a table with nothing in it is nil -
-- "this node has no metadata worth recording".
---@param table_ table?
---@return string|nil  -- serialized metadata, or nil when there is nothing to store
local function metadata_blob(table_)
	if type(table_) ~= "table" then return nil end
	local normalized = {fields = {}, inventory = {}}
	local any = false
	for key, value in pairs(table_.fields or {}) do
		normalized.fields[key] = tostring(value)
		any = true
	end
	for listname, list in pairs(table_.inventory or {}) do
		local items = {}
		for i, stack in ipairs(list) do
			if type(stack) == "string" then
				items[i] = stack
			elseif stack ~= nil and stack.to_string then
				items[i] = stack:to_string()
			else
				items[i] = ""
			end
		end
		normalized.inventory[listname] = items
		any = true
	end
	if not any then return nil end
	return core.serialize(normalized)
end

---@param pos table
---@return string|nil
local function metadata_at(pos)
	return metadata_blob(core.get_meta(pos):to_table())
end

local function record_metadata(rec, pos, blob, tick, t)
	rec.db:add_metadata({
		rec.db:next_id(), tick or rec.tick, t or rec.elapsed,
		math.floor(pos.x), math.floor(pos.y), math.floor(pos.z), blob or "",
	})
end

-- The metadata the recording starts from, written with tick 0 like the node
-- snapshot it belongs with.
local function record_metadata_baseline(rec)
	if not rec.metadata_enabled then return end
	local positions = core.find_nodes_with_meta(rec.region.pos1, rec.region.pos2)
	local known = {}
	for _, pos in pairs(positions or {}) do
		local blob = metadata_at(pos)
		if blob then
			known[position_key(pos)] = blob
			record_metadata(rec, pos, blob, 0, 0)
		end
	end
	rec.metadata_known = known
end

-- Compare the metadata in the region with what the recording knows. Only
-- differences become rows; a node that went away, or whose metadata was
-- cleared, gets an empty row. A position whose block is unloaded is left
-- alone: the scan cannot see it, and that is not the same as it being gone.
local function poll_metadata(rec)
	local known = rec.metadata_known
	local positions = core.find_nodes_with_meta(rec.region.pos1, rec.region.pos2)
	local seen = {}
	for _, pos in pairs(positions or {}) do
		local key = position_key(pos)
		seen[key] = true
		local blob = metadata_at(pos)
		if blob then
			if known[key] ~= blob then
				known[key] = blob
				record_metadata(rec, pos, blob)
			end
		elseif known[key] then
			known[key] = nil
			record_metadata(rec, pos, "")
		end
	end
	for key in pairs(known) do
		if not seen[key] then
			local x, y, z = key:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
			if x then
				local pos = {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
				local node = core.get_node(pos)
				if node and node.name ~= "ignore" then
					known[key] = nil
					record_metadata(rec, pos, "")
				end
			end
		end
	end
end

----------------------------------------------------------------------------
-- Writing events
----------------------------------------------------------------------------

-- Everything in a row comes either from the engine or from a mod, so it is made
-- to fit the column it goes into right here: a value SQLite refuses would cost
-- not just this event but every row buffered beside it.
---@param ev table
record_event = function(rec, ev)
	if not rec.recording then return end
	if type(ev.type) ~= "string" or ev.type == "" then
		complain(rec, "event without a type", "cannot record an event whose type is not a name")
		return
	end
	if not REGION_EXEMPT[ev.type] and not event_in_region(rec, ev) then return end
	if rec.disabled[ev.type] then return end
	local x, y, z = position_of(ev.pos)
	rec.db:add_event({
		rec.db:next_id(), ev.tick or rec.tick, ev.t or rec.elapsed, ev.type,
		player_id(rec, ev.subject), player_id(rec, ev.object),
		x, y, z,
		type(ev.node) == "string" and ev.node or nil,
		param2_of(ev.param2), stack_string(ev.item),
		ev.data and encode_data(ev.data) or nil,
	})
end

-- Offer an event to every recording; each keeps it if its own region says it
-- belongs there. A recording that fails on it does not cost the others.
local function broadcast_event(ev)
	for _, rec in pairs(recordings) do
		guarded(rec, "record an event", record_event, rec, ev)
	end
end

----------------------------------------------------------------------------
-- Per-tick sampling
----------------------------------------------------------------------------

local function sample_state(rec, player, pid, dtime)
	local pos = player:get_pos()
	if not pos then return nil end
	local vel = player:get_velocity() or { x = 0, y = 0, z = 0 }
	local prev = rec.prev[pid]
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
	rec.prev[pid] = sample
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
local function record_player(rec, player, dtime)
	local name = player_name(player)
	if not name then return end
	local pid = rec.db:player_id(name)
	if not pid then return end
	local sample = sample_state(rec, player, pid, dtime)
	if not sample then return end

	local wield = wielded(player)
	if rec.wield[pid] ~= wield then
		rec.wield[pid] = wield
		-- Tools wear out as they are used, so this is also where a degrading
		-- tool shows up.
		record_event(rec, { type = "wield", subject = name, item = stack_string(wield) })
	end

	local animation = animation_of(player)
	if animation and not same_animation(rec.anim[pid], animation) then
		rec.anim[pid] = animation
		record_event(rec, { type = "animation", subject = name, data = animation })
	end

	local last = rec.written[pid]
	if last and same_state(sample, last) then return end
	rec.written[pid] = sample
	rec.db:add_movement({
		rec.db:next_id(), rec.tick, rec.elapsed, dtime, pid,
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
		local properties = player:get_properties()
		return {
			pos = player:get_pos(),
			hp = player:get_hp(),
			breath = player:get_breath(),
			pitch = player:get_look_vertical(),
			yaw = player:get_look_horizontal(),
			-- What the player looks like, so a replay can wear the same skin.
			textures = properties and properties.textures or nil,
			inventory = inventory_snapshot(player),
		}
	end)
	if ok and snapshot then return snapshot end
	return {}
end

-- A player enters the recording: by joining the game inside the region, by
-- being online in it when the recording starts (at_start), or by walking into
-- it (reason "region").
local function on_join(rec, player, last_login, at_start, reason)
	local name = player_name(player)
	if not name then return end
	-- A player who joins the game outside the region is not in the recording
	-- yet; the next pass through the region will join them there.
	local pos = position_of_object(player)
	if rec.region and not (pos and region_module.contains(rec.region, pos)) then
		return
	end
	local pid = rec.db:player_id(name)
	local wield = wielded(player)
	if pid then
		-- The join event itself carries the wielded stack, so this only records
		-- the baseline that later changes are compared against.
		rec.wield[pid] = wield
	end
	local snapshot = player_snapshot(player)
	if pid then
		rec.joined[pid] = true
	end
	record_event(rec, {
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
			textures = snapshot.textures,
			inventory = snapshot.inventory,
		},
	})
end

local function on_leave(rec, player, timed_out)
	local name = player_name(player)
	if not name then return end
	local pid = rec.db:known_player_id(name)
	-- A player who was never in the recording (they stayed outside the region)
	-- has nothing to leave from, and is not added to it just to say so.
	if not pid or not rec.joined[pid] then return end
	-- Where they were when they left is what a reader following their trail
	-- has to end on. The engine is free to have let go of the object by now, so
	-- a player that cannot be read is recorded without a position.
	local read, pos = pcall(function() return player:get_pos() end)
	record_event(rec, {
		type = "leave",
		subject = name,
		pos = read and pos or nil,
		data = { timed_out = timed_out or nil },
	})
	-- Whatever the player does after rejoining has no relation to these,
	-- and the first sample after a rejoin has no previous velocity.
	rec.prev[pid] = nil
	rec.written[pid] = nil
	rec.wield[pid] = nil
	rec.anim[pid] = nil
	rec.joined[pid] = nil
end

-- One pass through the region: sample the players in it, and note who walked
-- in or out since the last pass. Everything in a recording is inside the
-- region, so a player who leaves it leaves the recording until they return.
local function observe_region(rec, dtime)
	local reg = rec.region
	local seen = {}
	for player in core.objects_in_area(reg.pos1, reg.pos2) do
		if core.is_player(player) then
			local name = player_name(player)
			if name then
				local pid = player_id(rec, name)
				if pid then
					seen[pid] = name
					if not rec.joined[pid] then
						-- They were outside when the recording started, or have
						-- walked in since; either way they enter the recording here.
						guarded(rec, "record a join", on_join, rec, player, nil, false, "region")
					end
					-- A player who could not be joined is not sampled either: a
					-- movement trail that begins without a join would leave a
					-- reader without the state the trail starts from.
					if rec.joined[pid] then
						guarded(rec, "sample a player", record_player, rec, player, dtime)
					end
				end
			end
		end
	end
	for pid, name in pairs(rec.sampled) do
		if not seen[pid] and rec.joined[pid] then
			-- They are still in the game but out of the region: their trail
			-- ends where it was last sampled.
			local last = rec.prev[pid]
			record_event(rec, {
				type = "leave",
				subject = name,
				pos = last and {x = last[S_POS_X], y = last[S_POS_Y], z = last[S_POS_Z]} or nil,
				data = { reason = "region" },
			})
			rec.joined[pid] = nil
			rec.prev[pid] = nil
			rec.written[pid] = nil
			rec.wield[pid] = nil
			rec.anim[pid] = nil
		end
	end
	rec.sampled = seen
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

local function write_meta(rec, key, value)
	if value == nil then return end
	local ok, err = rec.db:set_meta(key, value)
	if not ok then
		log_error(string.format("cannot write metadata %s: %s", key, tostring(err)))
	end
end

----------------------------------------------------------------------------
-- Committing
----------------------------------------------------------------------------

-- Assigned once stop() exists; a stop triggered from inside the sampling can
-- reach it from here.
local stop_recording

-- Buffered rows are committed in batches: one transaction a couple of seconds
-- instead of one per action. The same rows end up on disk, but the server is
-- not made to wait for a disk synchronization for each of them.
local function maybe_flush(rec)
	if rec.max_duration > 0 and rec.elapsed >= rec.max_duration then
		stop_recording(rec, "limit_duration")
		return
	end
	if rec.max_size > 0 and recording_size(rec.path) >= rec.max_size then
		stop_recording(rec, "limit_size")
		return
	end
	-- 0 means the interval alone decides when to commit
	local crowded = rec.max_buffered > 0 and rec.db:buffered() >= rec.max_buffered
	if not crowded and (rec.elapsed - rec.last_flush) < rec.flush_interval then
		return
	end
	rec.last_flush = rec.elapsed
	local ok, err, lost = rec.db:flush()
	if ok then
		write_troubles(rec)
		return
	end
	log_error(string.format("cannot write %d rows to %s: %s", lost or 0, tostring(rec.path), tostring(err)))
	-- The rows are gone, so what was last written is no longer what a reader
	-- would carry forward: every player's next sample is written again rather
	-- than looking like a quiet tick, and a held item or a pose that changed in
	-- the lost rows is announced again instead of going unmentioned.
	rec.written, rec.wield, rec.anim = {}, {}, {}
	record_event(rec, {
		type = "write_error",
		data = { dropped_rows = lost, message = err },
	})
	-- The database counts the failed commits itself, and clears the count on the
	-- first one that goes through, so there is one answer to "is this recording
	-- in trouble" rather than two that can drift apart.
	if rec.db:stats().failed >= MAX_FAILURES then
		log_error("giving up on the recording after repeated write failures")
		stop_recording(rec, "write_error")
	end
end

----------------------------------------------------------------------------
-- API
----------------------------------------------------------------------------

-- Resolve the region a recording covers. It is the caller's choice: a region
-- handed to start() (a game starting a recording knows exactly where), or the
-- marks the chat command resolves for the player who asked. There is no
-- provider to fall back on: a recording is about a particular place, and a
-- stateless source has no way to know which recording is being started.
---@param region_arg table?  -- {pos1 =, pos2 =}
---@return table|nil, string?
local function resolve_region(region_arg)
	if not region_arg then
		return nil, "a recording needs a region: mark two corners with /recorder pos1 and /recorder pos2," ..
			" or pass one to start()"
	end
	return region_module.normalize(region_arg.pos1, region_arg.pos2)
end

-- The recording did not become one: close the file and take it away, so a
-- failed start leaves nothing behind that looks like a recording.
---@param reason string
local function abort_start(rec, reason)
	local path = rec.path
	log_error(string.format("cannot start a recording in %s: %s", tostring(path), tostring(reason)))
	rec.db:close()
	if path then
		os.remove(path)
		os.remove(path .. "-wal")
		os.remove(path .. "-shm")
	end
	recordings[rec.id] = nil
	rec.recording = false
	rec.snapshot = nil
	rec.region = nil
	rec.known_ids, rec.known_param2 = nil, nil
	rec.light_enabled = false
	rec.known_light = nil
	rec.metadata_enabled = false
	rec.metadata_known = {}
	rec.pending_blocks = {}
	rec.anim = {}
	rec.name, rec.path = nil, nil
end

-- The snapshot is done: the file can say what the world looked like, and the
-- recording proper begins.
---@param result table
local function finish_start(rec, result)
	local light_body, light_encoding
	if result.light then
		light_body = light_codec.encode(result.light, region_module.volume(rec.region))
		light_encoding = "raw"
		if core.compress then
			local packed = core.compress(light_body, "deflate", 9)
			if packed then
				light_body, light_encoding = packed, "deflate"
			end
		end
	end
	local ok, err = rec.db:set_snapshot({
		tick = 0,
		t = 0,
		pos1 = rec.region.pos1,
		size = region_module.size(rec.region),
		names = table.concat(result.names, "\n"),
		encoding = result.encoding,
		data = result.data,
		light = light_body,
		light_encoding = light_encoding,
	})
	if not ok then
		abort_start(rec, err)
		return
	end
	rec.known_ids = result.ids
	rec.known_param2 = result.param2
	rec.known_light = result.light

	-- The schema version is not repeated here: PRAGMA user_version is where the
	-- file keeps it, and it is the version of the file rather than of the mod.
	write_meta(rec, META_PREFIX .. "name", rec.name)
	write_meta(rec, META_PREFIX .. "started_at", os.date("!%Y-%m-%dT%H:%M:%SZ", rec.started_at))
	local version = core.get_version()
	write_meta(rec, META_PREFIX .. "server_version", version and version.string or nil)
	local game = core.get_game_info()
	write_meta(rec, META_PREFIX .. "game", game and game.id or nil)
	rec.recording = true
	rec.snapshot = nil
	-- The baseline rows go in with the opening marker, so a reader has the
	-- state of every container from the first moment of the recording.
	record_metadata_baseline(rec)
	record_event(rec, { type = "recording_start" })
	-- Who is online and what the world time is has to wait for the first server
	-- step: a mod is allowed to start a recording while it loads, and the
	-- engine refuses those questions before the server is running.
	rec.pending_start = true
	local flushed, flush_err = rec.db:flush()
	if not flushed then
		abort_start(rec, flush_err)
		return
	end
	core.log("action", string.format("[recorder] recording %s (%s) started, writing to %s",
		rec.name, rec.id, rec.path))
end

-- One step of the snapshot phase. The recording is not active yet, so events
-- and samples are dropped by the same gate that drops them when nothing is
-- being recorded.
local function advance_snapshot(rec)
	local snap = rec.snapshot
	if not snap then return end
	local status, result = snapshot_module.step(snap, rec.snapshot_budget)
	if status == "working" then return end
	if status == "failed" then
		snapshot_module.free(snap)
		rec.snapshot = nil
		abort_start(rec, result)
		return
	end
	rec.snapshot = nil
	snapshot_module.free(snap)
	finish_start(rec, result)
end

-- Find a recording by id, by name, or by a unique id prefix. Without an
-- argument this answers with the only recording, and says so when there is not
-- exactly one.
---@param arg string?
---@return table|nil, string?
local function find_recording(arg)
	if arg == nil or arg == "" then
		local only, count = nil, 0
		for _, rec in pairs(recordings) do
			only = rec
			count = count + 1
		end
		if count == 1 then return only end
		if count == 0 then return nil, "no recording is in progress" end
		return nil, "several recordings are running; give an id (see /recorder status)"
	end
	local exact = recordings[arg]
	if exact then return exact end
	local named, name_count = nil, 0
	for _, rec in pairs(recordings) do
		if rec.name == arg then
			named = rec
			name_count = name_count + 1
		end
	end
	if name_count == 1 then return named end
	if name_count > 1 then
		return nil, "more than one recording is named " .. arg .. "; give an id"
	end
	local prefixed, prefix_count = nil, 0
	for id, rec in pairs(recordings) do
		if id:sub(1, #arg) == arg then
			prefixed = rec
			prefix_count = prefix_count + 1
		end
	end
	if prefix_count == 1 then return prefixed end
	if prefix_count > 1 then return nil, "more than one recording matches " .. arg end
	return nil, "no recording " .. arg
end

---@param record_name string?  -- used for the file name; "unnamed" if not given
---@param region_arg table  -- {pos1 =, pos2 =}; every recording names its region
---@return string|nil, string?  -- the recording's id, or an error message
recorder.start = function(record_name, region_arg)
	local limit = tonumber(core.settings:get("recorder.max_recordings")) or MAX_RECORDINGS_DEFAULT
	if limit > 0 then
		local running = 0
		for _ in pairs(recordings) do running = running + 1 end
		if running >= limit then
			return nil, string.format("too many recordings are running (%d); see recorder.max_recordings",
				running)
		end
	end
	local region, region_err = resolve_region(region_arg)
	if not region then
		return nil, region_err
	end
	local name = recorder_common.sanitize_name(record_name)
	local dir = recorder_common.recordings_dir()
	local now = os.time()
	-- An already existing directory is not an error, and the open below is
	-- what actually decides whether the directory is usable.
	core.mkdir(dir)
	local path = recorder_common.unique_path(dir, name .. "-" .. os.date("!%Y%m%dT%H%M%SZ", now))
	if not path then
		return nil, "too many recordings named " .. name .. " in " .. dir
	end
	local rec = new_state()
	rec.id = new_recording_id()
	rec.db = dbmanager.new(sqlite)
	local ok, err = rec.db:open(path)
	if not ok then
		log_error(tostring(err))
		return nil, err
	end

	-- Read here rather than at load time, so that a setting changed between two
	-- recordings applies to the next one.
	rec.flush_interval = tonumber(core.settings:get("recorder.flush_interval")) or FLUSH_DEFAULT
	rec.max_buffered = tonumber(core.settings:get("recorder.max_buffered")) or MAX_BUFFERED_DEFAULT
	rec.max_duration = tonumber(core.settings:get("recorder.max_duration")) or 0
	rec.max_size = (tonumber(core.settings:get("recorder.max_size_mb")) or 0) * 1024 * 1024
	rec.metadata_enabled = enabled_setting("recorder.metadata", true)
	rec.metadata_known = {}
	rec.next_metadata_poll = METADATA_INTERVAL
	rec.light_enabled = enabled_setting("recorder.light", true)
	rec.known_light = nil
	rec.disabled = {}
	for type_name in (core.settings:get("recorder.disabled_events") or ""):gmatch("[^,%s]+") do
		-- What the recording needs in order to explain itself - where it
		-- starts and stops, and where a gap is - is not a matter of taste.
		if MANDATORY_EVENTS[type_name] then
			log_error("the " .. type_name .. " event is always recorded; ignoring the setting for it")
		else
			rec.disabled[type_name] = true
		end
	end

	-- The recording proper starts when the snapshot is done; until then
	-- rec.recording stays false and the existing gate drops events.
	rec.recording = false
	rec.name = name
	rec.path = path
	rec.started_at = now
	rec.region = region
	rec.tick = 0
	rec.elapsed = 0
	rec.last_flush = 0
	rec.complaints, rec.player_errors = {}, {}
	rec.troubles, rec.troubles_dirty = {}, false
	rec.prev, rec.written, rec.wield, rec.joined = {}, {}, {}, {}
	rec.anim = {}
	rec.sampled = {}
	rec.known_ids, rec.known_param2 = nil, nil
	rec.pending_blocks = {}
	rec.snapshot_budget = math.max(1,
		math.floor(tonumber(core.settings:get("recorder.snapshot_budget")) or 20000))

	local snap, snap_err = snapshot_module.new(region.pos1, region.pos2, rec.light_enabled)
	if not snap then
		abort_start(rec, snap_err)
		return nil, snap_err
	end
	rec.snapshot = snap
	recordings[rec.id] = rec
	core.log("action", string.format("[recorder] snapshotting %s .. %s for %s (%s), writing to %s",
		core.pos_to_string(region.pos1), core.pos_to_string(region.pos2), name, rec.id, path))
	return rec.id
end

-- Stop one recording. The optional reason is stored in the recording (and is
-- what the automatic stops use).
---@param rec table
---@param reason string?
---@return nil|string  -- nil on success, an error message on failure
local function stop(rec, reason)
	if rec.snapshot then
		-- The recording never became one: there is nothing to mark in the file,
		-- and a file that was never a recording should not be left behind.
		local path = rec.path
		snapshot_module.free(rec.snapshot)
		rec.snapshot = nil
		rec.db:close()
		if path then
			os.remove(path)
			os.remove(path .. "-wal")
			os.remove(path .. "-shm")
		end
		recordings[rec.id] = nil
		rec.recording = false
		rec.region = nil
		rec.known_ids, rec.known_param2 = nil, nil
		rec.light_enabled = false
		rec.known_light = nil
		rec.metadata_enabled = false
		rec.metadata_known = {}
		rec.pending_blocks = {}
		rec.sampled = {}
		rec.anim = {}
		rec.name, rec.path = nil, nil
		core.log("action", "[recorder] recording " .. tostring(rec.id) ..
			" abandoned while snapshotting; the file is gone")
		return nil
	end
	if not rec.recording then
		return "no recording is in progress"
	end
	record_event(rec, { type = "recording_stop", data = { reason = reason or "api" } })
	local name, path = rec.name, rec.path
	rec.recording = false
	-- The end marker and the last rows go out first, and the metadata only
	-- follows if they made it: a file whose events have no ending must not
	-- claim, in its own metadata, that it stopped cleanly.
	local ok, err = rec.db:flush()
	if ok then
		write_meta(rec, META_PREFIX .. "stopped_at", os.date("!%Y-%m-%dT%H:%M:%SZ", os.time()))
		write_meta(rec, META_PREFIX .. "ticks", tostring(rec.tick))
		write_meta(rec, META_PREFIX .. "end_reason", reason or "api")
	end
	local closed, close_err = rec.db:close()
	-- Counted after the last batch, so the numbers cover the whole recording
	local stats = rec.db:stats()
	if ok and closed then
		core.log("action", string.format(
			"[recorder] recording %s (%s) stopped: %d events, %d movement rows, %d dropped (%s)",
			name, tostring(rec.id), stats.events, stats.movement, stats.dropped, path))
	else
		err = err or close_err
		log_error(string.format("recording %s could not be written out completely: %s", name, tostring(err)))
	end
	recordings[rec.id] = nil
	rec.name, rec.path = nil, nil
	rec.prev, rec.written, rec.wield, rec.joined = {}, {}, {}, {}
	rec.anim = {}
	rec.sampled = {}
	rec.region = nil
	rec.known_ids, rec.known_param2 = nil, nil
	rec.light_enabled = false
	rec.known_light = nil
	rec.metadata_enabled = false
	rec.metadata_known = {}
	rec.pending_start = false
	rec.pending_blocks = {}
	if ok and closed then return nil end
	return tostring(err)
end

stop_recording = function(rec, reason)
	local err = stop(rec, reason)
	if err then
		log_error(err)
	end
end

---@param id string?
---@param reason string?
---@return nil|string
recorder.stop = function(id, reason)
	local rec, err = find_recording(id)
	if not rec then return err end
	return stop(rec, reason)
end

-- Attach a key/value pair to a recording. Mods can use this to say what was
-- going on ("ctf:map" = "forge", "weather" = "storm", ...). With several
-- recordings running, the id says which one; without it there must be only one.
---@param key string
---@param value string
---@param id string?
---@return nil|string
recorder.add_meta = function(key, value, id)
	local rec, err = find_recording(id)
	if not rec then return err end
	if not rec.recording then
		return "the recording is still taking its snapshot"
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
	local ok, werr = rec.db:set_meta(key, value)
	if not ok then
		log_error(string.format("cannot write metadata %s: %s", key, tostring(werr)))
		return tostring(werr)
	end
	return nil
end

-- Record an event of a mod's own making, e.g. a flag capture. Type names are
-- free-form; a "modname:what happened" shape keeps them out of the way of the
-- types the recorder writes itself (see README.md). Every recording is offered
-- the event and keeps it if its own region says it belongs there.
---@param event_type string
---@param fields table?  -- subject/object/pos/node/param2/item/data
---@return nil|string
recorder.log_event = function(event_type, fields)
	local any = false
	for _, rec in pairs(recordings) do
		if rec.recording then any = true break end
	end
	if not any then
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
	broadcast_event({
		type = event_type,
		subject = fields and fields.subject,
		object = fields and fields.object,
		pos = fields and fields.pos,
		item = fields and fields.item,
		node = fields and fields.node,
		param2 = fields and fields.param2,
		data = fields and fields.data,
	})
	return nil
end

---@return boolean
recorder.is_recording = function()
	for _, rec in pairs(recordings) do
		if rec.recording then return true end
	end
	return false
end

---@param id string?
---@return string|nil  -- the name this recording was started with
recorder.get_recording_name = function(id)
	local rec = find_recording(id)
	return rec and rec.name or nil
end

---@param id string?
---@return string|nil  -- full path of the file being written
recorder.get_recording_path = function(id)
	local rec = find_recording(id)
	return rec and rec.path or nil
end

-- What is running right now, as plain data.
---@return table[]
recorder.list = function()
	local list = {}
	for id, rec in pairs(recordings) do
		list[#list + 1] = {
			id = id,
			name = rec.name,
			path = rec.path,
			recording = rec.recording,
			snapshotting = rec.snapshot ~= nil,
			elapsed = rec.elapsed,
			region = rec.region,
		}
	end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
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
local hook_complaints = {}
local function any_recording()
	for _, rec in pairs(recordings) do
		if rec.recording then return true end
	end
	return false
end
local function hook(label, register, func)
	if not register then return end
	register(function(...)
		if not any_recording() then return end
		local ok, err = pcall(func, ...)
		if not ok and not hook_complaints[label] then
			hook_complaints[label] = true
			log_error("cannot record a " .. label .. ": " .. tostring(err))
		end
	end)
end

-- A player joining or leaving the game is offered to every recording; each
-- joins them only if they are inside its region.
local function broadcast_join(player, last_login, at_start, reason)
	for _, rec in pairs(recordings) do
		if rec.recording then
			guarded(rec, "record a join", on_join, rec, player, last_login, at_start, reason)
		end
	end
end

local function broadcast_leave(player, timed_out)
	for _, rec in pairs(recordings) do
		if rec.recording then
			guarded(rec, "record a leave", on_leave, rec, player, timed_out)
		end
	end
end

hook("join", core.register_on_joinplayer, function(player, last_login)
	broadcast_join(player, last_login, false)
end)

hook("leave", core.register_on_leaveplayer, function(player, timed_out)
	broadcast_leave(player, timed_out)
end)

hook("die", core.register_on_dieplayer, function(player, reason)
	broadcast_event({ type = "die", subject = player, pos = player:get_pos(),
		data = { reason = describe_reason(reason) } })
end)

hook("respawn", core.register_on_respawnplayer, function(player)
	broadcast_event({ type = "respawn", subject = player, pos = player:get_pos() })
end)

hook("hp_change", core.register_on_player_hpchange, function(player, hp_change, reason)
	broadcast_event({
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
	broadcast_event(ev)
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
	broadcast_event(ev)
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
	broadcast_event(ev)
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
	broadcast_event(ev)
end)

hook("rightclick_player", core.register_on_rightclickplayer, function(player, clicker)
	local ev = {
		type = "rightclick_player",
		object = player,
		pos = player:get_pos(),
		item = stack_string(wielded(clicker)),
	}
	set_actor(ev, clicker)
	broadcast_event(ev)
end)

hook("craft", core.register_on_craft, function(itemstack, player, old_craft_grid, craft_inv)
	local grid = {}
	if type(old_craft_grid) == "table" then
		for i, stack in ipairs(old_craft_grid) do
			grid[i] = stack_string(stack) or ""
		end
	end
	broadcast_event({
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
	broadcast_event(ev)
end)

hook("item_pickup", core.register_on_item_pickup, function(itemstack, picker, pointed_thing)
	local ev = { type = "item_pickup", item = stack_string(itemstack) }
	set_actor(ev, picker)
	broadcast_event(ev)
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
	local stack = inventory:get_stack(info.to_list, info.to_index)
	return stack_string(stack)
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
	broadcast_event(ev)
end)

hook("chat", core.register_on_chat_message, function(name, message)
	local player = core.get_player_by_name(name)
	broadcast_event({
		type = "chat",
		subject = name,
		pos = player and player:get_pos() or nil,
		data = { message = message },
	})
end)

hook("chatcommand", core.register_on_chatcommand, function(name, command, params)
	local player = core.get_player_by_name(name)
	broadcast_event({
		type = "chatcommand",
		subject = name,
		pos = player and player:get_pos() or nil,
		data = { command = command, params = params },
	})
end)

hook("protection_violation", core.register_on_protection_violation, function(pos, name)
	broadcast_event({ type = "protection_violation", subject = name, pos = pos })
end)

hook("cheat", core.register_on_cheat, function(player, cheat)
	broadcast_event({
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
-- which anything changed. The changes are collected per recording, with the
-- tick that recording was on, and diffed against its known state in the next
-- step: a node that differs becomes a node_change row. This is what catches
-- changes no callback announces - an explosion, flowing water, an ABM, a mod's
-- set_node - because it watches the world instead of asking mods to report.
core.register_on_mapblocks_changed(function(modified_blocks, count)
	if not modified_blocks or not count or count == 0 then return end
	for _, rec in pairs(recordings) do
		if rec.recording or rec.snapshot then
			rec.pending_blocks[#rec.pending_blocks + 1] = {
				tick = rec.tick,     -- the step the change belongs to, which may
				t = rec.elapsed,     -- be one before the step that diffs it
				blocks = modified_blocks,
			}
		end
	end
end)

-- Read one mapblock back and compare it with what the recording last knew. Only
-- nodes that differ become rows; the block's nodes are addressed by arithmetic
-- rather than by building a position table for each of the 4096 of them. Light
-- is compared the same way: the callback reports blocks whose light changed
-- even when no node did, so a torch's glow is caught too.
local function diff_block(rec, block, tick, t, light_changes)
	local reg = rec.region
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
	local light_data = rec.light_enabled and vm:get_light_data() or nil
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
							local old_id = rec.known_ids[index]
							local old_param2 = rec.known_param2[index]
							if id ~= old_id or value ~= old_param2 then
								rec.known_ids[index] = id
								rec.known_param2[index] = value
								record_event(rec, {
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
							if light_data then
								local light_value = light_data[lvm_index] or 0
								if light_value ~= rec.known_light[index] then
									rec.known_light[index] = light_value
									light_changes[#light_changes + 1] =
										{i = index, n = 1, p = light_value}
								end
							end
						end
					end
				end
			end
		end
	end
end

-- The mapblock callback's hashes use the hash_node_position encoding, but the
-- position they encode is a mapblock position in mapblock units - not the
-- node-space base corner the documentation's wording suggests. The node-space
-- base is 16 times that. Both readings are tried and the region's bounds
-- discard the wrong one, so an engine that hands out node positions instead
-- keeps working as well.
---@param block table
---@return table[]
local function block_candidates(block)
	return {
		{x = block.x * 16, y = block.y * 16, z = block.z * 16},
		block,
	}
end

local function process_block_changes(rec)
	local pending = rec.pending_blocks
	if #pending == 0 then return end
	rec.pending_blocks = {}
	local block_min, block_max = region_module.blocks(rec.region)
	for _, entry in ipairs(pending) do
		local light_changes = {}
		for hash in pairs(entry.blocks) do
			local decoded = core.get_position_from_hash(hash)
			if decoded then
				local seen = {}
				for _, block in ipairs(block_candidates(decoded)) do
					local key = block.x .. "," .. block.y .. "," .. block.z
					if not seen[key] then
						seen[key] = true
						if block.x >= block_min.x and block.x <= block_max.x
							and block.y >= block_min.y and block.y <= block_max.y
							and block.z >= block_min.z and block.z <= block_max.z then
							diff_block(rec, block, entry.tick, entry.t, light_changes)
						end
					end
				end
			end
		end
		if #light_changes > 0 then
			-- The blocks are visited in hash order, so the entries are sorted
			-- into the codec's increasing-index order before encoding.
			table.sort(light_changes, function(a, b) return a.i < b.i end)
			local body, encode_err = snapshot_codec.encode(light_changes)
			if body then
				local encoding = "raw"
				if core.compress then
					local packed = core.compress(body, "deflate", 9)
					if packed then
						body, encoding = packed, "deflate"
					end
				end
				rec.db:add_light({
					rec.db:next_id(), entry.tick, entry.t, body, encoding,
				})
			else
				complain(rec, "encode light changes",
					"cannot encode light changes: " .. tostring(encode_err))
			end
		end
	end
end

-- A region marked by someone who has gone is theirs no more.
core.register_on_leaveplayer(function(player)
	local name = player_name(player)
	if name then marks[name] = nil end
end)

-- One recording's server step.
local function step_recording(rec, dtime)
	if rec.pending_start then
		-- Still tick 0: this is the state the recording opens with, and it
		-- belongs with the marker start() already wrote. The flag is cleared
		-- afterwards, so players missed by a failure here are picked up by the
		-- next step instead of being lost for the rest of the recording.
		local gametime = core.get_gametime()
		write_meta(rec, META_PREFIX .. "gametime", gametime and tostring(gametime) or nil)
		-- The light layer stores skylight, which the client scales by the
		-- current time of day. A replay can only show the recorded day if it
		-- knows which day it was.
		local timeofday = core.get_timeofday()
		write_meta(rec, META_PREFIX .. "timeofday", timeofday and tostring(timeofday) or nil)
		for player in core.objects_in_area(rec.region.pos1, rec.region.pos2) do
			if core.is_player(player) then
				local pid = player_id(rec, player)
				-- Someone who joined in the moment between start() and this step
				-- is already in the recording and does not need joining again.
				if not (pid and rec.joined[pid]) then
					guarded(rec, "record a join", on_join, rec, player, nil, true)
				end
			end
		end
		rec.pending_start = false
	end
	rec.tick = rec.tick + 1
	rec.elapsed = rec.elapsed + dtime
	observe_region(rec, dtime)
	process_block_changes(rec)
	if rec.metadata_enabled and rec.elapsed >= rec.next_metadata_poll then
		rec.next_metadata_poll = rec.elapsed + METADATA_INTERVAL
		guarded(rec, "scan node metadata", poll_metadata, rec)
	end
	maybe_flush(rec)
end

core.register_globalstep(function(dtime)
	-- A recording whose snapshot finishes in this step does not also take its
	-- first recording step: the first recording step is the next one.
	local snapshotting = {}
	for id, rec in pairs(recordings) do
		if rec.snapshot then
			snapshotting[id] = true
			advance_snapshot(rec)
		end
	end
	for id, rec in pairs(recordings) do
		if rec.recording and not snapshotting[id] then
			step_recording(rec, dtime)
		end
	end
end)

core.register_on_shutdown(function()
	local ids = {}
	for id in pairs(recordings) do ids[#ids + 1] = id end
	for _, id in ipairs(ids) do
		local rec = recordings[id]
		if rec then stop_recording(rec, "shutdown") end
	end
end)

----------------------------------------------------------------------------
-- Chat commands
----------------------------------------------------------------------------

local function limits_of(rec)
	local limit = ""
	if rec.max_duration > 0 then
		limit = limit .. string.format(", stops at %d s", math.floor(rec.max_duration))
	end
	if rec.max_size > 0 then
		limit = limit .. string.format(", stops at %.1f MB", rec.max_size / (1024 * 1024))
	end
	return limit
end

local function status_line(rec)
	if rec.snapshot then
		return string.format("%s  '%s'  snapshotting %d%% (%s)", rec.id, rec.name,
			math.floor(snapshot_module.progress(rec.snapshot) * 100), rec.path)
	end
	local stats = rec.db:stats()
	-- Commits that are failing right now are the difference between a recording
	-- that is whole and one whose last seconds are missing, so they are said out
	-- loud - and not said at all when there are none, which is the usual state.
	local failing = ""
	if stats.failed > 0 then
		failing = string.format(", %d failed write%s in a row", stats.failed,
			stats.failed == 1 and "" or "s")
	end
	local size = region_module.size(rec.region)
	return string.format(
		"%s  '%s'  %d s, tick %d, %d events, %d movement rows, %d buffered, %d dropped%s, " ..
		"%.1f MB on disk, region %dx%dx%d%s",
		rec.id, rec.name, math.floor(rec.elapsed), rec.tick,
		stats.events, stats.movement, stats.buffered, stats.dropped,
		failing, recording_size(rec.path) / (1024 * 1024),
		size.x, size.y, size.z, limits_of(rec))
end

---@param arg string?
---@return string[]
local function status_lines(arg)
	if arg == nil or arg == "" then
		local list = recorder.list()
		if #list == 0 then return {"No recording in progress."} end
		local lines = {}
		for _, entry in ipairs(list) do
			lines[#lines + 1] = status_line(recordings[entry.id])
		end
		return lines
	end
	local rec, err = find_recording(arg)
	if not rec then return {err} end
	return {status_line(rec)}
end

core.register_chatcommand("recorder", {
	description = "Control the action recorder",
	params = "[start [name] [x1,y1,z1 x2,y2,z2] | stop [id] | status [id] | pos1 | pos2 | unset | " ..
		"meta [id] <key> <value>]",
	privs = { server = true },
	---@param name string
	---@param params string
	func = function(name, params)
		local command, rest = params:match("^(%S+)%s*(.-)%s*$")
		if command == nil or command == "" or command == "status" then
			for _, line in ipairs(status_lines(rest ~= "" and rest or nil)) do
				core.chat_send_player(name, line)
			end
			return true
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
			-- them the caller's own marks are used.
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
			local id, err = recorder.start(#words > 0 and table.concat(words, " ") or nil, region)
			if not id then return false, err end
			return true, string.format(
				"Recording %s: snapshotting the region; it starts when that is done " ..
				"(see /recorder status)", id)
		end
		if command == "stop" then
			local err = recorder.stop(rest ~= "" and rest or nil)
			if err then return false, err end
			return true, "Recording stopped."
		end
		if command == "meta" then
			local first, remainder = rest:match("^(%S+)%s+(.+)$")
			if first and remainder then
				local key, value = remainder:match("^(%S+)%s+(.+)$")
				if key and recordings[first] then
					local err = recorder.add_meta(key, value, first)
					if err then return false, err end
					return true, string.format("Recorded metadata %s for %s.", key, first)
				end
			end
			local key, value = rest:match("^(%S+)%s+(.+)$")
			if not key then
				return false, "Usage: /recorder meta [id] <key> <value>"
			end
			local err = recorder.add_meta(key, value)
			if err then return false, err end
			return true, string.format("Recorded metadata %s.", key)
		end
		return false, "Usage: /recorder [start [name] [x1,y1,z1 x2,y2,z2] | stop [id] | " ..
			"status [id] | pos1 | pos2 | unset | meta [id] <key> <value>]"
	end,
})
