-- simplemod/init.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

local modname = "simplemod"

-- Dependencies (assumed present)
local algorithms = algorithms
local ipdb = ipdb
local chat_lib = chat_lib
local relays_available = core.global_exists("relays")
local discordmt_available = core.global_exists("discord")
local discord_mute_log_channel = "1210689151993774180"

-- Core mod storage
local storage = core.get_mod_storage()

-- --------------------------------------------------------------------------
-- Helper functions from algorithms
-- --------------------------------------------------------------------------
local parse_time = algorithms.parse_time
local time_to_string = algorithms.time_to_string

local function log_message_to_discord(message, ...)
	if not discordmt_available or not discord.enabled then
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
	-- if arg is exactly a template key, use that template
	if reason_templates[arg] then
		return reason_templates[arg]
	end
	-- otherwise treat as custom reason
	return arg
end

-- --------------------------------------------------------------------------
-- Name‑based data (core mod storage)
-- --------------------------------------------------------------------------

-- Active bans by name
local function get_name_bans()
	local data = storage:get_string("name_bans")
	return data ~= "" and core.deserialize(data) or {}
end
local function save_name_bans(bans)
	storage:set_string("name_bans", core.serialize(bans))
end

-- Active mutes by name
local function get_name_mutes()
	local data = storage:get_string("name_mutes")
	return data ~= "" and core.deserialize(data) or {}
end
local function save_name_mutes(mutes)
	storage:set_string("name_mutes", core.serialize(mutes))
end

-- Per‑player log (name actions)
local function get_name_log(player)
	local data = storage:get_string("log_name:"..player)
	return data ~= "" and core.deserialize(data) or {}
end
local function save_name_log(player, log)
	-- keep newest 100
	if #log > 100 then
		local new = {}
		for i=1,100 do new[i] = log[i] end
		log = new
	end
	storage:set_string("log_name:"..player, core.serialize(log))
end
local function add_name_log(player, entry)
	local log = get_name_log(player)
	table.insert(log, 1, entry)  -- newest first
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
	if #merged > 100 then
		local new = {}
		for i=1,100 do new[i] = merged[i] end
		merged = new
	end
	return {
		ban = merge_one("ban"),
		mute = merge_one("mute"),
		log = core.serialize(merged),
	}
end)

-- Helper: get ipdb context for a player name
local function ipdb_ctx(name)
	return ipdb_storage:get_context_by_name(name)
end

-- IP ban: source of truth is ipdb
local function get_ip_ban(name)
	local ctx, err = ipdb_ctx(name)
	if not ctx then return nil, err end
	local data = ctx:get_string("ban")
	err = ctx:finalize()
	if err then return nil, err end
	if not data then return nil end
	local ban = core.deserialize(data)
	if ban and ban.expiry and ban.expiry <= os.time() then
		-- expired – delete
		local ctx2, err2 = ipdb_ctx(name)
		if ctx2 then
			ctx2:set_string("ban", nil)
			ctx2:finalize()
		end
		return nil
	end
	return ban
end
local function set_ip_ban(name, ban)
	local ctx, err = ipdb_ctx(name)
	if not ctx then return false, err or "Player not known to ipdb" end
	err = ctx:set_string("ban", core.serialize(ban))
	err = err or ctx:finalize()
	if err then return false, err end
	return true
end
local function clear_ip_ban(name)
	local ctx, err = ipdb_ctx(name)
	if ctx then
		ctx:set_string("ban", nil)
		ctx:finalize()
	end
end

-- IP mute
local function get_ip_mute(name)
	local ctx, err = ipdb_ctx(name)
	if not ctx then return nil, err end
	local data = ctx:get_string("mute")
	err = ctx:finalize()
	if err then return nil, err end
	if not data then return nil end
	local mute = core.deserialize(data)
	if mute and mute.expiry and mute.expiry <= os.time() then
		local ctx2, err2 = ipdb_ctx(name)
		if ctx2 then
			ctx2:set_string("mute", nil)
			ctx2:finalize()
		end
		return nil
	end
	return mute
end
local function set_ip_mute(name, mute)
	local ctx, err = ipdb_ctx(name)
	if not ctx then return false, err or "Player not known to ipdb" end
	err = ctx:set_string("mute", core.serialize(mute))
	err = err or ctx:finalize()
	if err then return false, err end
	return true
