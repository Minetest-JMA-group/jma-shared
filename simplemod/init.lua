-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

local relays_available = core.global_exists("relays")
local discordmt_available = core.global_exists("discord") and discord.enabled
local discord_mute_log_channel = "1210689151993774180"

-- Core mod storage
local storage = core.get_mod_storage()
local LOG_LIMIT = 100

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

local function expand_reason(arg)
	if not arg or arg == "" then return "" end
	if reason_templates[arg] then
		return reason_templates[arg]
	end
	return arg
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

local function make_log_entry(action_type, scope, target, source, reason, duration_sec)
	return {
		type = action_type,
		scope = scope,
		target = target,
		source = source,
		reason = reason or "",
		duration = duration_sec,
		time = os.time(),
	}
end

-- --------------------------------------------------------------------------
-- Name‑based data (core mod storage)
-- --------------------------------------------------------------------------
local function get_storage_table(key)
	local data = storage:get_string(key)
	return data ~= "" and core.deserialize(data) or {}
end

local function save_storage_table(key, value)
	storage:set_string(key, core.serialize(value))
end

-- Active bans by name
local function get_name_bans()
	return get_storage_table("name_bans")
end
local function save_name_bans(bans)
	save_storage_table("name_bans", bans)
end

-- Active mutes by name
local function get_name_mutes()
	return get_storage_table("name_mutes")
end
local function save_name_mutes(mutes)
	save_storage_table("name_mutes", mutes)
end

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

local function get_ip_ban(name)
	local data, err = get_ip_data(name, "ban")
	if err then return nil, err end
	if not data then return nil end
	local ban = core.deserialize(data)
	if ban and ban.expiry and ban.expiry <= os.time() then
		clear_ip_data(name, "ban")
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
	local entry = make_log_entry(action_type, scope, target, source, reason, duration_sec)
	if scope == "name" then
		add_name_log(target, entry)
	else
		add_ip_log(target, entry)
	end
end

-- Name ban
function simplemod.ban_name(target, source, reason, duration_sec)
	local bans = get_name_bans()
	if bans[target] then return false, "Already name‑banned" end
	local ban = make_punishment_entry(source, reason, duration_sec)
	bans[target] = ban
	save_name_bans(bans)
	add_action_log("name", "ban", target, source, reason, duration_sec)
	local player = core.get_player_by_name(target)
	if player then
		local msg = "You have been banned" .. (ban.reason ~= "" and ": "..ban.reason or "")
		core.kick_player(target, msg)
	end
	return true
end
function simplemod.unban_name(target, source, reason)
	local bans = get_name_bans()
	if not bans[target] then return false, "Not name‑banned" end
	bans[target] = nil
	save_name_bans(bans)
	add_action_log("name", "unban", target, source, reason)
	return true
end
function simplemod.is_banned_name(target)
	local bans = get_name_bans()
	local ban = bans[target]
	if not ban then return false end
	if ban.expiry and ban.expiry <= os.time() then
		bans[target] = nil
		save_name_bans(bans)
		return false
	end
	return true
end

-- Name mute
function simplemod.mute_name(target, source, reason, duration_sec)
	local mutes = get_name_mutes()
	if mutes[target] then return false, "Already name‑muted" end
	local mute = make_punishment_entry(source, reason, duration_sec)
	mutes[target] = mute
	save_name_mutes(mutes)
	add_action_log("name", "mute", target, source, reason, duration_sec)
	return true
end
function simplemod.unmute_name(target, source, reason)
	local mutes = get_name_mutes()
	if not mutes[target] then return false, "Not name‑muted" end
	mutes[target] = nil
	save_name_mutes(mutes)
	add_action_log("name", "unmute", target, source, reason)
	return true
end
function simplemod.is_muted_name(target)
	local mutes = get_name_mutes()
	local mute = mutes[target]
	if not mute then return false end
	if mute.expiry and mute.expiry <= os.time() then
		mutes[target] = nil
		save_name_mutes(mutes)
		return false
	end
	return true
end

-- IP ban
function simplemod.ban_ip(target, source, reason, duration_sec)
	local existing, err = get_ip_ban(target)
	if err then return false, err end
	if existing then return false, "Already IP‑banned" end
	local ban = make_punishment_entry(source, reason, duration_sec)
	local ok
	ok, err = set_ip_data(target, "ban", core.serialize(ban))
	if not ok then return false, err end
	local list = get_storage_table("ip_ban_list")
	list[target] = ban
	save_storage_table("ip_ban_list", list)
	add_action_log("ip", "ban", target, source, reason, duration_sec)
	local player = core.get_player_by_name(target)
	if player then
		local msg = "Your IP has been banned" .. (ban.reason ~= "" and ": "..ban.reason or "")
		core.kick_player(target, msg)
	end
	return true
