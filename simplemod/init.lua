-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

local discordmt_available = core.global_exists("discord") and discord.enabled
local discord_mute_log_channel = "1210689151993774180"

-- Core mod storage
local storage = core.get_mod_storage()
local LOG_LIMIT = 100
local BAN_APPEAL_SUFFIX = [[

If you think that you got banned by mistake, please contact us on Discord: ctf.jma-sig.de or write an email to loki@jma-sig.de.
(de) Wenn Sie denken, dass es sich um ein Missverständnis handelt, dann schreiben Sie bitte eine E-Mail an loki@jma-sig.de oder kontaktieren Sie uns auf Discord über die Website ctf.jma-sig.de.]]

-- --------------------------------------------------------------------------
-- Helper functions
-- --------------------------------------------------------------------------
local function log_message_to_discord(message, ...)
	if not discordmt_available then
		return
	end
	discord.send(string.format(message, ...), discord_mute_log_channel)
end

-- --------------------------------------------------------------------------
-- Reason templates
-- --------------------------------------------------------------------------
local reason_templates = {
	spam = "Spamming",
	grief = "Griefing",
	hack = "Hacking / Cheating",
	language = "Offensive language",
	other = "", -- placeholder for custom reason
}
local reason_template_by_text = {}
local reason_template_index = {
	spam = 1,
	grief = 2,
	hack = 3,
	language = 4,
	other = 5,
}
for key, value in pairs(reason_templates) do
	if key ~= "other" and value ~= "" then
		reason_template_by_text[value] = key
	end
end

local function expand_reason(arg)
	if not arg or arg == "" then return "" end
	if reason_templates[arg] then
		return reason_templates[arg]
	end
	return arg
end

local function infer_reason_template(reason)
	return reason_template_by_text[reason or ""] or "other"
end

local function trim_log(log)
	if #log <= LOG_LIMIT then
		return log
	end
	local out = {}
	for i = 1, LOG_LIMIT do
		out[i] = log[i]
	end
	return out
end

local function make_punishment_entry(source, reason, duration_sec)
	local now = os.time()
	return {
		source = source,
		reason = reason or "",
		time = now,
		expiry = duration_sec and duration_sec > 0 and now + duration_sec or nil,
	}
end

local function format_ban_message(prefix, reason)
	local msg = prefix .. (reason ~= "" and ": "..reason or "")
	return msg .. BAN_APPEAL_SUFFIX
end

-- --------------------------------------------------------------------------
-- Name‑based data (core mod storage)
-- --------------------------------------------------------------------------
local function get_storage_table(key)
	return core.deserialize(storage:get_string(key)) or {}
end

local function save_storage_table(key, value)
	storage:set_string(key, core.serialize(value))
end

local NAME_BANS_KEY = "name_bans"
local NAME_MUTES_KEY = "name_mutes"
local IP_BAN_LIST_KEY = "ip_ban_list"
local IP_MUTE_LIST_KEY = "ip_mute_list"

-- Per‑player log (name actions)
local function get_name_log(player)
	return get_storage_table("log_name:"..player)
end
local function save_name_log(player, log)
	save_storage_table("log_name:"..player, trim_log(log))
end
local function add_name_log(player, entry)
	local log = get_name_log(player)
	table.insert(log, 1, entry)
	save_name_log(player, log)
end

-- --------------------------------------------------------------------------
-- IP‑based data (ipdb per‑entry storage)
-- --------------------------------------------------------------------------
local ipdb_storage = ipdb.get_mod_storage(function(entry1, entry2)
	-- Merge function: combine bans, mutes, and logs
	local function merge_one(key)
		local v1, v2 = entry1[key], entry2[key]
		if not v1 and not v2 then return nil end
		if not v1 then return v2 end
		if not v2 then return v1 end
		local t1, t2 = core.deserialize(v1), core.deserialize(v2)
		local now = os.time()
		local active1 = t1 and (not t1.expiry or t1.expiry > now)
		local active2 = t2 and (not t2.expiry or t2.expiry > now)
		if active1 and not active2 then return v1 end
		if active2 and not active1 then return v2 end
		if not active1 and not active2 then return nil end
		-- both active: keep later expiry
		local exp1 = t1.expiry or math.huge
		local exp2 = t2.expiry or math.huge
		return exp1 >= exp2 and v1 or v2
	end
	-- Merge logs
	local log1 = entry1.log and core.deserialize(entry1.log) or {}
	local log2 = entry2.log and core.deserialize(entry2.log) or {}
	local merged = {}
	for _, e in ipairs(log1) do table.insert(merged, e) end
	for _, e in ipairs(log2) do table.insert(merged, e) end
	table.sort(merged, function(a,b) return a.time > b.time end)
	merged = trim_log(merged)
	return {
		ban = merge_one("ban"),
		mute = merge_one("mute"),
		log = core.serialize(merged),
	}
end)

-- Helper: get ipdb context for a player name
local function ipdb_ctx(name)
	---@diagnostic disable-next-line: need-check-nil
	return ipdb_storage:get_context_by_name(name)
end

