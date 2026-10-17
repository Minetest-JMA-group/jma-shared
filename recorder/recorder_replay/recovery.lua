-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- What a participant had before they started watching, and how they get it
-- back. The stash lives in the player's own metadata, so it travels with the
-- player: a disconnect, a crash or a restart leaves a record that the next join
-- can act on. On a game whose world is not persistent the game owns inventories
-- and the return to the match, so nothing is stashed; its hooks put the player
-- back instead.

local recovery = {}

local controls -- the controls module, handed in by init
local arena    -- the arena module, for the viewing platform

---@param controls_module table
---@param arena_module table
function recovery.init(controls_module, arena_module)
	controls = controls_module
	arena = arena_module
end

local STASH = "recorder_replay:stash"

local function itemstrings(list)
	local items = {}
	for i, stack in ipairs(list or {}) do
		items[i] = stack:to_string()
	end
	return items
end

---@param player ObjectRef
---@param session table
---@param already_stashed boolean?  -- the player is coming back to a session
function recovery.enter(player, session, already_stashed)
	if recorder_common.game_hooks.world_persistent and not already_stashed then
		local inv = player:get_inventory()
		if inv then
			player:get_meta():set_string(STASH, core.serialize({
				session = session.id,
				pos = player:get_pos(),
				main = itemstrings(inv:get_list("main")),
			}))
		end
	end
	controls.fill(player)
	-- The stash above holds the position from before this teleport, which is
	-- where the player goes back to when they leave.
	if session.arena then
		player:set_pos(arena.viewing_position(session.arena))
	end
	local hook = recorder_common.game_hooks.on_enter
	if hook then pcall(hook, player, session) end
end

-- Put a player back where they were and give them their things back.
---@param player ObjectRef
---@param stash table
function recovery.restore(player, stash)
	if stash.pos then
		player:set_pos(stash.pos)
	end
	if stash.main then
		local inv = player:get_inventory()
		if inv then
			local list = {}
			for i, item in ipairs(stash.main) do
				list[i] = ItemStack(item)
			end
			inv:set_list("main", list)
		end
	end
end

---@param player ObjectRef
---@param session table
function recovery.leave(player, session)
	if recorder_common.game_hooks.world_persistent then
		local meta = player:get_meta()
		local raw = meta:get_string(STASH)
		if raw ~= "" then
			meta:set_string(STASH, "")
			local ok, stash = pcall(core.deserialize, raw)
			if ok and type(stash) == "table" then
				recovery.restore(player, stash)
			end
		end
	end
	local hook = recorder_common.game_hooks.on_leave
	if hook then pcall(hook, player, session) end
end

-- The stash a player carries, if any, for the join handler to act on.
---@param player ObjectRef
---@return table|nil
function recovery.pending(player)
	local raw = player:get_meta():get_string(STASH)
	if raw == "" then return nil end
	local ok, stash = pcall(core.deserialize, raw)
	if not ok or type(stash) ~= "table" then
		player:get_meta():set_string(STASH, "")
		return nil
	end
	return stash
end

---@param player ObjectRef
function recovery.clear(player)
	player:get_meta():set_string(STASH, "")
end

return recovery