end
function simplemod.unban_ip(target, source, reason)
	local existing, err = get_ip_ban(target)
	if err then return false, err end
	if not existing then return false, "Not IP‑banned" end
	clear_ip_data(target, "ban")
	local list = get_storage_table("ip_ban_list")
	list[target] = nil
	save_storage_table("ip_ban_list", list)
	add_action_log("ip", "unban", target, source, reason)
	return true
end
function simplemod.is_banned_ip(target)
	local ban = get_ip_ban(target)
	return ban ~= nil
end

-- IP mute
function simplemod.mute_ip(target, source, reason, duration_sec)
	local existing, err = get_ip_mute(target)
	if err then return false, err end
	if existing then return false, "Already IP‑muted" end
	local mute = make_punishment_entry(source, reason, duration_sec)
	local ok
	ok, err = set_ip_data(target, "mute", core.serialize(mute))
	if not ok then return false, err end
	local list = get_storage_table("ip_mute_list")
	list[target] = mute
	save_storage_table("ip_mute_list", list)
	add_action_log("ip", "mute", target, source, reason, duration_sec)
	return true
end
function simplemod.unmute_ip(target, source, reason)
	local existing, err = get_ip_mute(target)
	if err then return false, err end
	if not existing then return false, "Not IP‑muted" end
	clear_ip_data(target, "mute")
	local list = get_storage_table("ip_mute_list")
	list[target] = nil
	save_storage_table("ip_mute_list", list)
	add_action_log("ip", "unmute", target, source, reason)
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
		local ban = get_name_bans()[name]
		return "You are banned" .. (ban.reason ~= "" and ": "..ban.reason or "")
	end
	local ban = get_ip_ban(name)
	if ban then
		return "Your IP is banned" .. (ban.reason ~= "" and ": "..ban.reason or "")
	end
end)