local function get_ip_data(name, key)
	local ctx, err = ipdb_ctx(name)
	if not ctx then
		return nil, err
	end
	local data = ctx:get_string(key)
	err = err or ctx:finalize()
	if err then
		return nil, err
	end
	return data
end

local function set_ip_data(name, key, value)
	local ctx, err = ipdb_ctx(name)
	if not ctx then
		return false, err or "Player not known to ipdb"
	end
	err = err or ctx:set_string(key, value)
	err = err or ctx:finalize()
	if err then
		return false, err
	end
	return true
end

local function clear_ip_data(name, key)
	local ctx, err = ipdb_ctx(name)
	if not ctx then
		return err
	end
	err = err or ctx:set_string(key, nil)
	err = err or ctx:finalize()
	return err
end

local function clear_ip_list_entry(list_key, name)
	local list = get_storage_table(list_key)
	if list[name] == nil then
		return
	end
	list[name] = nil
	save_storage_table(list_key, list)
end

local function get_ip_linked_names(name)
	local ctx, err = ipdb_ctx(name)
	if not ctx then
		return nil, err
	end
	local ok, identifiers_or_err = pcall(ipdb.dbmanager.get_all_identifiers, ctx._userentry_id)
	err = err or ctx:finalize()
	if not ok then
		return nil, identifiers_or_err
	end
	if err then
		return nil, err
	end
	return identifiers_or_err and identifiers_or_err.names or {}
end

local function get_ip_ban(name)
	local data, err = get_ip_data(name, "ban")
	if err then return nil, err end
	if not data then return nil end
	local ban = core.deserialize(data)
	if ban and ban.expiry and ban.expiry <= os.time() then
		clear_ip_data(name, "ban")
		clear_ip_list_entry(IP_BAN_LIST_KEY, name)
		return nil
	end
	return ban
end

local function get_ip_mute(name)
	local data, err = get_ip_data(name, "mute")
	if err then return nil, err end
	if not data then return nil end
	local mute = core.deserialize(data)
	if mute and mute.expiry and mute.expiry <= os.time() then
		clear_ip_data(name, "mute")
		clear_ip_list_entry(IP_MUTE_LIST_KEY, name)
		return nil
	end
	return mute
end

local function get_ip_log(name)
	local data, err = get_ip_data(name, "log")
	if err then
		return {}
	end
	return data and core.deserialize(data) or {}
end
local function add_ip_log(name, entry)
	local data, err = get_ip_data(name, "log")
	if err then
		return
	end
	local log = data and core.deserialize(data) or {}
	table.insert(log, 1, entry)
	set_ip_data(name, "log", core.serialize(trim_log(log)))
end

-- --------------------------------------------------------------------------
-- Public API
-- --------------------------------------------------------------------------
simplemod = {}
simplemod.log_message_to_discord = log_message_to_discord

local function add_action_log(scope, action_type, target, source, reason, duration_sec)
	local entry = {
		type = action_type,
		scope = scope,
		target = target,
		source = source,
		reason = reason or "",
		duration = duration_sec,
		time = os.time(),
	}
	if scope == "name" then
		add_name_log(target, entry)
	else
		add_ip_log(target, entry)
	end
end

local function report_action(scope_text, action_type, target, source, reason, duration_sec)
	local has_reason = reason and reason ~= ""
	if action_type == "ban" or action_type == "mute" then
		if not has_reason then
			reason = "none"
		end
		local duration_text = (duration_sec and duration_sec > 0) and algorithms.time_to_string(duration_sec) or "permanent"
		relays.send_action_report(
			"simplemod %s (%s): **%s** -> **%s** for `%s` reason: `%s`",
			action_type, scope_text, source, target, duration_text, reason
		)
		return
	end

	if has_reason then
		relays.send_action_report(
			"simplemod %s (%s): **%s** -> **%s** reason: `%s`",
			action_type, scope_text, source, target, reason
		)
		return
	end

	relays.send_action_report(
		"simplemod %s (%s): **%s** -> **%s**",
		action_type, scope_text, source, target
	)
end

-- Name ban
function simplemod.ban_name(target, source, reason, duration_sec)
	local bans = get_storage_table(NAME_BANS_KEY)
	local ban = make_punishment_entry(source, reason, duration_sec)
	bans[target] = ban
	save_storage_table(NAME_BANS_KEY, bans)
	add_action_log("name", "ban", target, source, reason, duration_sec)
	report_action("name", "ban", target, source, reason, duration_sec)
	local player = core.get_player_by_name(target)
	if player then
		local msg = format_ban_message("You have been banned", ban.reason)
		core.disconnect_player(target, msg)
	end
	return true
end
function simplemod.unban_name(target, source, reason)
	local bans = get_storage_table(NAME_BANS_KEY)
	if not bans[target] then return false, "Not name‑banned" end
	bans[target] = nil
	save_storage_table(NAME_BANS_KEY, bans)
	add_action_log("name", "unban", target, source, reason)
	report_action("name", "unban", target, source, reason)
	return true
