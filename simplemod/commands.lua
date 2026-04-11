-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

return function(internal)
	local pending_cli_confirmations = {}
	local pending_cli_confirmation_id = 0

	internal.on_player_leave = function(name)
		pending_cli_confirmations[name] = nil
	end

	local function set_cli_confirmation(name, command, pending)
		pending_cli_confirmation_id = pending_cli_confirmation_id + 1
		pending.id = pending_cli_confirmation_id
		pending.expires_at = os.time() + internal.OVERRIDE_CONFIRM_WINDOW_SEC
		pending.command = command
		pending_cli_confirmations[name] = pending_cli_confirmations[name] or {}
		pending_cli_confirmations[name][command] = pending
		local expected_id = pending.id
		core.after(internal.OVERRIDE_CONFIRM_WINDOW_SEC, function()
			local by_player = pending_cli_confirmations[name]
			if not by_player then
				return
			end
			local current = by_player[command]
			if current and current.id == expected_id then
				by_player[command] = nil
				core.chat_send_player(name, "Override request timed out and was aborted.")
			end
	end)
end

	local function take_cli_confirmation(name, command)
		local by_player = pending_cli_confirmations[name]
		if not by_player then
			return nil
		end
		local pending = by_player[command]
		if not pending then
			return nil
		end
		by_player[command] = nil
		if pending.expires_at <= os.time() then
			return nil, "Override request timed out and was aborted."
		end
		return pending
	end

	local function handle_ban(name, params, is_mute)
		local args = {}
		for w in params:gmatch("%S+") do
			table.insert(args, w)
		end
		local cmd = is_mute and "sbmute" or "sbban"
		local action_type = is_mute and "mute" or "ban"
		if #args == 1 and (args[1] == "confirm" or args[1] == "abort") then
			local pending, pending_err = take_cli_confirmation(name, cmd)
			if not pending then
				return false, pending_err or "No pending override request"
			end
			if args[1] == "abort" then
				return true, "Override request aborted."
			end
			local ok, err = internal.run_action(pending.action_type, pending.scope, pending.target, pending.source, pending.reason, pending.duration, pending.allow_unknown)
			if not ok then
				return false, ("%s failed for %s (%s): %s"):format(
					pending.action_type == "mute" and "Mute" or "Ban",
					pending.target,
					pending.scope,
					err or "unknown"
				)
			end
			local done = pending.action_type == "mute" and "Muted" or "Banned"
			local reason_text = pending.reason ~= "" and pending.reason or "none"
			return true, ("%s %s (%s) for %s. Reason: %s."):format(done, pending.target, pending.scope, internal.format_duration_text(pending.duration), reason_text)
		end

		local parsed_args = {}
		local force_unknown = false
		for _, arg in ipairs(args) do
			if arg == "--new" then
				force_unknown = true
			else
				parsed_args[#parsed_args + 1] = arg
			end
		end
		args = parsed_args

		if #args < 3 then
			return false, "Usage: /" .. cmd .. " <player_or_ip> <name|ip> [--new] [duration] <reason> | /" .. cmd .. " <confirm|abort>"
		end
		local target = args[1]
		local scope = args[2]
		if scope ~= "name" and scope ~= "ip" then
			return false, ("Scope must be 'name' or 'ip' (got: %q)"):format(args[2] or "")
		end

		local time_str, reason
		if args[3]:match("^%d") then
			time_str = args[3]
			reason = table.concat(args, " ", 4)
		else
			time_str = nil
			reason = table.concat(args, " ", 3)
		end
		local duration = time_str and algorithms.parse_time(time_str) or 0
		local expanded_reason = internal.expand_reason(reason)

		if is_mute then
			if not core.check_player_privs(name, {pmute = true}) then
				return false, "Insufficient privileges"
			end
		else
			local allowed, err = internal.can_issue_ban(name, duration)
			if not allowed then
				return false, err
			end
		end

		local existing, existing_err = internal.get_active_punishment_entry(scope, target, action_type)
		if existing_err then
			return false, existing_err
		end
		if existing then
			local can_override, override_err = internal.can_override_punishment(action_type, name, existing, duration)
			if not can_override then
				return false, override_err
			end
			set_cli_confirmation(name, cmd, {
				action_type = action_type,
				scope = scope,
				target = target,
				source = name,
				reason = expanded_reason,
				duration = duration,
				allow_unknown = force_unknown,
			})
			for _, line in ipairs(internal.format_existing_punishment_lines(action_type, scope, target, existing)) do
				core.chat_send_player(name, line)
			end
			for _, line in ipairs(internal.format_new_punishment_lines(action_type, scope, target, name, expanded_reason, duration)) do
				core.chat_send_player(name, line)
			end
			core.chat_send_player(name, "Type /" .. cmd .. " confirm to proceed or /" .. cmd .. " abort within " .. internal.OVERRIDE_CONFIRM_WINDOW_SEC .. "s.")
			return true, "Override confirmation required."
		end

		local ok, err = internal.run_action(action_type, scope, target, name, expanded_reason, duration, force_unknown)
		if not ok then
			local action = is_mute and "Mute" or "Ban"
			return false, ("%s failed for %s (%s): %s"):format(action, target, scope, err or "unknown")
		end

		local action = is_mute and "Muted" or "Banned"
		local duration_text = duration > 0 and (" for " .. algorithms.time_to_string(duration)) or " permanently"
		local reason_text = expanded_reason ~= "" and expanded_reason or "none"
		return true, ("%s %s (%s)%s. Reason: %s."):format(action, target, scope, duration_text, reason_text)
	end

	local function handle_unban(name, params, is_mute)
		local args = {}
		for w in params:gmatch("%S+") do
			table.insert(args, w)
		end
		if #args < 2 then
			local cmd = is_mute and "sbunmute" or "sbunban"
			return false, "Usage: /" .. cmd .. " <player_or_ip> <name|ip> [reason]"
		end
		local target = args[1]
		local scope = args[2]
		if scope ~= "name" and scope ~= "ip" then
			return false, ("Scope must be 'name' or 'ip' (got: %q)"):format(args[2] or "")
		end
		local reason = table.concat(args, " ", 3)
		local expanded_reason = internal.expand_reason(reason)

		if is_mute then
			if not core.check_player_privs(name, {pmute = true}) then
				return false, "Insufficient privileges"
			end
		else
			local allowed, err = internal.can_issue_unban(name, scope, target)
			if not allowed then
				return false, err
			end
		end

		local ok, err = internal.run_action(is_mute and "unmute" or "unban", scope, target, name, expanded_reason)
		if not ok then
			local action = is_mute and "Unmute" or "Unban"
			return false, ("%s failed for %s (%s): %s"):format(action, target, scope, err or "unknown")
		end

		local action = is_mute and "Unmuted" or "Unbanned"
		if expanded_reason ~= "" then
			return true, ("%s %s (%s). Reason: %s."):format(action, target, scope, expanded_reason)
		end
		return true, ("%s %s (%s)."):format(action, target, scope)
	end

	ipdb.register_on_login(function(name)
		if simplemod.is_banned_name(name) then
			local ban = internal.get_active_punishment_entry("name", name, "ban")
			if ban then
				internal.log_ban_join_attempt("name", name, "login", ban.reason)
				local msg = internal.format_ban_message("name", ban)
				core.log("action", string.format("[simplemod] Name-banned player %s attempted to join. Reason: %s", name, ban.reason))
				return msg
			end
		end
		local ban = internal.get_ip_ban(name)
		if ban then
			internal.log_ban_join_attempt("ip", name, "login", ban.reason)
			local msg = internal.format_ban_message("ip", ban)
			core.log("action", string.format("[simplemod] IP-banned player %s attempted to join. Reason: %s", name, ban.reason))
			return msg
		end
	end)

	chat_lib.register_on_chat_message(0, function(name, message)
		if message:sub(1, 1) == "/" then
			return
		end
		local scope, mute_data = internal.get_active_mute(name)
		if not scope then
			return
		end

		local expiry = mute_data.expiry and " until " .. os.date("%Y-%m-%d %H:%M", mute_data.expiry) or " permanently"
		local base_message = "You are muted (" .. scope .. ")" .. expiry .. ". Reason: " .. (mute_data.reason or "none") .. ". "

		local player = core.get_player_by_name(name)
		if player and player:get_meta():get_string("mute_chat_access") == "false" then
			core.chat_send_player(name, base_message .. "Your messages are not visible to anyone.")
			return true
		end

		core.chat_send_player(name, base_message .. "Moderators can still see your messages. Use /muteappeal to appeal your mute.")

		local muted_message = string.format("[MUTED:%s] <%s>: %s", scope, name, message)
		chat_lib.send_message_to_privileged(muted_message, {ban = true, pmute = true}, name)
		internal.log_message_to_discord("**%s**: %s", name, message)
		return true
	end)

	core.register_on_chatcommand(function(name, command, params)
		local scope = internal.get_active_mute(name)
		if not scope then
			return
		end
		local def = core.registered_chatcommands[command]
		if not def or not def.privs or not def.privs.shout then
			return
		end
		core.chat_send_player(name, "You're muted. Commands that write to chat are disabled.")
		return true
	end)

	core.register_chatcommand("smca", {
		params = "<player_name> <on|off>",
		description = "Enable or disable a muted player's access to mute-chat log visible to moderators.",
		privs = {pmute = true},
		func = function(_, param)
			local muted_player_name, state = param:match("(%S+)%s+(%S+)")
			if not muted_player_name or not state then
				return false, "Enter a valid player name and on|off."
			end
			local muted_player = core.get_player_by_name(muted_player_name)
			if not muted_player then
				if core.player_exists(muted_player_name) ~= true then
					return false, "The player \"" .. muted_player_name .. "\" doesn't exist."
				end
				return false, "The player \"" .. muted_player_name .. "\" exists but is not online."
			end

			local is_on = state == "on"
			muted_player:get_meta():set_string("mute_chat_access", tostring(is_on))
			if is_on then
				return true, "Mute-chat access is now enabled for \"" .. muted_player_name .. "\"."
			end
			return true, "Mute-chat access is now disabled for \"" .. muted_player_name .. "\"."
		end,
	})

	core.register_chatcommand("sbban", {
		description = "Ban a player by name or IP",
		params = "<player_or_ip> <name|ip> [--new] [duration] <reason>",
		privs = {moderator = true},
		func = function(n, p)
			return handle_ban(n, p, false)
		end,
	})

	core.register_chatcommand("sbunban", {
		description = "Unban a player by name or IP",
		params = "<player_or_ip> <name|ip> [reason]",
		privs = {moderator = true},
		func = function(n, p)
			return handle_unban(n, p, false)
		end,
	})

	core.register_chatcommand("sbmute", {
		description = "Mute a player by name or IP",
		params = "<player_or_ip> <name|ip> [--new] [duration] <reason>",
		privs = {pmute = true},
		func = function(n, p)
			return handle_ban(n, p, true)
		end,
	})

	core.register_chatcommand("sbunmute", {
		description = "Unmute a player by name or IP",
		params = "<player_or_ip> <name|ip> [reason]",
		privs = {pmute = true},
		func = function(n, p)
			return handle_unban(n, p, true)
		end,
	})

	core.register_chatcommand("sbbanlist", {
		description = "List all active bans (name and IP)",
		privs = {ban = true},
		func = function()
			local name_bans = internal.get_active_name_bans()
			local ip_bans = internal.get_active_ip_bans()
			local lines = {"Name bans:"}
			for p, d in pairs(name_bans) do
				table.insert(lines, "  " .. internal.format_active_entry(p, d))
			end
			table.insert(lines, "IP bans:")
			for p, d in pairs(ip_bans) do
				table.insert(lines, "  " .. internal.format_active_entry(p, d))
			end
			if #lines == 2 then
				table.insert(lines, "  (none)")
			end
			return true, table.concat(lines, "\n")
		end,
	})

	core.register_chatcommand("sbmutelist", {
		description = "List all active mutes (name and IP)",
		privs = {pmute = true},
		func = function()
			local name_mutes = internal.get_active_name_mutes()
			local ip_mutes = internal.get_active_ip_mutes()
			local lines = {"Name mutes:"}
			for p, d in pairs(name_mutes) do
				table.insert(lines, "  " .. internal.format_active_entry(p, d))
			end
			table.insert(lines, "IP mutes:")
			for p, d in pairs(ip_mutes) do
				table.insert(lines, "  " .. internal.format_active_entry(p, d))
			end
			if #lines == 2 then
				table.insert(lines, "  (none)")
			end
			return true, table.concat(lines, "\n")
		end,
	})

	core.register_chatcommand("sblog", {
		description = "Show combined log for a player (name + IP actions)",
		params = "<player>",
		privs = {ban = true},
		func = function(_, param)
			local target = param:match("^%s*(%S+)%s*$")
			if not target then
				return false, "Usage: /sblog <player>"
			end
			local log = simplemod.get_player_log(target)
			if #log == 0 then
				return true, "No log entries for " .. target
			end
			local lines = {}
			for _, e in ipairs(log) do
				local line = string.format("[%s] %s (%s): %s by %s", os.date("%Y-%m-%d %H:%M", e.time), e.type, e.scope, e.target, e.source)
				if e.reason and e.reason ~= "" then
					line = line .. " (" .. e.reason .. ")"
				end
				if e.duration and e.duration > 0 then
					line = line .. " for " .. algorithms.time_to_string(e.duration)
				end
				table.insert(lines, line)
			end
			return true, table.concat(lines, "\n")
		end,
	})

	core.register_chatcommand("sblogjoins", {
		description = "Enable or disable logging of join attempts by banned players",
		params = "<on|off>",
		privs = {ban = true},
		func = function(_, param)
			local flag = param:match("^%s*(%S+)%s*$")
			if flag ~= "on" and flag ~= "off" then
				return false, "Usage: /sblogjoins <on|off>"
			end
			local enabled = flag == "on"
			internal.set_log_ban_join_attempts(enabled)
			return true, "Ban join-attempt logging is now " .. (enabled and "enabled." or "disabled.")
		end,
	})

	core.register_chatcommand("sb", {
		description = "Open simplemod GUI",
		privs = {moderator = true},
		func = function(name)
			internal.show_gui(name)
			return true, "Opened simplemod GUI."
		end,
	})

	core.register_chatcommand("mutereason", {
		description = "Check the reason why moderator muted you",
		func = function(name)
			local scope, mute_data = internal.get_active_mute(name)
			if not scope then
				return false, "You are not currently muted."
			end
			local expiry = mute_data.expiry and " until " .. os.date("%Y-%m-%d %H:%M", mute_data.expiry) or
			" permanently"
			return true, "You are muted (" .. scope .. ")" .. expiry .. ". Reason: " .. (mute_data.reason or "none")
		end
	})

	local player_cooldowns = {}
	local COOLDOWN_TIME = 172800

	core.register_chatcommand("muteappeal", {
		params = "<reason>",
		description = "Send a mute appeal to the staff team. The reason have to be at least 20 characters. If the reason doesnt makes sense the appeal will be rejected.",
		func = function(name, param)
			local scope = internal.get_active_mute(name)

			local new_param = param:gsub("^%s*(.-)%s*$", "%1") -- delete the spaces
			local length = #new_param

			local time = os.time()

			-- check if the cooldown is active for the player
			if player_cooldowns[name] and player_cooldowns[name] > time then
				local remaining = player_cooldowns[name] - time
				return false, "<You already appealed this mute, you can only appeal an mute once.>"
			end

			if not scope then
				return false, "You are currently not muted."
			end

			if param == "" then
				return false, "Please enter a reason to appeal an unmute."
			end

			if length < 20 then
				return false, "Please describe the reason for your appeal detailed."
			elseif length > 300 then
				return false, "Appeal is too long."
			else
				relays.send_feedback("**MUTEAPPEAL**: Player **".. name.."** requested a muteappeal. Reason: "..param)
				-- set cooldown time
				player_cooldowns[name] = time + COOLDOWN_TIME
				return true, "The appeal will be reviewed by the staff team soon."
			end
		end
	})
end
