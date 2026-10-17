-- Tests for the shared half of the recorder pack: where recordings live, how
-- they are named, the game hooks, and read-only access to a recording file.

local function script_dir()
	local src = debug.getinfo(1, "S").source:sub(2)  -- strip the leading "@"
	if src:sub(1, 1) ~= "/" then
		src = (os.getenv("PWD") or ".") .. "/" .. src
	end
	return src:match("^(.*)/[^/]+$")
end

local testdir = script_dir()
local modpath = testdir:gsub("/tests$", "")
local tmpbase = os.getenv("TMPDIR") or "/tmp"
local work = tmpbase .. "/recorder_common_tests/work"

os.execute("rm -rf " .. work)
os.execute("mkdir -p " .. work)

local settings = {}
local world = work .. "/world"
core = {
	get_modpath = function(name)
		if name == "recorder_common" then return modpath end
	end,
	get_worldpath = function() return world end,
	settings = {
		get = function(self, key) return settings[key] end,
		set = function(self, key, value) settings[key] = value end,
	},
}
dofile(modpath .. "/init.lua")
local common = recorder_common

local checks = 0
local function check(condition, message)
	checks = checks + 1
	if not condition then
		error("FAILED: " .. message, 2)
	end
	print("  ok - " .. message)
end

local function write_file(path, contents)
	local f = io.open(path, "wb")
	f:write(contents)
	f:close()
end

----------------------------------------------------------------------------
print("=== recording names ===")
----------------------------------------------------------------------------
check(common.sanitize_name("../../etc/passwd") == "_.._etc_passwd",
	"slashes are replaced and leading dots are dropped")
