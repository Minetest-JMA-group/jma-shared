-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- The part of the recorder modpack that its halves have to agree on: what a
-- recording file is, where recordings live, how they are named, and the shape
-- of a region snapshot inside one. Nothing here needs a running world, so it
-- loads on any game that has the pack.

recorder_common = {}

-- What schema.sql writes into every recording, and what a reader checks before
-- trusting one. A recording says this itself, so it can be recognised without
-- knowing which mod wrote it or which world it belongs to.
recorder_common.APPLICATION_ID = 0x4A4D4152  -- 'JMAR'
recorder_common.SCHEMA_VERSION = 1

recorder_common.DEFAULT_NAME = "unnamed"
recorder_common.NAME_MAX = 64

-- What the game (rather than the pack) knows about its own world. A game that
-- wants to provide the arena a replay is built in, or say how a participant
-- gets back from one, registers that here - so no code in the pack has to name
-- a game. A recording's region is deliberately not here: it is a choice about
-- what to record, and the caller of recorder.start() makes it.
--
--   arena                      -> function(size, taken) -> pos1, pos2; `size`
--                                 is the volume needed (the region plus its
--                                 shell), `taken` a list of boxes already in use
--   world_persistent           -> false on a game whose world is rebuilt from
--                                 scratch at boot (nothing to clean up or save)
--   before_enter(player, session) -> the player is about to be taken into a
--                                 replay, still where the game left them and
--                                 with their own inventory
--   on_enter(player, session)  -> a participant entered a replay
--   on_leave(player, session)  -> a participant left one
recorder_common.game_hooks = {
	arena = nil,
	world_persistent = true,
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

-- Where recordings are written. A directory named in the setting is taken
-- relative to the world unless it is an absolute path: the working directory is
-- a property of how the server was started - a systemd unit, the shell somebody
-- ran it from - and a recording has no business landing somewhere else because
-- of it.
---@return string
function recorder_common.recordings_dir()
	local dir = core.settings:get("recorder.directory")
	if not dir or dir == "" then
		return core.get_worldpath() .. "/recordings"
	end
	if dir:sub(1, 1) == "/" then
		return dir
	end
	return core.get_worldpath() .. "/" .. dir
end

-- A recording name ends up in a file name, so anything that is not plainly a
-- word character is replaced, and leading dots (which would walk out of the
-- recordings directory) are dropped.
---@param name string?
---@return string
function recorder_common.sanitize_name(name)
	local clean = tostring(name or ""):gsub("[^%w%-%._]", "_"):gsub("^%.+", "")
	clean = clean:sub(1, recorder_common.NAME_MAX)
	if clean == "" then return recorder_common.DEFAULT_NAME end
	return clean
end

-- Never write into a file that is already there: opening an existing recording
-- would append to it, and a name is not worth that.
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

-- Open a recording to read, and refuse anything that is not one. The connection
-- is read-only, so a bug in a reader can never append to a recording; a
-- recording that is still being written is read as of its last commit, which is
-- what WAL is for.
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

	-- A recording may be written to while it is being read. Readers never block
	-- a writer in WAL, so this only makes a brief checkpoint or schema lock wait
	-- instead of failing outright.
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
