-- * Copyright (c) 2024 Nanowolf4  (E-Mail: n4w@tutanota.com, XMPP/Jabber: n4w@nixnet.serivces)
-- * SPDX-License-Identifier: GPL-3.0-or-later

chat_lib = {
	registered_on_chat_send_all = {},
	registered_on_chat_send_player = {}
}

function chat_lib.register_on_chat_send_all(func)
	table.insert(chat_lib.registered_on_chat_send_all, func)
end

function chat_lib.register_on_chat_send_player(func)
	table.insert(chat_lib.registered_on_chat_send_player, func)
end

chat_lib.chat_send_all = minetest.chat_send_all
chat_lib.chat_send_player = minetest.chat_send_player

function minetest.chat_send_all(message, source)
	for _, func in ipairs(chat_lib.registered_on_chat_send_all) do
		if func(message, source) == true then
			-- Message is handled, not be sent to all players
			return
		end
	end

	chat_lib.chat_send_all(message)
end

function minetest.chat_send_player(name, message, source)
	for _, func in ipairs(chat_lib.registered_on_chat_send_player) do
		if func(name, message, source) == true then
			-- Message is handled, not be sent to player
			return
		end
	end

	chat_lib.chat_send_player(name, message)
end

function chat_lib.send_message_to_privileged(message, privileges)
	if not message or not privileges then
		return 0
	end

	-- Convert privileges to table if it's a string
	local priv_list = type(privileges) == "string" and {privileges} or privileges

	-- Convert list of privileges to check format if needed
	local priv_check = {}
	for _, priv in ipairs(priv_list) do
		if type(priv) == "string" then
			priv_check[priv] = true
		elseif type(priv) == "table" then
			-- Merge privilege tables
			for p, v in pairs(priv) do
				priv_check[p] = v
			end
		end
	end

	local count = 0
	local sent_to = {} -- Track players who already received the message

	-- Get all connected players
	for _, player in ipairs(minetest.get_connected_players()) do
		local player_name = player:get_player_name()
		-- Check if player has any of the required privileges and hasn't received the message yet
		if not sent_to[player_name] then
			for priv_name in pairs(priv_check) do
				if minetest.check_player_privs(player_name, {[priv_name] = true}) then
					minetest.chat_send_player(player_name, message)
					count = count + 1
					sent_to[player_name] = true
					break -- Stop checking other privileges for this player
				end
			end
		end
	end

	return count
end

dofile(minetest.get_modpath("chat_lib") .. "/chat_commands_utils.lua")
dofile(minetest.get_modpath("chat_lib") .. "/server_status_override.lua")
