-- The replay half, driven through a real recording: a session, its ghosts, the
-- clock, seeking, the remote control and what happens to a participant's things.

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
	writer:flush()
	writer:close()
end
make_fixture()

-- From here on, modules load as the replay mod.
mock.current_modname = "recorder_replay"
dofile(modpath .. "/init.lua")
local sessions = recorder_replay.sessions

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

----------------------------------------------------------------------------
print("=== starting a replay ===")
----------------------------------------------------------------------------

local watcher = mock.add_player("Watcher", {pos = {x = 0, y = 0, z = 0}})
watcher.inventory = {main = {"default:pick_stone", "", "default:torch 10"}}
watcher.meta = {}

local cmd = mock.chatcommands.replay
check(cmd ~= nil, "the /replay command is registered")
local ok, message = cmd.func("Watcher", "start fixture")
check(ok, "the command starts a replay: " .. tostring(message))
local session = sessions.for_player("Watcher")
check(session ~= nil, "the watcher is in the session")
check(session.rec.name == "fixture", "the recording is named: " .. tostring(session.rec.name))
check(near(session.rec.duration, 1), "its duration is read: " .. tostring(session.rec.duration))
check(session.T == 0 and not session.paused, "it starts at the beginning, running")
check(session.participants.Watcher, "the starter is a participant")

local alice = ghost_of("Alice")
local bob = ghost_of("Bob")
check(alice ~= nil and bob ~= nil, "both players have ghosts at the start")
check(alice and alice.pos.x == 0, "Alice's ghost is where the recording puts her")
check(bob and bob.pos.x == 5 and bob.pos.z == 5, "Bob's ghost is where he joined")
check(alice and alice.properties.mesh == "character.b3d", "the ghost wears the game's player model")
check(alice and alice.properties.textures and alice.properties.textures[1] == "character.png",
	"and the texture the recording carries")
check(alice and alice.properties.nametag == "Alice", "the ghost is named")
check(alice and alice.observers and alice.observers.Watcher == true, "the watcher sees the ghosts")
check(alice and next(alice.observers, next(alice.observers)) == nil, "and nobody else does")
check(watcher.inventory.main[1] == "recorder_replay:pause", "the controls are in the hotbar")
check(watcher.meta["recorder_replay:stash"] ~= nil and watcher.meta["recorder_replay:stash"] ~= "",
	"the watcher's things are stashed")

----------------------------------------------------------------------------
print("=== the clock ===")
----------------------------------------------------------------------------

mock.step(0.5)
check(near(session.T, 0.5), "half a second in: " .. tostring(session.T))
alice = ghost_of("Alice")
check(alice and near(alice.pos.x, 0.5), "Alice's ghost is at her tick-5 position: "
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

----------------------------------------------------------------------------
print("=== seeking ===")
----------------------------------------------------------------------------

sessions.seek(session, 0.3)
check(near(session.T, 0.3), "the clock is where it was asked")
check(ghost_of("Alice") ~= nil and near(ghost_of("Alice").pos.x, 0.3),
	"Alice is back at 0.3 s")
check(ghost_of("Bob") ~= nil, "Bob is back because he had not left yet")
sessions.seek(session, 0.6)
check(ghost_of("Bob") == nil, "and gone again past his leave")

use("seek", watcher)
check(watcher.formspec and watcher.formspec.name == "recorder_replay:seek",
	"the seek item opens a formspec")
check(watcher.formspec and watcher.formspec.formspec:find("scrollbar", 1, true) ~= nil,
	"with a slider")
mock.fire("register_on_player_receive_fields", watcher, "recorder_replay:seek", {seek = "CHG:4"})
check(near(session.T, 0.4), "the slider seeks: " .. tostring(session.T))

----------------------------------------------------------------------------
print("=== a second viewer ===")
----------------------------------------------------------------------------

local second = mock.add_player("Second", {pos = {x = 0, y = 0, z = 0}})
second.inventory = {main = {}}
local joined = sessions.join(session, second)
check(joined, "a second player joins")
alice = ghost_of("Alice")
check(alice.observers.Second == true and alice.observers.Watcher == true,
	"the ghosts are sent to both")
sessions.leave(session, second)
check(ghost_of("Alice").observers.Second == nil, "and not to one who left")

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
check(watcher.inventory.main[1] == "default:pick_stone",
	"the player's things are back after the engine's write: " .. tostring(watcher.inventory.main[1]))
check(watcher.inventory.main[3] == "default:torch 10", "all of them")
check(watcher.meta["recorder_replay:stash"] == "", "and the stash is gone")

----------------------------------------------------------------------------
print("=== a disconnect and a return ===")
----------------------------------------------------------------------------

watcher.pos = {x = 4, y = 5, z = 6}
local resumed = sessions.start("fixture", watcher)
check(resumed ~= nil, "a replay starts again")
mock.step(0.2)
mock.fire("register_on_leaveplayer", watcher, false)
check(sessions.for_player("Watcher") == nil, "a disconnect removes them from the session")
check(watcher.meta["recorder_replay:stash"] ~= "", "but keeps their things stashed")
-- The session ended with its only viewer, so the next join restores them.
mock.fire("register_on_joinplayer", watcher)
check(watcher.meta["recorder_replay:stash"] == "", "the stash is consumed on rejoin")
check(watcher.inventory.main[1] == "default:pick_stone", "and their things are back")
check(watcher.pos.x == 4 and watcher.pos.y == 5, "where they were when they started watching")

----------------------------------------------------------------------------
print("=== choosing among replays ===")
----------------------------------------------------------------------------

local starter = mock.add_player("Starter", {pos = {x = 0, y = 0, z = 0}})
starter.inventory = {main = {}}
local third = mock.add_player("Third", {pos = {x = 0, y = 0, z = 0}})
third.inventory = {main = {}}
local first = sessions.start(fixture_path, starter)
local other = sessions.start(fixture_path, third)
check(first and other, "two replays are running")

ok, message = cmd.func("Watcher", "join")
check(ok and watcher.formspec and watcher.formspec.name == "recorder_replay:sessions",
	"joining with more than one running opens the chooser")
ok, message = cmd.func("Watcher", "join " .. first.id)
check(ok and sessions.for_player("Watcher") == first, "joining by id picks that one")
cmd.func("Watcher", "leave")
recorder_replay.end_session(other.id, "test")
check(sessions.for_player("Third") == nil, "ending a session restores its participants")
recorder_replay.end_session(first.id, "test")

print(("\n%d checks passed"):format(checks))