end
local function clear_ip_mute(name)
	local ctx, err = ipdb_ctx(name)
	if ctx then
		ctx:set_string("mute", nil)
		ctx:finalize()
	end
end

-- IP log
local function get_ip_log(name)
	local ctx, err = ipdb_ctx(name)
	if not ctx then return {} end
	local data = ctx:get_string("log")
	ctx:finalize()
	return data and core.deserialize(data) or {}
end
local function add_ip_log(name, entry)
	local ctx, err = ipdb_ctx(name)
	if not ctx then return end
	local log = get_ip_log(name)
	table.insert(log, 1, entry)
	if #log > 100 then
		local new = {}
		for i=1,100 do new[i] = log[i] end
		log = new
	end
	ctx:set_string("log", core.serialize(log))
	ctx:finalize()
end

-- Lightweight lists of active IP bans/mutes for listing (stored in core storage)
local function get_ip_ban_list()
	local data = storage:get_string("ip_ban_list")
	return data ~= "" and core.deserialize(data) or {}
end
local function save_ip_ban_list(list)
	storage:set_string("ip_ban_list", core.serialize(list))
end
local function get_ip_mute_list()
	local data = storage:get_string("ip_mute_list")
	return data ~= "" and core.deserialize(data) or {}
end
local function save_ip_mute_list(list)
	storage:set_string("ip_mute_list", core.serialize(list))
end

-- --------------------------------------------------------------------------
-- Public API
-- --------------------------------------------------------------------------
simplemod = {}
simplemod.log_message_to_discord = log_message_to_discord

-- Name ban
function simplemod.ban_name(target, source, reason, duration_sec)
	local bans = get_name_bans()
	if bans[target] then return false, "Already name‑banned" end
	local ban = {
		source = source,
		reason = reason or "",
		time = os.time(),
		expiry = duration_sec and duration_sec > 0 and os.time() + duration_sec or nil,
	}
	bans[target] = ban
	save_name_bans(bans)
	add_name_log(target, {
		type = "ban", scope = "name", target = target, source = source,
		reason = reason, duration = duration_sec, time = os.time()
	})
	-- Kick if online
	local player = core.get_player_by_name(target)
	if player then
		local msg = "You have been banned" .. (reason ~= "" and ": "..reason or "")
		core.kick_player(target, msg)
	end
	return true
end
function simplemod.unban_name(target, source, reason)
	local bans = get_name_bans()
	if not bans[target] then return false, "Not name‑banned" end
	bans[target] = nil
	save_name_bans(bans)
	add_name_log(target, {
		type = "unban", scope = "name", target = target, source = source,
		reason = reason or "", time = os.time()
	})
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
	local mute = {
		source = source,
		reason = reason or "",
		time = os.time(),
		expiry = duration_sec and duration_sec > 0 and os.time() + duration_sec or nil,
	}
	mutes[target] = mute
	save_name_mutes(mutes)
	add_name_log(target, {
		type = "mute", scope = "name", target = target, source = source,
		reason = reason, duration = duration_sec, time = os.time()
	})
	return true
end
function simplemod.unmute_name(target, source, reason)
	local mutes = get_name_mutes()
	if not mutes[target] then return false, "Not name‑muted" end
	mutes[target] = nil
	save_name_mutes(mutes)
	add_name_log(target, {
		type = "unmute", scope = "name", target = target, source = source,
		reason = reason or "", time = os.time()
	})
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
	local ban = {
		source = source,
		reason = reason or "",
		time = os.time(),
		expiry = duration_sec and duration_sec > 0 and os.time() + duration_sec or nil,
	}
	local ok, err = set_ip_ban(target, ban)
	if not ok then return false, err end
	-- Update list
	local list = get_ip_ban_list()
	list[target] = ban
	save_ip_ban_list(list)
	add_ip_log(target, {
		type = "ban", scope = "ip", target = target, source = source,
		reason = reason, duration = duration_sec, time = os.time()
	})
	-- Kick player if online
	local player = core.get_player_by_name(target)
	if player then
		local msg = "Your IP has been banned" .. (reason ~= "" and ": "..reason or "")
		core.kick_player(target, msg)
	end
	return true
