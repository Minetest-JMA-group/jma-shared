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

-- Game hooks are other mods' code. A failure is logged rather than allowed to
-- abort the replay; the game still gets its chance on the other hooks.
local function call_hook(name, ...)
	local hook = recorder_common.game_hooks[name]
	if not hook then return end
	local ok, err = pcall(hook, ...)
	if not ok then
		core.log("error", "[replay] game hook " .. name .. " failed: " .. tostring(err))
	end
end

local function itemstrings(list)
	local items = {}
	for i, stack in ipairs(list or {}) do
		items[i] = stack:to_string()
	end
	return items
end

-- Give one participant the daylight of the mode the session is showing: the
-- recording's time of day when the light is recorded, and whatever override
-- the game had (or the server's own cycle) when it is live. The override the
-- participant arrived with is remembered the first time, for leaving.
---@param player ObjectRef
---@param session table
function recovery.apply_day_night(player, session)
	if not session.rec.timeofday or not core.time_to_day_night_ratio then return end
	local name = player:get_player_name()
	session.day_night = session.day_night or {}
	local previous = session.day_night[name]
	if not previous then
		previous = {ratio = player:get_day_night_ratio()}
		session.day_night[name] = previous
	end
	if session.light == "recorded" then
		player:override_day_night_ratio(core.time_to_day_night_ratio(session.rec.timeofday))
	else
		player:override_day_night_ratio(previous.ratio)
	end
end

---@param player ObjectRef
---@param session table
---@param already_stashed boolean?  -- the player is coming back to a session
function recovery.enter(player, session, already_stashed)
	-- The game still has the player where it left them, with their own
	-- inventory: this is where it takes them out of a running match. The
	-- stash, the controls and the move into the arena follow immediately.
	call_hook("before_enter", player, session)
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
	controls.fill(player, session)
	-- The stash above holds the position the game left them in before this
	-- teleport, which is where the player goes back to when they leave.
	if session.arena then
		player:set_pos(arena.viewing_position(session.arena))
	end
	recovery.apply_day_night(player, session)
	call_hook("on_enter", player, session)
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
	-- A stash that comes back without a running session has no saved override
	-- to return to; the game's own join handling can set one again.
	if player.override_day_night_ratio then
		player:override_day_night_ratio(nil)
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
			-- deserialize() reports a malformed stash in its return value; the
			-- player keeps their things and simply is not moved.
			local stash = core.deserialize(raw)
			if type(stash) == "table" then
				recovery.restore(player, stash)
			end
		end
	end
	-- Put back the day/night override the game had, if any. This runs before
	-- the game's own hook, so the hook has the last word either way.
	if session.rec.timeofday then
		local name = player:get_player_name()
		local previous = session.day_night and session.day_night[name]
		if previous then
			session.day_night[name] = nil
			player:override_day_night_ratio(previous.ratio)
		else
			player:override_day_night_ratio(nil)
		end
	end
	call_hook("on_leave", player, session)
end

-- The stash a player carries, if any, for the join handler to act on.
---@param player ObjectRef
---@return table|nil
function recovery.pending(player)
	local raw = player:get_meta():get_string(STASH)
	if raw == "" then return nil end
	-- A stash that cannot be read is dropped rather than kept for every join to
	-- trip over.
	local stash = core.deserialize(raw)
	if type(stash) ~= "table" then
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
