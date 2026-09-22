-- * Copyright (c) 2024 Nanowolf4  (E-Mail: n4w@tutanota.com, XMPP/Jabber: n4w@nixnet.serivces)
-- * SPDX-License-Identifier: GPL-3.0-or-later

local shareddb_obj = shareddb.get_mod_storage()

local function load_default_file(file_name)
	return dofile(core.get_modpath("chat_lib") .. "/" .. file_name)
end

local function deserialize_or(str, fallback)
	if str and str ~= "" then
		return core.deserialize(str) or fallback
	end
	return fallback
end

local function load_relay_config()
	local default_whitelist = load_default_file("relay_chat_commands.lua")
	local default_blacklist = load_default_file("relay_chat_command_blacklist.lua")

	local ctx = shareddb_obj:get_context()
	if not ctx then
		chat_lib.relay_allowed_chat_commands = default_whitelist
		chat_lib.relay_chat_command_blacklist = default_blacklist
		return
	end

	local whitelist_str = ctx:get_string("whitelist")
	local blacklist_str = ctx:get_string("blacklist")
	ctx:finalize()

	chat_lib.relay_allowed_chat_commands = deserialize_or(whitelist_str, default_whitelist)
	chat_lib.relay_chat_command_blacklist = deserialize_or(blacklist_str, default_blacklist)
end

load_relay_config()
shareddb.register_listener(load_relay_config)

-- Stores one of the relay settings in shareddb; requires a freshly reloaded value
local function save_setting(key, value)
	local ctx, err = shareddb_obj:get_context()
	if not ctx then
		return false, "Failed to save: " .. tostring(err)
	end
	err = ctx:set_string(key, core.serialize(value))
	err = err or ctx:finalize()
	if err then
		return false, "Failed to save: " .. tostring(err)
	end
	return true
end

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

function chat_lib.relay_is_chatcommand_allowed(command, relay)
	if chat_lib.relay_allowed_chat_commands[command] ~= true then
		return false
	end

	local relay_blacklist = relay and chat_lib.relay_chat_command_blacklist[relay]
	if relay_blacklist and relay_blacklist[command] then
		return false
	end

	return true
end

local function get_relay_blacklist(relay)
	local relay_blacklist = chat_lib.relay_chat_command_blacklist[relay]
	if not relay_blacklist then
		relay_blacklist = {}
		chat_lib.relay_chat_command_blacklist[relay] = relay_blacklist
	end
	return relay_blacklist
end

local function blacklist_add(relay, cmdname)
	local relay_blacklist = get_relay_blacklist(relay)
	if relay_blacklist[cmdname] then
		return false, "Command "..cmdname.." is already blacklisted for "..relay
	end
	relay_blacklist[cmdname] = true

	local ok, err = save_setting("blacklist", chat_lib.relay_chat_command_blacklist)
	if not ok then
		return false, err
	end
	return true, "Blacklisted "..cmdname.." for "..relay
end

local function blacklist_rm(relay, cmdname)
	local relay_blacklist = chat_lib.relay_chat_command_blacklist[relay]
	if not (relay_blacklist and relay_blacklist[cmdname]) then
		return false, "Command "..cmdname.." is not blacklisted for "..relay
	end
	relay_blacklist[cmdname] = nil
	if next(relay_blacklist) == nil then
		chat_lib.relay_chat_command_blacklist[relay] = nil
	end

	local ok, err = save_setting("blacklist", chat_lib.relay_chat_command_blacklist)
	if not ok then
		return false, err
	end
	return true, "Removed "..cmdname.." from the "..relay.." blacklist"
end

local function blacklist_clear(relay)
	if not chat_lib.relay_chat_command_blacklist[relay] then
		return false, "Relay "..relay.." has no blacklisted commands"
	end
	chat_lib.relay_chat_command_blacklist[relay] = nil

	local ok, err = save_setting("blacklist", chat_lib.relay_chat_command_blacklist)
	if not ok then
		return false, err
	end
	return true, "Cleared the blacklist of "..relay
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
				"rm <command_name>: Remove command from the whitelist\n" ..
				"blacklist add <relay> <command_name>: Forbid the command for one relay\n" ..
				"blacklist rm <relay> <command_name>: Allow the command for one relay\n" ..
				"blacklist clear <relay>: Remove all commands forbidden for the relay\n" ..
				"blacklist dump [relay]: Print the blacklist of one relay or of all relays\n" ..
				"blacklist reload: Overwrite the blacklist with the content of the file on the server"
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

			local ok, err = save_setting("whitelist", chat_lib.relay_allowed_chat_commands)
			if not ok then
				return false, err
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

			local ok, err = save_setting("whitelist", chat_lib.relay_allowed_chat_commands)
			if not ok then
				return false, err
			end
			return true, "Removed "..cmdname.." from the whitelist"

		elseif command == "reload" then
			chat_lib.relay_allowed_chat_commands = load_default_file("relay_chat_commands.lua")

			local ok, err = save_setting("whitelist", chat_lib.relay_allowed_chat_commands)
			if not ok then
				return false, err
			end
			return true, "Whitelist reloaded"

		elseif command == "dump" then
			core.chat_send_player(name, dump(chat_lib.relay_allowed_chat_commands))
			return true

		elseif command == "blacklist" then
			local subcommand = iter()

			if subcommand == "add" or subcommand == "rm" then
				local relay = iter()
				local cmdname = iter()
				if not relay or not cmdname or cmdname == "" then
					return false, "You have to enter valid relay and command name to "..subcommand
				end
				if subcommand == "add" then
					return blacklist_add(relay, cmdname)
				end
				return blacklist_rm(relay, cmdname)

			elseif subcommand == "clear" then
				local relay = iter()
				if not relay then
					return false, "You have to enter valid relay name to "..subcommand
				end
				return blacklist_clear(relay)

			elseif subcommand == "dump" then
				local relay = iter()
				if relay then
					local relay_blacklist = chat_lib.relay_chat_command_blacklist[relay]
					if not relay_blacklist then
						return false, "Relay "..relay.." has no blacklisted commands"
					end
					core.chat_send_player(name, dump(relay_blacklist))
				else
					core.chat_send_player(name, dump(chat_lib.relay_chat_command_blacklist))
				end
				return true

			elseif subcommand == "reload" then
				local default_blacklist = load_default_file("relay_chat_command_blacklist.lua")
				chat_lib.relay_chat_command_blacklist = default_blacklist

				local ok, err = save_setting("blacklist", chat_lib.relay_chat_command_blacklist)
				if not ok then
					return false, err
				end
				return true, "Blacklist reloaded"
			end
		end

		return false, "Invalid command; Run /relay_commands help for available commands"
	end,
})