end
function simplemod.is_banned_name(target)
	local bans = get_storage_table(NAME_BANS_KEY)
	local ban = bans[target]
	if not ban then return false end
	if ban.expiry and ban.expiry <= os.time() then
		bans[target] = nil
		save_storage_table(NAME_BANS_KEY, bans)
		return false
	end
	return true
end

-- Name mute
function simplemod.mute_name(target, source, reason, duration_sec)
	local mutes = get_storage_table(NAME_MUTES_KEY)
	local mute = make_punishment_entry(source, reason, duration_sec)
	mutes[target] = mute
	save_storage_table(NAME_MUTES_KEY, mutes)
	add_action_log("name", "mute", target, source, reason, duration_sec)
	report_action("name", "mute", target, source, reason, duration_sec)
	return true
end
function simplemod.unmute_name(target, source, reason)
	local mutes = get_storage_table(NAME_MUTES_KEY)
	if not mutes[target] then return false, "Not name‑muted" end
	mutes[target] = nil
	save_storage_table(NAME_MUTES_KEY, mutes)
	add_action_log("name", "unmute", target, source, reason)
	report_action("name", "unmute", target, source, reason)
	return true
end
function simplemod.is_muted_name(target)
	local mutes = get_storage_table(NAME_MUTES_KEY)
	local mute = mutes[target]
	if not mute then return false end
	if mute.expiry and mute.expiry <= os.time() then
		mutes[target] = nil
		save_storage_table(NAME_MUTES_KEY, mutes)
		return false
	end
	return true
end

-- IP ban
function simplemod.ban_ip(target, source, reason, duration_sec)
	local ban = make_punishment_entry(source, reason, duration_sec)
	local ok, err = set_ip_data(target, "ban", core.serialize(ban))
	if not ok then return false, err end
	local list = get_storage_table(IP_BAN_LIST_KEY)
	list[target] = ban
	save_storage_table(IP_BAN_LIST_KEY, list)
	add_action_log("ip", "ban", target, source, reason, duration_sec)
	report_action("IP", "ban", target, source, reason, duration_sec)
	local msg = format_ban_message("Your IP has been banned", ban.reason)
	local names, names_err = get_ip_linked_names(target)
	if names_err then
		core.log("warning", "[simplemod] failed to get linked names for IP ban target "..target..": "..tostring(names_err))
		if core.get_player_by_name(target) then
			core.disconnect_player(target, msg)
		end
		return true
	end
	local seen = {[target] = true}
	if core.get_player_by_name(target) then
		core.disconnect_player(target, msg)
	end
	for _, linked_name in ipairs(names) do
		if not seen[linked_name] then
			seen[linked_name] = true
			if core.get_player_by_name(linked_name) then
				core.disconnect_player(linked_name, msg)
			end
		end
	end
	return true
end
function simplemod.unban_ip(target, source, reason)
	local existing, err = get_ip_ban(target)
	if err then return false, err end
	if not existing then return false, "Not IP‑banned" end
	err = clear_ip_data(target, "ban")
	if err then return false, err end
	local list = get_storage_table(IP_BAN_LIST_KEY)
	list[target] = nil
	save_storage_table(IP_BAN_LIST_KEY, list)
	add_action_log("ip", "unban", target, source, reason)
	report_action("IP", "unban", target, source, reason)
	return true
end
function simplemod.is_banned_ip(target)
	local ban = get_ip_ban(target)
	return ban ~= nil
end

-- IP mute
function simplemod.mute_ip(target, source, reason, duration_sec)
	local mute = make_punishment_entry(source, reason, duration_sec)
	local ok, err = set_ip_data(target, "mute", core.serialize(mute))
	if not ok then return false, err end
	local list = get_storage_table(IP_MUTE_LIST_KEY)
	list[target] = mute
	save_storage_table(IP_MUTE_LIST_KEY, list)
	add_action_log("ip", "mute", target, source, reason, duration_sec)
	report_action("IP", "mute", target, source, reason, duration_sec)
	return true
end
function simplemod.unmute_ip(target, source, reason)
	local existing, err = get_ip_mute(target)
	if err then return false, err end
	if not existing then return false, "Not IP‑muted" end
	err = clear_ip_data(target, "mute")
	if err then return false, err end
	local list = get_storage_table(IP_MUTE_LIST_KEY)
	list[target] = nil
	save_storage_table(IP_MUTE_LIST_KEY, list)
	add_action_log("ip", "unmute", target, source, reason)
	report_action("IP", "unmute", target, source, reason)
	return true
end
function simplemod.is_muted_ip(target)
	local mute = get_ip_mute(target)
	return mute ~= nil
end

-- Combined log for a player
function simplemod.get_player_log(player)
	local name_log = get_name_log(player)
	local ip_log = get_ip_log(player)
	local combined = {}
	for _, e in ipairs(name_log) do table.insert(combined, e) end
	for _, e in ipairs(ip_log) do table.insert(combined, e) end
	table.sort(combined, function(a,b) return a.time > b.time end)
	return combined
end

