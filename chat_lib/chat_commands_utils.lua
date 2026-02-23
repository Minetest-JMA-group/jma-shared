-- * Copyright (c) 2024 Nanowolf4  (E-Mail: n4w@tutanota.com, XMPP/Jabber: n4w@nixnet.serivces)
-- * SPDX-License-Identifier: GPL-3.0-or-later

local shareddb_obj = shareddb.get_mod_storage()

local function load_whitelist()
	local ctx = shareddb_obj:get_context()
	if not ctx then
		chat_lib.relay_allowed_chat_commands = dofile(core.get_modpath("chat_lib") .. "/relay_chat_commands.lua")
		return
	end
	local wl_str = ctx:get_string("whitelist")
	ctx:finalize()
	if wl_str and wl_str ~= "" then
		chat_lib.relay_allowed_chat_commands = core.deserialize(wl_str) or {}
	else
		chat_lib.relay_allowed_chat_commands = dofile(core.get_modpath("chat_lib") .. "/relay_chat_commands.lua")
	end
end

load_whitelist()
shareddb.register_listener(load_whitelist)

function chat_lib.chatcommand_check_privs(name, command)
	local def = core.registered_chatcommands[command]
	local required_privs = def.privs
	local player_privs = core.get_player_privs(name)
	if type(required_privs) == "string" then
		required_privs = {[required_privs] = true}
	end
	for priv, value in pairs(required_privs) do
		if player_privs[priv] ~= value then
			return false
		end
	end
	return true
end

local send_player_callback = {}
chat_lib.register_on_chat_send_player(function(name, message)
	if send_player_callback[name] then
		return send_player_callback[name](name, message)
	end
end)

function chat_lib.execute_chatcommand(name, command, param, callback)
	if callback then
		send_player_callback[name] = callback
	end

	local success, ret_val = core.registered_chatcommands[command].func(name, param or "")
	send_player_callback[name] = nil
	return success, ret_val
end

function chat_lib.relay_is_chatcommand_allowed(command)
	return chat_lib.relay_allowed_chat_commands[command] == true
end

core.register_chatcommand("relay_commands", {
	description = "Execute relay management command",
	params = "<command> <command_args>",
	privs = {dev=true},
	func = function(name, param)
		local iter = param:gmatch("%S+")
		local command = iter()

		if command == "help" then
			local help = "List of possible commands:\n" ..
				"reload: Overwrite command whitelist with the content of the file on the server\n" ..
				"dump: Print the content of the allowed_commands\n" ..
				"add <command_name>: Add command to the whitelist\n" ..
				"rm <command_name>: Remove command from the whitelist"
			return true, help

		elseif command == "add" then
			local cmdname = iter()
			if not cmdname or cmdname == "" then
				return false, "You have to enter valid command name to "..command
			end
			if chat_lib.relay_allowed_chat_commands[cmdname] then
				return false, "Command "..cmdname.." is already in the whitelist"
			end
			chat_lib.relay_allowed_chat_commands[cmdname] = true

			local ctx, err = shareddb_obj:get_context()
			err = err or ctx:set_string("whitelist", core.serialize(chat_lib.relay_allowed_chat_commands))
			err = err or ctx:finalize()
			if err then
				return false, "Failed to save: " .. tostring(err)
			end
			return true, "Added "..cmdname.." to the whitelist"

		elseif command == "rm" then
			local cmdname = iter()
			if not cmdname or cmdname == "" then
				return false, "You have to enter valid command name to "..command
			end
			if not chat_lib.relay_allowed_chat_commands[cmdname] then
				return false, "Command "..cmdname.." hasn't existed in the whitelist"
			end
			chat_lib.relay_allowed_chat_commands[cmdname] = nil

			local ctx, err = shareddb_obj:get_context()
			err = err or ctx:set_string("whitelist", core.serialize(chat_lib.relay_allowed_chat_commands))
			err = err or ctx:finalize()
			if err then
				return false, "Failed to save: " .. tostring(err)
			end
			return true, "Removed "..cmdname.." from the whitelist"

		elseif command == "reload" then
			chat_lib.relay_allowed_chat_commands = dofile(core.get_modpath("chat_lib") .. "/relay_chat_commands.lua")

			local ctx, err = shareddb_obj:get_context()
			err = err or ctx:set_string("whitelist", core.serialize(chat_lib.relay_allowed_chat_commands))
			err = err or ctx:finalize()
			if err then
				return false, "Failed to save: " .. tostring(err)
			end
			return true, "Whitelist reloaded"

		elseif command == "dump" then
			core.chat_send_player(name, dump(chat_lib.relay_allowed_chat_commands))
			return true
		end

		return false, "Invalid command; Run /relay_commands help for available commands"
	end,
})