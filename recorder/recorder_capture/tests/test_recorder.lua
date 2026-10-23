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
local commonpath = modpath:gsub("/recorder_capture$", "/recorder_common")
local tmpbase = os.getenv("TMPDIR") or "/tmp"
local world = tmpbase .. "/recorder_tests/recorder"

os.execute("rm -rf " .. world)
os.execute("mkdir -p " .. world)

local sqlite = require("lsqlite3")
local mocklib = dofile(commonpath .. "/tests/mocklib.lua")
local mock = mocklib.new({
	modpaths = {recorder_capture = modpath, recorder_common = commonpath},
	world = world,
})
core = mock.core
-- The pack's shared half loads before the mod that depends on it.
dofile(commonpath .. "/init.lua")
algorithms = {
	require = function(name)
		if name == "lsqlite3" then return sqlite end
		return nil
	end,
}
dofile(modpath .. "/init.lua")

-- The region every test recording covers: wide enough for every position the
-- suite uses, and small enough that the mock can walk it in one step.
local TEST_REGION = {
	pos1 = {x = -10, y = -5, z = -10},
	pos2 = {x = 125, y = 12, z = 12},
}
mock.settings["recorder.snapshot_budget"] = "1000000"

local checks = 0
local function check(condition, message)
	checks = checks + 1
	if not condition then
		error("FAILED: " .. message, 2)
	end
	print("  ok - " .. message)
end

-- Start a recording and let the snapshot phase finish. In the mock, emergence
-- is synchronous, so one step is enough; in the engine this is where the
-- snapshot phase reports its progress.
local function start_recording(name, region)
	local id, err = recorder.start(name, region or TEST_REGION)
	if not id then return err end
	for _ = 1, 10 do
		if recorder.is_recording() then return nil end
		mock.step(0.1)
	end
	return "the snapshot did not finish"
end

-- Start one recording and wait until that one is recording, not merely until
-- something is.
local function start_and_wait(name, region)
	local id, err = recorder.start(name, region or TEST_REGION)
	if not id then return nil, err end
	for _ = 1, 10 do
		for _, entry in ipairs(recorder.list()) do
			if entry.id == id and entry.recording then return id end
		end
		mock.step(0.1)
	end
	return nil, "the snapshot did not finish"
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

-- The engine's mapblock callback hands out the positions of the changed
-- mapblocks in mapblock units (a block index), not the node-space base corner.
-- Tests fire the callback the way the engine does.
local function block_hash(pos)
	return core.hash_node_position({
		x = math.floor(pos.x / 16),
		y = math.floor(pos.y / 16),
		z = math.floor(pos.z / 16),
	})
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

