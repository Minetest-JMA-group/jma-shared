-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

local settings = recorder_common.settings

-- Recorded players as Lua entities using player_api/mcl_player models, with
-- sprite fallback. Ghosts are entities, so player-only APIs do not apply.

local ghost = {}

-- Entity lighting samples the collision-box centre. A body-sized box avoids
-- sampling dark feet/slabs; physical=false prevents collisions.
local PLAYER_BOX = {-0.3, 0.0, -0.3, 0.3, 1.8, 0.3}

-- Held items require a separate wielditem entity: mesh entities cannot render
-- wield_item, and set_wielded_item is player-only. Attach to player_api's arm
-- or mcl_player's Wield_Item bone, using family defaults or world overrides.
local function vector_setting(config, name)
	local raw = config[name]
	if not raw or raw == "" then return nil end
	local x, y, z = raw:match("^([^,]+),([^,]+),([^,]+)$")
	return {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
end

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

-- mcl_player hand poses use model units and radians. Bow poses require draw
-- state absent from wield events, so they are omitted.
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

-- Resolve after mods register their models; the registry also identifies the rig.
local function resolve_model(config)
	local model_name, model_def, model_family
	local wanted = config["replay.model"]
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

-- Freeze the model and appearance settings for each session.
function ghost.configuration()
	local config = settings:snapshot("replay.")
	config.model_name, config.model_def, config.model_family = resolve_model(config)
	return config
end

core.register_entity("recorder_replay:ghost", {
	-- Sessions do not survive restarts; neither should their entities.
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
		-- The engine only detaches children on removal; remove the held item too.
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

-- Attached wielditem entities follow the hand animation without an on_step.
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
function ghost.spawn(name, pos, textures, observers, config)
	config = config or ghost.configuration()
	local obj = core.add_entity(pos, "recorder_replay:ghost")
	if not obj then return nil end
	local model, def, family = config.model_name, config.model_def, config.model_family
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
		-- Keep observers for held items created later.
		ent.observers = observers
		ent.has_model = (model and def) ~= nil
		ent.model_family = family
		ent.model_def = def
		ent.config = config
	end
	return obj
end

---@param obj ObjectRef
---@param observers table
---@return boolean  -- false when the object has been invalidated in the meantime
function ghost.set_observers(obj, observers)
	if not obj or not obj:is_valid() then return false end
	-- Unloaded mapblocks or external clear-objects calls may invalidate ghosts.
	obj:set_observers(observers)
	-- A missing held item is recreated by wield(); it does not invalidate the ghost.
	local ent = obj:get_luaentity()
	if ent then
		ent.observers = observers
		local child = ent.wield_object
		if child and child:get_pos() then child:set_observers(observers) end
	end
	return true
end

-- Update the attached held item; an empty itemstring clears it.
-- Return false for invalid ghosts or disabled held items.
---@param obj ObjectRef
---@param itemstring string?
---@return boolean
function ghost.wield(obj, itemstring)
	if not obj or not obj:is_valid() then return false end
	local ent = obj:get_luaentity()
	if not ent then return false end
	-- A sprite fallback has no hand bone to attach to.
	if not ent.has_model then return true end
	local config = ent.config
	if config["replay.wield_item"] ~= "true" then return false end
	local defaults = WIELD_DEFAULTS[ent.model_family] or WIELD_DEFAULTS.player_api
	local bone = (config["replay.wield_bone"] ~= "" and config["replay.wield_bone"]) or defaults.bone
	local position = vector_setting(config, "replay.wield_pos") or defaults.position
	local rotation = vector_setting(config, "replay.wield_rot") or defaults.rotation
	local scale = vector_setting(config, "replay.wield_scale") or defaults.scale
	local item = itemstring or ""
	local child = ent.wield_object
	-- Replace a held item removed by the engine.
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

-- Remove both objects, tolerating engine-invalidated references.
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

-- Apply recorded frames, speed, blend and loop. Return false for invalid
-- objects or animation data.
---@param obj ObjectRef
---@param data table  -- {frames = {x =, y =}, speed =, blend =, loop =}
---@return boolean
function ghost.animate(obj, data)
	if not obj or not obj:is_valid() then return false end
	if type(data) ~= "table" or type(data.frames) ~= "table" then return false end
	obj:set_animation(data.frames, data.speed, data.blend, data.loop)
	return true
end

-- Apply movement in arena coordinates. keep_pose preserves recorded animation;
-- otherwise infer stand/walk/mine without restarting an unchanged animation.
-- Return false for invalid objects.
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
	local ent = obj:get_luaentity()
	local def = ent and ent.model_def
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
