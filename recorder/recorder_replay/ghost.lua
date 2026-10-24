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
-- hand bone; it follows the pose animations with the arm. The defaults below
-- are the default player model's (character.b3d); a game whose model has
-- different bones can tune them.
local function setting_on(name, default)
	local raw = core.settings:get(name)
	if raw == nil or raw == "" then return default end
	return core.settings:get_bool(name)
end

local function vector_setting(name, default)
	local raw = core.settings:get(name)
	if not raw then return default end
	local x, y, z = raw:match("^%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)%s*$")
	if not x then return default end
	return {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
end

local WIELD_ENABLED = setting_on("replay.wield_item", true)
local WIELD_BONE = core.settings:get("replay.wield_bone")
if not WIELD_BONE or WIELD_BONE == "" then WIELD_BONE = "Arm_Right" end
local WIELD_POSITION = vector_setting("replay.wield_pos", {x = 0, y = 5.5, z = 3})
local WIELD_ROTATION = vector_setting("replay.wield_rot", {x = -90, y = 225, z = 90})
local WIELD_SCALE = vector_setting("replay.wield_scale", {x = 0.3, y = 0.3, z = 0.25})

local resolved = false
local model_name, model_def

-- The game's player model, if it has one. Looked up lazily: a game's armour or
-- skin mods may register their model after this mod has loaded.
local function resolve_model()
	if resolved then return model_name, model_def end
	resolved = true
	local wanted = core.settings:get("replay.model")
	local registry
	if player_api and player_api.registered_models then
		registry = player_api.registered_models
	elseif mcl_player and mcl_player.registered_player_models then
		registry = mcl_player.registered_player_models
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
	return model_name, model_def
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
		-- own (an unloaded mapblock, a game clearing objects).
		if self.wield_object then
			pcall(function() self.wield_object:remove() end)
			self.wield_object = nil
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
		visual_size = WIELD_SCALE,
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
	local model, def = resolve_model()
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
	if obj.set_observers then obj:set_observers(observers) end
	local ent = obj:get_luaentity()
	if ent then
		-- The item entity is separate from the ghost and needs the same
		-- observers; the ghost remembers them for an item it creates later.
		ent.observers = observers
		ent.has_model = (model and def) ~= nil
	end
	return obj
end

---@param obj ObjectRef
---@param observers table
---@return boolean  -- false when the object has been invalidated in the meantime
function ghost.set_observers(obj, observers)
	if not obj then return false end
	-- An entity can vanish from under a session: its mapblocks may be unloaded
	-- once the viewers leave (the arena can be far from where they go back to),
	-- or the game may clear objects. Every call on a removed ObjectRef raises,
	-- so the session is told instead and drops the ghost.
	local ok = pcall(function()
		if obj.set_observers then obj:set_observers(observers) end
	end)
	if not ok then return false end
	-- The attached item is a separate object. If it has gone stale that is not
	-- a reason to drop the ghost; its own on_deactivate handles the common case
	-- and a later wield() sees the stale ref and makes a new one.
	local ent_ok, ent = pcall(function() return obj:get_luaentity() end)
	if ent_ok and ent then
		ent.observers = observers
		if ent.wield_object then
			pcall(function() ent.wield_object:set_observers(observers) end)
		end
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
	if not obj or not WIELD_ENABLED then return false end
	local ok, usable = pcall(function()
		local ent = obj:get_luaentity()
		if not ent then return false end
		-- A sprite fallback has no hand bone to attach to.
		if not ent.has_model then return true end
		local item = itemstring or ""
		local child = ent.wield_object
		local child_alive = false
		if child then
			-- get_pos() is a getter: on a dropped object it answers nothing
			-- rather than raising, so the value decides, not just the pcall.
			local child_ok, child_pos = pcall(function() return child:get_pos() end)
			child_alive = child_ok and child_pos ~= nil
		end
		if item == "" then
			if child_alive then child:remove() end
			ent.wield_object = nil
			return true
		end
		if not child_alive then
			child = core.add_entity(obj:get_pos(), "recorder_replay:wield_item")
			if not child then return false end
			child:set_attach(obj, WIELD_BONE, WIELD_POSITION, WIELD_ROTATION)
			if ent.observers and child.set_observers then
				child:set_observers(ent.observers)
			end
			ent.wield_object = child
		end
		child:set_properties({
			wield_item = item,
			-- The pre-wield_item client rendered an item from this field; it
			-- takes a plain item name, not the stack string.
			textures = {item:match("^(%S+)") or item},
			visual_size = WIELD_SCALE,
		})
		return true
	end)
	-- A getter answers nothing for an object the engine has dropped; that is
	-- not a success even when nothing raised.
	return ok and usable ~= false
end

-- Remove a ghost and the item attached to it. The engine may already have
-- removed either of them; both removals therefore tolerate a stale ref.
---@param obj ObjectRef
function ghost.remove(obj)
	if not obj then return end
	pcall(function()
		local ent = obj:get_luaentity()
		if ent and ent.wield_object then
			pcall(function() ent.wield_object:remove() end)
			ent.wield_object = nil
		end
		obj:remove()
	end)
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
	if not obj or type(data) ~= "table" or type(data.frames) ~= "table" then
		return false
	end
	local ok = pcall(obj.set_animation, obj, data.frames, data.speed, data.blend, data.loop)
	return ok
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
	local ok = pcall(function()
		local pos = row.pos
		if offset then
			pos = {x = pos.x + offset.x, y = pos.y + offset.y, z = pos.z + offset.z}
		end
		obj:move_to(pos, true)
		obj:set_yaw(row.yaw)
		local _, def = resolve_model()
		if not def then return end
		if obj.set_bone_override then
			-- The head bone follows the recorded pitch (radians, relative to the
			-- animated pose).
			obj:set_bone_override("Head", {
				rotation = {vec = {x = row.pitch, y = 0, z = 0}},
			})
		end
		if keep_pose then return end
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
	end)
	return ok
end

return ghost
