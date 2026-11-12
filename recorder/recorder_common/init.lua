-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- Shared settings, retention, file identity, paths and snapshot codecs.

recorder_common = {}
recorder_common.settings = dofile(core.get_modpath("recorder_common") .. "/settings.lua")

-- SQLite identity and schema version checked when opening recordings.
recorder_common.APPLICATION_ID = 0x4A4D4152  -- 'JMAR'
recorder_common.SCHEMA_VERSION = 1

recorder_common.DEFAULT_NAME = "unnamed"
recorder_common.NAME_MAX = 64

-- Game-specific replay hooks; capture regions belong to recorder.start().
--   arena(size, taken) -> pos1, pos2: fit the region plus shell; avoid taken boxes
--   world_persistent: false if the game rebuilds the world and owns inventories
--   can_enter(player, session): pure predicate; false + reason refuses entry;
--                               nil/true allows; session is nil before a start
--   before_enter(player, session): before replacing inventory and teleporting
--   on_enter(player, session): after entering the arena
--   on_leave(player, session): after restoring the player (online players only)
recorder_common.game_hooks = {
	arena = nil,
	world_persistent = true,
	can_enter = nil,
	before_enter = nil,
	on_enter = nil,
	on_leave = nil,
}

---@param hooks table
function recorder_common.register_game_hooks(hooks)
	for key, value in pairs(hooks or {}) do
		recorder_common.game_hooks[key] = value
	end
end

local function file_exists(path)
	local f = io.open(path, "rb")
	if not f then return false end
	f:close()
	return true
end

recorder_common.file_exists = file_exists

-- Resolve recorder.directory relative to the world, unless absolute.
---@return string
function recorder_common.recordings_dir()
	local dir = recorder_common.settings:get("recorder.directory")
	if not dir or dir == "" then
		return core.get_worldpath() .. "/recordings"
	end
	if dir:sub(1, 1) == "/" then
		return dir
	end
	return core.get_worldpath() .. "/" .. dir
end

-- Keep filenames within the recordings directory: replace unsafe characters
-- and strip leading dots.
---@param name string?
---@return string
function recorder_common.sanitize_name(name)
	local clean = tostring(name or ""):gsub("[^%w%-%._]", "_"):gsub("^%.+", "")
	clean = clean:sub(1, recorder_common.NAME_MAX)
	if clean == "" then return recorder_common.DEFAULT_NAME end
	return clean
end

-- Choose an unused path; never append to or overwrite an existing recording.
---@param dir string
---@param base string
---@return string?  -- nil when a thousand recordings already carry this name
function recorder_common.unique_path(dir, base)
	local path = dir .. "/" .. base .. ".sqlite"
	if not file_exists(path) then return path end
	for i = 2, 1000 do
		local candidate = string.format("%s/%s-%d.sqlite", dir, base, i)
		if not file_exists(candidate) then return candidate end
	end
	return nil
end

-- Validate identity/version and enable query_only. WAL exposes committed rows
-- of active recordings without blocking capture.
---@param path string
---@param sqlite table  -- the lsqlite3 library, loaded by the calling mod
---@return userdata|nil, string?
function recorder_common.open_read_only(path, sqlite)
	if not sqlite then
		return nil, "no SQLite library was handed to open_read_only"
	end
	local handle, err1, err2 = sqlite.open(path)
	if not handle then
		return nil, string.format("cannot open %s: %s", path, tostring(err2 or err1))
	end

	local function fail(message)
		handle:close()
		return nil, message
	end

	-- Briefly wait for checkpoint/schema locks; WAL readers do not block writers.
	handle:busy_timeout(250)
	if handle:exec("PRAGMA query_only = ON") ~= sqlite.OK then
		return fail(string.format("cannot open %s read-only: %s", path, tostring(handle:errmsg())))
	end

	local function scalar(sql)
		local stmt = handle:prepare(sql)
		if not stmt then return nil, tostring(handle:errmsg()) end
		local value
		local ret = stmt:step()
		if ret == sqlite.ROW then
			value = stmt:get_value(0)
		elseif ret ~= sqlite.DONE then
			local message = tostring(handle:errmsg())
			stmt:reset()
			stmt:finalize()
			return nil, message
		end
		stmt:reset()
		stmt:finalize()
		return value
	end

	local version, version_err = scalar("PRAGMA user_version")
	if version == nil and version_err then
		return fail(string.format("cannot read %s: %s", path, version_err))
	end
	local app_id = scalar("PRAGMA application_id")
	if app_id ~= recorder_common.APPLICATION_ID then
		return fail(string.format("%s is not a recorder recording (application_id %s)",
			path, tostring(app_id)))
	end
	if version ~= recorder_common.SCHEMA_VERSION then
		return fail(string.format("%s holds schema version %s; this recorder reads version %d",
			path, tostring(version), recorder_common.SCHEMA_VERSION))
	end
	return handle
end

recorder_common.snapshot = dofile(core.get_modpath("recorder_common") .. "/snapshot.lua")
recorder_common.region = dofile(core.get_modpath("recorder_common") .. "/region.lua")
recorder_common.light = dofile(core.get_modpath("recorder_common") .. "/light.lua")

recorder_common.retention = dofile(core.get_modpath("recorder_common") .. "/retention.lua")