end
function simplemod.unban_ip(target, source, reason)
	local existing, err = get_ip_ban(target)
	if err then return false, err end
	if not existing then return false, "Not IP‑banned" end
	clear_ip_ban(target)
	local list = get_ip_ban_list()
	list[target] = nil
	save_ip_ban_list(list)
	add_ip_log(target, {
		type = "unban", scope = "ip", target = target, source = source,
		reason = reason or "", time = os.time()
	})
	return true
end
function simplemod.is_banned_ip(target)
	local ban, err = get_ip_ban(target)
	return ban ~= nil
end

-- IP mute
function simplemod.mute_ip(target, source, reason, duration_sec)
	local existing, err = get_ip_mute(target)
	if err then return false, err end
	if existing then return false, "Already IP‑muted" end
	local mute = {
		source = source,
		reason = reason or "",
		time = os.time(),
		expiry = duration_sec and duration_sec > 0 and os.time() + duration_sec or nil,
	}
	local ok, err = set_ip_mute(target, mute)
	if not ok then return false, err end
	local list = get_ip_mute_list()
	list[target] = mute
	save_ip_mute_list(list)
	add_ip_log(target, {
		type = "mute", scope = "ip", target = target, source = source,
		reason = reason, duration = duration_sec, time = os.time()
	})
	return true
end
function simplemod.unmute_ip(target, source, reason)
	local existing, err = get_ip_mute(target)
	if err then return false, err end
	if not existing then return false, "Not IP‑muted" end
	clear_ip_mute(target)
	local list = get_ip_mute_list()
	list[target] = nil
	save_ip_mute_list(list)
	add_ip_log(target, {
		type = "unmute", scope = "ip", target = target, source = source,
		reason = reason or "", time = os.time()
	})
	return true
end
function simplemod.is_muted_ip(target)
	local mute, err = get_ip_mute(target)
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
ipdb.register_on_login(function(name, ip)
	if simplemod.is_banned_name(name) then
		local ban = get_name_bans()[name]
		return "You are banned" .. (ban.reason ~= "" and ": "..ban.reason or "")
	end
	if simplemod.is_banned_ip(name) then
		local ban = get_ip_ban(name)
		return "Your IP is banned" .. (ban.reason ~= "" and ": "..ban.reason or "")
	end
end)

local function get_active_mute(name)
	if simplemod.is_muted_name(name) then
		return "name", get_name_mutes()[name]
	end
	if simplemod.is_muted_ip(name) then
		local mute = get_ip_mute(name)
		if mute then
			return "ip", mute
		end
	end
end

core.register_chatcommand("smca", {
	params = "<player_name> <on|off>",
	description = "Enable or disable a muted player's access to mute-chat log visible to moderators.",
	privs = {pmute=true},
	func = function(player_name, param)
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
	local duration = time_str and parse_time(time_str) or 0
	local expanded_reason = expand_reason(reason)

	local priv = is_mute and "pmute" or "ban"
	if not core.check_player_privs(name, {[priv]=true}) then
		return false, "Insufficient privileges"
	end

	if scope == "name" then
		if is_mute then
			return simplemod.mute_name(target, name, expanded_reason, duration)
		else
			return simplemod.ban_name(target, name, expanded_reason, duration)
		end
	else
		if is_mute then
			return simplemod.mute_ip(target, name, expanded_reason, duration)
		else
			return simplemod.ban_ip(target, name, expanded_reason, duration)
		end
	end
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

	if scope == "name" then
		if is_mute then
			return simplemod.unmute_name(target, name, expanded_reason)
		else
			return simplemod.unban_name(target, name, expanded_reason)
		end
	else
		if is_mute then
			return simplemod.unmute_ip(target, name, expanded_reason)
		else
			return simplemod.unban_ip(target, name, expanded_reason)
		end
	end
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
	func = function(name)
		local name_bans = get_name_bans()
		local ip_bans = get_ip_ban_list()
		local lines = {"Name bans:"}
		for p,d in pairs(name_bans) do
			local exp = d.expiry and " until "..os.date("%Y-%m-%d %H:%M", d.expiry) or ""
			table.insert(lines, string.format("  %s: %s (by %s)%s", p, d.reason, d.source, exp))
		end
		table.insert(lines, "IP bans:")
		for p,d in pairs(ip_bans) do
			local exp = d.expiry and " until "..os.date("%Y-%m-%d %H:%M", d.expiry) or ""
			table.insert(lines, string.format("  %s: %s (by %s)%s", p, d.reason, d.source, exp))
		end
		if #lines == 2 then table.insert(lines, "  (none)") end
		return true, table.concat(lines, "\n")
	end,
})

