-- The replay half, driven through a real recording: choosing and building an
-- arena, rebuilding the region inside it, the ghosts, the clock, seeking, the
-- remote control, what happens to a participant's things, and the cleanup of an
-- arena a crash left behind.

local function script_dir()
	local src = debug.getinfo(1, "S").source:sub(2)  -- strip the leading "@"
	if src:sub(1, 1) ~= "/" then
		src = (os.getenv("PWD") or ".") .. "/" .. src
	end
	return src:match("^(.*)/[^/]+$")
end

local testdir = script_dir()
local modpath = testdir:gsub("/tests$", "")                       -- recorder_replay
local commonpath = modpath:gsub("/recorder_replay$", "/recorder_common")
local capturepath = modpath:gsub("/recorder_replay$", "/recorder_capture")
local tmpbase = os.getenv("TMPDIR") or "/tmp"
local world = tmpbase .. "/recorder_tests/replay"
os.execute("rm -rf " .. world)
os.execute("mkdir -p " .. world .. "/recordings")

local sqlite = require("lsqlite3")
local mocklib = dofile(commonpath .. "/tests/mocklib.lua")
local mock = mocklib.new({
	modpaths = {
		recorder_replay = modpath,
		recorder_common = commonpath,
		recorder_capture = capturepath,
	},
	world = world,
})
core = mock.core
algorithms = {require = function(name) if name == "lsqlite3" then return sqlite end end}
dofile(commonpath .. "/init.lua")
local common = recorder_common
local region = common.region

-- A game's player model, so the ghosts take the mesh path.
player_api = {
	registered_models = {
		["character.b3d"] = {
			animation_speed = 30,
			textures = {"character.png"},
			visual_size = {x = 1, y = 1},
			animations = {
				stand = {x = 0, y = 79},
				walk = {x = 168, y = 187},
				mine = {x = 189, y = 198},
				walk_mine = {x = 200, y = 219},
			},
		},
	},
}

-- The recording's region is 6 x 3 x 6, so the smallest arena that can hold it
-- is 8 x 5 x 8: one shell layer on every side.
local RECORDED = region.normalize({x = 0, y = 0, z = 0}, {x = 5, y = 2, z = 5})
local function index_of(x, y, z)
	return region.index(RECORDED, {x = x, y = y, z = z})
end

-- The fixture is written with capture's own database layer, so the reader is
-- tested against the format the writer actually produces.
local dbmanager = dofile(capturepath .. "/dbmanager.lua")

local fixture_path = world .. "/recordings/fixture-20260101T000000Z.sqlite"
local nolight_path = world .. "/recordings/0_nolight-20260101T000000Z.sqlite"
local function make_fixture(path, with_light)
	local writer = dbmanager.new(sqlite)
	local ok, err = writer:open(path)
	assert(ok, err)
	writer:set_meta("recorder.name", "fixture")
	writer:set_meta("recorder.timeofday", "0.5")
	local alice = writer:player_id("Alice")
	local bob = writer:player_id("Bob")

	local volume = 6 * 3 * 6
	local light_values
	if with_light then
		-- Daylight everywhere, a darker glass block and a dim corner.
		light_values = {}
		for i = 1, volume do light_values[i] = 15 end
		light_values[index_of(2, 1, 2)] = 7
		light_values[index_of(0, 0, 0)] = 12
	end

	-- A stone floor under Alice and Bob and a glass block with param2 at
	-- (2,1,2); everything else is air and not stored.
	local snapshot_ok, snapshot_err = writer:set_snapshot({
		tick = 0,
		t = 0,
		pos1 = {x = 0, y = 0, z = 0},
		size = {x = 6, y = 3, z = 6},
		names = "default:stone\ndefault:glass\nlost:block",
		encoding = "raw",
		data = common.snapshot.encode({
			{i = index_of(0, 0, 0), n = 1, p = 0},
			{i = index_of(2, 1, 2), n = 2, p = 7},
			{i = index_of(4, 1, 4), n = 3, p = 0},   -- a node this game will not have
			{i = index_of(5, 0, 5), n = 1, p = 0},
		}),
		light = with_light and common.light.encode(light_values, volume) or nil,
		light_encoding = with_light and "raw" or nil,
	})
	assert(snapshot_ok, snapshot_err)

	writer:add_event({writer:next_id(), 0, 0, "recording_start", nil, nil,
		nil, nil, nil, nil, nil, nil, nil})
	writer:add_event({writer:next_id(), 0, 0, "join", alice, nil, 0, 0, 0, nil, nil,
		"default:stone", '{"at_start":true,"textures":["character.png"]}'})
	writer:add_event({writer:next_id(), 0, 0, "join", bob, nil, 5, 0, 5, nil, nil,
		nil, '{"at_start":true}'})
	-- Alice walks one node per 0.1 s; on even ticks she holds the dig button.
	for tick = 1, 10 do
		local t = tick / 10
		writer:add_movement({writer:next_id(), tick, t, 0.1, alice,
			t, 0, 0, 0, 0, 1, 0, 0, nil, nil, nil, 1, tick % 2 == 0 and 128 or 0, 0, 0})
	end
	writer:add_movement({writer:next_id(), 1, 0.1, 0.1, bob,
		5, 0, 5, 0, 0, 0, 0, 0, nil, nil, nil, 0, 0, 0, 0})
	-- A smoke spawner at 0.1 s that runs for half a second, an endless ember
	-- spawner at 0.2 s, a single puff at 0.3 s, and a short-lived spawner at
	-- 0.45 s. The smoke is deleted at 0.6 s. See the particle section below.
	writer:add_event({writer:next_id(), 1, 0.1, "particlespawner", nil, nil, nil, nil, nil,
		nil, nil, nil,
		'{"definition":{"amount":20,"time":0.5,"minpos":{"x":0,"y":0,"z":0},' ..
		'"maxpos":{"x":1,"y":0,"z":0},"texture":"recorder_smoke.png"},' ..
		'"id":700}'})
	-- A delivered line and a mod broadcast, both in their final form. The tick
	-- is the step a row belongs to, so it has to follow the movement samples.
	writer:add_event({writer:next_id(), 2, 0.2, "chat", alice, nil, 0, 0, 0,
		nil, nil, nil, '{"message":"Alice: hello","source":"block_msgs"}'})
	writer:add_event({writer:next_id(), 2, 0.2, "particlespawner", nil, nil, nil, nil, nil,
		nil, nil, nil,
		'{"definition":{"amount":2,"time":0,"minpos":{"x":4,"y":0,"z":4},' ..
		'"maxpos":{"x":5,"y":0,"z":5},"texture":"recorder_ember.png",' ..
		'"attract":{"kind":"point","strength":1,"origin":{"x":4,"y":0,"z":4}}},' ..
		'"id":701}'})
	writer:add_event({writer:next_id(), 3, 0.3, "particle", nil, nil, 2, 1, 2,
		nil, nil, nil,
		'{"definition":{"pos":{"x":2,"y":1,"z":2},"velocity":{"x":0,"y":1,"z":0},' ..
		'"acceleration":{"x":0,"y":0,"z":0},"expirationtime":0.5,"size":2,' ..
		'"texture":"recorder_puff.png","playername":"Alice"}}'})
	-- At 0.4 s Alice's game lays her down (the death pose): a frame range that
	-- no speed-and-dig guess would ever produce.
	writer:add_event({writer:next_id(), 4, 0.4, "animation", alice, nil, nil, nil, nil,
		nil, nil, nil,
		'{"frames":{"x":220,"y":240},"speed":10,"blend":0.2,"loop":false}'})
	writer:add_event({writer:next_id(), 4, 0.45, "particlespawner", nil, nil, nil, nil, nil,
		nil, nil, nil,
		'{"definition":{"amount":1,"time":0.1,"minpos":{"x":3,"y":0,"z":3},' ..
		'"maxpos":{"x":3,"y":0,"z":3},"texture":"recorder_spark.png"},' ..
		'"id":702}'})
	-- Bob leaves at half a second.
	writer:add_event({writer:next_id(), 5, 0.5, "leave", bob, nil, 5, 0, 5,
		nil, nil, nil, nil})
	-- Alice draws a pick at half a second and puts it away at 0.7 s; the join
	-- event above carries "default:stone" for the time before she switches.
	writer:add_event({writer:next_id(), 5, 0.5, "wield", alice, nil, nil, nil, nil,
		nil, nil, "default:pick_stone", nil})
	writer:add_event({writer:next_id(), 6, 0.55, "chat", nil, nil, nil, nil, nil,
		nil, nil, nil, '{"message":"Server restarting","source":"server_restart"}'})
	-- The smoke spawner is cancelled at 0.6 s.
	writer:add_event({writer:next_id(), 6, 0.6, "particlespawner_delete", nil, nil, nil, nil,
		nil, nil, nil, nil, '{"id":700,"playername":"Alice"}'})
	writer:add_event({writer:next_id(), 7, 0.7, "wield", alice, nil, nil, nil, nil,
		nil, nil, nil, nil})
	-- At 0.8 s Alice digs the floor out from under herself, and at 0.9 s the
	-- glass is replaced by dirt with a different param2.
	writer:add_event({writer:next_id(), 8, 0.8, "node_change", alice, nil, 0, 0, 0,
		"air", 0, nil, '{"old_node":"default:stone","old_param2":0}'})
	writer:add_event({writer:next_id(), 9, 0.9, "node_change", alice, nil, 2, 1, 2,
		"default:dirt", 3, nil, '{"old_node":"default:glass","old_param2":7}'})
	-- A chest at (3,1,3): an inventory that changes at 0.7 s, and metadata that
	-- is taken away entirely at 0.9 s.
	writer:add_metadata({writer:next_id(), 0, 0, 3, 1, 3,
		core.serialize({fields = {owner = "alice"},
			inventory = {main = {"default:stone 5", "", "default:torch 3"}}})})
	writer:add_metadata({writer:next_id(), 7, 0.7, 3, 1, 3,
		core.serialize({fields = {owner = "alice"},
			inventory = {main = {"", "", "default:torch 3"}}})})
	writer:add_metadata({writer:next_id(), 9, 0.9, 3, 1, 3, ""})
	if with_light then
		-- The glass block's light changes at 0.8 s.
		writer:add_light({writer:next_id(), 8, 0.8,
			common.snapshot.encode({{i = index_of(2, 1, 2), n = 1, p = 3}}), "raw"})
	end
	writer:flush()
	writer:close()