-- --------------------------------------------------------------------------
-- Callbacks
-- --------------------------------------------------------------------------
-- Check bans on successful login (after ipdb processing)
ipdb.register_on_login(function(name, _)
	if simplemod.is_banned_name(name) then
		local ban = get_storage_table(NAME_BANS_KEY)[name]
		return format_ban_message("You are banned", ban.reason)
	end
	local ban = get_ip_ban(name)
	if ban then
		return format_ban_message("Your IP is banned", ban.reason)
	end
end)

local function get_active_mute(name)
	local mutes = get_storage_table(NAME_MUTES_KEY)
	local name_mute = mutes[name]
	if name_mute then
		if name_mute.expiry and name_mute.expiry <= os.time() then
			mutes[name] = nil
			save_storage_table(NAME_MUTES_KEY, mutes)
		else
			return "name", name_mute
		end
	end

	local ip_mute = get_ip_mute(name)
	if ip_mute then
		return "ip", ip_mute
	end
end

core.register_chatcommand("smca", {
	params = "<player_name> <on|off>",
	description = "Enable or disable a muted player's access to mute-chat log visible to moderators.",
	privs = {pmute=true},
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
	end
})

core.register_on_chat_message(function(name, message)
	if message:sub(1,1) == "/" then return end
	local scope, mute_data = get_active_mute(name)
	if not scope then
		return
	end

	local player = core.get_player_by_name(name)
	if player and player:get_meta():get_string("mute_chat_access") == "false" then
		core.chat_send_player(name, "You're muted. No one can read your messages.")
		return true
	end

	local expiry = mute_data.expiry and " until "..os.date("%Y-%m-%d %H:%M", mute_data.expiry) or " permanently"
	core.chat_send_player(name, "You are muted ("..scope..")"..expiry..". Reason: "..(mute_data.reason or "none"))

	local muted_message = string.format("[MUTED:%s] <%s>: %s", scope, name, message)
	chat_lib.send_message_to_privileged(muted_message, {ban=true, pmute=true}, name)
	log_message_to_discord("**%s**: %s", name, message)
	return true
end)

local function run_action(action_type, scope, target, source, reason, duration_sec)
	if action_type == "ban" then
		if scope == "name" then
			return simplemod.ban_name(target, source, reason, duration_sec)
		end
		if scope == "ip" then
			return simplemod.ban_ip(target, source, reason, duration_sec)
		end
	elseif action_type == "mute" then
		if scope == "name" then
			return simplemod.mute_name(target, source, reason, duration_sec)
		end
		if scope == "ip" then
			return simplemod.mute_ip(target, source, reason, duration_sec)
		end
	elseif action_type == "unban" then
		if scope == "name" then
			return simplemod.unban_name(target, source, reason)
		end
		if scope == "ip" then
			return simplemod.unban_ip(target, source, reason)
		end
	elseif action_type == "unmute" then
		if scope == "name" then
			return simplemod.unmute_name(target, source, reason)
		end
		if scope == "ip" then
			return simplemod.unmute_ip(target, source, reason)
		end
	end
	return false, "Invalid action or scope"
end

local function format_active_entry(player, data)
	local expiry = data.expiry and " until "..os.date("%Y-%m-%d %H:%M", data.expiry) or ""
	return string.format("%s: %s (by %s)%s", player, data.reason, data.source, expiry)
end

local ui_state = {}

local function get_ui_state(name)
	local state = ui_state[name]
	if state then
		return state
	end
	state = {
		tab = "1",
		filter = "",
		action_player = "",
		action_scope = "name",
		action_template = "spam",
		action_duration = "",
		action_custom_reason = "",
		selected_row = 1,
	}
	ui_state[name] = state
	return state
end

core.register_on_leaveplayer(function(player)
	ui_state[player:get_player_name()] = nil
end)

local function severity_color(action_type)
	if action_type == "ban" then
		return "#cc4444"
	end
	if action_type == "mute" then
		return "#b3872b"
	end
	if action_type == "unban" or action_type == "unmute" then
		return "#3f8f5b"
	end
	return "#d9d9d9"
end

