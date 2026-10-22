-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- The recorded players as ghosts: one Lua entity each, wearing the game's
-- player model when there is one, driven entirely by the recording. The model
-- comes from player_api or mcl_player - their registries are public - but the
-- entity is ours, so no player-only API is called and nothing else on the
-- server treats it as a player.

local ghost = {}

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
		collisionbox = {0, 0, 0, 0, 0, 0},
		stepheight = 0,
		nametag = "",
	},
	on_activate = function(self)
		self.object:set_velocity({x = 0, y = 0, z = 0})
	end,
	on_step = function() end,
	on_punch = function() end,
	on_blast = function() end,
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
			collisionbox = {0, 0, 0, 0, 0, 0},
		})
	else
		obj:set_properties({
			visual = "upright_sprite",
			textures = {"player.png", "player_back.png"},
			visual_size = {x = 1, y = 2},
			nametag = name,
			physical = false,
			pointable = false,
			collisionbox = {0, 0, 0, 0, 0, 0},
		})
	end
	if obj.set_observers then obj:set_observers(observers) end
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
	return ok
end

-- Put a ghost where a movement sample says its player was, and pick the pose
-- the sample describes. `offset` moves the recorded position into the arena
-- the session was given. Returns false when the object is no longer usable.
---@param obj ObjectRef
---@param row table
---@param offset table?
---@return boolean
function ghost.update(obj, row, offset)
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
