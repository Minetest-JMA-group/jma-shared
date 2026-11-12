-- The held item on an mcl_player rig: the Wield_Item bone, the pose the rig
-- expects for the hand, and the tool pose. No player_api registry is present,
-- so the ghost takes the mcl_player path.

local function script_dir()
	local src = debug.getinfo(1, "S").source:sub(2)  -- strip the leading "@"
	if src:sub(1, 1) ~= "/" then
		src = (os.getenv("PWD") or ".") .. "/" .. src
	end
	return src:match("^(.*)/[^/]+$")
end

local testdir = script_dir()
local modpath = testdir:gsub("/tests$", "")
local commonpath = modpath:gsub("/recorder_replay$", "/recorder_common")

local mocklib = dofile(commonpath .. "/tests/mocklib.lua")
local mock = mocklib.new({modpath = modpath})
core = mock.core
recorder_common = {settings = dofile(commonpath .. "/settings.lua")}

mcl_player = {
	registered_player_models = {
		["mcl_armor_character.b3d"] = {
			animation_speed = 30,
			textures = {"character.png"},
			visual_size = {x = 1, y = 1},
			animations = {
				stand = {x = 0, y = 79},
				walk = {x = 168, y = 187},
			},
		},
	},
}

local ghost = dofile(modpath .. "/ghost.lua")

local checks = 0
local function check(condition, message)
	checks = checks + 1
	if not condition then error("FAILED: " .. message, 2) end
	print("  ok - " .. message)
end

local obj = ghost.spawn("Test", {x = 0, y = 0, z = 0}, nil, {Watcher = true})
check(obj ~= nil, "a ghost spawns on an mcl model")
check(obj and obj.properties.mesh == "mcl_armor_character.b3d", "with the registered model")

ghost.wield(obj, "mcl_core:stone")
local child = obj.wield_object
check(child and child.properties.wield_item == "mcl_core:stone", "the ghost holds the item")
check(child and child.attached and child.attached.bone == "Wield_Item",
	"attached to the mcl Wield_Item bone")
check(child and child.attached.position.x == 0 and child.attached.position.y == 0,
	"with the bone doing the placement")
check(child and child.properties.visual_size.x == 0.21, "at mcl hand size")
local pose = obj.bones and obj.bones.Wield_Item
check(pose and pose.position.vec.y == 5.3 and pose.position.absolute == true,
	"the Wield_Item bone is posed at the hand")
check(pose and pose.rotation.vec.x == 1.57 and pose.rotation.absolute == true,
	"with the rig's hand rotation")

-- A tool gets the rig's tool pose.
core.register_craftitem("mcl_tools:pick_iron", {_mcl_toollike_wield = true})
ghost.wield(obj, "mcl_tools:pick_iron")
pose = obj.bones and obj.bones.Wield_Item
check(pose and pose.position.vec.y == 4.7, "a tool gets the rig's tool pose")

-- And a plain item puts it back.
ghost.wield(obj, "mcl_core:stone")
pose = obj.bones and obj.bones.Wield_Item
check(pose and pose.position.vec.y == 5.3, "a plain item gets the default pose again")

ghost.wield(obj, "")
check(obj.wield_object == nil, "an empty hand takes the item away")

-- New sessions take new appearance settings; existing sessions, including
-- ghosts created after a seek, keep the settings they started with.
local previous = ghost.configuration()
assert(recorder_common.settings:set("replay.wield_pos", "1,2,3"))
assert(recorder_common.settings:set("replay.wield_scale", "0.5,0.5,0.5"))
local next_config = ghost.configuration()
local newer = ghost.spawn("New", {x = 0, y = 0, z = 0}, nil, {Watcher = true}, next_config)
ghost.wield(newer, "mcl_core:stone")
check(newer.wield_object.attached.position.y == 2, "new sessions use changed wield offsets")
check(newer.wield_object.properties.visual_size.x == 0.5, "new sessions use changed wield scale")
local recreated = ghost.spawn("Old", {x = 0, y = 0, z = 0}, nil, {Watcher = true}, previous)
ghost.wield(recreated, "mcl_core:stone")
check(recreated.wield_object.attached.position.y == 0, "recreated ghosts retain their session offsets")
check(recreated.wield_object.properties.visual_size.x == 0.21, "recreated ghosts retain their session scale")
assert(recorder_common.settings:set("replay.wield_item", "false"))
local disabled = ghost.spawn("Disabled", {x = 0, y = 0, z = 0}, nil, {Watcher = true})
ghost.wield(disabled, "mcl_core:stone")
check(disabled.wield_object == nil, "new sessions can disable held items")
ghost.wield(recreated, "mcl_tools:pick_iron")
check(recreated.wield_object ~= nil, "existing sessions retain enabled held items")

print(("%d checks passed"):format(checks))
