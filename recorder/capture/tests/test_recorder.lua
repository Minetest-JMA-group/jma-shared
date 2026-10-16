-- Integration test: runs the REAL init.lua with a mocked Minetest core and
-- checks the API contract, what ends up in the recording file, and the rules
-- the schema promises a reader (ordering, omitted no-op ticks, derived
-- acceleration, metadata).
--
-- Usage: luajit test_recorder.lua  (from the tests directory or anywhere)

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
local world = tmpbase .. "/recorder_tests/recorder"

os.execute("rm -rf " .. world)
os.execute("mkdir -p " .. world)

local sqlite = require("lsqlite3")
local mocklib = dofile(testdir .. "/mocklib.lua")
local mock = mocklib.new({ modpath = modpath, world = world })
core = mock.core
algorithms = {
	require = function(name)
		if name == "lsqlite3" then return sqlite end
		return nil
	end,
}
dofile(modpath .. "/init.lua")

local checks = 0
local function check(condition, message)
	checks = checks + 1
	if not condition then
		error("FAILED: " .. message, 2)
	end
	print("  ok - " .. message)
end

local function recordings_dir()
	return world .. "/recordings"
end

local function list_recordings()
	local names = {}
	local pipe = io.popen("ls -1 '" .. recordings_dir() .. "' 2>/dev/null")
	for name in pipe:lines() do
		names[#names + 1] = name
	end
	pipe:close()
	table.sort(names)
	return names
end

local function file_exists_anywhere(path)
	local f = io.open(path, "rb")
	if f then f:close() return true end
	return false
end

local function open_recording(path)
	local db = sqlite.open(path)
	if not db then error("cannot open " .. path) end
	return db
end

local function rows(db, sql)
	local out = {}
	for row in db:nrows(sql) do
		out[#out + 1] = row
	end
	return out
end

local function value(db, sql)
	local stmt = db:prepare(sql)
	if not stmt then error("cannot prepare " .. sql .. ": " .. tostring(db:errmsg())) end
	local result
	if stmt:step() == sqlite.ROW then
		result = stmt:get_value(0)
	end
	stmt:reset()
	stmt:finalize()
	return result
end

----------------------------------------------------------------------------
print("=== the API exists without a recording ===")
----------------------------------------------------------------------------

check(type(recorder) == "table", "the mod exports the recorder table")
check(type(recorder.start) == "function" and type(recorder.stop) == "function", "start and stop are there")
check(type(recorder.add_meta) == "function", "add_meta is there")
check(recorder.is_recording() == false, "nothing is being recorded yet")
check(recorder.get_recording_path() == nil, "there is no file to point at yet")
check(type(recorder.stop()) == "string", "stopping without a recording fails with a message")
check(type(recorder.add_meta("k", "v")) == "string", "adding metadata without a recording fails")
check(type(recorder.log_event("mock:thing")) == "string", "logging an event without a recording fails")

----------------------------------------------------------------------------
print("=== while nothing is being recorded ===")
----------------------------------------------------------------------------

-- The mod is loaded on every server that has it in the tree, and most of the
-- time nobody is recording. Until start() is called it must cost the server
-- nothing but the branch that notices that.
local engine_calls = { get_connected_players = 0, mkdir = 0, write_json = 0, get_gametime = 0 }
for name in pairs(engine_calls) do
	local original = mock.core[name]
	mock.core[name] = function(...)
		engine_calls[name] = engine_calls[name] + 1
		return original(...)
	end
end
local files_before = #list_recordings()
local player = mock.add_player("Bystander", { pos = { x = 1, y = 2, z = 3 } })
-- Every callback the engine could fire, and a hundred server steps
for _, callback in ipairs({ "register_on_joinplayer", "register_on_leaveplayer", "register_on_dignode",
		"register_on_placenode", "register_on_punchplayer", "register_on_punchplayer",
		"register_on_player_hpchange", "register_on_chat_message", "register_on_chatcommand",
		"register_on_cheat", "register_on_player_inventory_action" }) do
	mock.fire(callback, player, { x = 0, y = 0, z = 0 }, { name = "default:stone", param2 = 0 })
end
mock.steps(100, 0.1)
for action, count in pairs(engine_calls) do
	check(count == 0, "the engine is not asked for anything while idle: " .. action .. " was called " ..
		tostring(count) .. " time(s)")
end
check(#list_recordings() == files_before, "no recording file appears")
check(not file_exists_anywhere(recordings_dir()), "not even the recordings directory is created")
mock.remove_player("Bystander")

----------------------------------------------------------------------------
print("=== starting and stopping ===")
----------------------------------------------------------------------------

check(recorder.start("first") == nil, "start() returns nil on success")
check(recorder.is_recording() == true, "is_recording() agrees")
check(recorder.get_recording_name() == "first", "the recording knows its name")
local first_path = recorder.get_recording_path()
check(first_path == recordings_dir() .. "/first-" .. os.date("!%Y%m%dT%H%M%SZ") .. ".sqlite",
	"the file is named after the recording and the UTC time: " .. tostring(first_path))
check(type(recorder.start("second")) == "string", "starting a second recording fails")
check(type(recorder.start()) == "string", "starting while recording fails even without a name")
check(recorder.stop() == nil, "stop() returns nil on success")
check(recorder.is_recording() == false, "the recording is over")
check(type(recorder.stop()) == "string", "stopping twice fails the second time")

local started = list_recordings()
check(#started == 1 and started[1]:find("^first%-") ~= nil, "exactly one file was written: " .. table.concat(started, ", "))

-- A recording that is started with no name still gets one
check(recorder.start() == nil, "start() without a name works")
check(recorder.get_recording_name() == "unnamed", "the name defaults to 'unnamed'")
check(recorder.stop() == nil, "it stops again")
check(#list_recordings() == 2, "two files now")

-- Same name in the same second must not overwrite the first file
check(recorder.start("first") == nil, "the same name can be used again")
local second_path = recorder.get_recording_path()
check(second_path ~= first_path, "a second recording never lands in the same file")
check(recorder.stop() == nil, "it stops again")

check(recorder.start("../../etc/passwd") == nil, "a name cannot walk out of the recordings directory")
local evil_path = recorder.get_recording_path()
check(evil_path:find(recordings_dir(), 1, true) == 1, "the file stays inside the recordings directory")
local evil_name = evil_path:sub(#recordings_dir() + 2)
check(evil_name:match("^[%w%-%._]+%.sqlite$") ~= nil,
	"the name is a single, harmless file name: " .. evil_name)
check(recorder.get_recording_name() == "_.._etc_passwd",
	"slashes are replaced and leading dots are dropped")
check(recorder.stop() == nil, "it stops again")

----------------------------------------------------------------------------
print("=== a recording with players and actions ===")
----------------------------------------------------------------------------

local alice = mock.add_player("Alice", { pos = { x = 0, y = 0, z = 0 } })
local bob = mock.add_player("Bob", { pos = { x = 10, y = 0, z = 10 }, wield = "default:sword_wood" })
alice.inventory = { main = { "default:pick_stone", "", "default:torch 10" } }

check(recorder.start("session") == nil, "the recording starts")
local session_path = recorder.get_recording_path()

-- t1: Alice and Bob were already online, so both get their first sample
mock.step(0.1)

-- A player joining while the recording runs
local carol = mock.add_player("Carol", { pos = { x = -5, y = 1, z = 2 }, wield = "default:apple" })
mock.fire("register_on_joinplayer", carol, nil)

-- t2: Alice and Bob say nothing new, Carol is sampled for the first time
mock.step(0.1)
-- t3: Alice starts walking
alice.pos.x = 1
alice.vel.x = 1
mock.step(0.1)
-- t4: Alice keeps walking at the same speed (no acceleration), and draws a tool
alice.pos.x = 2
alice.pitch = -0.5
alice.controls = { up = true, jump = true, movement_y = 0.5 }
alice.wield = "default:pick_stone"
mock.step(0.1)
-- t5: Alice stops (which is a change of velocity, so it is written)
alice.vel.x = 0
alice.controls = {}
mock.step(0.1)
-- t6: her acceleration falls back to zero, which differs from the row before
mock.step(0.1)
-- t7: now nothing about anyone differs, so nothing is written at all
mock.step(0.1)

check(recorder.is_recording(), "still recording")

-- Actions, with subjects, objects and payloads
mock.fire("register_on_dignode", { x = 1, y = 2, z = 3 }, { name = "default:stone", param2 = 3 }, alice)
mock.fire("register_on_placenode", { x = 1, y = 2, z = 4 }, { name = "default:torch", param2 = 1 }, alice,
	{ name = "default:stone", param2 = 0 }, { to_string = function() return "default:torch 1" end }, nil)
mock.fire("register_on_punchplayer", bob, alice, 0.5, {}, { x = 0, y = 0, z = 1 }, 4)
mock.fire("register_on_dignode", { x = 9, y = 9, z = 9 }, { name = "default:dirt", param2 = 0 }, nil)
local mob = { get_luaentity = function() return { name = "mobs:zombie" } end }
mock.fire("register_on_dignode", { x = 8, y = 9, z = 9 }, { name = "default:dirt", param2 = 0 }, mob)
-- An actor that will not even say what it is must not cost the event
mock.fire("register_on_dignode", { x = 7, y = 9, z = 9 }, { name = "default:dirt", param2 = 0 }, {})
mock.fire("register_on_chat_message", "Bob", "hello there")
mock.fire("register_on_chatcommand", "Carol", "recorder", "status")
mock.fire("register_on_dieplayer", bob, { type = "punch", object = alice, from = "engine" })
mock.fire("register_on_respawnplayer", bob)
mock.fire("register_on_player_hpchange", bob, -4, { type = "punch", object = alice })
mock.fire("register_on_craft", { to_string = function() return "default:torch 4" end }, alice,
	{ { to_string = function() return "default:coal_lump" end } }, nil)
mock.fire("register_on_item_eat", 2, nil, { to_string = function() return "default:apple" end }, carol, nil)
mock.fire("register_on_item_pickup", { to_string = function() return "default:stone 3" end }, alice, nil)
-- A move within one inventory carries no stack of its own (only put and take
-- do), so what it left in the destination slot is what the recorder has to go
-- by. Slot 5 is where the pick ends up.
alice.inventory.main[5] = "default:pick_stone 1"
mock.fire("register_on_player_inventory_action", alice, "move",
	alice:get_inventory(), { from_list = "main", from_index = 1, to_list = "main", to_index = 5, count = 1 })
mock.fire("register_on_player_inventory_action", alice, "take",
	alice:get_inventory(), { listname = "main", index = 3,
		stack = { to_string = function() return "default:torch 10" end } })
mock.fire("register_on_rightclickplayer", carol, alice)
mock.fire("register_on_protection_violation", { x = 0, y = 1, z = 0 }, "Bob")
mock.fire("register_on_cheat", alice, { type = "moved_too_fast" })

-- Another mod attaching what was going on
check(recorder.add_meta("ctf:map", "forge") == nil, "add_meta works while recording")
check(type(recorder.add_meta("recorder.mine", "x")) == "string", "the recorder's own keys are refused")
check(type(recorder.add_meta(nil, "x")) == "string", "a non-string key is refused")
check(recorder.log_event("ctf:capture", {
	subject = alice, item = "ctf:flag_red", pos = { x = 1, y = 2, z = 3 }, data = { team = "red" },
}) == nil, "another mod can log its own event")

-- Leaving, with and without a reason to remember
mock.fire("register_on_leaveplayer", bob, false)
mock.fire("register_on_leaveplayer", carol, true)

check(recorder.stop() == nil, "the recording stops")

----------------------------------------------------------------------------
print("=== what ended up in the file ===")
----------------------------------------------------------------------------

local db = open_recording(session_path)
local function events_of(type_name)
	return rows(db, "SELECT * FROM Events WHERE type = '" .. type_name .. "' ORDER BY id")
end
local function movement_of(player_name)
	return rows(db, ("SELECT Movement.* FROM Movement JOIN Players ON Players.id = Movement.player_id " ..
		"WHERE Players.name = '%s' ORDER BY Movement.id"):format(player_name))
end

check(value(db, "SELECT COUNT(*) FROM Players") == 3, "the three players are in the file")
check(value(db, "SELECT name FROM Players WHERE id = 1") == "Alice", "players are numbered as they appear")

-- Order
check(value(db, "SELECT MIN(tick) FROM Movement") >= 1, "sampling starts after the recording did")
check(value(db, "SELECT COUNT(*) FROM (SELECT id FROM Timeline GROUP BY id HAVING COUNT(*) > 1)") == 0,
	"no id is used by two rows")
local out_of_order = value(db, "SELECT COUNT(*) FROM (SELECT tick, LAG(tick) OVER (ORDER BY id) AS previous " ..
	"FROM Timeline) WHERE previous > tick")
check(out_of_order == 0, "the timeline never goes back in time")
local ids = rows(db, "SELECT id FROM Timeline ORDER BY id")
check(ids[1].id == 1 and ids[#ids].id == #ids, "the ids are one unbroken run from 1")

-- The opening of the recording
local start_event = events_of("recording_start")
check(#start_event == 1 and start_event[1].tick == 0, "the recording opens with a marker at tick 0")
local joins = events_of("join")
check(#joins == 3, "Alice and Bob are joined at the start, Carol when she connects")
check(joins[1].data:find('"at_start":true') ~= nil, "the two who were already online are marked as such")
check(joins[3].subject_player == 3 and joins[3].data:find('"at_start"') == nil,
	"Carol's join is an ordinary one")
check(joins[2].item == "default:sword_wood", "a join carries what the player was holding")
check(joins[1].item == nil, "a player holding nothing has no item")
check(joins[1].data:find('"main":%["default:pick_stone","","default:torch 10"%]') ~= nil,
	"a join carries the player's inventory, slot for slot: " .. tostring(joins[1].data))
local stops = events_of("recording_stop")
check(#stops == 1 and stops[1].data:find('"reason":"api"') ~= nil, "the recording closes with its reason")

-- Movement: written when something changes, not otherwise
-- Alice and Bob get one sample each on the first tick, then one more when
-- their acceleration turns out to be zero rather than unknown; Carol's two
-- land on the ticks she arrived and the one after; Alice's five moving ticks
-- follow; the last tick says nothing about anyone and is left out.
local total_movement = value(db, "SELECT COUNT(*) FROM Movement")
check(total_movement == 10, "quiet ticks are not written (got " .. tostring(total_movement) .. ")")
local alice_movement = movement_of("Alice")
check(#alice_movement == 6, "Alice has a row for each tick that said something new")
check(value(db, "SELECT MAX(tick) FROM Movement") == 6, "the last tick says nothing new")
check(alice_movement[1].pos_x == 0 and alice_movement[1].acc_x == nil,
	"the first sample is where she stood, with no acceleration to derive")
check(alice_movement[2].acc_x == 0.0, "the sample after it says the acceleration is zero")
check(alice_movement[3].pos_x == 1 and math.abs(alice_movement[3].acc_x - 10) < 1e-9,
	"walking from a standstill is acceleration 10 (1 m/s in a 0.1 s step)")
check(alice_movement[4].pos_x == 2 and alice_movement[4].acc_x == 0,
	"keeping the speed is no acceleration")
check(math.abs(alice_movement[5].acc_x + 10) < 1e-9, "stopping is negative acceleration")
check(alice_movement[4].pitch == -0.5 and alice_movement[4].yaw == 0, "orientation is recorded")
check(alice_movement[4].controls == 1 + 16, "the pressed keys are recorded as a bitmask")
check(alice_movement[4].move_y == 0.5, "the analog movement axis is recorded")
check(alice_movement[4].speed == 1, "speed is the length of the velocity")
local bob_movement = movement_of("Bob")
check(#bob_movement == 2 and bob_movement[1].vel_x == 0 and bob_movement[1].speed == 0,
	"a player who never moves has just those first two samples")
local carol_movement = movement_of("Carol")
check(#carol_movement == 2 and carol_movement[1].tick == 2 and carol_movement[1].acc_x == nil,
	"a player who joins is sampled from the tick they arrived on")

-- Events: subject, object and payload
local digs = events_of("dig")
check(#digs == 4, "the digs are recorded")
check(digs[1].subject_player == 1 and digs[1].node == "default:stone" and digs[1].param2 == 3,
	"a dig has its digger, the node and the node's param2")
check(digs[1].pos_x == 1 and digs[1].pos_y == 2 and digs[1].pos_z == 3, "a dig has the position")
check(digs[1].item == "default:pick_stone", "a dig has the tool that was used")
check(digs[2].subject_player == nil, "a dig with no digger has no subject")
check(digs[3].subject_player == nil and digs[3].data == '{"actor":"entity:mobs:zombie"}',
	"a dig by a mob says what did it")
check(digs[4].data == '{"actor":"unknown"}', "an actor that cannot be identified is still recorded")

local places = events_of("place")
check(places[1].subject_player == 1 and places[1].node == "default:torch" and places[1].param2 == 1,
	"a place has the node that appeared")
check(places[1].item == "default:torch 1", "a place has the stack that was placed")
check(places[1].data:find('"old_node":"default:stone"') ~= nil, "a place remembers what it replaced")

local punches = events_of("punch_player")
check(punches[1].subject_player == 1 and punches[1].object_player == 2,
	"a punch separates the puncher from the punched")
check(punches[1].data:find('"damage":4') ~= nil and punches[1].data:find('"dir"') ~= nil,
	"a punch carries its damage and direction")
check(punches[1].data:find('"tool":"default:pick_stone"') ~= nil,
	"a punch carries what the puncher was holding")

check(#events_of("chat") == 1 and #events_of("chatcommand") == 1, "talking is recorded")
check(events_of("chat")[1].subject_player == 2, "who talked is the subject")
check(events_of("chat")[1].data:find("hello there") ~= nil, "what was said is in the data")
local leaves = events_of("leave")
check(#leaves == 2, "leaving is recorded")
check(leaves[1].data == nil, "an ordinary quit carries no data: " .. tostring(leaves[1].data))
check(leaves[2].data == '{"timed_out":true}', "a timeout says so: " .. tostring(leaves[2].data))
check(#events_of("die") == 1 and #events_of("respawn") == 1, "dying and coming back are recorded")
check(events_of("die")[1].data:find('"object":"Alice"') ~= nil,
	"the reason for a death names the player responsible, not an ObjectRef")
check(events_of("hp_change")[1].data:find('"amount":-4', 1, true) ~= nil,
	"damage is recorded with its amount")
check(#events_of("craft") == 1 and #events_of("item_eat") == 1, "crafting and eating are recorded")
check(#events_of("item_pickup") == 1, "picking something up is recorded")
check(#events_of("inventory_move") == 1, "moving something in an inventory is recorded")
check(events_of("inventory_move")[1].item == "default:pick_stone 1",
	"a move says what it left in the destination slot")
check(events_of("inventory_move")[1].data:find('"from_list":"main"') ~= nil, "the lists involved are kept")
check(events_of("inventory_take")[1].item == "default:torch 10", "a take says what was taken")
check(#events_of("rightclick_player") == 1, "rightclicking a player is recorded")
check(events_of("rightclick_player")[1].object_player == 3 and
	events_of("rightclick_player")[1].subject_player == 1, "with its clicker and its target")
check(#events_of("protection_violation") == 1, "protection violations are recorded")
check(#events_of("cheat") == 1 and events_of("cheat")[1].data:find("moved_too_fast") ~= nil, "cheats are recorded")

local wield = events_of("wield")
check(#wield == 1 and wield[1].subject_player == 1 and wield[1].item == "default:pick_stone",
	"drawing a different tool is an event")
check(#events_of("ctf:capture") == 1, "the event another mod logged is in the timeline")
check(events_of("ctf:capture")[1].item == "ctf:flag_red", "with the fields it gave")

check(value(db, "SELECT COUNT(*) FROM Events WHERE data IS NOT NULL AND json_valid(data) = 0") == 0,
	"every data blob is valid JSON")

-- Metadata
check(value(db, "SELECT value FROM Metadata WHERE key = 'ctf:map'") == "forge", "add_meta reached the file")
check(value(db, "SELECT value FROM Metadata WHERE key = 'recorder.name'") == "session",
	"the recorder describes its own recording")
check(value(db, "PRAGMA user_version") == 1, "the schema version the file carries itself is 1")
check(value(db, "SELECT COUNT(*) FROM Metadata WHERE key = 'recorder.format_version'") == 0,
	"and is not repeated in the metadata, where it could drift from it")
check(value(db, "SELECT value FROM Metadata WHERE key = 'recorder.started_at'") ~= nil, "the start time is in the file")
check(value(db, "SELECT value FROM Metadata WHERE key = 'recorder.game'") == "mockgame", "so is the game")
check(value(db, "SELECT value FROM Metadata WHERE key = 'recorder.server_version'") == "5.14.0-mock",
	"and the engine version")
db:close()

----------------------------------------------------------------------------
print("=== a recording of nothing but movement ===")
----------------------------------------------------------------------------

-- The steady state: players walking and nobody doing anything, so every commit
-- is a batch of movement rows with no event beside it. Such a batch is the
-- ordinary shape, not a special case.
mock.settings["recorder.flush_interval"] = "0.2"
check(recorder.start("walking") == nil, "the recording starts")
local walking_path = recorder.get_recording_path()
for i = 1, 20 do
	alice.pos.x = i
	alice.vel.x = 1
	mock.step(0.1)
end
check(recorder.is_recording(), "it is still recording after twenty steps")
check(recorder.stop() == nil, "it stops")
db = open_recording(walking_path)
local walk_errors = value(db, "SELECT COUNT(*) FROM Events WHERE type = 'write_error'")
check(walk_errors == 0, "no gap was invented (got " .. tostring(walk_errors) .. " write_error events)")
local walker_rows = value(db, "SELECT COUNT(*) FROM Movement JOIN Players ON Players.id = Movement.player_id " ..
	"WHERE Players.name = 'Alice'")
check(walker_rows == 20, "every step she walked was written (got " .. tostring(walker_rows) .. ")")
db:close()

----------------------------------------------------------------------------
print("=== a mod logging something odd ===")
----------------------------------------------------------------------------

check(recorder.start("odd") == nil, "the recording starts")
local odd_path = recorder.get_recording_path()
check(type(recorder.log_event("mock:bad", { pos = 5 })) == "string", "a position that is not a table is refused")
check(type(recorder.log_event("mock:bad", { pos = { x = 1 } })) == "string", "a position missing values is refused")
check(type(recorder.log_event("mock:bad", { node = {} })) == "string", "a node that is not a name is refused")
check(type(recorder.log_event("mock:bad", { param2 = "lots" })) == "string", "a param2 that is not a number is refused")
check(recorder.log_event("mock:flag", { item = { to_string = function() return "ctf:flag_red 1" end } }) == nil,
	"an ItemStack is accepted where an itemstring belongs")
check(recorder.log_event("mock:rounded", { node = "default:wool", param2 = 2.5 }) == nil,
	"a param2 that is not a whole number is accepted")
check(recorder.log_event("mock:named", { subject = "Alice", item = "default:stick" }) == nil,
	"a player can be named instead of handed over")
check(recorder.stop() == nil, "it stops")
db = open_recording(odd_path)
check(value(db, "SELECT COUNT(*) FROM Events WHERE type = 'mock:bad'") == 0, "nothing malformed was written")
check(value(db, "SELECT item FROM Events WHERE type = 'mock:flag'") == "ctf:flag_red 1",
	"the stack was stored as an itemstring")
check(value(db, "SELECT param2 FROM Events WHERE type = 'mock:rounded'") == 2,
	"the fractional param2 was rounded down rather than costing the row")
check(value(db, "SELECT subject_player FROM Events WHERE type = 'mock:named'") ==
	value(db, "SELECT id FROM Players WHERE name = 'Alice'"), "the named player is the subject")
db:close()

----------------------------------------------------------------------------
print("=== when a player's row cannot be written ===")
----------------------------------------------------------------------------

-- The database is busy for a moment while somebody joins. The join must not
-- raise, and the player must not be struck off the recording for good.
mock.settings["recorder.flush_interval"] = "0.01"
check(recorder.start("unwritable") == nil, "the recording starts")
local unwritable_path = recorder.get_recording_path()
local blocker = sqlite.open(unwritable_path)
check(blocker:exec("BEGIN IMMEDIATE") == sqlite.OK, "another connection takes the write lock")
local erin = mock.add_player("Erin", { pos = { x = 1, y = 2, z = 3 } })
local joined = pcall(mock.fire, "register_on_joinplayer", erin, nil)
check(joined, "the join callback survives it")
mock.step(0.1)
check(recorder.is_recording(), "and the recording carries on")
blocker:exec("ROLLBACK")
blocker:close()
mock.steps(3, 0.1)
check(recorder.stop() == nil, "it stops")
db = open_recording(unwritable_path)
check(value(db, "SELECT COUNT(*) FROM Players WHERE name = 'Erin'") == 1,
	"the player is in the recording once writing works again")
local trouble = value(db, "SELECT value FROM Metadata WHERE key = 'recorder.player_errors'")
check(trouble ~= nil and trouble:find("Erin", 1, true) ~= nil,
	"and the recording writes down that her row was a problem: " .. tostring(trouble))
local erin_rows = value(db, "SELECT COUNT(*) FROM Movement JOIN Players ON Players.id = Movement.player_id " ..
	"WHERE Players.name = 'Erin'")
check(erin_rows >= 1, "their movement is recorded too (got " .. tostring(erin_rows) .. ")")
db:close()
mock.settings["recorder.flush_interval"] = nil
mock.remove_player("Erin")

----------------------------------------------------------------------------
print("=== a stop that cannot be written ===")
----------------------------------------------------------------------------

check(recorder.start("stuck") == nil, "the recording starts")
local stuck_path = recorder.get_recording_path()
mock.step(0.1)
local stuck_blocker = sqlite.open(stuck_path)
check(stuck_blocker:exec("BEGIN IMMEDIATE") == sqlite.OK, "another connection takes the write lock")
local stop_error = recorder.stop()
check(type(stop_error) == "string", "stop reports that the last rows could not be written: " ..
	tostring(stop_error))
check(recorder.is_recording() == false, "and the recording is over all the same")
stuck_blocker:exec("ROLLBACK")
stuck_blocker:close()
db = open_recording(stuck_path)
check(value(db, "SELECT COUNT(*) FROM Events WHERE type = 'recording_stop'") == 0,
	"the file has no end marker, the way an interrupted recording does not")
check(value(db, "SELECT COUNT(*) FROM Metadata WHERE key = 'recorder.stopped_at'") == 0,
	"and its metadata does not claim it stopped cleanly")
db:close()

----------------------------------------------------------------------------
print("=== a tool drawn while the write is stuck ===")
----------------------------------------------------------------------------

mock.settings["recorder.flush_interval"] = "0.01"  -- commit on every step
check(recorder.start("wieldgap") == nil, "the recording starts")
local wieldgap_path = recorder.get_recording_path()
mock.step(0.1)
local wield_blocker = sqlite.open(wieldgap_path)
check(wield_blocker:exec("BEGIN IMMEDIATE") == sqlite.OK, "another connection takes the write lock")
alice.wield = "default:pick_steel"
mock.step(0.1)
wield_blocker:exec("ROLLBACK")
wield_blocker:close()
mock.steps(2, 0.1)
check(recorder.stop() == nil, "it stops")
db = open_recording(wieldgap_path)
check(value(db, "SELECT COUNT(*) FROM Events WHERE type = 'write_error'") >= 1, "the gap is marked")
check(value(db, "SELECT COUNT(*) FROM Events WHERE type = 'wield' AND item LIKE 'default:pick_steel%'") >= 1,
	"and the tool is announced again rather than lost with the rows that went missing")
db:close()
mock.settings["recorder.flush_interval"] = nil

----------------------------------------------------------------------------
print("=== 0 means no early commit, not a commit every step ===")
----------------------------------------------------------------------------

mock.settings["recorder.flush_interval"] = "100"
mock.settings["recorder.max_buffered"] = "0"
check(recorder.start("patient") == nil, "the recording starts")
local patient_path = recorder.get_recording_path()
alice.pos.x = 123
alice.vel.x = 0
mock.steps(3, 0.1)
local watcher = sqlite.open(patient_path)
check(value(watcher, "SELECT COUNT(*) FROM Movement") == 0, "nothing is committed before the interval is up")
watcher:close()
check(recorder.stop() == nil, "it stops")
db = open_recording(patient_path)
check(value(db, "SELECT COUNT(*) FROM Movement") > 0, "stopping writes out what was still buffered")
db:close()
mock.settings["recorder.flush_interval"] = nil
mock.settings["recorder.max_buffered"] = nil

----------------------------------------------------------------------------
print("=== a player joining in the moment the recording starts ===")
----------------------------------------------------------------------------

-- The opening state of the world is taken at the first server step, because a
-- mod is allowed to start a recording while it is still loading. Someone who
-- joins in between is already in the recording and must not be joined again.
local dave = mock.add_player("Dave", { pos = { x = 1, y = 1, z = 1 } })
check(recorder.start("window") == nil, "the recording starts")
local window_path = recorder.get_recording_path()
mock.fire("register_on_joinplayer", dave, nil)
mock.step(0.1)
check(recorder.stop() == nil, "it stops")
db = open_recording(window_path)
local dave_joins = value(db, "SELECT COUNT(*) FROM Events WHERE type = 'join' AND subject_player = " ..
	"(SELECT id FROM Players WHERE name = 'Dave')")
check(dave_joins == 1, "the player is joined exactly once, not twice (got " .. tostring(dave_joins) .. ")")
local all_joins = value(db, "SELECT COUNT(*) FROM Events WHERE type = 'join'")
check(all_joins == 4, "everyone online is in the recording (got " .. tostring(all_joins) .. ")")
check(value(db, "SELECT COUNT(*) FROM Events WHERE type = 'join' AND data LIKE '%at_start%'") == 3,
	"the three who were already there are marked as such, the one who joined is not")
check(value(db, "SELECT COUNT(*) FROM Events WHERE type = 'join' AND tick = 0") == 4,
	"the recording opens at tick 0 with everybody in it")
db:close()
mock.remove_player("Dave")

----------------------------------------------------------------------------
print("=== a player that cannot be read ===")
----------------------------------------------------------------------------

-- An object that is gone by the time it is sampled must not take the rest of
-- the recording with it, on this tick or on the ones after it.
local broken = mock.add_player("Broken")
broken.get_pos = function() error("this object no longer exists") end
check(recorder.start("broken_player") == nil, "a recording starts")
local broken_path = recorder.get_recording_path()
mock.steps(3, 0.1)
check(recorder.is_recording(), "it does not end over one unreadable player")
check(recorder.stop() == nil, "it stops normally")
db = open_recording(broken_path)
check(value(db, ("SELECT COUNT(*) FROM Movement JOIN Players ON Players.id = Movement.player_id " ..
	"WHERE Players.name = 'Alice' AND Movement.tick = 1")) == 1, "the other players are still recorded")
check(value(db, ("SELECT COUNT(*) FROM Movement JOIN Players ON Players.id = Movement.player_id " ..
	"WHERE Players.name = 'Broken'")) == 0, "the player that cannot be read has no samples")
db:close()
local complaints = 0
for _, log in ipairs(mock.logs) do
	if log.message and log.message:find("cannot sample a player", 1, true) then complaints = complaints + 1 end
end
check(complaints == 1, "the problem is reported once, not once per tick")
mock.remove_player("Broken")

----------------------------------------------------------------------------
print("=== when the write cannot happen ===")
----------------------------------------------------------------------------

-- Someone else holding the write lock makes the next commit fail. What matters
-- then is that the recording carries on, says so, and starts over from a known
-- state for every player instead of pretending nothing happened.
mock.settings["recorder.flush_interval"] = "0.01"  -- commit on every step
check(recorder.start("blocked") == nil, "the recording starts")
local blocked_path = recorder.get_recording_path()
mock.step(0.1)
local logged_before = #mock.logs

local blocker = sqlite.open(blocked_path)
check(blocker:exec("BEGIN IMMEDIATE") == sqlite.OK, "another connection takes the write lock")
alice.pos.x = 3
mock.step(0.1)
check(recorder.is_recording(), "one failed commit does not end the recording")
local complaint
for i = logged_before + 1, #mock.logs do
	if mock.logs[i].message:find("cannot write", 1, true) then complaint = mock.logs[i].message end
end
check(complaint ~= nil, "the failure is logged: " .. tostring(complaint))
blocker:exec("ROLLBACK")
blocker:close()

mock.step(0.1)
check(recorder.stop() == nil, "the recording stops normally afterwards")
db = open_recording(blocked_path)
local errors = events_of("write_error")
check(#errors == 1, "the recording itself says where the gap is")
check(errors[1].data:find('"dropped_rows"', 1, true) ~= nil, "and how much was lost: " .. tostring(errors[1].data))
-- Bob never moved, so he only has a row again because the recording re-synced
local bob_rows = value(db, ("SELECT COUNT(*) FROM Movement JOIN Players ON Players.id = Movement.player_id " ..
	"WHERE Players.name = 'Bob' AND Movement.tick = %d"):format(errors[1].tick + 1))
check(bob_rows == 1, "every player is written again after a gap, so a reader is not left guessing")
db:close()
mock.settings["recorder.flush_interval"] = nil

----------------------------------------------------------------------------
print("=== settings ===")
----------------------------------------------------------------------------

-- A recording that gives itself a deadline
mock.settings["recorder.max_duration"] = "0.25"
check(recorder.start("limited") == nil, "a recording with a duration limit starts")
local limited_path = recorder.get_recording_path()
mock.steps(6, 0.1)
check(recorder.is_recording() == false, "it stops itself at the limit")
db = open_recording(limited_path)
check(value(db, "SELECT COUNT(*) FROM Events WHERE type = 'recording_stop' AND data LIKE '%limit_duration%'") == 1,
	"and says why it stopped")
db:close()
mock.settings["recorder.max_duration"] = nil

-- Events an operator does not want
mock.settings["recorder.disabled_events"] = "chat, chatcommand"
check(recorder.start("quiet") == nil, "a recording with noisy events turned off starts")
local quiet_path = recorder.get_recording_path()
mock.fire("register_on_chat_message", "Alice", "not recorded")
mock.fire("register_on_dignode", { x = 0, y = 0, z = 0 }, { name = "default:stone", param2 = 0 }, alice)
check(recorder.stop() == nil, "it stops")
db = open_recording(quiet_path)
check(value(db, "SELECT COUNT(*) FROM Events WHERE type = 'chat'") == 0, "the turned-off event is not there")
check(value(db, "SELECT COUNT(*) FROM Events WHERE type = 'dig'") == 1, "the others still are")
db:close()
mock.settings["recorder.disabled_events"] = nil

-- What a recording needs in order to explain itself is not a matter of taste
mock.settings["recorder.disabled_events"] = "write_error"
mock.settings["recorder.flush_interval"] = "0.01"  -- commit on every step
local logged_before = #mock.logs
check(recorder.start("markers") == nil, "a recording starts")
local markers_path = recorder.get_recording_path()
local markers_blocker = sqlite.open(markers_path)
check(markers_blocker:exec("BEGIN IMMEDIATE") == sqlite.OK, "another connection takes the write lock")
mock.step(0.1)
markers_blocker:exec("ROLLBACK")
markers_blocker:close()
check(recorder.stop() == nil, "it stops")
db = open_recording(markers_path)
check(value(db, "SELECT COUNT(*) FROM Events WHERE type = 'write_error'") >= 1,
	"the gap marker is written even though the setting names it")
db:close()
local objected = false
for i = logged_before + 1, #mock.logs do
	if mock.logs[i].message and mock.logs[i].message:find("always recorded", 1, true) then objected = true end
end
check(objected, "and the setting is reported as ignored")
mock.settings["recorder.disabled_events"] = nil
mock.settings["recorder.flush_interval"] = nil

-- The chat command
local command = mock.chatcommands.recorder
check(command ~= nil, "the /recorder command is registered")
check(command.privs.server == true, "and needs the server privilege")
local ok, message = command.func("someone", "")
check(ok and message:find("No recording in progress") ~= nil, "/recorder says nothing is being recorded")
ok, message = command.func("someone", "start fromchat")
check(ok and recorder.is_recording(), "/recorder start begins a recording")
ok, message = command.func("someone", "meta mode survival")
check(ok and recorder.add_meta("mode", "survival") == nil, "/recorder meta attaches metadata")
ok, message = command.func("someone", "status")
check(ok and message:find("Recording 'fromchat'") ~= nil, "/recorder status describes it: " .. tostring(message))
ok, message = command.func("someone", "stop")
check(ok and not recorder.is_recording(), "/recorder stop ends it")

-- The server going down takes the recording with it
check(recorder.start("shutdown") == nil, "a recording starts before the shutdown")
local shutdown_path = recorder.get_recording_path()
mock.fire("register_on_shutdown")
check(recorder.is_recording() == false, "the shutdown stopped it")
db = open_recording(shutdown_path)
check(value(db, "SELECT COUNT(*) FROM Events WHERE data LIKE '%shutdown%'") == 1,
	"the recording says it was the shutdown that ended it")
db:close()

print(("\n%d checks passed"):format(checks))
