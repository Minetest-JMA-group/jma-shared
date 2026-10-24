-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- The recorded players as ghosts: one Lua entity each, wearing the game's
-- player model when there is one, driven entirely by the recording. The model
-- comes from player_api or mcl_player - their registries are public - but the
-- entity is ours, so no player-only API is called and nothing else on the
-- server treats it as a player.

local ghost = {}

-- The client lights an entity from the light at its bounding-box centre. With
-- a zero box that sample is the entity's feet - on a slab, a stair or a block
-- boundary that can be a solid, unlit node, and the whole model turns black
-- while the world around it is bright. A player-sized box samples the body
-- instead. The ghost is physical=false, so the box never collides with
-- anything; it only gives the renderer the right shape to light.
local PLAYER_BOX = {-0.3, 0.0, -0.3, 0.3, 1.8, 0.3}

-- Held items. `set_wielded_item` is player-only (the base ServerActiveObject
-- returns false, only PlayerSAO overrides it), and an object property
-- `wield_item` is only rendered for the `wielditem` visual, not for a mesh.
-- The item is therefore a separate `wielditem` entity attached to the model's
-- hand bone; it follows the pose animations with the arm.
--
-- The two model registries carry the item differently: the player_api rig
-- puts it on the arm, while the mcl_player rig has a Wield_Item bone that the
-- game poses at the hand. Each family has its own defaults; a setting
-- overrides them for either.
local function vector_setting(name, default)
	local raw = core.settings:get(name)
	if not raw then return default end
	local x, y, z = raw:match("^%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)%s*$")
	if not x then return default end
	return {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
end

local WIELD_ENABLED = core.settings:get_bool("replay.wield_item", true)
local WIELD_BONE = core.settings:get("replay.wield_bone")
if not WIELD_BONE or WIELD_BONE == "" then WIELD_BONE = nil end
local WIELD_POSITION = vector_setting("replay.wield_pos", nil)
local WIELD_ROTATION = vector_setting("replay.wield_rot", nil)
local WIELD_SCALE = vector_setting("replay.wield_scale", nil)

local WIELD_DEFAULTS = {
	player_api = {
		bone = "Arm_Right",
		position = {x = 0, y = 5.5, z = 3},
		rotation = {x = -90, y = 225, z = 90},
		scale = {x = 0.3, y = 0.3, z = 0.25},
	},
	mcl_player = {
		bone = "Wield_Item",
		-- The bone itself is at the hand; the attachment has no offset of its
		-- own.
		position = {x = 0, y = 0, z = 0},
		rotation = {x = 0, y = 0, z = 0},
		scale = {x = 0.21, y = 0.21, z = 0.21},
	},
}

-- The mcl_player rig's Wield_Item bone is posed for what is held: these are
-- the rig's own values (model units, radians). The bow poses are left out
-- because their arm pose depends on drawing, which a held-item event does not
-- say.
local MCL_POSES = {
	default = {position = {x = 0, y = 5.3, z = 2}, rotation = {x = 1.57, y = 0, z = 0}},
	tool = {position = {x = 0, y = 4.7, z = 3.1}, rotation = {x = -1.57, y = 3.93, z = 1.57}},
	no_image = {position = {x = 0, y = 6, z = 2}, rotation = {x = 3.1415, y = -0.785, z = 0}},
}

local function mcl_pose(item)
	local name = item:match("^(%S+)") or item
	local def = core.registered_items[name]
	if def and def._mcl_toollike_wield then return "tool", MCL_POSES.tool end
	if def and def.inventory_image == "" then return "no_image", MCL_POSES.no_image end
	return "default", MCL_POSES.default
end

local resolved = false
local model_name, model_def, model_family

-- The game's player model, if it has one. Looked up lazily: a game's armour or
-- skin mods may register their model after this mod has loaded. The registry
-- it came from also says how that rig carries a held item.
local function resolve_model()
	if resolved then return model_name, model_def, model_family end
	resolved = true
	local wanted = core.settings:get("replay.model")
	local registry
	if player_api and player_api.registered_models then
		registry = player_api.registered_models
		model_family = "player_api"
	elseif mcl_player and mcl_player.registered_player_models then
		registry = mcl_player.registered_player_models
		model_family = "mcl_player"
	end
	if not registry then return nil end
	if wanted and registry[wanted] then
		model_name = wanted
	else
		local names = {}
		for name in pairs(registry) do names[#names + 1] = name end
		table.sort(names)
		model_name = registry["character.b3d"] and "character.b3d" or nil
		if not model_name then
			for _, name in ipairs(names) do
				if name:find("character", 1, true) then model_name = name break end
			end
		end
		model_name = model_name or names[1]
	end
	model_def = model_name and registry[model_name]
	return model_name, model_def, model_family
end

core.register_entity("recorder_replay:ghost", {
	-- A ghost belongs to a session, and sessions do not survive a restart; an
	-- entity left on disk would be an orphan nobody could remove.
	static_save = false,
	initial_properties = {
		visual = "mesh",
		mesh = "character.b3d",
		textures = {"character.png"},
		visual_size = {x = 1, y = 1},
		physical = false,
		pointable = false,
		collisionbox = PLAYER_BOX,
		stepheight = 0,
		nametag = "",
	},
	on_activate = function(self)
		self.object:set_velocity({x = 0, y = 0, z = 0})
	end,
	on_deactivate = function(self)
		-- The item is attached to this object, but it is a separate engine
		-- object; it must not outlive its ghost if the engine removes us on its
		-- own (an unloaded mapblock, a game clearing objects). The engine only
		-- detaches children.
		local child = self.wield_object
		if child then
			self.wield_object = nil
			if child:get_pos() then child:remove() end
		end
	end,
	on_step = function() end,
	on_punch = function() end,
	on_blast = function() end,
})

-- The item a ghost wears. The `wielditem` visual is the only one that draws an
-- item; set_attach() puts it on the ghost's hand bone and keeps it there as
-- the arm animates. It has no on_step: it is attached and still, so stepping
-- it every server tick would only call into Lua for nothing.
core.register_entity("recorder_replay:wield_item", {
	static_save = false,
	initial_properties = {
		visual = "wielditem",
		wield_item = "",
		textures = {},
		physical = false,
		pointable = false,
		nametag = "",
	},
})

-- Spawn a ghost for a recorded player. `observers` is the set of players the
-- entity is sent to; nobody else sees it.
---@param name string
---@param pos table
---@param textures table?  -- the recorded textures, when the recording has them
---@param observers table
---@return ObjectRef|nil
function ghost.spawn(name, pos, textures, observers)
	local obj = core.add_entity(pos, "recorder_replay:ghost")
	if not obj then return nil end
	local model, def, family = resolve_model()
	if model and def then
		obj:set_properties({
			visual = "mesh",
			mesh = model,
			textures = textures or def.textures,
			visual_size = def.visual_size or {x = 1, y = 1},
			stepheight = def.stepheight or 0,
			nametag = name,
			physical = false,
			pointable = false,
			collisionbox = PLAYER_BOX,
		})
	else
		obj:set_properties({
			visual = "upright_sprite",
			textures = {"player.png", "player_back.png"},
			visual_size = {x = 1, y = 2},
			nametag = name,
			physical = false,
			pointable = false,
			collisionbox = PLAYER_BOX,
		})
	end
	obj:set_observers(observers)
	local ent = obj:get_luaentity()
	if ent then
		-- The item entity is separate from the ghost and needs the same
		-- observers; the ghost remembers them for an item it creates later.
		ent.observers = observers
		ent.has_model = (model and def) ~= nil
		ent.model_family = family
	end
	return obj
end

---@param obj ObjectRef
---@param observers table
---@return boolean  -- false when the object has been invalidated in the meantime
function ghost.set_observers(obj, observers)
	if not obj or not obj:is_valid() then return false end
	-- An entity can vanish from under a session: its mapblocks may be unloaded
	-- once the viewers leave (the arena can be far from where they go back to),
	-- or the game may clear objects. The session is told instead and drops it.
	obj:set_observers(observers)
	-- The attached item is a separate object. A dropped one is not a reason to
	-- drop the ghost; the ghost's own on_deactivate handles the common case and
	-- a later wield() sees the stale ref and makes a new one.
	local ent = obj:get_luaentity()
	if ent then
		ent.observers = observers
		local child = ent.wield_object
		if child and child:get_pos() then child:set_observers(observers) end
	end
	return true
end

-- Show what a recorded player was holding: a `wielditem` entity attached to
-- the model's hand bone. An empty itemstring takes it away. Returns false
-- when the object is no longer usable or the item is disabled.
---@param obj ObjectRef
---@param itemstring string?
---@return boolean
function ghost.wield(obj, itemstring)
	if not obj or not WIELD_ENABLED or not obj:is_valid() then return false end
	local ent = obj:get_luaentity()
	if not ent then return false end
	-- A sprite fallback has no hand bone to attach to.
	if not ent.has_model then return true end
	local defaults = WIELD_DEFAULTS[ent.model_family] or WIELD_DEFAULTS.player_api
	local bone = WIELD_BONE or defaults.bone
	local position = WIELD_POSITION or defaults.position
	local rotation = WIELD_ROTATION or defaults.rotation
	local scale = WIELD_SCALE or defaults.scale
	local item = itemstring or ""
	local child = ent.wield_object
	-- get_pos() answers nothing for an object the engine has dropped; that
	-- child is replaced below.
	if child and not child:get_pos() then child = nil end
	if item == "" then
		if child then child:remove() end
		ent.wield_object = nil
		return true
	end
	-- The mcl_player rig expects the game to put its Wield_Item bone at the
	-- hand; the attachment itself then has no offset.
	if ent.model_family == "mcl_player" and bone == "Wield_Item" and obj.set_bone_override then
		local pose_name, pose = mcl_pose(item)
		if ent.wield_pose ~= pose_name then
			obj:set_bone_override("Wield_Item", {
				position = {vec = pose.position, absolute = true},
				rotation = {vec = pose.rotation, absolute = true},
			})
			ent.wield_pose = pose_name
		end
	end
	if not child then
		child = core.add_entity(obj:get_pos(), "recorder_replay:wield_item")
		if not child then return false end
		child:set_attach(obj, bone, position, rotation)
		child:set_observers(ent.observers)
		ent.wield_object = child
	end
	child:set_properties({
		wield_item = item,
		-- The pre-wield_item client rendered an item from this field; it
		-- takes a plain item name, not the stack string.
		textures = {item:match("^(%S+)") or item},
		visual_size = scale,
	})
	return true
end

-- Remove a ghost and the item attached to it. The engine may already have
-- removed either of them; both removals therefore tolerate a stale ref.
---@param obj ObjectRef
function ghost.remove(obj)
	if not obj or not obj:is_valid() then return end
	local ent = obj:get_luaentity()
	if ent and ent.wield_object then
		local child = ent.wield_object
		ent.wield_object = nil
		if child:get_pos() then child:remove() end
	end
	obj:remove()
end

-- Put a recorded animation on a ghost: the engine's four animation values,
-- taken from the recording rather than guessed from the movement sample. A
-- pose a game sets itself (lying down while dead) has no other description.
-- Returns false when the object is no longer usable or the data is not an
-- animation.
---@param obj ObjectRef
---@param data table  -- {frames = {x =, y =}, speed =, blend =, loop =}
---@return boolean
function ghost.animate(obj, data)
	if not obj or not obj:is_valid() then return false end
	if type(data) ~= "table" or type(data.frames) ~= "table" then return false end
	obj:set_animation(data.frames, data.speed, data.blend, data.loop)
	return true
end

-- Put a ghost where a movement sample says its player was, and pick the pose
-- the sample describes. `offset` moves the recorded position into the arena
-- the session was given. `keep_pose` says the recording itself has a pose
-- event for this player: the speed-and-dig guess must not overwrite it, and
-- re-setting the same animation on every sample would restart it anyway.
-- Returns false when the object is no longer usable.
---@param obj ObjectRef
---@param row table
---@param offset table?
---@param keep_pose boolean?
---@return boolean
function ghost.update(obj, row, offset, keep_pose)
	if not obj or not obj:is_valid() then return false end
	local pos = row.pos
	if offset then
		pos = {x = pos.x + offset.x, y = pos.y + offset.y, z = pos.z + offset.z}
	end
	obj:move_to(pos, true)
	obj:set_yaw(row.yaw)
	local _, def = resolve_model()
	if not def then return true end
	if obj.set_bone_override then
		-- The head bone follows the recorded pitch (radians, relative to the
		-- animated pose).
		obj:set_bone_override("Head", {
			rotation = {vec = {x = row.pitch, y = 0, z = 0}},
		})
	end
	if keep_pose then return true end
	local digging = math.floor((row.controls or 0) / 128) % 2 == 1
	local animation = "stand"
	if row.speed > 0.1 then
		animation = digging and "walk_mine" or "walk"
	elseif digging then
		animation = "mine"
	end
	local frames = def.animations and def.animations[animation]
	if frames then
		obj:set_animation(frames, def.animation_speed or 30, 0, true)
	end
	return true
end

return ghost
