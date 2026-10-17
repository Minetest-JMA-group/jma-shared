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
local function make_fixture()
	local writer = dbmanager.new(sqlite)
	local ok, err = writer:open(fixture_path)
	assert(ok, err)
	writer:set_meta("recorder.name", "fixture")
	local alice = writer:player_id("Alice")
	local bob = writer:player_id("Bob")

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
	-- Bob leaves at half a second.
	writer:add_event({writer:next_id(), 5, 0.5, "leave", bob, nil, 5, 0, 5,
		nil, nil, nil, nil})
	-- At 0.8 s Alice digs the floor out from under herself, and at 0.9 s the
	-- glass is replaced by dirt with a different param2.
	writer:add_event({writer:next_id(), 8, 0.8, "node_change", alice, nil, 0, 0, 0,
		"air", 0, nil, '{"old_node":"default:stone","old_param2":0}'})
	writer:add_event({writer:next_id(), 9, 0.9, "node_change", alice, nil, 2, 1, 2,
		"default:dirt", 3, nil, '{"old_node":"default:glass","old_param2":7}'})
	writer:flush()
	writer:close()
end
make_fixture()

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

local function near(a, b)
	return type(a) == "number" and math.abs(a - b) < 1e-9
end

local function ghost_of(name)
	for _, obj in pairs(mock.entities) do
		if obj.properties and obj.properties.nametag == name then return obj end
	end
	return nil
end

local function item(kind)
	return mock.items["recorder_replay:" .. kind]
end

local function use(kind, player)
	local def = item(kind)
	return def.on_use(ItemStack("recorder_replay:" .. kind), player)
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
watcher.inventory = {main = {"default:pick_stone", "", "default:torch 10"}}
watcher.meta = {}

mark(watcher, WATCHER_ARENA)
watcher.pos = {x = 0, y = 0, z = 0}
ok, message = cmd.func("Watcher", "")
check(ok, "a bare /replay opens the recording chooser")
check(watcher.formspec and watcher.formspec.name == "recorder_replay:recordings",
	"with the recording formspec")
check(watcher.formspec and watcher.formspec.formspec:find("fixture-", 1, true) ~= nil,
	"the recordings in the directory are listed")

-- A client can submit any form name it likes; the privilege is what makes the
-- submission trustworthy.
watcher.privs.replay = nil
mock.fire("register_on_player_receive_fields", watcher, "recorder_replay:recordings",
	{watch = "Watch"})
check(sessions.for_player("Watcher") == nil,
	"a submission without the replay privilege starts nothing")
watcher.privs.replay = true

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
check(watcher.formspec and watcher.formspec.name == "recorder_replay:recordings",
	"the chooser stays open")
check(watcher.formspec and watcher.formspec.formspec:find("no snapshot", 1, true) ~= nil,
	"with the reason in it")
check(watcher.formspec and watcher.formspec.formspec:find("#FF5555", 1, true) ~= nil,
	"as red text")
check(#mock.chats == chats_before, "and not in chat")

mock.fire("register_on_player_receive_fields", watcher, "recorder_replay:recordings",
	{recordings = "CHG:1"})
mock.fire("register_on_player_receive_fields", watcher, "recorder_replay:recordings",
	{watch = "Watch"})
check(sessions.for_player("Watcher") ~= nil, "the Watch button starts the selected recording")

local session = sessions.for_player("Watcher")
check(session ~= nil, "the watcher is in the session")
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
mock.step(0.25)
check(near(session.T, 0.95), "playback crosses the change: " .. tostring(session.T))
check(mock.get_node({x = 101, y = 11, z = 101}).name == "air",
	"a node change crossed by the clock is applied")
check(mock.get_node({x = 103, y = 12, z = 103}).name == "default:dirt",
	"the other change as well")
check(#mock.vms == vms + 1, "the crossed changes are written once for the step")
check(mock.liquids_updated == false, "still without starting liquid flow")

----------------------------------------------------------------------------
print("=== a second viewer ===")
----------------------------------------------------------------------------

local second = add_player("Second", {pos = {x = 0, y = 0, z = 0}})
second.inventory = {main = {}}
local joined = sessions.join(session, second)
check(joined, "a second player joins")
check(near(second.pos.x, 103.5) and second.pos.y == 15,
	"and is put on the viewing platform: " .. core.pos_to_string(second.pos))
alice = ghost_of("Alice")
check(alice.observers.Second == true and alice.observers.Watcher == true,
	"the ghosts are sent to both")
sessions.leave(session, second)
check(ghost_of("Alice").observers.Second == nil, "and not to one who left")
check(second.pos.x == 0 and second.pos.y == 0, "the viewer is back where they were")
check(mock.get_node({x = 100, y = 10, z = 100}).name == "recorder_replay:barrier",
	"one viewer leaving does not touch the arena")

----------------------------------------------------------------------------
print("=== leaving and ending ===")
----------------------------------------------------------------------------

use("leave", watcher)
check(sessions.for_player("Watcher") ~= nil, "the leave item asks to leave")
-- The engine writes the used stack back into its slot after on_use returns;
-- the restore has to win over that write.
watcher.inventory.main[1] = "recorder_replay:leave"
mock.step(0.1)
check(sessions.for_player("Watcher") == nil, "the next step leaves the replay")
check(next(mock.entities) == nil, "no ghosts are left")
local empty, offender = box_is_air(WATCHER_ARENA)
check(empty, "the whole arena is air again: " .. tostring(offender))
check(flag_count() == 0, "and the boot flag is gone")
check(watcher.inventory.main[1] == "default:pick_stone",
	"the player's things are back after the engine's write: " .. tostring(watcher.inventory.main[1]))
check(watcher.inventory.main[3] == "default:torch 10", "all of them")
check(watcher.meta["recorder_replay:stash"] == "", "and the stash is gone")
check(near(watcher.pos.x, 0) and near(watcher.pos.y, 0), "the watcher is back where they started")

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
mock.step(0.2)
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

print(("\n%d checks passed"):format(checks))
