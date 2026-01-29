-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

local storage = core.get_mod_storage()

-- Clean up old storage keys from previous version
storage:set_string("database", "")
storage:set_int("filter", 0)
storage:set_int("LCSthreshold", 0)

local mode = storage:contains("mode") and storage:get_int("mode") or 1

local function make_logger(level)
	return function(text, ...)
		core.log(level, "[nameban] " .. text:format(...))
	end
end

local ACTION = make_logger("action")
local WARNING = make_logger("warning")
local is_discord = core.global_exists("discord")

local function report_to_discord(message, ...)
	if is_discord then
		discord.send_action_report(message, ...)
	end
end

local blacklist = regex.create({
	storage = storage,
	path = core.get_modpath("nameban") .. "/blacklist.txt",
	storage_key = "blacklist",
	list_name = "blacklist",
	help_prefix = "Blacklist: ",
	logger = function(level, message)
		core.log(level, "[nameban:blacklist] " .. message)
	end
})

local whitelist = regex.create({
	storage = storage,
	path = core.get_modpath("nameban") .. "/whitelist.txt",
	storage_key = "whitelist",
	list_name = "whitelist",
	help_prefix = "Whitelist: ",
	logger = function(level, message)
		core.log(level, "[nameban:whitelist] " .. message)
	end
})

if not blacklist then
	WARNING("Failed to initialize blacklist regex context. Nameban mod will be disabled.")
	return
end

if not whitelist then
	WARNING("Failed to initialize whitelist regex context. Nameban mod will be disabled.")
	return
end

local function check_username(name)
	if whitelist:match(name) then
		ACTION("User %s allowed via whitelist", name)
		return nil
	end

	if blacklist:match(name) then
		local msg = "Your username is not allowed. Please change it and reconnect."

		if mode == 1 then
			ACTION("User %s denied via blacklist [ENFORCING]", name)
			report_to_discord("nameban: User %s denied via blacklist [ENFORCING]", name)
			return msg
		else
			ACTION("User %s would have been denied via blacklist [PERMISSIVE]", name)
			report_to_discord("nameban: User %s would have been denied via blacklist [PERMISSIVE]", name)
			return nil
		end
	end

	return nil
end

local function check_online_players()
	for _, player in ipairs(core.get_connected_players()) do
		local playername = player:get_player_name()
		local msg = check_username(playername)
		if msg then
			core.kick_player(playername, msg)
		end
	end
end

core.register_chatcommand("nameban", {
	description = "Manage name ban system using regex patterns",
	params = "<subcommand> [args]",
	privs = { ban = true },
	func = function(name, params)
		local subcommand, rest = params:match("^%s*(%S+)%s*(.*)$")
		subcommand = subcommand or ""

		if subcommand == "help" then
			return true, [[
nameban - Manage username restrictions using regex patterns

Subcommands:
  blacklist <command> [args] - Manage blacklist patterns
  whitelist <command> [args] - Manage whitelist patterns
  mode <permissive|enforcing> - Set operation mode
  reload                     - Reload both lists from files
  export                     - Export both lists to files
  check <username>           - Check if a username would be allowed
  scan                       - Check all currently online players

Whitelist patterns override blacklist patterns.
Use /nameban blacklist help or /nameban whitelist help for more info.
]]

		elseif subcommand == "blacklist" or subcommand == "whitelist" then
			local target_list = (subcommand == "blacklist") and blacklist or whitelist
			local list_cmd = rest:match("^%s*(%S+)") or ""

			if list_cmd == "help" then
				return true, target_list.help_prefix .. target_list.internal_help
			else
				local success, result = target_list:handle_command(name, rest)
				if success then
					if result ~= nil then
						-- If a pattern was added or removed, check online players and report to Discord
						if list_cmd == "add" or list_cmd == "rm" then
							check_online_players()
							report_to_discord("nameban: %s %s pattern: %s", name,
								list_cmd == "add" and "added" or "removed",
								rest:match("%S+%s+(.+)") or "unknown pattern")
						end
						return true, result
					else
						return true, "Done"
					end
				elseif result ~= nil then
					return false, result
				else
					return false, "Unknown subcommand. Use /nameban " .. subcommand .. " help"
				end
			end

		elseif subcommand == "mode" then
			local mode_param = rest:match("^%s*(%S+)%s*$")

			if mode_param == "permissive" then
				if mode == 0 then
					return false, "Mode is already permissive"
				end
				mode = 0
				storage:set_int("mode", 0)
				ACTION("Nameban mode set to permissive by %s", name)
				report_to_discord("nameban: %s set mode to permissive", name)
				return true, "Nameban mode set to permissive"

			elseif mode_param == "enforcing" then
				if mode == 1 then
					return false, "Mode is already enforcing"
				end
				mode = 1
				storage:set_int("mode", 1)
				ACTION("Nameban mode set to enforcing by %s", name)
				report_to_discord("nameban: %s set mode to enforcing", name)
				check_online_players()
				return true, "Nameban mode set to enforcing"

			else
				return false, "Usage: /nameban mode <permissive|enforcing>"
			end

		elseif subcommand == "reload" then
			blacklist:load_file()
			whitelist:load_file()
			ACTION("Both lists reloaded from files by %s", name)
			report_to_discord("nameban: %s reloaded both lists from files", name)
			check_online_players()
			return true, "Both lists reloaded from files"

		elseif subcommand == "export" then
			local ok1, err1 = blacklist:save_file()
			local ok2, err2 = whitelist:save_file()

			if ok1 and ok2 then
				ACTION("Both lists exported to files by %s", name)
				report_to_discord("nameban: %s exported both lists to files", name)
				return true, "Both lists exported to files"
			else
				local errors = {}
				if not ok1 then table.insert(errors, "Blacklist: " .. (err1 or "failed")) end
				if not ok2 then table.insert(errors, "Whitelist: " .. (err2 or "failed")) end
				return false, "Export failed: " .. table.concat(errors, "; ")
			end

		elseif subcommand == "check" then
			local username = rest:match("^%s*(%S+)%s*$")
			if not username then
				return false, "Usage: /nameban check <username>"
			end

			local msg = check_username(username)
			if msg then
				if mode == 1 then
					return true, "Username '" .. username .. "' would be DENIED (enforcing mode)"
				else
					return true, "Username '" .. username .. "' would be DENIED but allowed (permissive mode)"
				end
			else
				return true, "Username '" .. username .. "' would be ALLOWED"
			end

		elseif subcommand == "scan" then
			ACTION("Scanning online players by %s", name)
			report_to_discord("nameban: %s scanned online players", name)
			check_online_players()
			return true, "Scanned all online players"

		else
			return false, "Unknown subcommand. Use /nameban help"
		end
	end
})

core.register_on_prejoinplayer(function(name)
	return check_username(name)
end)

ACTION("Nameban mod loaded successfully (mode: %s)", mode == 1 and "enforcing" or "permissive")