end
make_fixture(fixture_path, true)
make_fixture(nolight_path, false)

-- From here on, modules load as the replay mod.
mock.current_modname = "recorder_replay"
dofile(modpath .. "/init.lua")

-- Names the reconstruction resolves. They are registered after the mod loads,
-- so the barrier takes content id 0, as the first node registered on a real
-- server does. Treating 0 as "unknown" was a real bug this order catches.
mock.add_node_name("default:stone")
mock.add_node_name("default:glass")
mock.add_node_name("default:dirt")
local sessions = recorder_replay.sessions
local arena = recorder_replay.arena

local checks = 0
local function check(condition, message)
	checks = checks + 1
	if not condition then
		error("FAILED: " .. message, 2)
	end
	print("  ok - " .. message)
end

-- The cursor queries ask the tick indexes for the last row at or before a
-- moment instead of scanning for MAX(id). On a file whose ids follow its
-- ticks the answer is the same, which is what these compare against.
do
	local reader_module = dofile(modpath .. "/reader.lua")
	local handle = assert(reader_module.open(fixture_path, sqlite))
	local function old_max(table_name, tick)
		local stmt = assert(handle.db:prepare(
			("SELECT MAX(id) FROM %s WHERE tick <= %d"):format(table_name, tick)))
		local value
		if stmt:step() == sqlite.ROW then value = stmt:get_value(0) end
		stmt:finalize()
		return tonumber(value) or 0
	end
	for _, tick in ipairs({0, 1, 3, 4, 5, 6, 9, 10}) do
		check(reader_module.last_event_id(handle, tick) == old_max("Events", tick),
			"the event cursor at tick " .. tick .. " is the moment's last row")
	end
	for _, tick in ipairs({0, 3, 7, 9, 10}) do
		check(reader_module.last_metadata_id(handle, tick) == old_max("NodeMetadata", tick),
			"the metadata cursor at tick " .. tick .. " is the moment's last row")
	end
	for _, tick in ipairs({0, 7, 8, 10}) do
		check(reader_module.last_light_id(handle, tick) == old_max("LightChanges", tick),
			"the light cursor at tick " .. tick .. " is the moment's last row")
	end
	reader_module.close(handle)
end

local function near(a, b)
	return type(a) == "number" and math.abs(a - b) < 1e-9
end

local function ghost_of(name)
	for _, obj in pairs(mock.entities) do
		if obj.properties and obj.properties.nametag == name then return obj end
	end
	return nil
end

-- What a ghost holds is a separate `wielditem` entity attached to its hand.
local function held_by(obj)
	if not obj or not obj.wield_object then return nil end
	return obj.wield_object.properties.wield_item
end

local function item(kind)
	return mock.items["recorder_replay:" .. kind]
end

local function use(kind, player)
	local def = item(kind)
	return def.on_use(ItemStack("recorder_replay:" .. kind), player)
end

-- Forms opened from an input callback are shown a moment later, so the input
-- cannot click them. Only the timer clock needs to move for that; stepping the
-- server would also advance any running session.
local function deferred_form()
	mock.run_timers(0.2)
end

local function box(x1, y1, z1, x2, y2, z2)
	return {pos1 = {x = x1, y = y1, z = z1}, pos2 = {x = x2, y = y2, z = z2}}
end

local function box_is_air(area)
	for z = area.pos1.z, area.pos2.z do
		for y = area.pos1.y, area.pos2.y do
			for x = area.pos1.x, area.pos2.x do
				local node = mock.get_node({x = x, y = y, z = z})
				if node.name ~= "air" then
					return false, string.format("%s is %s", core.pos_to_string({x = x, y = y, z = z}), node.name)
				end
			end
		end
	end
	return true
end

-- Test players are trusted by default; a test that cares takes the privilege
-- away from one player and checks that the formspec submission is refused.
local function add_player(name, fields)
	fields = fields or {}
	if fields.privs == nil then fields.privs = {replay = true} end
	return mock.add_player(name, fields)
end

local function flag_entries()
	local raw = mock.modstorage["recorder_replay:session"]
	if not raw or raw == "" then return {} end
	local parsed = core.deserialize(raw)
	if type(parsed) == "table" then return parsed end
	return {}
end

local function flag_count()
	local count = 0
	for _ in pairs(flag_entries()) do count = count + 1 end
	return count
end

local function mark(player, area)
	local name = player:get_player_name()
	player.pos = area.pos1
	mock.chatcommands.replay.func(name, "pos1")
	player.pos = area.pos2
	mock.chatcommands.replay.func(name, "pos2")
end

local WATCHER_ARENA = box(100, 10, 100, 107, 14, 107)
local WATCHER_OFFSET = {x = 101, y = 11, z = 101}
-- Deliberately larger than the minimum 8 x 5 x 8: the recording goes in the
-- low corner and the rest of the interior stays air.
local STARTER_ARENA = box(200, 20, 200, 211, 26, 209)
local THIRD_ARENA = box(300, 30, 300, 307, 34, 307)

-- A fresh world has no arena to clean up; let the boot handler run now so that
-- later steps cannot mistake a running session's flag for a crash's.
mock.step(0)
check(mock.modstorage["recorder_replay:session"] == "" or
	mock.modstorage["recorder_replay:session"] == nil,
	"a fresh boot has nothing to recover")

----------------------------------------------------------------------------
print("=== choosing an arena ===")
----------------------------------------------------------------------------

local resolved, err = arena.resolve("Nobody", RECORDED)
check(resolved == nil, "without marks, a provider or a setting there is no arena")
check(tostring(err):find("/replay pos1", 1, true) ~= nil,
	"and the error says how to make one: " .. tostring(err))
check(tostring(err):find("replay.arena", 1, true) ~= nil, "it names the setting too")

arena.set_mark("Small", "pos1", {x = 60, y = 60, z = 60})
arena.set_mark("Small", "pos2", {x = 66, y = 64, z = 67})  -- 7 x 5 x 8
resolved, err = arena.resolve("Small", RECORDED)
check(resolved == nil and tostring(err):find("8 x 5 x 8", 1, true) ~= nil,
	"an arena smaller than the region plus its shell is refused: " .. tostring(err))
arena.clear_marks("Small")

arena.set_mark("Marked", "pos1", {x = 50.7, y = 50.2, z = 49.9})
arena.set_mark("Marked", "pos2", {x = 57, y = 54, z = 56})
resolved, err = arena.resolve("Marked", RECORDED)
check(resolved and resolved.pos1.x == 50 and resolved.pos1.y == 50 and resolved.pos1.z == 49,
	"marks resolve to their node, fractional corners floored")
check(resolved and resolved.pos2.x == 57 and resolved.pos2.y == 54 and resolved.pos2.z == 56,
	"and keep their far corner")
arena.clear_marks("Marked")

-- Two players marking overlapping boxes would both build where the other is.
arena.set_mark("Alice", "pos1", {x = 150, y = 10, z = 150})
arena.set_mark("Alice", "pos2", {x = 157, y = 14, z = 157})
arena.set_mark("Bob", "pos1", {x = 155, y = 10, z = 150})
arena.set_mark("Bob", "pos2", {x = 162, y = 14, z = 157})
resolved, err = arena.resolve("Bob", RECORDED)
check(resolved == nil and tostring(err):find("another player", 1, true) ~= nil,
	"an arena overlapping another player's pending one is refused: " .. tostring(err))
arena.clear_marks("Alice")
arena.clear_marks("Bob")

-- The commands mark where the player stands, and a mark dies with them.
local marker = add_player("Marker", {pos = {x = 50, y = 50, z = 50}})
mock.chatcommands.replay.func("Marker", "pos1")
marker.pos = {x = 57, y = 54, z = 57}
mock.chatcommands.replay.func("Marker", "pos2")
check(arena.has_marks("Marker"), "/replay pos1 and pos2 mark both corners")
resolved = arena.resolve("Marker", RECORDED)
check(resolved ~= nil, "and the marked arena resolves")
mock.fire("register_on_leaveplayer", marker, false)
check(not arena.has_marks("Marker"), "a mark is dropped when its player leaves")
marker.pos = {x = 50, y = 50, z = 50}
mock.chatcommands.replay.func("Marker", "pos1")
marker.pos = {x = 57, y = 54, z = 57}
mock.chatcommands.replay.func("Marker", "pos2")
mock.chatcommands.replay.func("Marker", "unset")
check(not arena.has_marks("Marker"), "/replay unset drops them")

-- The setting is the fallback of last resort.
mock.settings["replay.arena"] = "10,20,30,17,24,37"
resolved, err = arena.resolve("Setting", RECORDED)
check(resolved and resolved.pos1.x == 10 and resolved.pos2.z == 37,
	"replay.arena is used when there is no provider: " .. tostring(err))
mock.settings["replay.arena"] = "10,20,30"
resolved, err = arena.resolve("Setting", RECORDED)
check(resolved == nil and tostring(err):find("six numbers", 1, true) ~= nil,
	"a malformed setting is refused")
