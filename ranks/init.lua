-- ranks/init.lua

ranks = {}

local registered   = {}

-- Load mod storage
local storage = core.get_mod_storage()

---
--- API
---

-- [local function] Get colour
local function get_colour(colour)
	if type(colour) == "table" and core.rgba then
		return core.rgba(colour.r, colour.g, colour.b, colour.a)
	elseif type(colour) == "string" then
		return colour
	else
		return "#ffffff"
	end
end

-- [function] Register rank
function ranks.register(name, def)
	assert(name ~= "clear", "Invalid name \"clear\" for rank")

	registered[name] = def
end

-- [function] Unregister rank
function ranks.unregister(name)
	registered[name] = nil
end

-- [function] List ranks in plain text
function ranks.list_plaintext()
	local list = ""
	for rank, i in pairs(registered) do
		if list == "" then
			list = rank
		else
			list = list..", "..rank
		end
	end
	return list
end

-- [function] Get player rank
function ranks.get_rank(name)
	if type(name) ~= "string" then
		name = core.get_player_by_name(name)
	end

	local rank = storage:get_string(name)
	if rank ~= "" and registered[rank] then
		return rank
	end
end

-- [function] Get rank definition
function ranks.get_def(rank)
	if not rank then
		return
	end

	return registered[rank]
end

-- [function] Set player rank
function ranks.set_rank(name, rank)
	if type(name) ~= "string" then
		name = name:get_player_name()
	end

	if registered[rank] and core.player_exists(name) then
		storage:set_string(name, rank)

		return true
	end
end

-- [function] Remove rank from player
function ranks.remove_rank(name)
	if type(name) ~= "string" then
		name = name:get_player_name()
	end

	local rank = ranks.get_rank(name)
	if rank ~= nil then
		-- Empty string deletes the key (nil value is deprecated)
		storage:set_string(name, "")
	end
end

-- [function] Get the player's chat prefix, or nil
-- Honors the ranks.prefix_chat setting: set to "false" to disable prefixes
function ranks.get_player_prefix(name)
	if core.settings:get("ranks.prefix_chat") ~= "false" then
		local rank = ranks.get_rank(name)
		if rank then
			local def = ranks.get_def(rank)
			if def.prefix then
				local colour = get_colour(def.colour)
				return {prefix = def.prefix, color = colour}
			end
		end
	end
	return nil
end

-- Display the rank prefix in chat. On the CTF server, ctf_chat owns the chat
-- formatting pipeline: it overrides core.format_chat_message (which block_msgs
-- calls when delivering chat) and renders rank prefixes via register_prefix.
-- So this override only applies where ctf_chat is absent — i.e. on the
-- MineClone2 and Creative servers.
if not core.global_exists("ctf_chat") then
	local old_format_chat_message = core.format_chat_message
	core.format_chat_message = function(name, message)
		local formatted = old_format_chat_message(name, message)
		local prefix = ranks.get_player_prefix(name)
		if prefix then
			return core.colorize(prefix.color, prefix.prefix) .. " " .. formatted
		end
		return formatted
	end
end

---
--- Registrations
---

-- [privilege] Rank
core.register_privilege("ranking", {
	description = "Permission to use /rank chatcommand ",
	give_to_singleplayer = false,
})

-- Assign/update rank on join player
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()

	-- If database item exists and new storage item does not, use database item
	if player:get_attribute("ranks:rank") ~= nil and storage:get_string(name) == "" then
		-- Add entry into new storage system
		storage:set_string(name, player:get_attribute("ranks:rank"))

		-- Store backup then invalidate database item
		player:set_attribute("ranks:rank-old", player:get_attribute("ranks:rank"))
		player:set_attribute("ranks:rank", nil)
	end

	-- Both items exist, remove old one
	if player:get_attribute("ranks:rank") ~= nil and storage:get_string(name) ~= "" then
		player:set_attribute("ranks:rank-old", player:get_attribute("ranks:rank"))
		player:set_attribute("ranks:rank", nil)
	end

	if ranks.get_rank(name) then
		-- Rank already set
	else
		if ranks.default then
			ranks.set_rank(name, ranks.default)
		end
	end

end)

-- [chatcommand] /rank
core.register_chatcommand("ranking", {
	description = "Set a player's rank",
	params = "<player> <new rank> / \"list\" | username, rankname / list ranks",
	privs = {ranking = true},
	func = function(name, param)
		local param = param:split(" ")
		if #param == 0 then
			return false, "Invalid usage (see /help rank)"
		end

		if #param == 1 and param[1] == "list" then
			return true, "Available Ranks: "..ranks.list_plaintext()
		elseif #param == 2 then
			if core.player_exists(param[1]) == false then
					return false, "Player does not exist"
			end

			if ranks.get_def(param[2]) then
				if ranks.set_rank(param[1], param[2]) then
					if name ~= param[1] then
						core.chat_send_player(param[1], name.." set your rank to "..param[2])
					end

					return true, "Set "..param[1].."'s rank to "..param[2]
				else
					return false, "Unknown error while setting "..param[1].."'s rank to "..param[2]
				end
			elseif param[2] == "clear" then
				ranks.remove_rank(param[1])
				return true, "Removed rank from "..param[1]
			else
				return false, "Invalid rank (see /rank list)"
			end
		else
			return false, "Invalid usage (see /help rank)"
		end
	end,
})

-- [chatcommand] /getrank
core.register_chatcommand("getrank", {
	description = "Get a player's rank. If no player is specified, your own rank is returned.",
	params = "<name> | name of player",
	func = function(name, param)
		if param and param ~= "" then
			local rank = ranks.get_rank(param)
			if rank then
				return true, "Rank of " .. param .. ": " .. rank:gsub("^%l", string.upper)
			elseif core.player_exists(param) then
				return false, "Rank of " .. param .. ": No rank"
			else
				return false, "Player does not exist"
			end
		else
			local rank = ranks.get_rank(name) or "No rank"
			return true, "Your rank: " .. rank:gsub("^%l", string.upper)
		end
	end,
})

---
--- Ranks
---

-- Load default ranks
dofile(core.get_modpath("ranks").."/ranks.lua")

local path = core.get_worldpath().."/ranks.lua"
-- Attempt to load per-world ranks
if io.open(path) then
	dofile(path)
end

-- Integrate with ctf_chat on the CTF server (optional_depends = ctf_chat
-- guarantees load order). Priority 0: rank prefix renders before league prefixes.
if core.global_exists("ctf_chat") and ctf_chat.register_prefix then
	ctf_chat.register_prefix(0, function(name, tcolor)
		local prefix = ranks.get_player_prefix(name)
		if prefix then
			return core.colorize(prefix.color, prefix.prefix)
		end
	end)
end
