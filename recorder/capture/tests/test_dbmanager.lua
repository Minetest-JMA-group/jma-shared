-- Integration test: runs the REAL dbmanager.lua against a real SQLite file
-- with a mocked Minetest core. Covers the schema, the shared id sequence, the
-- NULL semantics, foreign keys, dropped batches, metadata and closing.
--
-- Usage: luajit test_dbmanager.lua  (from the tests directory or anywhere)

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
local world = tmpbase .. "/recorder_tests/dbmanager"

os.execute("rm -rf " .. world)
os.execute("mkdir -p " .. world)

local sqlite = require("lsqlite3")

local logs = {}
core = {
	get_current_modname = function() return "recorder" end,
	get_modpath = function() return modpath end,
	get_worldpath = function() return world end,
	log = function(level, msg)
		if type(level) == "string" and msg ~= nil then
			logs[#logs + 1] = level .. ": " .. tostring(msg)
		else
			logs[#logs + 1] = tostring(level)
		end
	end,
}

local dbmanager = dofile(modpath .. "/dbmanager.lua")
dbmanager.init(sqlite)

local checks = 0
local function check(condition, message)
	checks = checks + 1
	if not condition then
		error("FAILED: " .. message, 2)
	end
	print("  ok - " .. message)
end

local function query(handle, sql)
	local rows = {}
	for row in handle:nrows(sql) do
		rows[#rows + 1] = row
	end
	return rows
end

-- The single value of a one-column, one-row query. The statement is stepped,
-- reset and finalized explicitly: leaving one mid-iteration would keep this
-- connection's read snapshot pinned, and later queries would not see what the
-- recorder wrote in the meantime.
local function scalar(handle, sql)
	local stmt = handle:prepare(sql)
	if not stmt then error("cannot prepare " .. sql .. ": " .. tostring(handle:errmsg())) end
	local value
	if stmt:step() == sqlite.ROW then
		value = stmt:get_value(0)  -- lsqlite3 counts result columns from 0
	end
	stmt:reset()
	stmt:finalize()
	return value
end

local path = world .. "/test.sqlite"

print("=== opening a fresh recording ===")
check(dbmanager.open(path) == true, "open() creates the file")
check(dbmanager.is_open(), "is_open() reports the open database")

local reader = sqlite.open(path)  -- a second connection, as an analyst would
check(reader ~= nil, "a second connection can be opened while recording")

check(scalar(reader, "PRAGMA user_version") == 1, "schema version is 1")
check(scalar(reader, "PRAGMA application_id") == 0x4A4D4152, "application_id marks the file as a recording")
check(scalar(reader, "PRAGMA journal_mode") == "wal", "the recording runs in WAL mode")

local tables = {}
for _, row in ipairs(query(reader, "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view')")) do
	tables[row.name] = row.type
end
check(tables.Metadata == "table" and tables.Players == "table", "Metadata and Players exist")
check(tables.Movement == "table" and tables.Events == "table", "Movement and Events exist")
check(tables.Timeline == "view", "the Timeline view exists")

print("=== players ===")
check(dbmanager.player_id("Alice") == 1, "the first player gets id 1")
check(dbmanager.player_id("Bob") == 2, "the next player gets id 2")
check(dbmanager.player_id("Alice") == 1, "a known player is not inserted twice")
check(scalar(reader, "SELECT COUNT(*) FROM Players") == 2, "two Players rows")

print("=== writing rows ===")
-- Movement row 1: the first sample of a player has no acceleration to derive
dbmanager.add_movement({ dbmanager.next_id(), 1, 0.1, 0.1, 1,
	1.0, 2.0, 3.0, 0.25, 1.5, 0.0, 0.0, 5.0, nil, nil, nil, 5.0, 1 + 4, 0.0, 1.0 })
dbmanager.add_event({ dbmanager.next_id(), 1, 0.1, "dig", 1, nil, 10.0, 11.0, 12.0,
	"default:stone", 3, "default:pick_stone", nil })
-- Movement row 2, with acceleration derived from row 1
dbmanager.add_movement({ dbmanager.next_id(), 2, 0.2, 0.1, 1,
	1.0, 2.0, 3.0, 0.25, 1.5, 0.0, 1.0, 5.0, 0.0, 10.0, 0.0, math.sqrt(26), 5, 0.0, 1.0 })
check(dbmanager.buffered() == 3, "three rows are buffered")
check(dbmanager.stats().movement == 0, "nothing is counted as written before the flush")

check(dbmanager.flush() == true, "flush() writes the batch")
check(dbmanager.buffered() == 0, "the buffer is empty after the flush")
local stats = dbmanager.stats()
check(stats.movement == 2 and stats.events == 1, "the written rows are counted")
check(scalar(reader, "SELECT COUNT(*) FROM Movement") == 2, "the movement rows are there")
check(scalar(reader, "SELECT COUNT(*) FROM Events") == 1, "the event row is there")

local first = query(reader, "SELECT * FROM Movement WHERE id = 1")[1]
check(first.acc_x == nil and first.acc_y == nil, "the first sample has NULL acceleration")
check(first.pos_x == 1.0 and first.pos_z == 3.0, "positions are stored as given")
check(first.pitch == 0.25 and first.yaw == 1.5, "orientation is stored as given")
check(first.controls == 5, "the control bitmask is stored as an integer")
check(first.dtime == 0.1 and first.t == 0.1, "the step length and the time are stored")

local second = query(reader, "SELECT * FROM Movement WHERE id = 3")[1]
check(second.acc_y == 10.0, "derived acceleration is stored")

local event = query(reader, "SELECT * FROM Events WHERE id = 2")[1]
check(event.type == "dig" and event.subject_player == 1, "the event records its subject")
check(event.node == "default:stone" and event.param2 == 3, "the event records the node it is about")
check(event.item == "default:pick_stone", "the event records the item used")
check(event.object_player == nil and event.data == nil, "absent fields stay NULL")

print("=== the shared id sequence ===")
local timeline = query(reader, "SELECT id, kind, type FROM Timeline ORDER BY id")
check(#timeline == 3, "the view merges both tables")
check(timeline[1].kind == "movement" and timeline[2].kind == "event" and timeline[3].kind == "movement",
	"the view keeps the order the rows happened in")
check(timeline[2].type == "dig", "the view carries the event type")

print("=== metadata ===")
check(dbmanager.set_meta("ctf:map", "forge") == true, "set_meta writes")
check(dbmanager.get_meta("ctf:map") == "forge", "get_meta reads back")
check(dbmanager.get_meta("nothing") == nil, "an unknown key reads as nil")
check(dbmanager.set_meta("ctf:map", "second") == true, "a key can be written again")
check(dbmanager.get_meta("ctf:map") == "second", "the second value replaces the first")

print("=== rejected rows and dropped batches ===")
dbmanager.add_event({ dbmanager.next_id(), 3, 0.3, "dig", 999, nil,
	nil, nil, nil, nil, nil, nil, nil })
local ok, err, lost = dbmanager.flush()
check(ok == nil, "a row pointing at a player that does not exist fails the flush")
check(lost == 1, "the failed batch reports how many rows were lost")
check(tostring(err):find("FOREIGN KEY constraint failed") ~= nil,
	"foreign keys are enforced: " .. tostring(err))
check(dbmanager.buffered() == 0, "a failed batch is dropped instead of retried forever")
check(dbmanager.stats().dropped == 1, "the dropped rows are counted")
check(dbmanager.stats().failed == 1, "the failure is counted")
check(scalar(reader, "SELECT COUNT(*) FROM Events") == 1, "the failed row is not in the file")

check(dbmanager.flush() == true, "the next flush works again")
check(dbmanager.stats().failed == 0, "a successful flush clears the failure count")

print("=== closing ===")
check(dbmanager.close() == true, "close() folds the log back in")
check(not dbmanager.is_open(), "the database is closed")
check(scalar(reader, "SELECT COUNT(*) FROM Movement") == 2, "the open connection still reads the recording")
reader:close()
-- The log file goes away once nothing holds the recording open
local leftover_wal = io.open(path .. "-wal")
check(leftover_wal == nil, "the write-ahead log is gone")
if leftover_wal then leftover_wal:close() end

local final = sqlite.open(path)
check(final ~= nil, "the finished file opens on its own")
check(scalar(final, "SELECT COUNT(*) FROM Movement") == 2, "the movement rows survived the close")
check(scalar(final, "SELECT value FROM Metadata WHERE key = 'ctf:map'") == "second",
	"the metadata survived the close")
local timeline_after = query(final, "SELECT id FROM Timeline ORDER BY id")
check(#timeline_after == 3, "the view works on the finished file")

print("=== refusing to reuse a file ===")
final:close()
check(select(1, dbmanager.open(path)) == nil, "opening a finished recording is refused")
local not_a_db = world .. "/garbage.sqlite"
local f = io.open(not_a_db, "wb")
f:write("this is not a database at all")
f:close()
local opened, open_err = dbmanager.open(not_a_db)
check(opened == nil, "opening a file that is not a database is refused")
check(tostring(open_err):find("not a SQLite database") ~= nil, "and says so: " .. tostring(open_err))

print("=== closing while something else is reading ===")
local busy_path = world .. "/read-while-closing.sqlite"
check(dbmanager.open(busy_path) == true, "a recording opens")
dbmanager.player_id("Reader")
dbmanager.add_event({ dbmanager.next_id(), 1, 0.1, "test", 1, nil, nil, nil, nil, nil, nil, nil, nil })
check(dbmanager.flush() == true, "a row is written")
local busy_reader = sqlite.open(busy_path)
local reader_stmt = busy_reader:prepare("SELECT COUNT(*) FROM Events")
check(reader_stmt:step() == sqlite.ROW, "another connection reads the recording and holds its snapshot")
local logs_before = #logs
check(dbmanager.close() == true, "the recording still closes")
local told = false
for i = logs_before + 1, #logs do
	if logs[i]:find("write-ahead log", 1, true) then told = true end
end
check(told, "and the operator is told the log file has to travel with it")
reader_stmt:reset()
reader_stmt:finalize()
busy_reader:close()

print("=== a database that is not a recording ===")
local foreign_path = world .. "/foreign.sqlite"
local fdb = sqlite.open(foreign_path)
fdb:exec("CREATE TABLE Notes (id INTEGER PRIMARY KEY, text TEXT) STRICT")
fdb:exec("INSERT INTO Notes (text) VALUES ('somebody else''s data')")
fdb:close()
local refused, refused_err = dbmanager.open(foreign_path)
check(refused == nil, "a database belonging to something else is refused")
check(tostring(refused_err):find("not empty") ~= nil, "and says why: " .. tostring(refused_err))
local foreign = sqlite.open(foreign_path)
check(scalar(foreign, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'Events'") == 0,
	"none of the recorder's schema was written into it")
check(scalar(foreign, "SELECT text FROM Notes") == "somebody else's data", "and its data is untouched")
foreign:close()

print("=== a batch of movement with no events ===")
-- Players moving and nobody doing anything is the ordinary shape of a batch
local only_path = world .. "/movement-only.sqlite"
check(dbmanager.open(only_path) == true, "a recording opens")
dbmanager.player_id("Walker")
dbmanager.add_movement({ dbmanager.next_id(), 1, 0.1, 0.1, 1,
	0, 0, 0, 0, 0, 1, 0, 0, nil, nil, nil, 1, 0, 0, 0 })
dbmanager.add_movement({ dbmanager.next_id(), 2, 0.2, 0.1, 1,
	1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0 })
check(dbmanager.flush() == true, "a batch holding only movement rows is written")
check(dbmanager.stats().movement == 2, "both rows are counted as written")
check(dbmanager.stats().dropped == 0, "nothing was dropped")
check(dbmanager.close() == true, "the recording closes")
local only = sqlite.open(only_path)
check(scalar(only, "SELECT COUNT(*) FROM Movement") == 2, "both movement rows are in the file")
check(scalar(only, "SELECT COUNT(*) FROM Events") == 0, "and no event row was invented")
only:close()

print("=== a value the database refuses ===")
local bad_path = world .. "/bad-value.sqlite"
check(dbmanager.open(bad_path) == true, "a recording opens")
dbmanager.player_id("Writer")
-- lsqlite3 raises rather than returning a code for a value it cannot bind; a
-- raise must not leave the transaction open for every later batch to stumble on
dbmanager.add_event({ dbmanager.next_id(), 1, 0.1, "test", 1, nil, nil, nil, nil, nil, nil, {}, nil })
local rejected, reject_err = dbmanager.flush()
check(rejected == nil, "the batch fails")
check(tostring(reject_err):find("cannot insert row") ~= nil, "with a message: " .. tostring(reject_err))
dbmanager.add_event({ dbmanager.next_id(), 2, 0.2, "test", 1, nil, nil, nil, nil, nil, nil, "fine", nil })
check(dbmanager.flush() == true, "the next batch writes, so no transaction was left open")
check(dbmanager.close() == true, "the recording closes")
local bad = sqlite.open(bad_path)
check(scalar(bad, "SELECT COUNT(*) FROM Events") == 1, "only the good row is in the file")
check(scalar(bad, "SELECT item FROM Events") == "fine", "and it is the one that was expected")
bad:close()

print("=== a player row that cannot be written ===")
local locked_path = world .. "/locked-player.sqlite"
check(dbmanager.open(locked_path) == true, "a recording opens")
local blocker = sqlite.open(locked_path)
check(blocker:exec("BEGIN IMMEDIATE") == sqlite.OK, "another connection takes the write lock")
local player, player_err = dbmanager.player_id("Locked")
check(player == nil, "the player row is not written while the database is locked")
check(tostring(player_err):find("cannot add player") ~= nil, "and the failure is reported, not raised: " ..
	tostring(player_err))
blocker:exec("ROLLBACK")
blocker:close()
check(dbmanager.player_id("Locked") ~= nil, "the same player is picked up once the lock is gone")
check(dbmanager.close() == true, "the recording closes")

print(("\n%d checks passed"):format(checks))