mock.settings["replay.arena"] = "10,20,30,16,24,37"
resolved, err = arena.resolve("Setting", RECORDED)
check(resolved == nil and tostring(err):find("too small", 1, true) ~= nil,
	"a configured arena that is too small is refused")

-- A provider is always consulted before the setting, and is told the size and
-- what is already in use.
local provider_box = box(400, 40, 400, 407, 44, 407)
local seen_size, seen_taken
recorder_common.game_hooks.arena = function(size, taken)
	seen_size, seen_taken = size, taken
	return provider_box.pos1, provider_box.pos2
end
mock.settings["replay.arena"] = "10,20,30,17,24,37"
resolved, err = arena.resolve("Pilot", RECORDED)
check(resolved and resolved.pos1.x == 400,
	"a provider is used instead of the setting: " .. tostring(err))
check(seen_size and seen_size.x == 8 and seen_size.y == 5 and seen_size.z == 8,
	"the provider is asked for the region plus its shell")
check(type(seen_taken) == "table" and #seen_taken == 0, "and for a free box")

recorder_common.game_hooks.arena = function()
	return {x = 400, y = 40, z = 400}, {x = 406, y = 44, z = 407}
end
resolved, err = arena.resolve("Pilot", RECORDED)
check(resolved == nil and tostring(err):find("too small", 1, true) ~= nil,
	"a provider answer that is too small is refused")
recorder_common.game_hooks.arena = function() return nil, "the core is full" end
resolved, err = arena.resolve("Pilot", RECORDED)
check(resolved == nil and tostring(err):find("the core is full", 1, true) ~= nil,
	"a provider that cannot help says why")

-- Marks are the player's own choice, so they come before the provider.
recorder_common.game_hooks.arena = function() return provider_box.pos1, provider_box.pos2 end
arena.set_mark("Both", "pos1", {x = 50, y = 50, z = 50})
arena.set_mark("Both", "pos2", {x = 57, y = 54, z = 57})
resolved = arena.resolve("Both", RECORDED)
check(resolved and resolved.pos1.x == 50, "a player's own marks win over the provider")
arena.clear_marks("Both")
recorder_common.game_hooks.arena = nil
mock.settings["replay.arena"] = nil

----------------------------------------------------------------------------
print("=== starting a replay in an arena ===")
----------------------------------------------------------------------------

-- A recording with no snapshot row, for the chooser's failure path. Its name
-- sorts before the fixture's, so the fixture stays first in the list.
local stale_path = world .. "/recordings/aa_stale-20250101T000000Z.sqlite"
local stale_writer = dbmanager.new(sqlite)
assert(stale_writer:open(stale_path))
stale_writer:set_meta("recorder.name", "stale")
stale_writer:add_event({stale_writer:next_id(), 0, 0, "recording_start", nil, nil,
	nil, nil, nil, nil, nil, nil, nil})
stale_writer:flush()
stale_writer:close()

local planner = add_player("Planner", {pos = {x = 0, y = 0, z = 0}})
local cmd = mock.chatcommands.replay
local ok, message = cmd.func("Planner", "")
check(not ok and tostring(message):find("/replay pos1", 1, true) ~= nil,
	"a bare /replay without an arena says how to make one: " .. tostring(message))

local watcher = add_player("Watcher", {pos = {x = 0, y = 0, z = 0}})
watcher.inventory = {main = {"default:pick_stone", "", "default:torch 10", "", "", "", "", ""}}
watcher.meta = {}
watcher.day_night_ratio = 0.25  -- what the game had given them

mark(watcher, WATCHER_ARENA)
watcher.pos = {x = 0, y = 0, z = 0}
ok, message = cmd.func("Watcher", "")
check(ok, "a bare /replay opens the recording chooser")
-- The form is shown one step later so the Enter that sent the command cannot
-- click it; the tests step the server the same way.
deferred_form()
check(watcher.formspec and watcher.formspec.name == "recorder_replay:recordings",
	"with the recording formspec")
check(watcher.formspec and watcher.formspec.formspec:find("fixture-", 1, true) ~= nil,
	"the recordings in the directory are listed")
check(watcher.formspec and watcher.formspec.formspec:find(";0;", 1, true) ~= nil,
	"with nothing selected yet")
check(watcher.formspec and watcher.formspec.formspec:find(";delete;", 1, true) == nil,
	"a replay-only player gets no Delete button")

-- A client can submit any form name it likes; the privilege is what makes the
-- submission trustworthy.
watcher.privs.replay = nil
mock.fire("register_on_player_receive_fields", watcher, "recorder_replay:recordings",
	{watch = "Watch"})
check(sessions.for_player("Watcher") == nil,
	"a submission without the replay privilege starts nothing")
watcher.privs.replay = true

-- Watch means the selected recording, and nothing is selected on opening.
mock.fire("register_on_player_receive_fields", watcher, "recorder_replay:recordings",
	{watch = "Watch"})
check(sessions.for_player("Watcher") == nil, "Watch with nothing selected starts nothing")
deferred_form()
check(watcher.formspec and watcher.formspec.formspec:find("Choose a recording first", 1, true) ~= nil,
	"and asks for a selection")

-- Selecting remembers the choice; the Watch button starts it.
mock.fire("register_on_player_receive_fields", watcher, "recorder_replay:recordings",
	{recordings = "CHG:1"})
check(sessions.for_player("Watcher") == nil, "selecting a recording does not start it")
mock.fire("register_on_player_receive_fields", watcher, "recorder_replay:recordings",
	{recordings = "DCL:99"})
check(sessions.for_player("Watcher") == nil, "a double-click on nothing starts nothing")

-- A start that fails keeps the chooser open with the reason in it, in red;
-- it is not sent to chat, where the reopened form would hide it.
local chats_before = #mock.chats
mock.fire("register_on_player_receive_fields", watcher, "recorder_replay:recordings",
	{recordings = "CHG:2"})  -- aa_stale, which has no snapshot
mock.fire("register_on_player_receive_fields", watcher, "recorder_replay:recordings",
	{watch = "Watch"})
check(sessions.for_player("Watcher") == nil, "a recording that cannot start does not start")
deferred_form()
check(watcher.formspec and watcher.formspec.name == "recorder_replay:recordings",
	"the chooser stays open")
check(watcher.formspec and watcher.formspec.formspec:find("no snapshot", 1, true) ~= nil,
	"with the reason in it")
check(watcher.formspec and watcher.formspec.formspec:find("#FF5555", 1, true) ~= nil,
	"as red text")
check(#mock.chats == chats_before, "and not in chat")

-- The game's before_enter hook must see the player before replay moves them
-- and before the hotbar becomes the remote control.
local before_enter_calls = {}
recorder_common.game_hooks.before_enter = function(player, session)
	before_enter_calls[#before_enter_calls + 1] = {
		name = player:get_player_name(),
		session_id = session and session.id,
		pos = player:get_pos(),
		first = watcher.inventory.main[1],
	}
end
mock.fire("register_on_player_receive_fields", watcher, "recorder_replay:recordings",
	{recordings = "CHG:1"})
mock.fire("register_on_player_receive_fields", watcher, "recorder_replay:recordings",
	{watch = "Watch"})
check(sessions.for_player("Watcher") ~= nil, "the Watch button starts the selected recording")

local session = sessions.for_player("Watcher")
check(session ~= nil, "the watcher is in the session")
check(#before_enter_calls == 1 and before_enter_calls[1].session_id == session.id,
	"the game's before_enter hook runs with the session")
check(before_enter_calls[1].name == "Watcher", "for the player entering the replay")
check(before_enter_calls[1].pos.x == 0 and before_enter_calls[1].pos.y == 0
	and before_enter_calls[1].pos.z == 0, "while they are still where the game left them")
check(before_enter_calls[1].first == "default:pick_stone",
	"with their own inventory, before the replay controls")
recorder_common.game_hooks.before_enter = nil
check(session.rec.name == "fixture", "the recording is named: " .. tostring(session.rec.name))
check(near(session.rec.duration, 1), "its duration is read: " .. tostring(session.rec.duration))
check(session.T == 0 and not session.paused, "it starts at the beginning, running")
check(session.participants.Watcher, "the starter is a participant")
check(session.arena and session.arena.pos1.x == 100 and session.arena.pos2.x == 107,
	"the session's arena is the one that was marked")
check(session.offset and session.offset.x == 101 and session.offset.y == 11
	and session.offset.z == 101, "the recording is placed one node in from the corner")
check(not arena.has_marks("Watcher"), "the marks became the session's arena")

-- What the bare command can know before a recording is chosen: whether a
-- source exists, and whether the box it names is free.
check(arena.available("Planner") == false, "no source means no chooser")
arena.set_mark("Planner", "pos1", WATCHER_ARENA.pos1)
arena.set_mark("Planner", "pos2", WATCHER_ARENA.pos2)
local available, why = arena.available("Planner")
check(available == false and tostring(why):find("in use", 1, true) ~= nil,
	"a marked arena over a running one is refused before the chooser: " .. tostring(why))
arena.clear_marks("Planner")
mock.settings["replay.arena"] = "100,10,100,107,14,107"
available, why = arena.available("Planner")
check(available == false and tostring(why):find("in use", 1, true) ~= nil,
	"a configured arena that is running is refused before the chooser")
mock.settings["replay.arena"] = nil

local entries = flag_entries()
check(entries[session.id] ~= nil, "the arena is remembered in mod storage")
check(entries[session.id] and entries[session.id].pos1.x == 100
	and entries[session.id].pos2.z == 107, "with its bounds")

check(mock.get_node({x = 100, y = 10, z = 100}).name == "recorder_replay:barrier",
	"the arena's outer layer is the barrier")
check(mock.get_node({x = 107, y = 14, z = 107}).name == "recorder_replay:barrier",
	"including the far corner")
check(mock.get_node({x = 103, y = 14, z = 103}).name == "recorder_replay:barrier",
	"and the ceiling")
check(mock.get_node({x = 103, y = 10, z = 103}).name == "recorder_replay:barrier",
	"and the floor")
check(mock.get_node({x = 103, y = 11, z = 103}).name == "air",
	"the interior starts as air")

local stone = mock.get_node({x = 101, y = 11, z = 101})
check(stone.name == "default:stone", "the snapshot's node is rebuilt inside: " .. stone.name)
local glass = mock.get_node({x = 103, y = 12, z = 103})
check(glass.name == "default:glass", "a node at (2,1,2) is rebuilt at the translated position")
check(glass.param2 == 7, "with its param2")
check(mock.get_node({x = 106, y = 11, z = 106}).name == "default:stone",
	"and the node at the far corner")
check(mock.get_node({x = 101, y = 12, z = 101}).name == "air",
	"nodes the snapshot does not name stay air")
check(mock.get_node({x = 105, y = 12, z = 105}).name == "unknown",
	"a node name this game does not have becomes unknown, not an error")
local barrier_def = mock.node_defs["recorder_replay:barrier"]
check(barrier_def and barrier_def.sunlight_propagates == true,
	"the shell lets sunlight through, so the arena is not a dark box")
check(barrier_def and barrier_def.paramtype == "light", "and takes part in lighting")
check(#mock.relit > 0 and mock.relit[#mock.relit].pos1.x == 100,
	"the arena is relit when it is built")
check(mock.liquids_updated == false, "the reconstruction does not start liquid flow")

local alice = ghost_of("Alice")
local bob = ghost_of("Bob")
check(alice ~= nil and bob ~= nil, "both players have ghosts at the start")
check(alice and near(alice.pos.x, 101) and near(alice.pos.y, 11) and near(alice.pos.z, 101),
	"Alice's ghost is translated into the arena: " .. tostring(alice and alice.pos.x))
check(bob and near(bob.pos.x, 106) and near(bob.pos.z, 106), "Bob's ghost too")
check(alice and alice.properties.mesh == "character.b3d", "the ghost wears the game's player model")
check(alice and alice.properties.textures and alice.properties.textures[1] == "character.png",
	"and the texture the recording carries")
check(alice and alice.properties.nametag == "Alice", "the ghost is named")
check(alice and alice.properties.collisionbox and alice.properties.collisionbox[5] > 0,
	"the ghost is lit from a body-sized box, not its feet")
check(watcher.day_night_ratio == 0.5, "the arena is lit at the recording's time of day")
check(alice and alice.observers and alice.observers.Watcher == true, "the watcher sees the ghosts")
check(alice and next(alice.observers, next(alice.observers)) == nil, "and nobody else does")

check(near(watcher.pos.x, 103.5) and watcher.pos.y == 15 and near(watcher.pos.z, 103.5),
	"the starter stands on the arena's top face: " .. core.pos_to_string(watcher.pos))
check(watcher.inventory.main[1] == "recorder_replay:pause", "the controls are in the hotbar")
local stash = core.deserialize(watcher.meta["recorder_replay:stash"] or "")
check(type(stash) == "table", "the watcher's things are stashed")
check(stash and stash.pos.x == 0 and stash.pos.y == 0 and stash.pos.z == 0,
	"the stash keeps the position from before the teleport")
check(stash and stash.main[1] == "default:pick_stone" and stash.main[3] == "default:torch 10",
	"and the inventory")

----------------------------------------------------------------------------
print("=== the clock ===")
----------------------------------------------------------------------------

mock.step(0.5)
check(near(session.T, 0.5), "half a second in: " .. tostring(session.T))
alice = ghost_of("Alice")
check(alice and near(alice.pos.x, 101.5), "Alice's ghost is at her tick-5 position: "
	.. tostring(alice and alice.pos.x))
check(alice and alice.animation ~= nil, "she is posed from the sample")
check(ghost_of("Bob") == nil, "Bob's leave at that moment removed his ghost")

----------------------------------------------------------------------------
print("=== held items ===")
----------------------------------------------------------------------------

check(held_by(alice) == "default:pick_stone",
	"the clock crossing a wield event changes what the ghost holds")
local held = alice and alice.wield_object
check(held and held.properties.visual == "wielditem",
	"the item is a wielditem entity, the only visual that draws one")
check(held and held.attached and held.attached.parent == alice
	and held.attached.bone == "Arm_Right",
	"attached to the model's hand bone")
check(held and held.attached.position.y == 5.5 and held.attached.position.z == 3,
	"with the player_api arm offset")
check(held and held.attached.rotation.x == -90 and held.attached.rotation.y == 225,
	"and its hand rotation")
check(held and held.properties.visual_size.x == 0.3, "at player_api hand size")
check(held and held.observers and held.observers.Watcher == true,
	"the item is sent to the watcher")
check(held and next(held.observers, next(held.observers)) == nil,
	"and to nobody else")
sessions.seek(session, 0)
check(held_by(ghost_of("Alice")) == "default:stone",
	"a seek falls back to the item the join event carries")
sessions.seek(session, 0.6)
check(held_by(ghost_of("Alice")) == "default:pick_stone",
	"a later wield event is applied on a seek")
sessions.seek(session, 0.8)
local emptied = held_by(ghost_of("Alice"))
check(emptied == nil, "an empty wield event puts the hands down")
check(held and held.removed == true, "and takes the item entity away")
sessions.seek(session, 0.45)
check(held_by(ghost_of("Alice")) == "default:stone", "before the change the join item is back")
mock.step(0.1)
check(held_by(ghost_of("Alice")) == "default:pick_stone", "forward playback crosses the change")
mock.step(0.15)
emptied = held_by(ghost_of("Alice"))
check(emptied == nil, "and reaches the empty hand")

-- A game or a cleanup can drop the item entity out from under a ghost; the
-- next wield must notice the stale ref and make a new item rather than leave
-- the ghost empty-handed.
sessions.seek(session, 0.45)
local restored = ghost_of("Alice")
check(restored and restored.wield_object ~= nil, "the seek brings the item back")
restored.wield_object:remove()
mock.step(0.05)
check(held_by(ghost_of("Alice")) == "default:pick_stone",
	"an item entity the engine dropped is made again")

----------------------------------------------------------------------------
print("=== the item a returning player holds ===")
----------------------------------------------------------------------------

-- A player who walks out of the region and back in has a leave and a join.
-- The join carries what they hold now; a wield from before the leave must not
-- win over it.
do
	local rejoin_path = world .. "/recordings/aa_rejoin-20250101T000000Z.sqlite"
	local rejoin_writer = dbmanager.new(sqlite)
	assert(rejoin_writer:open(rejoin_path))
	rejoin_writer:set_meta("recorder.name", "rejoin")
	assert(rejoin_writer:set_snapshot({
		tick = 0,
		t = 0,
		pos1 = {x = 0, y = 0, z = 0},
		size = {x = 4, y = 2, z = 4},
		names = "air",
		encoding = "raw",
		data = common.snapshot.encode({}),
	}))
	local carol = rejoin_writer:player_id("Carol")
	rejoin_writer:add_event({rejoin_writer:next_id(), 0, 0, "recording_start", nil, nil,
		nil, nil, nil, nil, nil, nil, nil})
	rejoin_writer:add_event({rejoin_writer:next_id(), 0, 0, "join", carol, nil, 0, 0, 0,
		nil, nil, "default:stone", nil})
	rejoin_writer:add_event({rejoin_writer:next_id(), 2, 0.2, "wield", carol, nil,
		nil, nil, nil, nil, nil, "default:pick_stone", nil})
	rejoin_writer:add_event({rejoin_writer:next_id(), 3, 0.3, "leave", carol, nil, 0, 0, 0,
		nil, nil, nil, nil})
	rejoin_writer:add_event({rejoin_writer:next_id(), 5, 0.5, "join", carol, nil, 0, 0, 0,
		nil, nil, "default:torch", nil})
	rejoin_writer:flush()
	rejoin_writer:close()

	local returner = add_player("Returner", {pos = {x = 0, y = 0, z = 0}})
	returner.inventory = {main = {}}
	mark(returner, box(1000, 100, 1000, 1007, 104, 1007))
	returner.pos = {x = 0, y = 0, z = 0}
	local rejoin_session = sessions.start(rejoin_path, returner)
	check(rejoin_session ~= nil, "a recording with a leave and a return starts")

	sessions.seek(rejoin_session, 0.25)
	check(ghost_of("Carol") ~= nil and held_by(ghost_of("Carol")) == "default:pick_stone",
		"before the leave the ghost holds what the last wield says")
	sessions.seek(rejoin_session, 0.6)
	check(ghost_of("Carol") ~= nil and held_by(ghost_of("Carol")) == "default:torch",
		"after the return the join's item wins over the earlier wield")

	recorder_replay.end_session(rejoin_session.id, "test")
	check(sessions.for_player("Returner") == nil, "and the test session ends")
end

----------------------------------------------------------------------------
print("=== recorded poses ===")
----------------------------------------------------------------------------

-- Before the pose event the recording says nothing about the pose, so the
-- speed-and-dig guess poses the ghost: Alice walks at 0.3 s.
sessions.seek(session, 0.3)
local posed = ghost_of("Alice")
check(posed and posed.animation and posed.animation.x == 168 and posed.animation.y == 187,
	"without a recorded pose the speed-and-dig guess poses the ghost")
check(posed and posed.animation_speed == 30, "at the model's animation speed")

-- From the pose event on, the recorded frame range is what the ghost wears,
-- even though Alice's movement samples still say she is walking and mining.
sessions.seek(session, 0.5)
posed = ghost_of("Alice")
check(posed and posed.animation and posed.animation.x == 220 and posed.animation.y == 240,
	"a seek applies the recorded pose")
check(posed and posed.animation_speed == 10 and posed.animation_blend == 0.2
	and posed.animation_loop == false, "with its speed, blend and loop")
sessions.seek(session, 0.9)
posed = ghost_of("Alice")
check(posed and posed.animation.x == 220, "later movement samples do not overwrite the recorded pose")

sessions.seek(session, 0.2)
posed = ghost_of("Alice")
check(posed and posed.animation and posed.animation.x ~= 220,
	"seeking back before the pose event drops it")

sessions.seek(session, 0.35)
posed = ghost_of("Alice")
check(posed and posed.animation.x ~= 220, "before the pose event forward playback still guesses")
mock.step(0.1)
posed = ghost_of("Alice")
check(posed and posed.animation and posed.animation.x == 220,
	"the clock crossing the pose event puts it on the ghost")
mock.step(0.2)
posed = ghost_of("Alice")
check(posed and posed.animation.x == 220, "and it stays while she moves")

----------------------------------------------------------------------------
print("=== particle effects ===")
----------------------------------------------------------------------------

local function live_by_texture(texture)
	local found = {}
	for _, definition in pairs(mock.live_spawners) do
		if definition.texture == texture then found[#found + 1] = definition end
	end
	return found
end

sessions.seek(session, 0.05)
check(next(mock.live_spawners) == nil, "before any spawner event there is nothing alive")

sessions.seek(session, 0.3)
check(#live_by_texture("recorder_smoke.png") == 1, "a seek recreates the spawner alive at T")
check(#live_by_texture("recorder_ember.png") == 1, "and the endless one")
check(#live_by_texture("recorder_spark.png") == 0, "but not one created after T")
local smoke = live_by_texture("recorder_smoke.png")[1]
check(smoke and smoke.minpos.x == 101 and smoke.minpos.y == 11 and smoke.minpos.z == 101,
	"translated into the arena: " .. tostring(smoke and smoke.minpos.x))
check(smoke and smoke.maxpos.x == 102, "both corners move together")
check(smoke and smoke.playername == nil, "a per-player effect is sent to every watcher")
local ember = live_by_texture("recorder_ember.png")[1]
check(ember and ember.attract and ember.attract.origin.x == 105
	and ember.attract.origin.y == 11 and ember.attract.origin.z == 105,
	"an attractor's origin moves with the spawner")

sessions.seek(session, 0.7)
check(#live_by_texture("recorder_smoke.png") == 0, "a deleted spawner is not recreated at a later moment")
check(#live_by_texture("recorder_ember.png") == 1, "the endless one still is")
check(#live_by_texture("recorder_spark.png") == 0, "an expired spawner is not recreated either")

sessions.seek(session, 0.3)
check(#live_by_texture("recorder_smoke.png") == 1, "seeking back recreates the deleted spawner")
check(next(mock.live_spawners) ~= nil, "and leaves a live spawner behind")

-- Forward playback creates and deletes as the clock reaches the events, and a
-- single particle is spawned when its moment comes.
sessions.seek(session, 0)
check(next(mock.live_spawners) == nil, "at the start no spawner is running")
local particles_before = #mock.particles
mock.step(0.25)
check(#live_by_texture("recorder_smoke.png") == 1 and #live_by_texture("recorder_ember.png") == 1,
	"forward playback creates spawners when the clock reaches them")
check(#mock.particles == particles_before, "and the puff at 0.3 s is not there yet")
mock.step(0.1)
check(#mock.particles == particles_before + 1, "the clock reaching the particle spawns one")
local puff = mock.particles[#mock.particles]
check(puff and puff.pos.x == 103 and puff.pos.y == 12 and puff.pos.z == 103,
	"translated into the arena: " .. tostring(puff and puff.pos.x))
check(puff and puff.texture == "recorder_puff.png" and puff.playername == nil,
	"with its definition and no player restriction")
mock.step(0.3)
check(#live_by_texture("recorder_smoke.png") == 0, "the delete event cancels the replay spawner")
check(#live_by_texture("recorder_ember.png") == 1, "and leaves the others alone")

----------------------------------------------------------------------------
print("=== recorded chat ===")
----------------------------------------------------------------------------

-- Chat is transient: it is shown when the clock reaches it and is not rebuilt
-- by a seek.
sessions.seek(session, 0.1)
local chats_before = #mock.chats
mock.step(0.1)  -- T = 0.2, across the line at 0.2
check(#mock.chats == chats_before + 1, "a recorded line is shown when the clock reaches it")
check(mock.chats[#mock.chats].name == "Watcher", "to the replay's participant")
check(mock.chats[#mock.chats].message == "[replay] Alice: hello",
	"verbatim, with a marker: " .. tostring(mock.chats[#mock.chats].message))

sessions.seek(session, 0.5)
chats_before = #mock.chats
mock.step(0.1)  -- T = 0.6, across the broadcast at 0.55
check(#mock.chats == chats_before + 1
	and mock.chats[#mock.chats].message == "[replay] Server restarting",
	"a broadcast is shown too: " .. tostring(mock.chats[#mock.chats].message))

chats_before = #mock.chats
sessions.seek(session, 0.1)
sessions.seek(session, 0.6)
check(#mock.chats == chats_before, "a seek does not replay chat from the past")

-- The switch is read when a session starts.
mock.settings["replay.chat"] = "false"
local quiet = add_player("Quiet", {pos = {x = 0, y = 0, z = 0}})
quiet.inventory = {main = {}}
mark(quiet, box(1100, 110, 1100, 1107, 114, 1107))
quiet.pos = {x = 0, y = 0, z = 0}
local was_paused = session.paused
session.paused = true
local quiet_session = sessions.start(fixture_path, quiet)
check(quiet_session ~= nil, "a session with replay.chat off starts")
local quiet_before = #mock.chats
sessions.seek(quiet_session, 0.1)
mock.step(0.1)  -- T = 0.2, across the line at 0.2
local quiet_chats = 0
for i = quiet_before + 1, #mock.chats do
	if mock.chats[i].name == "Quiet" then quiet_chats = quiet_chats + 1 end
end
check(quiet_chats == 0, "replay.chat = false keeps recorded chat out")
recorder_replay.end_session(quiet_session.id, "test")
session.paused = was_paused
mock.settings["replay.chat"] = nil

----------------------------------------------------------------------------
print("=== the remote control ===")
----------------------------------------------------------------------------

use("pause", watcher)
check(session.paused == true, "the pause item pauses")
local frozen = session.T
mock.step(0.5)
check(session.T == frozen, "a paused clock does not move")
use("pause", watcher)
check(session.paused == false, "and the same item resumes")

use("speed", watcher)
check(session.speed == 2, "the speed item doubles the speed")
mock.step(0.1)
check(near(session.T, frozen + 0.2), "so a step advances twice as far: " .. tostring(session.T))
use("speed", watcher)
use("speed", watcher)
use("speed", watcher)
check(session.speed == 1, "and the item cycles back to 1x")

use("back", watcher)
check(session.T == 0, "back 10 s clamps to the start")
use("forward", watcher)
check(near(session.T, 1), "forward 10 s clamps to the end")

use("seek", watcher)
deferred_form()
check(watcher.formspec and watcher.formspec.name == "recorder_replay:seek",
	"the seek item opens a formspec")
check(watcher.formspec and watcher.formspec.formspec:find("scrollbar", 1, true) ~= nil,
	"with a slider")
mock.fire("register_on_player_receive_fields", watcher, "recorder_replay:seek", {seek = "CHG:4"})
check(near(session.T, 0.4), "the slider seeks: " .. tostring(session.T))

----------------------------------------------------------------------------
print("=== seeking the reconstruction ===")
----------------------------------------------------------------------------

sessions.seek(session, 0.3)
check(near(session.T, 0.3), "the clock is where it was asked")
check(ghost_of("Alice") ~= nil and near(ghost_of("Alice").pos.x, 101.3),
	"Alice is back at 0.3 s")
check(ghost_of("Bob") ~= nil, "Bob is back because he had not left yet")
check(mock.get_node({x = 101, y = 11, z = 101}).name == "default:stone",
	"the node dug later is still there at 0.3 s")
check(mock.get_node({x = 103, y = 12, z = 103}).name == "default:glass",
	"and so is the glass")

sessions.seek(session, 0.9)
check(ghost_of("Bob") == nil, "and gone again past his leave")
check(mock.get_node({x = 101, y = 11, z = 101}).name == "air",
	"a node change up to the seek is applied")
local dirt = mock.get_node({x = 103, y = 12, z = 103})
check(dirt.name == "default:dirt" and dirt.param2 == 3,
	"a replacement is applied with its param2: " .. dirt.name .. " p" .. tostring(dirt.param2))

sessions.seek(session, 0.3)
check(mock.get_node({x = 101, y = 11, z = 101}).name == "default:stone",
	"seeking back restores the snapshot")
check(mock.get_node({x = 103, y = 12, z = 103}).name == "default:glass",
	"and the other node")

sessions.seek(session, 0.7)
check(mock.get_node({x = 101, y = 11, z = 101}).name == "default:stone",
	"before the change the floor is whole again")
local vms = #mock.vms
local relit = #mock.relit
mock.step(0.25)
check(near(session.T, 0.95), "playback crosses the change: " .. tostring(session.T))
check(mock.get_node({x = 101, y = 11, z = 101}).name == "air",
	"a node change crossed by the clock is applied")
check(mock.get_node({x = 103, y = 12, z = 103}).name == "default:dirt",
	"the other change as well")
check(#mock.vms == vms + 1, "the crossed changes are written once for the step")
check(#mock.relit == relit, "forward changes leave the light to write_to_map()")
check(mock.liquids_updated == false, "still without starting liquid flow")

----------------------------------------------------------------------------
print("=== node metadata ===")
----------------------------------------------------------------------------

-- The chest is at recorded (3,1,3), so (104,12,104) in the arena.
local CHEST = "104,12,104"
local function chest()
	return mock.node_meta[CHEST]
end
sessions.seek(session, 0.3)
check(chest() ~= nil, "the baseline metadata is applied to the reconstruction")
check(chest() and chest().fields.owner == "alice", "with its fields")
check(chest() and chest().inventory.main[1] == "default:stone 5"
	and chest().inventory.main[3] == "default:torch 3", "and its inventory, slot for slot")

sessions.seek(session, 0.8)
check(chest() and chest().inventory.main[1] == "", "a later metadata change is applied")
check(chest() and chest().inventory.main[3] == "default:torch 3", "leaving the rest alone")

sessions.seek(session, 0.3)
check(chest() and chest().inventory.main[1] == "default:stone 5",
	"seeking back restores the earlier contents")

sessions.seek(session, 0.5)
check(chest() and chest().inventory.main[1] == "default:stone 5", "before the change")
mock.step(0.35)
check(near(session.T, 0.85), "the clock crossed the change: " .. tostring(session.T))
check(chest() and chest().inventory.main[1] == "",
	"forward playback applies the metadata change when the clock reaches it")
mock.step(0.1)
check(chest() == nil, "and the clearing row when it reaches that")

----------------------------------------------------------------------------
print("=== lighting ===")
----------------------------------------------------------------------------

local glass_cell = {x = 103, y = 12, z = 103}
local stone_cell = {x = 101, y = 11, z = 101}
sessions.seek(session, 0.3)
check(session.light == "recorded", "a recording with light starts on its own lighting")
check(mock.get_node(glass_cell).light == 7, "the recorded light is in the world")
check(mock.get_node(stone_cell).light == 12, "at the recorded values")
check(watcher.inventory.main[7] == "recorder_replay:light_recorded",
	"and the lighting switch is in the hotbar")

local swapped = use("light_recorded", watcher)
check(swapped and swapped:to_string() == "recorder_replay:light_live",
	"using it swaps the item for the other mode")
check(session.light == "live", "the session is on live lighting now")
check(mock.get_node(glass_cell).light == 15, "and the light is recalculated")
check(watcher.day_night_ratio == 0.25, "and the server's own time of day is back")
check(watcher.inventory.main[7] == "recorder_replay:light_live",
	"the hotbar shows the live mode")

local back = use("light_live", watcher)
check(back and back:to_string() == "recorder_replay:light_recorded",
	"using that one swaps back")
check(session.light == "recorded", "recorded lighting again")
check(mock.get_node(glass_cell).light == 7, "and the recorded value is back")
check(watcher.day_night_ratio == 0.5, "and so is the recording's time of day")
check(watcher.inventory.main[7] == "recorder_replay:light_recorded",
	"and the hotbar shows the recorded mode")

sessions.seek(session, 0.9)
check(session.light == "recorded", "seeking keeps the chosen mode")
check(mock.get_node(glass_cell).light == 3, "a recorded light change is applied")
sessions.seek(session, 0.3)
check(mock.get_node(glass_cell).light == 7, "and seeking back restores the earlier light")
check(mock.get_node(stone_cell).light == 12, "the rest of the layer is untouched")

sessions.seek(session, 0.5)
local relit_before = #mock.relit
mock.step(0.35)
check(mock.get_node(glass_cell).light == 3,
	"forward playback applies the light change in recorded mode")
check(mock.get_node({x = 101, y = 11, z = 101}).name == "air",
	"the node change crossed too")
check(#mock.relit == relit_before, "without recalculating it live")

sessions.seek(session, 0.5)
local vms_before_same = #mock.vms
sessions.seek(session, 0.5)
check(#mock.vms == vms_before_same, "seeking to the same moment writes nothing")

sessions.seek(session, 0.3)
check(mock.get_node({x = 101, y = 11, z = 101}).name == "default:stone",
	"seeking back after playback restores the node as well")
check(mock.get_node(glass_cell).light == 7, "and the light from before the changes")

----------------------------------------------------------------------------
print("=== a ghost that disappears ===")
----------------------------------------------------------------------------

sessions.seek(session, 0.5)
alice = ghost_of("Alice")
check(alice ~= nil, "Alice has a ghost")
local vanished = alice
vanished:remove()
check(mock.entities[vanished.id] == nil, "the object is gone, as if its mapblocks unloaded")
sessions.update_observers(session)
local stale = false
for _, obj in pairs(session.ghosts) do
	if obj == vanished then stale = true end
end
check(not stale, "updating observers drops the stale ghost instead of raising")

sessions.seek(session, 0.5)
alice = ghost_of("Alice")
check(alice ~= nil, "a seek brings it back")
vanished = alice
vanished:remove()
mock.step(0.1)
stale = false
for _, obj in pairs(session.ghosts) do
	if obj == vanished then stale = true end
end
check(not stale, "a movement step also drops a ghost that vanished")
sessions.seek(session, 0.5)
check(ghost_of("Alice") ~= nil, "and a later seek still restores it")

----------------------------------------------------------------------------
print("=== a second viewer ===")
----------------------------------------------------------------------------

local second = add_player("Second", {pos = {x = 0, y = 0, z = 0}})
second.inventory = {main = {}}
local joined = sessions.join(session, second)
check(joined, "a second player joins")
check(near(second.pos.x, 103.5) and second.pos.y == 15,
	"and is put on the viewing platform: " .. core.pos_to_string(second.pos))
check(second.day_night_ratio == 0.5, "and gets the recording's time of day too")
alice = ghost_of("Alice")
check(alice.observers.Second == true and alice.observers.Watcher == true,
	"the ghosts are sent to both")
sessions.leave(session, second)
check(ghost_of("Alice").observers.Second == nil, "and not to one who left")
check(second.pos.x == 0 and second.pos.y == 0, "the viewer is back where they were")
check(second.day_night_ratio == nil, "with their own sky back")
check(mock.get_node({x = 100, y = 10, z = 100}).name == "recorder_replay:barrier",
	"one viewer leaving does not touch the arena")

----------------------------------------------------------------------------
print("=== leaving and ending ===")
----------------------------------------------------------------------------

-- The chest has metadata at 0.3 s; leaving must take it out of the arena with
-- the nodes, because a VoxelManip write does not touch node metadata.
sessions.seek(session, 0.3)
check(chest() ~= nil, "the chest has metadata again before leaving")
use("leave", watcher)
check(sessions.for_player("Watcher") ~= nil, "the leave item asks to leave")
-- The engine writes the used stack back into its slot after on_use returns;
-- the restore has to win over that write.
watcher.inventory.main[1] = "recorder_replay:leave"
mock.step(0.1)
check(sessions.for_player("Watcher") == nil, "the next step leaves the replay")
check(next(mock.entities) == nil, "no ghosts are left")
check(next(mock.live_spawners) == nil, "no particle spawners are left either")
local empty, offender = box_is_air(WATCHER_ARENA)
check(empty, "the whole arena is air again: " .. tostring(offender))
check(#mock.relit > 0 and mock.relit[#mock.relit].pos1.x == 100,
	"clearing it recalculates the light of the ground it covered")
check(chest() == nil, "and its node metadata goes with the nodes")
check(flag_count() == 0, "and the boot flag is gone")
check(watcher.inventory.main[1] == "default:pick_stone",
	"the player's things are back after the engine's write: " .. tostring(watcher.inventory.main[1]))
check(watcher.inventory.main[3] == "default:torch 10", "all of them")
check(watcher.meta["recorder_replay:stash"] == "", "and the stash is gone")
check(near(watcher.pos.x, 0) and near(watcher.pos.y, 0), "the watcher is back where they started")
check(watcher.day_night_ratio == 0.25, "and the game's day/night override is back")

----------------------------------------------------------------------------
print("=== recordings that cannot be read ===")
----------------------------------------------------------------------------

-- A file that is not SQLite at all.
local garbage_path = world .. "/recordings/garbage-20240101T000000Z.sqlite"
local garbage = assert(io.open(garbage_path, "wb"))
garbage:write("this is not a database")
garbage:close()
local bad_session, bad_err = sessions.start(garbage_path, planner)
check(bad_session == nil and tostring(bad_err):find("not a database", 1, true) ~= nil,
	"a file that is not a database is refused: " .. tostring(bad_err))

-- A file that carries the recording's identity but none of its tables. Every
-- query against it raises, so it is refused before a session can be built.
local crafted_path = world .. "/recordings/crafted-20240101T000000Z.sqlite"
local crafted = assert(sqlite.open(crafted_path))
crafted:exec(string.format("PRAGMA application_id = %d", common.APPLICATION_ID))
crafted:exec(string.format("PRAGMA user_version = %d", common.SCHEMA_VERSION))
crafted:close()
bad_session, bad_err = sessions.start(crafted_path, planner)
check(bad_session == nil and tostring(bad_err):find("cannot read", 1, true) ~= nil,
	"a file with the identity but not the tables is refused: " .. tostring(bad_err))
check(tostring(bad_err):find("missing", 1, true) ~= nil,
	"and the error says what is missing")

-- The recording without a snapshot row, made for the chooser's failure path,
-- is also refused when started through the API.
local vms_before = #mock.vms
bad_session, bad_err = sessions.start(stale_path, planner)
check(bad_session == nil and tostring(bad_err):find("no snapshot", 1, true) ~= nil,
	"a recording without a snapshot is refused: " .. tostring(bad_err))
check(#mock.vms == vms_before, "and no arena is built for it")
check(flag_count() == 0, "nor remembered")

----------------------------------------------------------------------------
print("=== a disconnect and a return ===")
----------------------------------------------------------------------------

watcher.pos = {x = 4, y = 5, z = 6}
mark(watcher, WATCHER_ARENA)
watcher.pos = {x = 4, y = 5, z = 6}
local resumed = sessions.start("fixture", watcher)
check(resumed ~= nil, "a replay starts again")
check(near(watcher.pos.x, 103.5) and watcher.pos.y == 15, "the starter is on the platform")
deferred_form()
mock.fire("register_on_leaveplayer", watcher, false)
check(sessions.for_player("Watcher") == nil, "a disconnect removes them from the session")
check(watcher.meta["recorder_replay:stash"] ~= "", "but keeps their things stashed")
check(box_is_air(WATCHER_ARENA), "a disconnect tears the arena down")
check(flag_count() == 0, "and the flag goes with it")
-- The session ended with its only viewer, so the next join restores them.
mock.fire("register_on_joinplayer", watcher)
check(watcher.meta["recorder_replay:stash"] == "", "the stash is consumed on rejoin")
check(watcher.inventory.main[1] == "default:pick_stone", "and their things are back")
check(watcher.pos.x == 4 and watcher.pos.y == 5, "where they were when they started watching")
check(watcher.day_night_ratio == nil, "and no day/night override is left behind")

----------------------------------------------------------------------------
print("=== a disconnect with the replay still running ===")
----------------------------------------------------------------------------

-- Someone else keeps the replay going while the watcher is away, so coming
-- back puts them in it again and the original save waits for the leave.
watcher.inventory = {main = {"default:pick_stone", "", "default:torch 10", "", "", "", "", ""}}
watcher.pos = {x = 4, y = 5, z = 6}
mark(watcher, WATCHER_ARENA)
watcher.pos = {x = 4, y = 5, z = 6}
local still_running = sessions.start("fixture", watcher)
check(still_running ~= nil, "a replay starts with the watcher")
deferred_form()
local keeper = add_player("Keeper", {pos = {x = 0, y = 0, z = 0}})
keeper.inventory = {main = {}}
check(sessions.join(still_running, keeper), "a second viewer keeps it running")
mock.fire("register_on_leaveplayer", watcher, false)
check(sessions.for_player("Watcher") == nil, "the watcher disconnects")
check(watcher.meta["recorder_replay:stash"] ~= "", "with their things stashed")
check(not box_is_air(WATCHER_ARENA), "the other viewer keeps the arena up")
mock.fire("register_on_joinplayer", watcher)
check(sessions.for_player("Watcher") == still_running,
	"coming back returns them to the running replay")
check(watcher.meta["recorder_replay:stash"] ~= "", "and leaves the save for the eventual leave")
check(near(watcher.pos.x, 103.5) and watcher.pos.y == 15, "on the viewing platform again")
sessions.leave(still_running, watcher)
check(sessions.for_player("Watcher") == nil, "leaving the replay")
check(watcher.meta["recorder_replay:stash"] == "", "consumes the save")
check(watcher.inventory.main[1] == "default:pick_stone"
	and watcher.inventory.main[3] == "default:torch 10", "and gives their things back")
check(watcher.pos.x == 4 and watcher.pos.y == 5 and watcher.pos.z == 6,
	"where the save put them")
sessions.leave(still_running, keeper)
check(box_is_air(WATCHER_ARENA) and flag_count() == 0,
	"the last viewer ends the session and its arena")
mock.remove_player("Keeper")

----------------------------------------------------------------------------
print("=== a game without a persistent world ===")
----------------------------------------------------------------------------

-- Replay stashes nothing here. before_enter is where the game saves the
-- player, and on_leave is where it gets them back; neither replay itself nor
-- a stash touches their position or inventory.
local NONP_ARENA = box(900, 90, 900, 907, 94, 907)
local solo = add_player("Solo", {pos = {x = 5, y = 6, z = 7}})
solo.inventory = {main = {"default:pick_stone", "", "default:torch 10", "", "", "", "", ""}}
mark(solo, NONP_ARENA)
solo.pos = {x = 5, y = 6, z = 7}
local saved = {}
local entered_at, left_at, left_first, left_ratio
recorder_common.game_hooks.world_persistent = false
recorder_common.game_hooks.before_enter = function(player, session)
	saved[player:get_player_name()] = {
		pos = player:get_pos(),
		main = player:get_inventory():get_list("main"),
	}
end
recorder_common.game_hooks.on_enter = function(player, session)
	entered_at = player:get_pos()
end
recorder_common.game_hooks.on_leave = function(player, session)
	left_at = player:get_pos()
	left_ratio = player:get_day_night_ratio()
	local inv = player:get_inventory()
	left_first = inv and inv:get_list("main")[1]:to_string()
	local state = saved[player:get_player_name()]
	player:set_pos(state.pos)
	inv:set_list("main", state.main)
end
local solo_session = sessions.start("fixture", solo)
check(solo_session ~= nil, "a replay starts on a non-persistent world")
deferred_form()
check(solo.meta["recorder_replay:stash"] == nil or solo.meta["recorder_replay:stash"] == "",
	"replay stashes nothing")
check(saved.Solo and saved.Solo.pos.x == 5 and saved.Solo.pos.y == 6 and saved.Solo.pos.z == 7,
	"before_enter sees the player where the game left them")
check(saved.Solo and saved.Solo.main[1] and saved.Solo.main[1]:to_string() == "default:pick_stone",
	"with their own inventory")
local viewing = arena.viewing_position(NONP_ARENA)
check(entered_at and near(entered_at.x, viewing.x) and entered_at.y == viewing.y,
	"on_enter runs after the teleport")
sessions.leave(solo_session, solo)
check(solo.meta["recorder_replay:stash"] == nil or solo.meta["recorder_replay:stash"] == "",
	"still nothing stashed")
check(left_at and near(left_at.x, viewing.x) and left_at.y == viewing.y,
	"on_leave sees them still at the viewing platform")
check(left_first == "recorder_replay:pause", "with the replay controls still in the hotbar")
check(left_ratio == nil, "and the day/night override already put back")
check(solo.pos.x == 5 and solo.pos.y == 6 and solo.pos.z == 7,
	"the game's hook puts them back")
check(solo.inventory.main[1] == "default:pick_stone", "with their own things")
check(box_is_air(NONP_ARENA), "the session's arena is cleared")
recorder_common.game_hooks.world_persistent = true
recorder_common.game_hooks.before_enter = nil
recorder_common.game_hooks.on_enter = nil
recorder_common.game_hooks.on_leave = nil
mock.remove_player("Solo")

----------------------------------------------------------------------------
print("=== several arenas at once ===")
----------------------------------------------------------------------------

local starter = add_player("Starter", {pos = {x = 0, y = 0, z = 0}})
starter.inventory = {main = {}}
local third = add_player("Third", {pos = {x = 0, y = 0, z = 0}})
third.inventory = {main = {}}

mark(starter, STARTER_ARENA)
mark(third, THIRD_ARENA)
starter.pos = {x = 0, y = 0, z = 0}
third.pos = {x = 0, y = 0, z = 0}
local first = sessions.start(fixture_path, starter)
local other = sessions.start(fixture_path, third)
check(first and other, "two replays are running")
check(mock.get_node({x = 201, y = 21, z = 201}).name == "default:stone",
	"the first arena has its own reconstruction")
check(mock.get_node({x = 211, y = 26, z = 209}).name == "recorder_replay:barrier",
	"a larger arena gets its shell on its own outer layer")
check(mock.get_node({x = 210, y = 25, z = 208}).name == "air",
	"and the interior the recording does not use stays air")
check(mock.get_node({x = 301, y = 31, z = 301}).name == "default:stone",
	"the second session's arena has its own reconstruction too")
check(near(starter.pos.x, 205.5) and starter.pos.y == 27,
	"each starter stands on their own arena's top face: " .. core.pos_to_string(starter.pos))
check(near(third.pos.x, 303.5) and third.pos.y == 35, "the second on theirs: "
	.. core.pos_to_string(third.pos))
check(flag_count() == 2, "both arenas are remembered")

-- A provider has to be told both boxes are taken.
local seen
recorder_common.game_hooks.arena = function(size, taken)
	seen = taken
	return {x = 500, y = 50, z = 500}, {x = 507, y = 54, z = 507}
end
resolved = arena.resolve("Fourth", RECORDED)
recorder_common.game_hooks.arena = nil
check(resolved ~= nil and type(seen) == "table" and #seen == 2,
	"the provider is told which arenas are taken")

ok, message = cmd.func("Watcher", "join")
deferred_form()
check(ok and watcher.formspec and watcher.formspec.name == "recorder_replay:sessions",
	"joining with more than one running opens the chooser")
ok, message = cmd.func("Watcher", "join " .. first.id)
check(ok and sessions.for_player("Watcher") == first, "joining by id picks that one")
cmd.func("Watcher", "leave")
recorder_replay.end_session(other.id, "test")
check(sessions.for_player("Third") == nil, "ending a session restores its participants")
check(box_is_air(THIRD_ARENA), "and clears its arena")
check(flag_count() == 1, "the other session's flag entry stays")
check(mock.get_node({x = 201, y = 21, z = 201}).name == "default:stone",
	"the other arena is untouched")
recorder_replay.end_session(first.id, "test")
check(box_is_air(STARTER_ARENA), "ending the last session clears its arena")
check(flag_count() == 0, "and the flag is gone")
check(starter.pos.x == 0 and starter.pos.y == 0, "its starter is back where they were")

----------------------------------------------------------------------------
print("=== boot recovery ===")
----------------------------------------------------------------------------

local crashed = box(500, 50, 500, 507, 54, 507)
mock.set_node(crashed.pos1, {name = "recorder_replay:barrier"})
mock.set_node({x = 503, y = 52, z = 503}, {name = "recorder_replay:barrier"})
mock.modstorage["recorder_replay:session"] = core.serialize({
	old1 = {pos1 = crashed.pos1, pos2 = crashed.pos2},
})
recorder_common.game_hooks.world_persistent = true
mock.liquids_updated = false
arena.recover()
check(box_is_air(crashed), "a persistent world's leftover arena is cleared")
check(mock.modstorage["recorder_replay:session"] == "", "the flag is erased")
check(mock.liquids_updated == false, "without starting liquid flow")

local rebuilt = box(600, 60, 600, 607, 64, 607)
mock.set_node(rebuilt.pos1, {name = "recorder_replay:barrier"})
mock.modstorage["recorder_replay:session"] = core.serialize({
	old2 = {pos1 = rebuilt.pos1, pos2 = rebuilt.pos2},
})
recorder_common.game_hooks.world_persistent = false
arena.recover()
check(mock.get_node(rebuilt.pos1).name == "recorder_replay:barrier",
	"a world the game rebuilds is not written")
check(mock.modstorage["recorder_replay:session"] == "", "but the flag is still erased")
recorder_common.game_hooks.world_persistent = true

-- A crash can leave several arenas behind; every one of them is remembered.
local one = box(700, 70, 700, 707, 74, 707)
local two = box(800, 80, 800, 807, 84, 807)
mock.set_node(one.pos1, {name = "recorder_replay:barrier"})
mock.set_node(two.pos1, {name = "recorder_replay:barrier"})
mock.modstorage["recorder_replay:session"] = core.serialize({
	a = {pos1 = one.pos1, pos2 = one.pos2},
	b = {pos1 = two.pos1, pos2 = two.pos2},
})
arena.recover()
check(box_is_air(one) and box_is_air(two), "every arena of a crashed run is cleared")
check(mock.modstorage["recorder_replay:session"] == "", "and the flag is erased")

-- A flag left in a shape nobody can read names no arena to clean up; the boot
-- must not fail on it, and must still erase it.
mock.modstorage["recorder_replay:session"] = "}{ not a serialized table"
arena.recover()
check(mock.modstorage["recorder_replay:session"] == "",
	"a flag that cannot be read is erased instead of raising")

----------------------------------------------------------------------------
print("=== a recording without light ===")
----------------------------------------------------------------------------

local NOLIGHT_ARENA = box(400, 40, 400, 407, 44, 407)
mark(planner, NOLIGHT_ARENA)
planner.pos = {x = 0, y = 0, z = 0}
planner.inventory = {main = {"", "", "", "", "", "", "", ""}}
local dark_session, dark_err = sessions.start(nolight_path, planner)
check(dark_session ~= nil, "a recording without light still starts: " .. tostring(dark_err))
check(dark_session and dark_session.light == "recorded", "with the recorded time of day by default")
check(dark_session and not dark_session.reconstruct.has_light, "even though it has no light layer")
check(planner.day_night_ratio == 0.5, "so the arena gets the recorded day")
check(planner.inventory.main[7] == "recorder_replay:light_recorded",
	"and the switch is offered for the time of day")

local vms_before_switch = #mock.vms
local switched = use("light_recorded", planner)
check(switched and switched:to_string() == "recorder_replay:light_live",
	"the switch changes just the time of day")
check(dark_session.light == "live", "the session is on the server's time")
check(planner.day_night_ratio == nil, "and so is the arena")
check(#mock.vms == vms_before_switch, "without touching the map")
check(planner.inventory.main[7] == "recorder_replay:light_live", "the hotbar follows")
use("light_live", planner)
check(planner.day_night_ratio == 0.5, "and switching back restores the recorded day")

recorder_replay.end_session(dark_session.id, "test")
check(sessions.for_player("Planner") == nil, "and it ends cleanly")
check(planner.day_night_ratio == nil, "with the day/night override gone")

----------------------------------------------------------------------------
print("=== deleting a recording ===")
----------------------------------------------------------------------------

local DELETE_NAME = "zz_delete_me-20250101T000000Z.sqlite"
local DELETE_PATH = world .. "/recordings/" .. DELETE_NAME
local delete_file = assert(io.open(DELETE_PATH, "wb"))
delete_file:write("a file that only has to be listed and removed")
delete_file:close()
local delete_wal = assert(io.open(DELETE_PATH .. "-wal", "wb"))
delete_wal:write("wal")
delete_wal:close()

local function chooser_index(file_name)
	local names = {}
	for _, name in ipairs(core.get_dir_list(world .. "/recordings", false) or {}) do
		if name:sub(-7) == ".sqlite" then names[#names + 1] = name end
	end
	table.sort(names, function(a, b) return a > b end)
	for i, name in ipairs(names) do
		if name == file_name then return i end
	end
	return nil
end

local DELETE_ARENA = box(900, 90, 900, 907, 94, 907)
mark(planner, DELETE_ARENA)
planner.pos = {x = 0, y = 0, z = 0}
planner.privs.server = true

local ok, message = cmd.func("Planner", "")
check(ok, "a chooser opens for the delete test: " .. tostring(message))
deferred_form()
check(planner.formspec and planner.formspec.formspec:find(";delete;", 1, true) ~= nil,
	"a server-privileged player gets a Delete button")

local delete_index = chooser_index(DELETE_NAME)
check(delete_index ~= nil, "the test recording is in the list")
mock.fire("register_on_player_receive_fields", planner, "recorder_replay:recordings",
	{recordings = "CHG:" .. delete_index})
mock.fire("register_on_player_receive_fields", planner, "recorder_replay:recordings",
	{delete = "Delete"})
deferred_form()
check(planner.formspec and planner.formspec.name == "recorder_replay:delete",
	"Delete asks for confirmation")
check(planner.formspec and planner.formspec.formspec:find(DELETE_NAME, 1, true) ~= nil,
	"naming the recording")

mock.fire("register_on_player_receive_fields", planner, "recorder_replay:delete",
	{cancel = "Cancel", quit = "true"})
deferred_form()
check(planner.formspec and planner.formspec.name == "recorder_replay:recordings",
	"Cancel returns to the list")
check(recorder_common.file_exists(DELETE_PATH), "and the file is still there")

delete_index = chooser_index(DELETE_NAME)
mock.fire("register_on_player_receive_fields", planner, "recorder_replay:recordings",
	{recordings = "CHG:" .. delete_index})
mock.fire("register_on_player_receive_fields", planner, "recorder_replay:recordings",
	{delete = "Delete"})
deferred_form()
mock.fire("register_on_player_receive_fields", planner, "recorder_replay:delete",
	{confirm = "Delete", quit = "true"})
deferred_form()
check(not recorder_common.file_exists(DELETE_PATH), "Delete removes the recording")
check(not recorder_common.file_exists(DELETE_PATH .. "-wal"), "and its write-ahead sidecar")
check(planner.formspec and planner.formspec.name == "recorder_replay:recordings",
	"and the list comes back")
check(planner.formspec and planner.formspec.formspec:find("zz_delete_me", 1, true) == nil,
	"without the deleted file")
check(#mock.chats > 0 and mock.chats[#mock.chats].message:find("Deleted", 1, true) ~= nil,
	"and the player is told")

planner.privs.server = nil
cmd.func("Planner", "")
deferred_form()
check(planner.formspec and planner.formspec.formspec:find(";delete;", 1, true) == nil,
	"without the server privilege there is no Delete button")
planner.privs.server = true

-- A recording a session is reading cannot be deleted.
local IN_USE_ARENA = box(950, 90, 950, 957, 94, 957)
mark(watcher, IN_USE_ARENA)
watcher.pos = {x = 0, y = 0, z = 0}
local in_use = sessions.start(fixture_path, watcher)
check(in_use ~= nil, "a session opens on the fixture")
cmd.func("Planner", "")
deferred_form()
local fixture_name = fixture_path:match("([^/]+)$")
local fixture_index = chooser_index(fixture_name)
check(fixture_index ~= nil, "the watched recording is in the list")
mock.fire("register_on_player_receive_fields", planner, "recorder_replay:recordings",
	{recordings = "CHG:" .. fixture_index})
mock.fire("register_on_player_receive_fields", planner, "recorder_replay:recordings",
	{delete = "Delete"})
deferred_form()
mock.fire("register_on_player_receive_fields", planner, "recorder_replay:delete",
	{confirm = "Delete", quit = "true"})
deferred_form()
check(recorder_common.file_exists(fixture_path), "a recording being watched is not deleted")
check(planner.formspec and planner.formspec.formspec:find("Cannot delete", 1, true) ~= nil,
	"and the reason is in the list")
recorder_replay.end_session(in_use.id, "test")

-- The chooser does not offer a recording capture is still writing.
recorder = {list = function() return {{path = fixture_path}} end}
cmd.func("Planner", "")
deferred_form()
check(planner.formspec and planner.formspec.formspec:find("fixture-", 1, true) == nil,
	"a recording still being made is not offered")
local live_session, live_err = sessions.start(fixture_path, planner)
check(live_session == nil and tostring(live_err):find("still being made", 1, true) ~= nil,
	"and a session refuses to start on it")

-- replay.allow_unfinished restores the old behaviour: offer it, and let it be
-- watched up to the moment the replay started.
mock.settings["replay.allow_unfinished"] = "true"
cmd.func("Planner", "")
deferred_form()
check(planner.formspec and planner.formspec.formspec:find("fixture-", 1, true) ~= nil,
	"the setting offers recordings that are still being made")
live_session, live_err = sessions.start(fixture_path, planner)
check(live_session ~= nil, "and a session can start on one: " .. tostring(live_err))
recorder_replay.end_session(live_session.id, "test")
recorder = nil
mock.settings["replay.allow_unfinished"] = nil

print(("\n%d checks passed"):format(checks))
