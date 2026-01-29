-- * Copyright (c) 2024 Nanowolf4  (E-Mail: n4w@tutanota.com, XMPP/Jabber: n4w@nixnet.serivces)
-- * SPDX-License-Identifier: GPL-3.0-or-later

chat_lib = {
	registered_on_chat_send_all = {},
	registered_on_chat_send_player = {},
	registered_on_chat_message = {},
	registered_on_chat_message_sorted_priorities = {}
}

function chat_lib.register_on_chat_message(priority, func)
	if type(priority) ~= "number" or type(func) ~= "function" then
		error("chat_lib.register_on_chat_message called with invalid types of arguments")
	end
	if chat_lib.registered_on_chat_message[priority] then
		error("chat_lib.register_on_chat_message: Tried to register two callbacks with the same priority")
	end
	chat_lib.registered_on_chat_message[priority] = func

	local t = chat_lib.registered_on_chat_message_sorted_priorities
	for i = 1, #t do
		if priority < t[i] then
			table.insert(t, i, priority)
			return
		end
	end
	-- In the case priority is larger than all existing values, just insert it at the end
	table.insert(t, priority)
end

table.insert(core.registered_on_chat_messages, 1, function(name, message)
	if message:sub(1, 1) == "/" then
		return false -- let commands through unhandled
	end
	for _, v in ipairs(chat_lib.registered_on_chat_message_sorted_priorities) do
		if chat_lib.registered_on_chat_message[v](name, message) then
			return true
		end
	end
	return false
end)

function chat_lib.register_on_chat_send_all(func)
	table.insert(chat_lib.registered_on_chat_send_all, func)
end

function chat_lib.register_on_chat_send_player(func)
	table.insert(chat_lib.registered_on_chat_send_player, func)
end

chat_lib.chat_send_all = core.chat_send_all
chat_lib.chat_send_player = core.chat_send_player

function core.chat_send_all(message, source)
	for _, func in ipairs(chat_lib.registered_on_chat_send_all) do
		if func(message, source) == true then
			-- Message is handled, not be sent to all players
			return
		end
	end

	chat_lib.chat_send_all(message)
end

function core.chat_send_player(name, message, source)
	for _, func in ipairs(chat_lib.registered_on_chat_send_player) do
		if func(name, message, source) == true then
			-- Message is handled, not be sent to player
			return
		end
	end

	chat_lib.chat_send_player(name, message)
end

function chat_lib.send_message_to_privileged(message, privileges, sender)
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
	for _, player in ipairs(core.get_connected_players()) do
		local player_name = player:get_player_name()
		-- Check if player has any of the required privileges and hasn't received the message yet
		if not sent_to[player_name] then
			for priv_name in pairs(priv_check) do
				if core.check_player_privs(player_name, {[priv_name] = true}) then
					if not sender or not block_msgs or not block_msgs.is_chat_blocked(sender, player_name) then
						core.chat_send_player(player_name, message)
						count = count + 1
					end
					sent_to[player_name] = true
					break -- Stop checking other privileges for this player
				end
			end
		end
	end

	return count
end

dofile(core.get_modpath("chat_lib") .. "/chat_commands_utils.lua")
dofile(core.get_modpath("chat_lib") .. "/server_status_override.lua")