check(common.sanitize_name("") == "unnamed", "an empty name becomes the default")
check(common.sanitize_name(nil) == "unnamed", "so does no name at all")
check(#common.sanitize_name(string.rep("a", 200)) == common.NAME_MAX, "a long name is cut to the limit")
check(common.sanitize_name("ctf match 1!") == "ctf_match_1_", "spaces and punctuation become underscores")

----------------------------------------------------------------------------
print("=== where recordings live ===")
----------------------------------------------------------------------------
check(common.recordings_dir() == world .. "/recordings", "the default is world/recordings")
settings["recorder.directory"] = "recordings"
check(common.recordings_dir() == world .. "/recordings", "a relative directory is taken from the world")
settings["recorder.directory"] = "/var/lib/recordings"
check(common.recordings_dir() == "/var/lib/recordings", "an absolute directory is used as it is")
settings["recorder.directory"] = nil

----------------------------------------------------------------------------
print("=== unique file names ===")
----------------------------------------------------------------------------
local dir = work .. "/recordings"
os.execute("mkdir -p " .. dir)
local first = common.unique_path(dir, "match")
check(first == dir .. "/match.sqlite", "the first recording gets the plain name")
write_file(first, "x")
check(common.unique_path(dir, "match") == dir .. "/match-2.sqlite", "an existing file is not reused")
write_file(dir .. "/match-2.sqlite", "x")
check(common.unique_path(dir, "match") == dir .. "/match-3.sqlite", "the next number follows")
check(common.file_exists(first), "file_exists sees a file")
check(not common.file_exists(dir .. "/nothing.sqlite"), "and does not invent one")

----------------------------------------------------------------------------
print("=== game hooks ===")
----------------------------------------------------------------------------
check(common.game_hooks.world_persistent == true, "a world is persistent unless the game says otherwise")
check(common.game_hooks.region == nil and common.game_hooks.arena == nil, "no provider by default")
local region = function() return nil end
local arena = function() return nil end
common.register_game_hooks({region = region, arena = arena, world_persistent = false})
check(common.game_hooks.region == region and common.game_hooks.arena == arena,
	"a game adds its providers")
check(common.game_hooks.world_persistent == false, "and its world policy")
check(common.game_hooks.on_enter == nil, "hooks it does not set keep their defaults")

----------------------------------------------------------------------------
print("=== read-only access ===")
----------------------------------------------------------------------------
local sqlite = require("lsqlite3")

local function make_database(path, contents)
	local db = sqlite.open(path)
	assert(db, "cannot create " .. path)
	for _, sql in ipairs(contents) do
		assert(db:exec(sql) == sqlite.OK, sql .. ": " .. tostring(db:errmsg()))
	end
	return db
end

local garbage = work .. "/garbage.sqlite"
write_file(garbage, "this is not a database at all")
local opened, err = common.open_read_only(garbage, sqlite)
check(opened == nil, "a file that is not a database is refused")
check(tostring(err):find("cannot read", 1, true) ~= nil or tostring(err):find("not a recorder", 1, true) ~= nil,
	"with a message: " .. tostring(err))

local foreign = work .. "/foreign.sqlite"
local fdb = make_database(foreign, {
	"CREATE TABLE Notes (id INTEGER PRIMARY KEY, text TEXT) STRICT",
	"INSERT INTO Notes (text) VALUES ('somebody else''s data')",
})
fdb:close()
opened, err = common.open_read_only(foreign, sqlite)
check(opened == nil, "a database belonging to something else is refused")
check(tostring(err):find("not a recorder recording", 1, true) ~= nil, "and says why: " .. tostring(err))

local future = work .. "/future.sqlite"
local fut = make_database(future, {
	string.format("PRAGMA application_id = %d", common.APPLICATION_ID),
	"PRAGMA user_version = 99",
	"CREATE TABLE Something (x INTEGER) STRICT",
})
fut:close()
opened, err = common.open_read_only(future, sqlite)
check(opened == nil, "an unknown schema version is refused")
check(tostring(err):find("schema version 99", 1, true) ~= nil, "and says which: " .. tostring(err))

local recording = work .. "/recording.sqlite"
local rdb = make_database(recording, {
	string.format("PRAGMA application_id = %d", common.APPLICATION_ID),
	string.format("PRAGMA user_version = %d", common.SCHEMA_VERSION),
	"PRAGMA journal_mode = WAL",
	"CREATE TABLE Events (id INTEGER PRIMARY KEY, type TEXT NOT NULL) STRICT",
	"INSERT INTO Events (type) VALUES ('dig')",
})
local reader = common.open_read_only(recording, sqlite)
check(reader ~= nil, "a recording opens for reading")

local seen = 0
for row in reader:nrows("SELECT type FROM Events") do
	seen = seen + 1
	check(row.type == "dig", "and its rows are readable")
end
check(seen == 1, "exactly the committed row")
check(reader:exec("CREATE TABLE Nope (x INTEGER)") ~= sqlite.OK,
	"the connection refuses writes even though it could make them")
reader:close()

-- A reader must see the last commit of a recording that is still being written,
-- without waiting for the writer.
local live = work .. "/live.sqlite"
local wdb = make_database(live, {
	string.format("PRAGMA application_id = %d", common.APPLICATION_ID),
	string.format("PRAGMA user_version = %d", common.SCHEMA_VERSION),
	"PRAGMA journal_mode = WAL",
	"CREATE TABLE Events (id INTEGER PRIMARY KEY, type TEXT NOT NULL) STRICT",
	"INSERT INTO Events (type) VALUES ('place')",
})
check(wdb:exec("BEGIN IMMEDIATE") == sqlite.OK, "a writer takes the write lock")
local live_reader = common.open_read_only(live, sqlite)
check(live_reader ~= nil, "a live recording still opens for reading")
local live_seen
for row in live_reader:nrows("SELECT type FROM Events") do live_seen = row.type end
check(live_seen == "place", "and shows what was last committed: " .. tostring(live_seen))
live_reader:close()
wdb:exec("ROLLBACK")
wdb:close()
rdb:close()

print(("\n%d checks passed"):format(checks))