local function make_table_rows(tab, filter)
	local rows = {}
	if tab == "1" then
		for p,d in pairs(get_storage_table(NAME_BANS_KEY)) do
			table.insert(rows, {
				color = severity_color("ban"),
				text = "[BAN] [Name] "..format_active_entry(p, d),
				target = p,
				scope = "name",
				kind = "ban",
				reason = d.reason or "",
			})
		end
		for p,d in pairs(get_storage_table(IP_BAN_LIST_KEY)) do
			table.insert(rows, {
				color = severity_color("ban"),
				text = "[BAN] [IP] "..format_active_entry(p, d),
				target = p,
				scope = "ip",
				kind = "ban",
				reason = d.reason or "",
			})
		end
	elseif tab == "2" then
		for p,d in pairs(get_storage_table(NAME_MUTES_KEY)) do
			table.insert(rows, {
				color = severity_color("mute"),
				text = "[MUTE] [Name] "..format_active_entry(p, d),
				target = p,
				scope = "name",
				kind = "mute",
				reason = d.reason or "",
			})
		end
		for p,d in pairs(get_storage_table(IP_MUTE_LIST_KEY)) do
			table.insert(rows, {
				color = severity_color("mute"),
				text = "[MUTE] [IP] "..format_active_entry(p, d),
				target = p,
				scope = "ip",
				kind = "mute",
				reason = d.reason or "",
			})
		end
	elseif tab == "3" then
		if filter and filter ~= "" then
			local log = simplemod.get_player_log(filter)
			for i = 1, math.min(50, #log) do
				local e = log[i]
				local line = ("[%s] %s (%s): %s by %s"):format(
					os.date("%Y-%m-%d %H:%M", e.time), e.type, e.scope, e.target, e.source)
				if e.reason and e.reason ~= "" then
					line = line .. " ("..e.reason..")"
				end
				if e.duration and e.duration > 0 then
					line = line .. " for " .. algorithms.time_to_string(e.duration)
				end
				table.insert(rows, {
					color = severity_color(e.type),
					text = line,
					target = e.target,
					scope = e.scope,
					kind = e.type,
					reason = e.reason or "",
				})
			end
		else
			table.insert(rows, {
				color = "#d9d9d9",
				text = "Enter a player name above and press View Log.",
			})
		end
	end

	if tab == "1" or tab == "2" then
		table.sort(rows, function(a, b)
			return a.text < b.text
		end)
	end

	if #rows == 0 then
		table.insert(rows, {color = "#d9d9d9", text = "(none)"})
	end
	return rows
end

local function make_table_data(rows)
	local data = {}
	for _, row in ipairs(rows) do
		table.insert(data, row.color)
		table.insert(data, core.formspec_escape(row.text))
	end
	return table.concat(data, ",")
end

local function online_player_dropdown(current_name)
	local names = {}
	for _, player in ipairs(core.get_connected_players()) do
		table.insert(names, player:get_player_name())
	end
	table.sort(names)
	table.insert(names, 1, "(select online)")

	local selected = 1
	for i = 2, #names do
		if names[i] == current_name then
			selected = i
			break
		end
	end
	return table.concat(names, ","), selected
end

local function has_active_punishment(scope, target, kind)
	if not target or target == "" then
		return false
	end
	if scope == "ip" then
		if kind == "mute" then
			return simplemod.is_muted_ip(target)
		end
		return simplemod.is_banned_ip(target)
	end
	if kind == "mute" then
		return simplemod.is_muted_name(target)
	end
	return simplemod.is_banned_name(target)
end

-- --------------------------------------------------------------------------
-- Chat commands (unified with type argument)
-- --------------------------------------------------------------------------
local function handle_ban(name, params, is_mute)
	local args = {}
	for w in params:gmatch("%S+") do table.insert(args, w) end
	if #args < 3 then
		local cmd = is_mute and "sbmute" or "sbban"
		return false, "Usage: /"..cmd.." <player> <name|ip> [duration] <reason>"
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
	local expanded_reason = expand_reason(reason)

	local priv = is_mute and "pmute" or "ban"
	if not core.check_player_privs(name, {[priv]=true}) then
		return false, "Insufficient privileges"
	end

	local ok, err = run_action(is_mute and "mute" or "ban", scope, target, name, expanded_reason, duration)
	if not ok then
		local action = is_mute and "Mute" or "Ban"
		return false, ("%s failed for %s (%s): %s"):format(action, target, scope, err or "unknown")
	end

	local action = is_mute and "Muted" or "Banned"
	local duration_text = duration > 0 and (" for "..algorithms.time_to_string(duration)) or " permanently"
	local reason_text = expanded_reason ~= "" and expanded_reason or "none"
	return true, ("%s %s (%s)%s. Reason: %s."):format(action, target, scope, duration_text, reason_text)
end

local function handle_unban(name, params, is_mute)
	local args = {}
	for w in params:gmatch("%S+") do table.insert(args, w) end
	if #args < 2 then
		local cmd = is_mute and "sbunmute" or "sbunban"
		return false, "Usage: /"..cmd.." <player> <name|ip> [reason]"
	end
	local target = args[1]
	local scope = args[2]
	if scope ~= "name" and scope ~= "ip" then
		return false, ("Scope must be 'name' or 'ip' (got: %q)"):format(args[2] or "")
	end
	local reason = table.concat(args, " ", 3)
	local expanded_reason = expand_reason(reason)

	local priv = is_mute and "pmute" or "ban"
	if not core.check_player_privs(name, {[priv]=true}) then
		return false, "Insufficient privileges"
	end

	local ok, err = run_action(is_mute and "unmute" or "unban", scope, target, name, expanded_reason)
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

core.register_chatcommand("sbban", {
	description = "Ban a player by name or IP",
	params = "<player> <name|ip> [duration] <reason>",
	privs = {ban=true},
	func = function(n,p) return handle_ban(n,p,false) end,
})
core.register_chatcommand("sbunban", {
	description = "Unban a player by name or IP",
	params = "<player> <name|ip> [reason]",
	privs = {ban=true},
	func = function(n,p) return handle_unban(n,p,false) end,
})
core.register_chatcommand("sbmute", {
	description = "Mute a player by name or IP",
	params = "<player> <name|ip> [duration] <reason>",
	privs = {pmute=true},
	func = function(n,p) return handle_ban(n,p,true) end,
})
core.register_chatcommand("sbunmute", {
	description = "Unmute a player by name or IP",
	params = "<player> <name|ip> [reason]",
	privs = {pmute=true},
	func = function(n,p) return handle_unban(n,p,true) end,
})

-- List active bans
core.register_chatcommand("sbbanlist", {
	description = "List all active bans (name and IP)",
	privs = {ban=true},
	func = function(_)
		local name_bans = get_storage_table(NAME_BANS_KEY)
		local ip_bans = get_storage_table(IP_BAN_LIST_KEY)
		local lines = {"Name bans:"}
		for p,d in pairs(name_bans) do
			table.insert(lines, "  "..format_active_entry(p, d))
		end
		table.insert(lines, "IP bans:")
		for p,d in pairs(ip_bans) do
			table.insert(lines, "  "..format_active_entry(p, d))
		end
		if #lines == 2 then table.insert(lines, "  (none)") end
		return true, table.concat(lines, "\n")
	end,
})

-- List active mutes
core.register_chatcommand("sbmutelist", {
	description = "List all active mutes (name and IP)",
	privs = {pmute=true},
	func = function(_)
		local name_mutes = get_storage_table(NAME_MUTES_KEY)
		local ip_mutes = get_storage_table(IP_MUTE_LIST_KEY)
		local lines = {"Name mutes:"}
		for p,d in pairs(name_mutes) do
			table.insert(lines, "  "..format_active_entry(p, d))
		end
		table.insert(lines, "IP mutes:")
		for p,d in pairs(ip_mutes) do
			table.insert(lines, "  "..format_active_entry(p, d))
		end
		if #lines == 2 then table.insert(lines, "  (none)") end
		return true, table.concat(lines, "\n")
	end,
})

-- Per‑player log
core.register_chatcommand("sblog", {
	description = "Show combined log for a player (name + IP actions)",
	params = "<player>",
	privs = {ban=true},
	func = function(name, param)
		local target = param:match("^%s*(%S+)%s*$")
		if not target then return false, "Usage: /sblog <player>" end
		local log = simplemod.get_player_log(target)
		if #log == 0 then
			return true, "No log entries for "..target
		end
		local lines = {}
		for _, e in ipairs(log) do
			local line = string.format("[%s] %s (%s): %s by %s",
				os.date("%Y-%m-%d %H:%M", e.time),
				e.type, e.scope, e.target, e.source)
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

-- GUI (extended with Actions tab)
local function show_gui(name, tab, filter_player, action_player, action_scope, action_template, action_duration, action_custom_reason)
	tab = tab or "1"
	filter_player = filter_player or ""
	action_player = action_player or ""
	action_scope = action_scope or "name"
	action_template = action_template or "spam"
	action_duration = action_duration or ""
	action_custom_reason = action_custom_reason or ""

	local state = get_ui_state(name)
	state.tab = tab
	state.filter = filter_player
	state.action_player = action_player
	state.action_scope = action_scope
	state.action_template = action_template
	state.action_duration = action_duration
	state.action_custom_reason = action_custom_reason

	local is_other_reason = action_template == "other"
	local can_unban = has_active_punishment(action_scope, action_player, "ban")
	local can_unmute = has_active_punishment(action_scope, action_player, "mute")
	local rows = make_table_rows(tab, filter_player)
	local formspec = "formspec_version[6]size[13,10]"..
		"bgcolor[#1a1a1acc;true]"..
		"style_type[label;font_size=18]"..
		"style[close;bgcolor=#3a3a3a;bgcolor_hovered=#4a4a4a]"..
		"style[refresh;bgcolor=#355070;bgcolor_hovered=#42678f]"..
		"style[quick_to_actions;bgcolor=#425e7a;bgcolor_hovered=#527494]"..
		"style[action_ban;bgcolor=#8f2626;bgcolor_hovered=#aa2f2f]"..
		"style[action_mute;bgcolor=#6e5a2f;bgcolor_hovered=#85703a]"..
		"style[action_unban;bgcolor=#305f3e;bgcolor_hovered=#3a774c]"..
		"style[action_unmute;bgcolor=#305f3e;bgcolor_hovered=#3a774c]"..
		"style[action_unban_disabled;bgcolor=#474747;bgcolor_hovered=#474747;font_color=#9a9a9a]"..
		"style[action_unmute_disabled;bgcolor=#474747;bgcolor_hovered=#474747;font_color=#9a9a9a]"..
		"style_type[table;background=#151515;border=true]"..
		"tablecolumns[color;text]"..
		"tableoptions[highlight=#355070;border=false]"..
		"tabheader[0.2,0.2;tabs;Active Bans,Active Mutes,Player Log,Actions;"..tab..";false;false]"

	if tab == "1" or tab == "2" then
		formspec = formspec ..
			"label[0.3,1.0;"..(tab == "1" and "Active bans (red)" or "Active mutes (yellow)").."]"..
			"table[0.3,1.4;12.4,7.4;main_table;"..make_table_data(rows)..";"..tostring(state.selected_row or 1).."]"..
			"button[7.5,9.0;2.9,1;quick_to_actions;Open In Actions]"..
			"tooltip[quick_to_actions;Open selected entry in Actions tab with fields prefilled.]"
	elseif tab == "3" then
		local online_names, online_selected = online_player_dropdown(filter_player)
		formspec = formspec ..
			"label[0.3,1.0;Player name]"..
			"field[0.3,1.6;6.5,1;player_filter;;"..core.formspec_escape(filter_player).."]"..
			"dropdown[7.0,1.6;2.6,1;player_filter_pick;"..online_names..";"..online_selected.."]"..
			"field_close_on_enter[player_filter;false]"..
			"button[9.9,1.6;2.8,1;view_log;View Log]"..
			"table[0.3,2.8;12.4,6.2;main_table;"..make_table_data(rows)..";"..tostring(state.selected_row or 1).."]"
	elseif tab == "4" then
		local online_names, online_selected = online_player_dropdown(action_player)
		formspec = formspec ..
			"box[0.2,0.9;12.6,8.0;#1f1f1fa8]"..
			"label[0.5,1.2;Apply moderation action]"..
			"label[0.5,1.8;Player name]"..
			"field[0.5,2.3;6.0,1;action_player;;"..core.formspec_escape(action_player).."]"..
			"field_close_on_enter[action_player;false]"..
			"dropdown[6.7,2.3;2.6,1;action_player_pick;"..online_names..";"..online_selected.."]"..
			"label[9.5,1.8;Scope]"..
			"dropdown[9.5,2.3;1.6,1;action_scope;name,ip;"..(action_scope == "ip" and "2" or "1").."]"..
			"label[11.3,1.8;Reason]"..
			"dropdown[11.3,2.3;1.5,1;action_template;spam,grief,hack,language,other;"..
				(reason_template_index[action_template] or 1).."]"..
			"label[0.5,3.9;Duration (e.g. 1h, 2d, empty = permanent)]"..
			"field[0.5,4.4;4.0,1;action_duration;;"..core.formspec_escape(action_duration).."]"
		if is_other_reason then
			formspec = formspec ..
				"label[0.5,5.7;Custom reason]"..
				"field[0.5,6.1;12.0,1;action_custom_reason;;"..core.formspec_escape(action_custom_reason).."]"
		end
		formspec = formspec ..
			"button[0.5,7.4;2.8,1;action_ban;Ban]"..
			"button[3.5,7.4;2.8,1;action_mute;Mute]"..
			(can_unban
				and "button[6.5,7.4;2.8,1;action_unban;Unban]"
				or "button[6.5,7.4;2.8,1;action_unban_disabled;Unban]")..
			(can_unmute
				and "button[9.5,7.4;2.8,1;action_unmute;Unmute]"
				or "button[9.5,7.4;2.8,1;action_unmute_disabled;Unmute]")..
			"tooltip[action_ban;Ban and disconnect immediately.]"
	end

	formspec = formspec ..
		"button_exit[0.3,9.0;2.0,1;close;Close]"..
		"button[10.5,9.0;2.2,1;refresh;Refresh]"

	core.show_formspec(name, "simplemod:main", formspec)
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "simplemod:main" then return end
	local name = player:get_player_name()
	if not core.check_player_privs(name, {moderator=true}) then return end
	local state = get_ui_state(name)

	if fields.close or fields.quit then
		ui_state[name] = nil
		return
	end

	if fields.main_table then
		local event = core.explode_table_event(fields.main_table)
		if event.type == "CHG" then
			state.selected_row = event.row
		elseif event.type == "DCL" then
			state.selected_row = event.row
			if state.tab == "1" or state.tab == "2" then
				local rows = make_table_rows(state.tab, state.filter)
				local selected = rows[state.selected_row]
				if selected and selected.target then
					local template = infer_reason_template(selected.reason)
					show_gui(
						name,
						"4",
						state.filter,
						selected.target,
						selected.scope,
						template,
						state.action_duration,
						template == "other" and selected.reason or ""
					)
					return
				end
			end
		end
	end

	if fields.key_enter_field == "player_filter" then
		fields.view_log = true
	end
	if fields.key_enter_field == "action_player" then
		show_gui(
			name,
			"4",
			fields.player_filter or state.filter,
			fields.action_player or "",
			fields.action_scope or state.action_scope,
			fields.action_template or state.action_template,
			fields.action_duration or state.action_duration,
			fields.action_custom_reason or state.action_custom_reason
		)
		return
	end

	if fields.player_filter_pick and fields.player_filter_pick ~= "(select online)" then
		local dropdown_only = not fields.view_log and not fields.tabs and not fields.refresh and not fields.key_enter_field
		if dropdown_only or not fields.player_filter or fields.player_filter == "" then
			fields.player_filter = fields.player_filter_pick
		end
		if dropdown_only then
			fields.view_log = true
		end
	end

	if fields.view_log then
		local target = fields.player_filter
		if target and target ~= "" then
			show_gui(name, "3", target, fields.action_player, fields.action_scope, fields.action_template, fields.action_duration, fields.action_custom_reason)
		else
			core.chat_send_player(name, "Please enter a player name")
		end
		return
	end

	if fields.action_player_pick and fields.action_player_pick ~= "(select online)" then
		local dropdown_only = not fields.action_ban
			and not fields.action_mute
			and not fields.action_unban
			and not fields.action_unmute
			and not fields.refresh
			and not fields.tabs
			and not fields.key_enter_field
		if dropdown_only or not fields.action_player or fields.action_player == "" then
			fields.action_player = fields.action_player_pick
		end
		if dropdown_only then
			show_gui(
				name,
				"4",
				fields.player_filter or state.filter,
				fields.action_player,
				fields.action_scope or state.action_scope,
				fields.action_template or state.action_template,
				fields.action_duration or state.action_duration,
				fields.action_custom_reason or state.action_custom_reason
			)
			return
		end
	end

	if fields.action_unban_disabled or fields.action_unmute_disabled then
		show_gui(
			name,
			"4",
			fields.player_filter or state.filter,
			fields.action_player or state.action_player,
			fields.action_scope or state.action_scope,
			fields.action_template or state.action_template,
			fields.action_duration or state.action_duration,
			fields.action_custom_reason or state.action_custom_reason
		)
		return
	end

	if fields.action_ban or fields.action_mute or fields.action_unban or fields.action_unmute then
		local target = fields.action_player
		if not target or target == "" then
			core.chat_send_player(name, "Player name required")
			show_gui(name, "4", "", target, fields.action_scope, fields.action_template, fields.action_duration, fields.action_custom_reason)
			return
		end
		local scope = fields.action_scope or "name"
		local template_key = fields.action_template or "spam"
		local custom = fields.action_custom_reason or ""
		local reason
		if template_key == "other" then
			reason = custom
		else
			reason = reason_templates[template_key] or template_key
		end
		local duration_str = fields.action_duration or ""
		local duration = duration_str ~= "" and algorithms.parse_time(duration_str) or 0

		if fields.action_unban and not has_active_punishment(scope, target, "ban") then
			show_gui(name, "4", "", target, scope, template_key, duration_str, custom)
			return
		end
		if fields.action_unmute and not has_active_punishment(scope, target, "mute") then
			show_gui(name, "4", "", target, scope, template_key, duration_str, custom)
			return
		end

		local priv = (fields.action_mute or fields.action_unmute) and "pmute" or "ban"
		if not core.check_player_privs(name, {[priv]=true}) then
			core.chat_send_player(name, "Insufficient privileges")
			show_gui(name, "4", "", target, scope, template_key, duration_str, custom)
			return
		end

		local success, msg
		local action_type
		if fields.action_ban then
			action_type = "ban"
		elseif fields.action_mute then
			action_type = "mute"
		elseif fields.action_unban then
			action_type = "unban"
		elseif fields.action_unmute then
			action_type = "unmute"
		end
		success, msg = run_action(action_type, scope, target, name, reason, duration)

		if success then
			core.chat_send_player(name, "Action completed")
		else
			core.chat_send_player(name, "Error: " .. (msg or "unknown"))
		end
		show_gui(name, "4", "", target, scope, template_key, duration_str, custom)
		return
	end

	if fields.quick_to_actions then
		local tab = fields.tabs or state.tab
		if tab ~= "1" and tab ~= "2" then
			show_gui(name, tab, fields.player_filter or state.filter, fields.action_player or "", fields.action_scope or "name", fields.action_template or "spam", fields.action_duration or "", fields.action_custom_reason or "")
			return
		end
		local rows = make_table_rows(tab, fields.player_filter or state.filter)
		local selected = rows[state.selected_row or 1]
		if not selected or not selected.target then
			core.chat_send_player(name, "Select an entry first.")
			show_gui(name, tab, fields.player_filter or state.filter, fields.action_player or "", fields.action_scope or "name", fields.action_template or "spam", fields.action_duration or "", fields.action_custom_reason or "")
			return
		end
		local template = infer_reason_template(selected.reason)
		show_gui(
			name,
			"4",
			fields.player_filter or state.filter,
			selected.target,
			selected.scope,
			template,
			fields.action_duration or "",
			template == "other" and selected.reason or ""
		)
		return
	end

	if fields.action_template then
		show_gui(
			name,
			fields.tabs or "4",
			fields.player_filter or state.filter,
			fields.action_player or "",
			fields.action_scope or "name",
			fields.action_template,
			fields.action_duration or "",
			fields.action_custom_reason or ""
		)
		return
	end

	if fields.refresh or fields.tabs then
		show_gui(
			name,
			fields.tabs or "1",
			fields.player_filter or "",
			fields.action_player or "",
			fields.action_scope or "name",
			fields.action_template or "spam",
			fields.action_duration or "",
			fields.action_custom_reason or ""
		)
	end
end)

core.register_chatcommand("sb", {
	description = "Open simplemod GUI",
	privs = {moderator=true},
	func = function(name)
		show_gui(name)
		return true, "Opened simplemod GUI."
	end,
})

core.log("action", "[simplemod] loaded successfully")
