-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- Read-only access to one recording during playback: the facts a session reads
-- once, and the queries its cursors run. Nothing here writes, and a recording
-- that is still being made can be read - its WAL makes committed rows visible
-- as they land.

local reader = {}

---@param rec table
---@param sql string
---@return string|number|nil
function reader.scalar(rec, sql)
	local stmt = rec.db:prepare(sql)
	if not stmt then return nil end
	local value
	if stmt:step() == rec.sqlite.ROW then
		value = stmt:get_value(0)
	end
	stmt:reset()
	stmt:finalize()
	return value
end

-- The tables a recording is made of. A file can carry the right identity and
-- schema version without holding them - hand-made, or damaged after the
-- header - and every query against such a file raises instead of returning an
-- error, so their presence is checked before anything reads rows.
local REQUIRED_TABLES = {"Metadata", "Snapshot", "Players", "Movement", "Events"}

-- Open a recording and read the facts that do not change during a session.
---@param path string
---@param sqlite table
---@return table|nil, string?
function reader.open(path, sqlite)
	local db, err = recorder_common.open_read_only(path, sqlite)
	if not db then return nil, err end
	local rec = {
		db = db,
		sqlite = sqlite,
		path = path,
		name = "unnamed",
		players = {},   -- player id -> name
		duration = 0,
	}
	-- The whole read is under pcall: a damaged page makes lsqlite3 raise, and
	-- a recording that cannot be read is a message, not a lost server step.
	local ok, read_err = pcall(function()
		local seen = {}
		for row in db:nrows("SELECT name FROM sqlite_master WHERE type = 'table'") do
			seen[row.name] = true
		end
		local missing = {}
		for _, name in ipairs(REQUIRED_TABLES) do
			if not seen[name] then missing[#missing + 1] = name end
		end
		if #missing > 0 then
			error("it is missing " .. table.concat(missing, ", "), 0)
		end

		for row in db:nrows("SELECT key, value FROM Metadata") do
			if row.key == "recorder.name" then rec.name = row.value
			elseif row.key == "recorder.started_at" then rec.started_at = row.value
			elseif row.key == "recorder.game" then rec.game = row.value
			elseif row.key == "recorder.end_reason" then rec.end_reason = row.value
			end
		end
		for row in db:nrows("SELECT id, name FROM Players") do
			rec.players[row.id] = row.name
		end
		local movement_end = reader.scalar(rec, "SELECT MAX(t) FROM Movement")
		local event_end = reader.scalar(rec, "SELECT MAX(t) FROM Events")
		rec.duration = math.max(tonumber(movement_end) or 0, tonumber(event_end) or 0)
	end)
	if not ok then
		db:close()
		return nil, string.format("cannot read %s: %s", path, tostring(read_err))
	end
	return rec
end

---@param rec table
function reader.close(rec)
	rec.db:close()
end

-- Find a recording by name: an exact path, or the newest file whose name
-- begins with the given recording name. Recording files carry the UTC time
-- they began at, so their names sort by age.
---@param arg string?
---@return string|nil, string?
function reader.resolve(arg)
	if not arg or arg == "" then
		return nil, "which recording? Give a name from /replay list, or a .sqlite path"
	end
	if arg:find("/", 1, true) or arg:match("%.sqlite$") then
		if not recorder_common.file_exists(arg) then
			return nil, "no such recording: " .. arg
		end
		return arg
	end
	local dir = recorder_common.recordings_dir()
	local prefix = recorder_common.sanitize_name(arg) .. "-"
	local names = core.get_dir_list(dir, false) or {}
	table.sort(names, function(a, b) return a > b end)
	for _, name in ipairs(names) do
		if name:sub(1, #prefix) == prefix and name:sub(-7) == ".sqlite" then
			return dir .. "/" .. name
		end
	end
	return nil, "no recording named " .. arg .. " in " .. dir
end

local MOVEMENT_COLUMNS =
	"tick, t, dtime, pos_x, pos_y, pos_z, pitch, yaw, vel_x, vel_y, vel_z, speed, controls"

local function movement_row(row)
	return {
		tick = row.tick,
		t = row.t,
		dtime = row.dtime,
		pos = {x = row.pos_x, y = row.pos_y, z = row.pos_z},
		pitch = row.pitch,
		yaw = row.yaw,
		vel = {x = row.vel_x, y = row.vel_y, z = row.vel_z},
		speed = row.speed,
		controls = row.controls,
	}
end

---@param rec table
---@param player_id integer
---@param tick integer
---@param limit integer
---@return table[]
function reader.movement_after(rec, player_id, tick, limit)
	local rows = {}
	local sql = string.format(
		"SELECT %s FROM Movement WHERE player_id = %d AND tick > %d ORDER BY tick LIMIT %d",
		MOVEMENT_COLUMNS, player_id, tick, limit)
	for row in rec.db:nrows(sql) do
		rows[#rows + 1] = movement_row(row)
	end
	return rows
end

-- The last sample of a player at or before a tick, or nil when there is none.
---@param rec table
---@param player_id integer
---@param tick integer
---@return table|nil
function reader.last_movement(rec, player_id, tick)
	local sql = string.format(
		"SELECT %s FROM Movement WHERE player_id = %d AND tick <= %d ORDER BY tick DESC LIMIT 1",
		MOVEMENT_COLUMNS, player_id, tick)
	for row in rec.db:nrows(sql) do
		return movement_row(row)
	end
	return nil
end

local EVENT_COLUMNS =
	"id, tick, t, type, subject_player, object_player, pos_x, pos_y, pos_z, node, param2, item, data"

---@param rec table
---@param after_id integer
---@param limit integer
---@return table[]
function reader.events_after(rec, after_id, limit)
	local rows = {}
	local sql = string.format(
		"SELECT %s FROM Events WHERE id > %d ORDER BY id LIMIT %d",
		EVENT_COLUMNS, after_id, limit)
	for row in rec.db:nrows(sql) do
		rows[#rows + 1] = {
			id = row.id,
			tick = row.tick,
			t = row.t,
			type = row.type,
			subject_player = row.subject_player,
			object_player = row.object_player,
			pos = (row.pos_x ~= nil) and {x = row.pos_x, y = row.pos_y, z = row.pos_z} or nil,
			node = row.node,
			param2 = row.param2,
			item = row.item,
			data = row.data,
		}
	end
	return rows
end

-- The tick a moment in the recording falls on. `t` is not indexed, so this is
-- one scan; seeks are human-driven, and everything after them uses the tick
-- index.
---@param rec table
---@param t number
---@return integer
function reader.tick_at(rec, t)
	local value = reader.scalar(rec,
		string.format("SELECT MAX(tick) FROM Movement WHERE t <= %.6f", t))
	if value == nil then
		value = reader.scalar(rec,
			string.format("SELECT MAX(tick) FROM Events WHERE t <= %.6f", t))
	end
	return tonumber(value) or 0
end

-- The join and leave events up to a tick, in the order they happened. Applying
-- them in order leaves exactly the players who are present at that moment.
---@param rec table
---@param tick integer
---@return table[]
function reader.join_leave_until(rec, tick)
	local rows = {}
	local sql = string.format(
		"SELECT id, tick, type, subject_player, pos_x, pos_y, pos_z, data FROM Events " ..
		"WHERE type IN ('join', 'leave') AND tick <= %d ORDER BY id", tick)
	for row in rec.db:nrows(sql) do
		rows[#rows + 1] = {
			id = row.id,
			tick = row.tick,
			type = row.type,
			subject_player = row.subject_player,
			pos = (row.pos_x ~= nil) and {x = row.pos_x, y = row.pos_y, z = row.pos_z} or nil,
			data = row.data,
		}
	end
	return rows
end

---@param rec table
---@param tick integer
---@return integer
function reader.last_event_id(rec, tick)
	return tonumber(reader.scalar(rec,
		string.format("SELECT MAX(id) FROM Events WHERE tick <= %d", tick))) or 0
end

return reader