-- List active mutes
core.register_chatcommand("sbmutelist", {
	description = "List all active mutes (name and IP)",
	privs = {pmute=true},
	func = function(name)
		local name_mutes = get_name_mutes()
		local ip_mutes = get_ip_mute_list()
		local lines = {"Name mutes:"}
		for p,d in pairs(name_mutes) do
			local exp = d.expiry and " until "..os.date("%Y-%m-%d %H:%M", d.expiry) or ""
			table.insert(lines, string.format("  %s: %s (by %s)%s", p, d.reason, d.source, exp))
		end
		table.insert(lines, "IP mutes:")
		for p,d in pairs(ip_mutes) do
			local exp = d.expiry and " until "..os.date("%Y-%m-%d %H:%M", d.expiry) or ""
			table.insert(lines, string.format("  %s: %s (by %s)%s", p, d.reason, d.source, exp))
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
				line = line .. " for " .. time_to_string(e.duration)
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

	-- Handle action buttons
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
		local duration = duration_str ~= "" and parse_time(duration_str) or 0

		local priv = (fields.action_mute or fields.action_unmute) and "pmute" or "ban"
		if not core.check_player_privs(name, {[priv]=true}) then
			core.chat_send_player(name, "Insufficient privileges")
			show_gui(name, "4", "", target, scope, template_key, duration_str)
			return
		end

		local success, msg
		if fields.action_ban then
			if scope == "name" then
				success, msg = simplemod.ban_name(target, name, reason, duration)
			else
				success, msg = simplemod.ban_ip(target, name, reason, duration)
			end
		elseif fields.action_mute then
			if scope == "name" then
				success, msg = simplemod.mute_name(target, name, reason, duration)
			else
				success, msg = simplemod.mute_ip(target, name, reason, duration)
			end
		elseif fields.action_unban then
			if scope == "name" then
				success, msg = simplemod.unban_name(target, name, reason)
			else
				success, msg = simplemod.unban_ip(target, name, reason)
			end
		elseif fields.action_unmute then
			if scope == "name" then
				success, msg = simplemod.unmute_name(target, name, reason)
			else
				success, msg = simplemod.unmute_ip(target, name, reason)
			end
		end

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
				local exp = d.expiry and " until "..os.date("%Y-%m-%d %H:%M", d.expiry) or ""
				table.insert(items, ("[Name] %s: %s (by %s)%s"):format(p, d.reason, d.source, exp))
			end
			for p,d in pairs(get_ip_ban_list()) do
				local exp = d.expiry and " until "..os.date("%Y-%m-%d %H:%M", d.expiry) or ""
				table.insert(items, ("[IP]   %s: %s (by %s)%s"):format(p, d.reason, d.source, exp))
			end
		elseif tab == "2" then  -- Active Mutes
			for p,d in pairs(get_name_mutes()) do
				local exp = d.expiry and " until "..os.date("%Y-%m-%d %H:%M", d.expiry) or ""
				table.insert(items, ("[Name] %s: %s (by %s)%s"):format(p, d.reason, d.source, exp))
			end
			for p,d in pairs(get_ip_mute_list()) do
				local exp = d.expiry and " until "..os.date("%Y-%m-%d %H:%M", d.expiry) or ""
				table.insert(items, ("[IP]   %s: %s (by %s)%s"):format(p, d.reason, d.source, exp))
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
						line = line .. " for " .. time_to_string(e.duration)
					end
					table.insert(items, line)
				end
			else
				table.insert(items, "Enter a player name and click View Log")
			end
		elseif tab == "4" then
			-- Actions tab: we don't populate items, just show the action form (handled above)
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