local function get_active_mute(name)
	local mutes = get_name_mutes()
	local name_mute = mutes[name]
	if name_mute then
		if name_mute.expiry and name_mute.expiry <= os.time() then
			mutes[name] = nil
			save_name_mutes(mutes)
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
	if relays_available then
		relays.send_action_report("[MUTED:%s] %s: %s", scope, name, message)
	end
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
		return false, "Scope must be 'name' or 'ip'"
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

	return run_action(is_mute and "mute" or "ban", scope, target, name, expanded_reason, duration)
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
		return false, "Scope must be 'name' or 'ip'"
	end
	local reason = table.concat(args, " ", 3)
	local expanded_reason = expand_reason(reason)

	local priv = is_mute and "pmute" or "ban"
	if not core.check_player_privs(name, {[priv]=true}) then
		return false, "Insufficient privileges"
	end

	return run_action(is_mute and "unmute" or "unban", scope, target, name, expanded_reason)
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
		local name_bans = get_name_bans()
		local ip_bans = get_storage_table("ip_ban_list")
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
		local name_mutes = get_name_mutes()
		local ip_mutes = get_storage_table("ip_mute_list")
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
local function show_gui(name, tab, filter_player, action_player, action_scope, action_template, action_duration)
	tab = tab or "1"
	filter_player = filter_player or ""
	action_player = action_player or ""
	action_scope = action_scope or "name"
	action_template = action_template or "spam"
	action_duration = action_duration or ""

	local formspec = "size[12,10]"..
		"tabheader[0,0;tabs;Active Bans;Active Mutes;Player Log;Actions;"..tab..";false;false]"..
		"field[0,1;6,1;player_filter;Player name (for log tab);"..core.formspec_escape(filter_player).."]"..
		"button[6,0.9;2,1;view_log;View Log]"

	if tab == "1" or tab == "2" or tab == "3" then
		formspec = formspec .. "textlist[0,2;12,6;main_list;;0]"
	elseif tab == "4" then
		-- Actions tab
		formspec = formspec ..
			"field[0,2;6,1;action_player;Player name;"..core.formspec_escape(action_player).."]"..
			"dropdown[0,3;3,1;action_scope;name,ip;"..(action_scope == "ip" and "2" or "1").."]"..
			"dropdown[3,3;3,1;action_template;spam,grief,hack,language,other;"..
				(({spam=1,grief=2,hack=3,language=4,other=5})[action_template] or "1").."]"..
			"field[6,2;6,1;action_custom_reason;Custom reason (if 'other');]"..
			"field[0,4;4,1;action_duration;Duration (e.g. 1h, 2d);"..core.formspec_escape(action_duration).."]"..
			"button[0,5;3,1;action_ban;Ban]"..
			"button[3,5;3,1;action_mute;Mute]"..
			"button[6,5;3,1;action_unban;Unban]"..
			"button[9,5;3,1;action_unmute;Unmute]"
	end

	formspec = formspec ..
		"button[10,9;2,1;refresh;Refresh]"..
		"button[0,9;2,1;close;Close]"

	core.show_formspec(name, "simplemod:main", formspec)
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "simplemod:main" then return end
	local name = player:get_player_name()
	if not core.check_player_privs(name, {ban=true}) then return end

	if fields.close then return end

	if fields.view_log then
		local target = fields.player_filter
		if target and target ~= "" then
			show_gui(name, "3", target)
		else
			core.chat_send_player(name, "Please enter a player name")
		end
		return
	end

	if fields.action_ban or fields.action_mute or fields.action_unban or fields.action_unmute then
		local target = fields.action_player
		if not target or target == "" then
			core.chat_send_player(name, "Player name required")
			show_gui(name, "4", "", target, fields.action_scope, fields.action_template, fields.action_duration)
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

		local priv = (fields.action_mute or fields.action_unmute) and "pmute" or "ban"
		if not core.check_player_privs(name, {[priv]=true}) then
			core.chat_send_player(name, "Insufficient privileges")
			show_gui(name, "4", "", target, scope, template_key, duration_str)
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
		show_gui(name, "4", "", "", "name", "spam", "")
		return
	end

	if fields.refresh or fields.tabs then
		local tab = fields.tabs or "1"
		local filter = fields.player_filter or ""
		local items = {}

		if tab == "1" then  -- Active Bans
			for p,d in pairs(get_name_bans()) do
				table.insert(items, "[Name] "..format_active_entry(p, d))
			end
			for p,d in pairs(get_storage_table("ip_ban_list")) do
				table.insert(items, "[IP]   "..format_active_entry(p, d))
			end
		elseif tab == "2" then  -- Active Mutes
			for p,d in pairs(get_name_mutes()) do
				table.insert(items, "[Name] "..format_active_entry(p, d))
			end
			for p,d in pairs(get_storage_table("ip_mute_list")) do
				table.insert(items, "[IP]   "..format_active_entry(p, d))
			end
		elseif tab == "3" then  -- Player Log
			if filter and filter ~= "" then
				local log = simplemod.get_player_log(filter)
				for i=1, math.min(50, #log) do
					local e = log[i]
					local line = ("[%s] %s (%s): %s by %s"):format(
						os.date("%H:%M", e.time), e.type, e.scope, e.target, e.source)
					if e.reason and e.reason ~= "" then line = line .. " ("..e.reason..")" end
					if e.duration and e.duration > 0 then
						line = line .. " for " .. algorithms.time_to_string(e.duration)
					end
					table.insert(items, line)
				end
			else
				table.insert(items, "Enter a player name and click View Log")
			end
		elseif tab == "4" then
			show_gui(name, tab, filter, fields.action_player, fields.action_scope, fields.action_template, fields.action_duration)
			return
		end

		if #items == 0 then table.insert(items, "(none)") end

		local new_fs = "size[12,10]"..
			"tabheader[0,0;tabs;Active Bans;Active Mutes;Player Log;Actions;"..tab..";false;false]"..
			"field[0,1;6,1;player_filter;Player name (for log tab);"..core.formspec_escape(filter).."]"..
			"button[6,0.9;2,1;view_log;View Log]"..
			"textlist[0,2;12,6;main_list;"..table.concat(items, ",")..";0]"..
			"button[10,9;2,1;refresh;Refresh]"..
			"button[0,9;2,1;close;Close]"
		core.show_formspec(name, "simplemod:main", new_fs)
	end
end)

core.register_chatcommand("sb", {
	description = "Open simplemod GUI",
	privs = {ban=true},
	func = function(name)
		show_gui(name)
	end,
})

core.log("action", "[simplemod] loaded successfully")