check(start_recording("first") == nil, "start() returns nil on success")
check(recorder.is_recording() == true, "is_recording() agrees")
local running = recorder.list()
check(#running == 1, "one recording is running")
local first_id = running[1].id
check(recorder.get_recording_name(first_id) == "first", "the recording knows its name")
local first_path = recorder.get_recording_path(first_id)
check(first_path == recordings_dir() .. "/first-" .. os.date("!%Y%m%dT%H%M%SZ") .. ".sqlite",
	"the file is named after the recording and the UTC time: " .. tostring(first_path))

-- A second recording over its own region runs at the same time.
local second_id, second_err = start_and_wait("second")
check(second_id ~= nil, "a second recording starts while the first runs" ..
	(second_id and "" or (": " .. tostring(second_err))))
running = recorder.list()
check(#running == 2, "two recordings are running")
check(recorder.get_recording_name(second_id) == "second",
	"each recording has its own id and name")
check(recorder.get_recording_path("not-a-recording") == nil, "an unknown id has no path")

check(recorder.stop(first_id) == nil, "one recording stops on its own")
running = recorder.list()
check(#running == 1 and running[1].id == second_id, "the other keeps running")
check(recorder.is_recording() == true, "and is still recording")
check(recorder.stop(second_id) == nil, "the second stops too")
check(recorder.is_recording() == false, "the recordings are over")
check(type(recorder.stop()) == "string", "stopping with nothing running fails")

local started = list_recordings()
check(#started == 2, "both files were written: " .. table.concat(started, ", "))
local started_names = table.concat(started, ",")
check(started_names:find("first-", 1, true) ~= nil and started_names:find("second-", 1, true) ~= nil,
	"named after their recordings: " .. started_names)

-- A recording that is started with no name still gets one
check(start_recording() == nil, "start() without a name works")
check(recorder.get_recording_name() == "unnamed", "the name defaults to 'unnamed'")
check(recorder.stop() == nil, "it stops again")
check(#list_recordings() == 3, "a third file now")

-- Same name in the same second must not overwrite the first file
check(start_recording("first") == nil, "the same name can be used again")
local second_path = recorder.get_recording_path()
check(second_path ~= first_path, "a second recording never lands in the same file")
check(recorder.stop() == nil, "it stops again")

check(start_recording("../../etc/passwd") == nil, "a name cannot walk out of the recordings directory")
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

check(start_recording("session") == nil, "the recording starts")
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
check(joins[1].data:find('"textures":%["character.png"%]') ~= nil,
	"and the textures the player was wearing: " .. tostring(joins[1].data))
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
check(#digs == 4, "the digs are recorded (got " .. #digs .. ")")
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
check(leaves[1].pos_x == 10 and leaves[1].pos_z == 10,
	"a leave says where the player was when they went: " .. tostring(leaves[1].pos_x))
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
check(start_recording("walking") == nil, "the recording starts")
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

check(start_recording("odd") == nil, "the recording starts")
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
local logs_before_bad_data = #mock.logs
check(recorder.log_event("mock:unserializable", { data = { fn = function() end } }) == nil,
	"an event whose data cannot be serialized is still accepted")
check(recorder.stop() == nil, "it stops")
db = open_recording(odd_path)
check(value(db, "SELECT COUNT(*) FROM Events WHERE type = 'mock:bad'") == 0, "nothing malformed was written")
check(value(db, "SELECT item FROM Events WHERE type = 'mock:flag'") == "ctf:flag_red 1",
	"the stack was stored as an itemstring")
check(value(db, "SELECT param2 FROM Events WHERE type = 'mock:rounded'") == 2,
	"the fractional param2 was rounded down rather than costing the row")
check(value(db, "SELECT subject_player FROM Events WHERE type = 'mock:named'") ==
	value(db, "SELECT id FROM Players WHERE name = 'Alice'"), "the named player is the subject")
check(value(db, "SELECT COUNT(*) FROM Events WHERE type = 'mock:unserializable'") == 1,
	"an event with unserializable data keeps its row")
check(value(db, "SELECT COUNT(*) FROM Events WHERE type = 'mock:unserializable' AND data IS NULL") == 1,
	"and is written without a data column rather than dropped")
local bad_data_logged = false
for i = logs_before_bad_data + 1, #mock.logs do
	if mock.logs[i].message and mock.logs[i].message:find("cannot serialize event data", 1, true) then
		bad_data_logged = true
	end
end
check(bad_data_logged, "and the reason is logged")
db:close()

----------------------------------------------------------------------------
print("=== when a player's row cannot be written ===")
----------------------------------------------------------------------------

-- The database is busy for a moment while somebody joins. The join must not
-- raise, and the player must not be struck off the recording for good.
mock.settings["recorder.flush_interval"] = "0.01"
check(start_recording("unwritable") == nil, "the recording starts")
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

check(start_recording("stuck") == nil, "the recording starts")
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
check(start_recording("wieldgap") == nil, "the recording starts")
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
check(start_recording("patient") == nil, "the recording starts")
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
check(start_recording("window") == nil, "the recording starts")
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
-- the recording with it, on this tick or on the ones after it. It joins while
-- it can still be read, and then the object goes away.
local broken = mock.add_player("Broken")
check(start_recording("broken_player") == nil, "a recording starts")
mock.step(0.1)  -- the recording opens while Broken can still be read
broken.get_pos = function() error("this object no longer exists") end
local broken_path = recorder.get_recording_path()
mock.steps(3, 0.1)
check(recorder.is_recording(), "it does not end over one unreadable player")
-- An object that cannot be read is one thing; a player leaving is another, and
-- the leave has to be recorded whether or not the engine still knows where the
-- player was.
mock.fire("register_on_leaveplayer", broken, false)
check(recorder.stop() == nil, "it stops normally")
db = open_recording(broken_path)
check(value(db, "SELECT COUNT(*) FROM Events WHERE type = 'leave'") == 1,
	"a player that cannot be read still leaves the recording")
check(value(db, "SELECT pos_x FROM Events WHERE type = 'leave'") == nil,
	"and is recorded with no position rather than with no event")
check(value(db, ("SELECT COUNT(*) FROM Movement JOIN Players ON Players.id = Movement.player_id " ..
	"WHERE Players.name = 'Alice' AND Movement.tick = 1")) == 1, "the other players are still recorded")
check(value(db, ("SELECT COUNT(*) FROM Movement JOIN Players ON Players.id = Movement.player_id " ..
	"WHERE Players.name = 'Broken'")) == 1,
	"the one sample taken before the object went away is kept")
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
check(start_recording("blocked") == nil, "the recording starts")
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
-- A run of failed commits is the one thing an operator looking at the status
-- has to be told about, because it is the difference between a recording that
-- is whole and one whose last seconds are missing.
local chat_before = #mock.chats
local status_ok = mock.chatcommands.recorder.func("someone", "status")
local status_message = (#mock.chats > chat_before) and mock.chats[#mock.chats].message or ""
check(status_ok and status_message:find("failed write", 1, true) ~= nil,
	"the status says the writes are failing: " .. tostring(status_message))
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
print("=== giving up on a recording that cannot be written ===")
----------------------------------------------------------------------------

-- A database that stays unavailable is no reason to buffer rows until the
-- server runs out of memory. Ten commits in a row that fail end the recording,
-- and the log says so - the recording itself cannot, its rows being exactly
-- what will not go in.
mock.settings["recorder.flush_interval"] = "0.01"  -- commit on every step
check(start_recording("doomed") == nil, "a recording starts")
local doomed_path = recorder.get_recording_path()
-- One step before the lock goes on, so that the opening state - the world time,
-- the joins, a Players row each - is written while the database still accepts
-- writes. Otherwise every later step pays the busy timeout again for the player
-- row it cannot write, and this test spends half a minute saying what it could
-- say in four seconds.
mock.step(0.1)
local doomed_blocker = sqlite.open(doomed_path)
check(doomed_blocker:exec("BEGIN IMMEDIATE") == sqlite.OK, "another connection takes the write lock")
local before_giving_up = #mock.logs
for i = 1, 12 do
	-- Something has to be buffered each step: a commit with nothing to write
	-- succeeds without touching the database, and would clear the count.
	alice.pos.x = 100 + i
	mock.step(0.1)
end
check(recorder.is_recording() == false, "the recording gives up instead of buffering for ever")
local gave_up = false
for i = before_giving_up + 1, #mock.logs do
	if mock.logs[i].message and mock.logs[i].message:find("giving up on the recording", 1, true) then
		gave_up = true
	end
end
check(gave_up, "and the log says why")
doomed_blocker:exec("ROLLBACK")
doomed_blocker:close()
mock.settings["recorder.flush_interval"] = nil

----------------------------------------------------------------------------
print("=== settings ===")
----------------------------------------------------------------------------

-- A recording that gives itself a deadline
mock.settings["recorder.max_duration"] = "0.25"
check(start_recording("limited") == nil, "a recording with a duration limit starts")
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
check(start_recording("quiet") == nil, "a recording with noisy events turned off starts")
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
check(start_recording("markers") == nil, "a recording starts")
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

----------------------------------------------------------------------------
print("=== where a recording is written ===")
----------------------------------------------------------------------------

-- A relative directory belongs to the world it is a recording of. The working
-- directory is a property of how the server was started - a systemd unit, the
-- shell somebody ran it from - and a recording that followed it around would
-- land somewhere different for no reason a reader could see.
mock.settings["recorder.directory"] = "myrecordings"
check(start_recording("relative") == nil, "a recording with a directory of its own starts")
check(recorder.get_recording_path():find(world .. "/myrecordings/", 1, true) == 1,
	"a relative directory is taken from the world directory: " .. tostring(recorder.get_recording_path()))
check(recorder.stop() == nil, "it stops")

local absolute_dir = tmpbase .. "/recorder_tests/absolute"
mock.settings["recorder.directory"] = absolute_dir
check(start_recording("absolute") == nil, "a recording with an absolute directory starts")
check(recorder.get_recording_path():find(absolute_dir .. "/", 1, true) == 1,
	"an absolute directory is used as it is: " .. tostring(recorder.get_recording_path()))
check(recorder.stop() == nil, "it stops")
mock.settings["recorder.directory"] = nil

----------------------------------------------------------------------------
print("=== a region is required ===")
----------------------------------------------------------------------------

-- A recording is about a particular place: there is no provider to fall back on.
local no_id, no_region = recorder.start("noregion")
check(no_id == nil and type(no_region) == "string" and no_region:find("region", 1, true) ~= nil,
	"a start without a region is refused: " .. tostring(no_region))

----------------------------------------------------------------------------
print("=== the snapshot is in the file ===")
----------------------------------------------------------------------------

mock.set_node({x = 2, y = 2, z = 2}, {name = "default:stone"})
mock.set_node({x = 3, y = 2, z = 2}, {name = "default:dirt", param2 = 4})
check(start_recording("snapshot") == nil, "a recording with nodes in its region starts")
local snapshot_path = recorder.get_recording_path()
check(recorder.stop() == nil, "it stops")

local sdb = open_recording(snapshot_path)
local snap_row = rows(sdb, "SELECT * FROM Snapshot")[1]
check(snap_row ~= nil, "the file carries the snapshot")
local whole = recorder_common.region.normalize(TEST_REGION.pos1, TEST_REGION.pos2)
local whole_size = recorder_common.region.size(whole)
check(snap_row.size_x == whole_size.x and snap_row.size_y == whole_size.y
	and snap_row.size_z == whole_size.z, "with the region's size")
check(snap_row.pos1_x == whole.pos1.x and snap_row.pos1_z == whole.pos1.z,
	"and its low corner")
local names = {}
for line in snap_row.names:gmatch("[^\n]+") do names[#names + 1] = line end
check(#names >= 2, "the name table lists the nodes: " .. table.concat(names, ", "))

local entries = recorder_common.snapshot.decode(snap_row.data)
check(entries ~= nil and #entries >= 2, "the body decodes")
local by_index = {}
for _, entry in ipairs(entries) do by_index[entry.i] = entry end
local stone_entry = by_index[recorder_common.region.index(whole, {x = 2, y = 2, z = 2})]
check(stone_entry ~= nil and names[stone_entry.n] == "default:stone",
	"a node is stored at its region index, by name")
local dirt_entry = by_index[recorder_common.region.index(whole, {x = 3, y = 2, z = 2})]
check(dirt_entry ~= nil and names[dirt_entry.n] == "default:dirt" and dirt_entry.p == 4,
	"with its param2")
sdb:close()

----------------------------------------------------------------------------
print("=== walking in and out of the region ===")
----------------------------------------------------------------------------

local outsider = mock.add_player("Outsider", {pos = {x = 500, y = 0, z = 0}})
check(start_recording("regions") == nil, "a recording starts")
local regions_path = recorder.get_recording_path()
mock.step(0.1)      -- tick 1: outside the region
outsider.pos.x = 0
mock.step(0.1)      -- tick 2: walked in
outsider.pos.x = 500
mock.step(0.1)      -- tick 3: walked out
check(recorder.stop() == nil, "it stops")

local rdb = open_recording(regions_path)
local outsider_id = value(rdb, "SELECT id FROM Players WHERE name = 'Outsider'")
check(outsider_id ~= nil, "the outsider is known once they enter")
local outsider_join = rows(rdb, ("SELECT * FROM Events WHERE type = 'join' AND subject_player = %d")
	:format(outsider_id))[1]
check(outsider_join ~= nil, "they join the recording when they walk in")
check(outsider_join.data:find('"reason":"region"', 1, true) ~= nil, "as a region join")
check(outsider_join.data:find("at_start", 1, true) == nil, "not as an at_start one")
local outsider_leave = rows(rdb, ("SELECT * FROM Events WHERE type = 'leave' AND subject_player = %d")
	:format(outsider_id))[1]
check(outsider_leave ~= nil, "and leave it when they walk out")
check(outsider_leave.data:find('"reason":"region"', 1, true) ~= nil, "as a region leave")
check(outsider_leave.pos_x == 0 and outsider_leave.pos_z == 0,
	"at the place they were last seen")
check(value(rdb, ("SELECT COUNT(*) FROM Movement WHERE player_id = %d"):format(outsider_id)) == 1,
	"only the tick inside the region is sampled")
rdb:close()
mock.remove_player("Outsider")

----------------------------------------------------------------------------
print("=== the pose a player is wearing ===")
----------------------------------------------------------------------------

-- A game sets a player's animation itself (the death pose is one); it is not
-- derivable from the movement sample, so the recording keeps the engine's four
-- animation values whenever they change.
local ANIM_REGION = {pos1 = {x = 600, y = 0, z = 0}, pos2 = {x = 605, y = 4, z = 5}}
local anim_in = mock.add_player("AnimIn", {
	pos = {x = 602, y = 0, z = 2},
	animation = {frames = {x = 189, y = 198}, speed = 2, blend = 0, loop = false},
})
local anim_out = mock.add_player("AnimOut", {
	pos = {x = 700, y = 0, z = 2},
	animation = {frames = {x = 0, y = 79}, speed = 30, blend = 0, loop = true},
})
-- An engine that cannot answer for a player must not cost their movement row.
local anim_broken = mock.add_player("AnimBroken", {pos = {x = 604, y = 0, z = 2}})
anim_broken.get_animation = function() error("no animation here") end
-- The engine's "never given an animation" answer is not a pose.
local anim_default = mock.add_player("AnimDefault", {
	pos = {x = 601, y = 0, z = 2},
	animation = {frames = {x = 1, y = 1}, speed = 15, blend = 0, loop = true},
})

check(start_recording("poses", ANIM_REGION) == nil, "a recording with an animated player starts")
local anim_path = recorder.get_recording_path()
mock.step(0.1)  -- the first sample records the pose the player is wearing
anim_in.animation = {frames = {x = 200, y = 219}, speed = 30, blend = 0.1, loop = true}
mock.step(0.1)
mock.step(0.1)  -- unchanged: no row
check(recorder.stop() == nil, "it stops")

local anim_db = open_recording(anim_path)
local anim_id = value(anim_db, "SELECT id FROM Players WHERE name = 'AnimIn'")
local pose_events = rows(anim_db, ("SELECT * FROM Events WHERE type = 'animation' AND subject_player = %d " ..
	"ORDER BY id"):format(anim_id))
check(#pose_events == 2, "one animation event per pose change (got " .. #pose_events .. ")")
local first_pose = core.parse_json(pose_events[1].data)
check(first_pose and first_pose.frames.x == 189 and first_pose.frames.y == 198,
	"the first event holds the frame range the player was wearing")
check(first_pose and first_pose.speed == 2 and first_pose.blend == 0 and first_pose.loop == false,
	"with its speed, blend and loop")
local second_pose = core.parse_json(pose_events[2].data)
check(second_pose and second_pose.frames.x == 200 and second_pose.frames.y == 219
	and second_pose.speed == 30 and second_pose.blend == 0.1 and second_pose.loop == true,
	"and the next one holds the changed pose")
check(value(anim_db, "SELECT COUNT(*) FROM Players WHERE name = 'AnimOut'") == 0,
	"a player outside the region is not in the recording")
local anim_broken_id = value(anim_db, "SELECT id FROM Players WHERE name = 'AnimBroken'")
check(anim_broken_id ~= nil, "a player whose pose cannot be read is still recorded")
check(value(anim_db, ("SELECT COUNT(*) FROM Events WHERE type = 'animation' AND subject_player = %d")
	:format(anim_broken_id)) == 0, "with no pose row")
check(value(anim_db, ("SELECT COUNT(*) FROM Movement WHERE player_id = %d"):format(anim_broken_id)) >= 1,
	"and their movement sample survives the unreadable pose")
local anim_default_id = value(anim_db, "SELECT id FROM Players WHERE name = 'AnimDefault'")
check(anim_default_id ~= nil and value(anim_db,
	("SELECT COUNT(*) FROM Events WHERE type = 'animation' AND subject_player = %d")
	:format(anim_default_id)) == 0, "an animation the engine never was given is not recorded as a pose")
anim_db:close()
mock.remove_player("AnimIn")
mock.remove_player("AnimOut")
mock.remove_player("AnimBroken")
mock.remove_player("AnimDefault")

----------------------------------------------------------------------------
print("=== particle effects ===")
----------------------------------------------------------------------------

-- The particle APIs have no callback, so the recording can only keep what the
-- wrappers saw. Every call here is made the way a mod makes it.
do
local PART_REGION = {pos1 = {x = 800, y = 0, z = 0}, pos2 = {x = 805, y = 4, z = 5}}
check(start_recording("particles", PART_REGION) == nil, "a recording with particles starts")
local part_path = recorder.get_recording_path()

local inside_particle = {
	pos = {x = 801.5, y = 1, z = 1},
	velocity = {x = 0, y = 2, z = 0},
	acceleration = {x = 0, y = -9, z = 0},
	expirationtime = 0.4,
	size = 3,
	texture = "recorder_smoke.png",
}
check(core.add_particle(inside_particle) == inside_particle,
	"a particle call returns exactly what the engine returned")
-- Outside the region: the engine still gets the call, the file does not.
core.add_particle({
	pos = {x = 900, y = 1, z = 1}, velocity = {x = 0, y = 0, z = 0},
	acceleration = {x = 0, y = 0, z = 0}, expirationtime = 1, size = 1,
	texture = "outside_particle.png",
})
-- The deprecated positional form is recorded in the table form the engine
-- documents today, so the file does not depend on the old call shape.
local old_pos = {x = 802, y = 1, z = 1}
check(core.add_particle(old_pos, {x = 1, y = 0, z = 0}, {x = 0, y = 0, z = 0},
	0.5, 2, false, "recorder_deprecated.png") == old_pos,
	"the deprecated positional call still returns the engine's value")

local inside_spawner = {
	amount = 20,
	time = 0.5,
	minpos = {x = 800.5, y = 0, z = 0.5},
	maxpos = {x = 803, y = 2, z = 2},
	minvel = {x = 0, y = 5, z = 0},
	maxvel = {x = 0, y = 7, z = 0},
	minacc = {x = 0, y = 1, z = 0},
	maxacc = {x = 0, y = 1, z = 0},
	minexptime = 0.3,
	maxexptime = 0.6,
	minsize = 7,
	maxsize = 10,
	collisiondetection = true,
	collision_removal = false,
	vertical = false,
	texture = "recorder_boom.png",
}
local inside_id = core.add_particlespawner(inside_spawner)
check(type(inside_id) == "number" and inside_id == mock.next_spawner_id,
	"a spawner call returns the engine's id")
-- An emission box that crosses the region boundary is still the region's.
local straddling_id = core.add_particlespawner({
	amount = 1, time = 0.1,
	minpos = {x = 799.5, y = 1, z = 1}, maxpos = {x = 800.5, y = 1, z = 1},
	minsize = 1, maxsize = 1, texture = "recorder_edge.png",
})
-- The deprecated positional form, with its fifteen arguments.
local old_spawner_id = core.add_particlespawner(5, 1,
	{x = 801, y = 1, z = 1}, {x = 802, y = 1, z = 1},
	{x = 0, y = 0, z = 0}, {x = 0, y = 1, z = 0},
	{x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0},
	0.1, 0.2, 1, 2, false, "recorder_old.png")
core.add_particlespawner({
	amount = 1, time = 1,
	minpos = {x = 900, y = 1, z = 1}, maxpos = {x = 901, y = 1, z = 1},
	texture = "outside_spawner.png",
})
check(core.delete_particlespawner(inside_id, "Alice") == inside_id,
	"a delete call returns exactly what the engine returned")
core.delete_particlespawner(straddling_id)
-- An effect attached to an object follows it; a file cannot. The call still
-- happens and its id still comes back, but nothing is written.
local attached_id = core.add_particlespawner({
	amount = 1, time = 1, attached = {},
	minpos = {x = 801, y = 1, z = 1}, maxpos = {x = 801, y = 1, z = 1},
	texture = "attached.png",
})
check(type(attached_id) == "number", "an attached spawner still returns the engine's id")

check(recorder.stop() == nil, "it stops")

local part_db = open_recording(part_path)
local particles = rows(part_db, "SELECT * FROM Events WHERE type = 'particle' ORDER BY id")
check(#particles == 2, "only particles inside the region are recorded (got " .. #particles .. ")")
local first_particle = core.parse_json(particles[1].data)
check(first_particle and first_particle.definition.texture == "recorder_smoke.png",
	"the particle definition is recorded")
check(particles[1].pos_x == 801.5 and particles[1].pos_y == 1 and particles[1].pos_z == 1,
	"with the position the event is about")
local deprecated_particle = core.parse_json(particles[2].data)
check(deprecated_particle and deprecated_particle.definition.texture == "recorder_deprecated.png"
	and deprecated_particle.definition.expirationtime == 0.5
	and deprecated_particle.definition.size == 2,
	"the deprecated call is recorded as a table definition")
check(deprecated_particle and deprecated_particle.definition.pos.x == 802
	and deprecated_particle.definition.velocity.x == 1,
	"with its position and velocity")

local spawner_events = rows(part_db,
	"SELECT * FROM Events WHERE type = 'particlespawner' ORDER BY id")
check(#spawner_events == 3, "only spawners touching the region are recorded (got "
	.. #spawner_events .. ")")
local first_spawner = core.parse_json(spawner_events[1].data)
check(first_spawner and first_spawner.id == inside_id, "a spawner records the engine id")
check(first_spawner and first_spawner.definition.texture == "recorder_boom.png",
	"and its definition")
check(spawner_events[1].pos_x == (800.5 + 803) / 2 and spawner_events[1].pos_y == 1,
	"the event position is the emission box's centre")
local straddling = core.parse_json(spawner_events[2].data)
check(straddling and straddling.id == straddling_id,
	"a spawner whose box crosses the boundary is recorded")
local old_spawner = core.parse_json(spawner_events[3].data)
check(old_spawner and old_spawner.id == old_spawner_id
	and old_spawner.definition.texture == "recorder_old.png"
	and old_spawner.definition.minpos.x == 801,
	"the deprecated spawner call is recorded as a table definition")

local deletes = rows(part_db,
	"SELECT * FROM Events WHERE type = 'particlespawner_delete' ORDER BY id")
check(#deletes == 2, "spawner deletes are recorded")
local first_delete = core.parse_json(deletes[1].data)
check(first_delete and first_delete.id == inside_id and first_delete.playername == "Alice",
	"a delete carries the recorded id and its player restriction")

local attached_logged = 0
for _, log in ipairs(mock.logs) do
	if log.message and log.message:find("attached to an object", 1, true) then
		attached_logged = attached_logged + 1
	end
end
check(attached_logged == 1, "an attached effect is reported once and not recorded")
part_db:close()

-- One event type can be turned off on its own; recorder.particles turns off
-- all three, which is the switch for a server where a per-step effect would
-- cost too many rows.
mock.settings["recorder.disabled_events"] = "particle"
check(start_recording("noparticles", PART_REGION) == nil, "a recording with one particle type off starts")
local noparticles_path = recorder.get_recording_path()
core.add_particle(inside_particle)
core.add_particlespawner(inside_spawner)
check(recorder.stop() == nil, "it stops")
local noparticles_db = open_recording(noparticles_path)
check(value(noparticles_db, "SELECT COUNT(*) FROM Events WHERE type = 'particle'") == 0,
	"the turned-off particle is not recorded")
check(value(noparticles_db, "SELECT COUNT(*) FROM Events WHERE type = 'particlespawner'") == 1,
	"the spawner still is")
noparticles_db:close()
mock.settings["recorder.disabled_events"] = nil

mock.settings["recorder.particles"] = "false"
check(start_recording("particlesoff", PART_REGION) == nil, "a recording with particles off starts")
local particlesoff_path = recorder.get_recording_path()
core.add_particle(inside_particle)
core.add_particlespawner(inside_spawner)
core.delete_particlespawner(inside_id)
check(recorder.stop() == nil, "it stops")
local particlesoff_db = open_recording(particlesoff_path)
check(value(particlesoff_db,
	"SELECT COUNT(*) FROM Events WHERE type IN ('particle', 'particlespawner', 'particlespawner_delete')") == 0,
	"recorder.particles = false turns off all three event types")
particlesoff_db:close()
mock.settings["recorder.particles"] = nil
end

----------------------------------------------------------------------------
print("=== changes to the nodes ===")
----------------------------------------------------------------------------

mock.set_node({x = 5, y = 5, z = 5}, {name = "default:stone"})
check(start_recording("changes") == nil, "a recording starts")
local changes_path = recorder.get_recording_path()
mock.step(0.1)      -- tick 1

-- A change inside the region, announced by the engine's mapblock callback.
local inside_hash = block_hash({x = 5, y = 5, z = 5})
mock.set_node({x = 5, y = 5, z = 5}, {name = "default:dirt", param2 = 3})
mock.fire("register_on_mapblocks_changed", {[inside_hash] = true}, 1)
mock.step(0.1)      -- tick 2: the change is diffed and tagged with tick 1

-- A change outside the region: no node inside the region differs, so no row.
local outside_hash = block_hash({x = 500, y = 5, z = 5})
mock.set_node({x = 500, y = 5, z = 5}, {name = "default:stone"})
mock.fire("register_on_mapblocks_changed", {[outside_hash] = true}, 1)
mock.step(0.1)      -- tick 3

-- A node removed.
mock.set_node({x = 5, y = 5, z = 5}, {name = "air"})
mock.fire("register_on_mapblocks_changed", {[inside_hash] = true}, 1)
mock.step(0.1)      -- tick 4

check(recorder.stop() == nil, "it stops")

local cdb = open_recording(changes_path)
local changes = rows(cdb, "SELECT * FROM Events WHERE type = 'node_change' ORDER BY id")
check(#changes == 2, "only changes inside the region are recorded (got " .. #changes .. ")")
check(changes[1].tick == 1, "a change carries the tick it happened on")
check(changes[1].pos_x == 5 and changes[1].pos_y == 5 and changes[1].pos_z == 5,
	"and the position")
check(changes[1].node == "default:dirt" and changes[1].param2 == 3, "the node it became")
check(changes[1].data:find('"old_node":"default:stone"', 1, true) ~= nil,
	"and what it was: " .. tostring(changes[1].data))
check(changes[2].node == "air", "removal is recorded as a change to air")
check(changes[2].data:find('"old_node":"default:dirt"', 1, true) ~= nil,
	"with the removed node's name")
check(value(cdb, "SELECT COUNT(*) FROM Events WHERE type = 'node_change' AND pos_x = 500") == 0,
	"a change outside the region leaves no row")
cdb:close()

-- The callback names a mapblock in mapblock units: block index (25,0,0) is
-- the block whose node base is (400,0,0). The engine does this even though
-- the hash format is shared with hash_node_position; this is the shape that
-- used to be filtered out and produced no node_change rows at all.
local far_region = {pos1 = {x = 400, y = 0, z = 0}, pos2 = {x = 415, y = 4, z = 15}}
check(start_recording("farblock", far_region) == nil, "a recording far from the origin starts")
local far_path = recorder.get_recording_path()
mock.step(0.1)
mock.set_node({x = 404, y = 1, z = 2}, {name = "default:stone"})
mock.fire("register_on_mapblocks_changed",
	{[core.hash_node_position({x = 25, y = 0, z = 0})] = true}, 1)
mock.step(0.1)
check(recorder.stop() == nil, "it stops")
local far_db = open_recording(far_path)
local far_changes = rows(far_db,
	"SELECT pos_x, pos_y, pos_z FROM Events WHERE type = 'node_change'")
check(#far_changes == 1 and far_changes[1].pos_x == 404
	and far_changes[1].pos_y == 1 and far_changes[1].pos_z == 2,
	"a block named in mapblock units is diffed at its node-space base")
far_db:close()

----------------------------------------------------------------------------
print("=== two recordings over two regions ===")
----------------------------------------------------------------------------

-- A match map and a practice area, in miniature: two recordings at the same
-- time, each keeping only what happened inside its own region.
local in_a = mock.add_player("InA", {pos = {x = -5, y = 0, z = 0}})
local in_b = mock.add_player("InB", {pos = {x = 100, y = 0, z = 0}})
local region_a = {pos1 = {x = -10, y = -5, z = -10}, pos2 = {x = 0, y = 12, z = 12}}
local region_b = {pos1 = {x = 90, y = -5, z = -10}, pos2 = {x = 110, y = 12, z = 12}}
local id_a, err_a = start_and_wait("area_a", region_a)
local id_b, err_b = start_and_wait("area_b", region_b)
check(id_a ~= nil and id_b ~= nil,
	"two recordings run over two regions: " .. tostring(err_a or err_b))
check(id_a ~= id_b, "with different ids")
local path_a, path_b = recorder.get_recording_path(id_a), recorder.get_recording_path(id_b)

-- An action by each player, and a node change inside the first region.
mock.fire("register_on_dignode", {x = -5, y = 0, z = 1}, {name = "default:stone", param2 = 0}, in_a)
mock.fire("register_on_dignode", {x = 100, y = 0, z = 1}, {name = "default:stone", param2 = 0}, in_b)
mock.set_node({x = -5, y = 5, z = 0}, {name = "default:stone"})
mock.fire("register_on_mapblocks_changed",
	{[block_hash({x = -5, y = 5, z = 0})] = true}, 1)
mock.step(0.1)
mock.step(0.1)
check(recorder.stop(id_a) == nil and recorder.stop(id_b) == nil, "both stop")

local db_a, db_b = open_recording(path_a), open_recording(path_b)
check(value(db_a, "SELECT COUNT(*) FROM Players WHERE name = 'InA'") == 1,
	"the first recording knows the player in its region")
check(value(db_a, "SELECT COUNT(*) FROM Players WHERE name = 'InB'") == 0,
	"and not the one outside it")
check(value(db_b, "SELECT COUNT(*) FROM Players WHERE name = 'InB'") == 1,
	"the second knows its own player")
check(value(db_b, "SELECT COUNT(*) FROM Players WHERE name = 'InA'") == 0,
	"and not the other")
check(value(db_a, "SELECT P.name FROM Events e JOIN Players P ON P.id = e.subject_player " ..
	"WHERE e.type = 'dig'") == "InA", "the first recording kept the first player's dig")
check(value(db_b, "SELECT P.name FROM Events e JOIN Players P ON P.id = e.subject_player " ..
	"WHERE e.type = 'dig'") == "InB", "the second kept the second player's dig")
check(value(db_a, "SELECT COUNT(*) FROM Events WHERE type = 'node_change'") == 1,
	"the node changed inside the first region")
check(value(db_b, "SELECT COUNT(*) FROM Events WHERE type = 'node_change'") == 0,
	"and not inside the second")
db_a:close()
db_b:close()

----------------------------------------------------------------------------
print("=== marking a region by hand ===")
----------------------------------------------------------------------------

local marker = mock.add_player("Marker", {pos = {x = 0, y = 0, z = 0}})
local cmd = mock.chatcommands.recorder
local ok, msg = cmd.func("Marker", "pos1")
check(ok and msg:find("pos1 set", 1, true) ~= nil, "pos1 marks the player's position: " .. tostring(msg))
marker.pos = {x = 4, y = 3, z = 2}
ok, msg = cmd.func("Marker", "pos2")
check(ok and msg:find("start will use", 1, true) ~= nil, "pos2 completes the marks: " .. tostring(msg))
ok, msg = cmd.func("Marker", "start byhand")
check(ok, "the command starts a recording: " .. tostring(msg))
mock.step(0.1)
check(recorder.is_recording(), "the snapshot completes in a step")
local byhand_path = recorder.get_recording_path()
check(recorder.stop() == nil, "it stops")
local bdb = open_recording(byhand_path)
local bsnap = rows(bdb, "SELECT * FROM Snapshot")[1]
check(bsnap.size_x == 5 and bsnap.size_y == 4 and bsnap.size_z == 3,
	string.format("the marks decide the region: %dx%dx%d",
		bsnap.size_x, bsnap.size_y, bsnap.size_z))
bdb:close()
ok, msg = cmd.func("Marker", "unset")
check(ok and msg:find("cleared", 1, true) ~= nil, "unset clears them")
mock.remove_player("Marker")

----------------------------------------------------------------------------
print("=== the snapshot phase reports itself ===")
----------------------------------------------------------------------------

local phase_id = recorder.start("phasetest", TEST_REGION)
check(phase_id ~= nil, "a recording starts directly")
local chat_before = #mock.chats
local status_ok = cmd.func("someone", "status")
local status_msg = (#mock.chats > chat_before) and mock.chats[#mock.chats].message or ""
check(status_ok and status_msg:find("snapshotting", 1, true) ~= nil,
	"the status says what the phase is doing: " .. tostring(status_msg))
mock.step(0.1)
check(recorder.is_recording(), "and the recording begins when it is done")
check(recorder.stop() == nil, "it stops")

----------------------------------------------------------------------------
-- The chat command
----------------------------------------------------------------------------
local command = mock.chatcommands.recorder
check(command ~= nil, "the /recorder command is registered")
check(command.privs.server == true, "and needs the server privilege")
local ok, message = command.func("someone", "")
local said = (#mock.chats > 0) and mock.chats[#mock.chats].message or ""
check(ok and said:find("No recording in progress") ~= nil,
	"/recorder says nothing is being recorded: " .. tostring(said))
ok, message = command.func("someone", "start fromchat -6,-6,-6 6,6,6")
check(ok, "/recorder start accepts the command")
mock.step(0.1)  -- the snapshot phase runs in server steps
check(recorder.is_recording(), "/recorder start begins a recording")
ok, message = command.func("someone", "meta mode survival")
check(ok and recorder.add_meta("mode", "survival") == nil, "/recorder meta attaches metadata")
local before_status = #mock.chats
ok = command.func("someone", "status")
local status_line = (#mock.chats > before_status) and mock.chats[#mock.chats].message or ""
check(ok and status_line:find("fromchat", 1, true) ~= nil,
	"/recorder status describes it: " .. tostring(status_line))
ok, message = command.func("someone", "stop")
check(ok and not recorder.is_recording(), "/recorder stop ends it")

-- The server going down takes the recording with it
check(start_recording("shutdown") == nil, "a recording starts before the shutdown")
local shutdown_path = recorder.get_recording_path()
mock.fire("register_on_shutdown")
check(recorder.is_recording() == false, "the shutdown stopped it")
db = open_recording(shutdown_path)
check(value(db, "SELECT COUNT(*) FROM Events WHERE data LIKE '%shutdown%'") == 1,
	"the recording says it was the shutdown that ended it")
db:close()

----------------------------------------------------------------------------
-- Node metadata and inventories
----------------------------------------------------------------------------
local META_REGION = {pos1 = {x = 200, y = 0, z = 0}, pos2 = {x = 205, y = 4, z = 5}}
local chest = {x = 202, y = 1, z = 2}
local sign = {x = 203, y = 1, z = 2}
mock.set_node(chest, {name = "default:chest"})
mock.set_node(sign, {name = "default:sign_wall_wood"})
core.get_meta(chest):from_table({
	fields = {owner = "alice", infotext = "Chest"},
	inventory = {main = {"default:stone 5", "", "default:torch 3"}},
})
core.get_meta(sign):set_string("text", "hello")

check(start_recording("meta", META_REGION) == nil, "a recording with metadata starts")
local meta_path = recorder.get_recording_path()
mock.step(0.1)
core.get_meta(chest):from_table({
	fields = {owner = "alice", infotext = "Chest"},
	inventory = {main = {"", "", "default:torch 3"}},
})
mock.steps(11, 0.1)  -- past the one-second scan
core.get_meta(chest):from_table(nil)
mock.steps(11, 0.1)
check(recorder.stop() == nil, "it stops")

local meta_db = open_recording(meta_path)
check(value(meta_db, "SELECT value FROM Metadata WHERE key = 'recorder.timeofday'") == "0.5",
	"the time of day is recorded with the file")
local chest_rows = rows(meta_db, string.format(
	"SELECT tick, data FROM NodeMetadata WHERE pos_x = %d AND pos_y = %d AND pos_z = %d ORDER BY id",
	chest.x, chest.y, chest.z))
check(#chest_rows == 3, "the chest has a baseline, a change and a clearing: " .. #chest_rows)
check(chest_rows[1].tick == 0, "the first row is the baseline at tick 0")
local baseline_table = core.deserialize(chest_rows[1].data)
check(baseline_table and baseline_table.fields.owner == "alice", "the fields are recorded")
check(baseline_table and baseline_table.inventory.main[1] == "default:stone 5",
	"the inventory is recorded slot for slot")
check(baseline_table and baseline_table.inventory.main[2] == "",
	"and an empty slot keeps its place")
local changed = core.deserialize(chest_rows[2].data)
check(changed and changed.inventory.main[1] == "" and changed.inventory.main[3] == "default:torch 3",
	"an inventory change is seen at the next scan")
check(chest_rows[3].data == "", "taking the metadata away is recorded as a clearing")
local sign_rows = rows(meta_db, string.format(
	"SELECT tick, data FROM NodeMetadata WHERE pos_x = %d AND pos_y = %d AND pos_z = %d",
	sign.x, sign.y, sign.z))
check(#sign_rows == 1, "a node whose metadata did not change has its baseline only")
check(core.deserialize(sign_rows[1].data).fields.text == "hello", "the sign text is recorded")
meta_db:close()

-- The setting turns the whole thing off for the recording (replay is not
-- affected: it only acts on what the file holds).
mock.settings["recorder.metadata"] = "false"
check(start_recording("nometa", META_REGION) == nil, "a recording without metadata starts")
local nometa_path = recorder.get_recording_path()
check(recorder.stop() == nil, "it stops")
local nometa_db = open_recording(nometa_path)
check(value(nometa_db, "SELECT COUNT(*) FROM NodeMetadata") == 0,
	"with recorder.metadata = false the file holds no metadata rows")
nometa_db:close()
mock.settings["recorder.metadata"] = nil

----------------------------------------------------------------------------
-- Lighting
----------------------------------------------------------------------------
local LIGHT_REGION = {pos1 = {x = 300, y = 0, z = 0}, pos2 = {x = 305, y = 4, z = 5}}
local dark = {x = 302, y = 1, z = 2}
local lit = {x = 303, y = 1, z = 2}
mock.set_node(dark, {name = "default:stone", light = 3})
mock.set_node(lit, {name = "default:stone", light = 9})

check(start_recording("light", LIGHT_REGION) == nil, "a recording with light starts")
local light_path = recorder.get_recording_path()
mock.step(0.1)
mock.set_node(dark, {name = "default:stone", light = 7})
mock.fire("register_on_mapblocks_changed",
	{[block_hash(dark)] = true}, 1)
mock.step(0.1)
check(recorder.stop() == nil, "it stops")

local light_db = open_recording(light_path)
local snap_light = rows(light_db,
	"SELECT light, light_encoding FROM Snapshot")[1]
check(snap_light and snap_light.light ~= nil, "the snapshot holds a light layer")
local light_region = recorder_common.region.normalize(LIGHT_REGION.pos1, LIGHT_REGION.pos2)
local light_volume = recorder_common.region.volume(light_region)
local light_body = snap_light.light
if snap_light.light_encoding == "deflate" then
	light_body = core.decompress(light_body, "deflate")
end
local base_light = recorder_common.light.decode(light_body, light_volume)
check(base_light ~= nil, "which decodes to one byte per node")
local dark_index = recorder_common.region.index(light_region, dark)
local lit_index = recorder_common.region.index(light_region, lit)
check(base_light and base_light[dark_index] == 3 and base_light[lit_index] == 9,
	"with the values the world had")
local light_changes = rows(light_db, "SELECT data, encoding FROM LightChanges ORDER BY id")
check(#light_changes == 1, "the light change is one row: " .. #light_changes)
local change_body = light_changes[1].data
if light_changes[1].encoding == "deflate" then
	change_body = core.decompress(change_body, "deflate")
end
local changes = recorder_common.snapshot.decode(change_body)
check(changes and #changes == 1 and changes[1].i == dark_index and changes[1].p == 7,
	"holding the node that changed and its new light")
light_db:close()

mock.settings["recorder.light"] = "false"
check(start_recording("nolight", LIGHT_REGION) == nil, "a recording without light starts")
local nolight_light_path = recorder.get_recording_path()
mock.step(0.1)  -- the opening metadata is taken at the first recording step
check(recorder.stop() == nil, "it stops")
local nolight_light_db = open_recording(nolight_light_path)
check(value(nolight_light_db, "SELECT COUNT(*) FROM Snapshot WHERE light IS NOT NULL") == 0,
	"with recorder.light = false the snapshot has no light layer")
check(value(nolight_light_db, "SELECT value FROM Metadata WHERE key = 'recorder.timeofday'") == "0.5",
	"but the time of day is still recorded")
check(value(nolight_light_db, "SELECT COUNT(*) FROM LightChanges") == 0, "and no light changes")
nolight_light_db:close()
mock.settings["recorder.light"] = nil

print(("\n%d checks passed"):format(checks))
