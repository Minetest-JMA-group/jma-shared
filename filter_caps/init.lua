-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2023 Marko Petrović

local get_player_by_name = core.get_player_by_name

if not core.registered_privileges.filtering then
	core.register_privilege("filtering", "Filter manager")
end

local caps_space = 2
local caps_max = 2
local caps_wrap = 2
local whitelist = {}
local shareddb_obj = shareddb.get_mod_storage()
local function load_settings(key)
	local ctx = shareddb_obj:get_context()
	if not ctx then
		return
	end
	if not key or key == "capsSpace" then
		local space_str = ctx:get_string("capsSpace")
		caps_space = space_str and tonumber(space_str) or 2
	end

	if not key or key == "capsMax" then
		local max_str = ctx:get_string("capsMax")
		caps_max = max_str and tonumber(max_str) or 2
	end

	if not key or key == "capsWrap" then
		local wrap_str = ctx:get_string("capsWrap")
		caps_wrap = wrap_str and tonumber(wrap_str) or 2
	end

	if not key or key == "whitelist" then
		local wl_str = ctx:get_string("whitelist")
		whitelist = wl_str and core.deserialize(wl_str) or {}
	end

	ctx:finalize()
end
load_settings()
shareddb.register_listener(load_settings)

local utf8_lower = utf8_simple.lower
local utf8_chars = utf8_simple.chars
local utf8_sub = utf8_simple.sub
local utf8_codepoint = utf8_simple.codepoint

-- Allowed player name characters, mirrored from the engine's
-- PLAYERNAME_ALLOWED_CHARS define
local player_name_chars = {}
for _, char in utf8_chars("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_АБВГДЂЕЖЗИЈКЛЉМНЊОПРСТЋУФХЦЧЏШабвгдђежзијклљмнњопрстћуфхцчџџшЁёЙйЩщЪъЫыЬьЭэЮюЯя") do
	player_name_chars[utf8_codepoint(char)] = true
end

local function clamp_uppercase(word)
	local uppercase_count = 0
	local changed
	local out = {}
	for _, char in utf8_chars(word) do
		local lower_char = utf8_lower(char)
		if lower_char ~= char then
			uppercase_count = uppercase_count + 1
			if uppercase_count > caps_max then
				char = lower_char
				changed = true
			end
		end
		out[#out + 1] = char
	end

	if changed then
		return table.concat(out)
	end
	return word
end

-- Strip up to caps_wrap characters that aren't valid player name characters
-- from each side of a word, so e.g. "@bob", "bob!" or "(bob,)" match
local function strip_name_wrap(word)
	local stripped = 0
	while stripped < caps_wrap do
		local first = utf8_sub(word, 1, 1)
		if first == "" or player_name_chars[utf8_codepoint(first)] then
			break
		end
		word = utf8_sub(word, 2)
		stripped = stripped + 1
	end
	stripped = 0
	while stripped < caps_wrap do
		local last = utf8_sub(word, -1)
		if last == "" or player_name_chars[utf8_codepoint(last)] then
			break
		end
		word = utf8_sub(word, 1, -2)
		stripped = stripped + 1
	end
	return word
end

filter_caps = {}

function filter_caps.parse(name, message)
	if type(message) ~= "string" or message == "" then
		return ""
	end

	local processed = {}
	local curr_caps_space = caps_space + 1

	for word in message:gmatch("[^ ]+") do
		local candidate = strip_name_wrap(word)
		if get_player_by_name(candidate) then
			processed[#processed + 1] = word
		else
			local lower_word = utf8_lower(word)
			if whitelist[lower_word] then
				processed[#processed + 1] = word
			else
				if curr_caps_space < caps_space then
					if lower_word == word then
						curr_caps_space = curr_caps_space + 1
					else
						curr_caps_space = 0
					end
					processed[#processed + 1] = lower_word
				else
					if lower_word == word then
						curr_caps_space = curr_caps_space + 1
						processed[#processed + 1] = word
					else
						curr_caps_space = 0
						processed[#processed + 1] = clamp_uppercase(word)
					end
				end
			end
		end
	end

	return table.concat(processed, " ")
end

local registered_on_chat_message = {}

function filter_caps.register_on_chat_message(func)
	table.insert(registered_on_chat_message, func)
end

local usage_lines = table.concat({
	"Invalid usage. Usage: filter_caps <command> [arg]",
	"capsSpace <int>: Set the minimal number of words between two capitalized words",
	"capsMax <int>: Set the maximal number of capital letters in one word",
	"capsWrap <int>: Set the maximal number of non-name characters around player names",
	"dump: Print the current whitelist content",
	"add <word>: Add new word to the whitelist",
	"rm <word>: Remove word from the whitelist",
}, "\n")

local function save_value(key, value, oldctx)
	local ctx = oldctx or shareddb_obj:get_context()
	if not ctx then
		return "shareddb is not available"
	end

	local err = ctx:set_string(key, value)
	err = err or ctx:finalize()
	if err then
		return "Failed to save: " .. tostring(err)
	end
end

local function parse_int(param)
	if type(param) ~= "string" or param == "" then
		return nil
	end
	if not param:match("^%d+$") then
		return nil
	end
	return param
end

local caps_settings = {
	capsSpace = {key = "capsSpace", get = function() return caps_space end, set = function(v) caps_space = v end},
	capsMax = {key = "capsMax", get = function() return caps_max end, set = function(v) caps_max = v end},
	capsWrap = {key = "capsWrap", get = function() return caps_wrap end, set = function(v) caps_wrap = v end},
}

local function set_setting(setting, param)
	local s = caps_settings[setting]
	if not s then
		return false, "Unknown setting: " .. setting
	end
	local value = parse_int(param)
	if not value then
		return false, (setting.." is currently at value: %d\nYou have to enter a valid number to change it"):format(s.get())
	end
	local err = save_value(s.key, value)
	if err then return false, err end
	s.set(tonumber(value))
	return true, (setting.." set to: %s"):format(value)
end

local function add_to_whitelist(_, param)
	if not param or param == "" then
		return false, "You can't add empty word to the whitelist..."
	end
	param = utf8_lower(param)

	local ctx = shareddb_obj:get_context()
	if not ctx then
		return false, "shareddb is not available"
	end

	-- Read current whitelist inside the transaction
	local wl_str, err = ctx:get_string("whitelist")
	if err then return false, err end
	local wl = wl_str and core.deserialize(wl_str) or whitelist
	wl[param] = true
	err = save_value("whitelist", core.serialize(wl), ctx)
	if err then return false, err end

	whitelist[param] = true   -- update cache
	return true, "Added to whitelist: " .. param
end

local function remove_from_whitelist(_, param)
	if not param or param == "" then
		return false, "You have to enter a word to remove it from the whitelist"
	end
	param = utf8_lower(param)

	local ctx = shareddb_obj:get_context()
	if not ctx then
		return false, "shareddb is not available"
	end

	local wl_str, err = ctx:get_string("whitelist")
	if err then return false, err end
	local wl = wl_str and core.deserialize(wl_str) or whitelist
	if not wl[param] then
		ctx:finalize()
		return false, ('Word "%s" hasn\'t existed in the whitelist'):format(param)
	end
	wl[param] = nil
	err = save_value("whitelist", core.serialize(wl), ctx)
	if err then return false, err end

	whitelist[param] = nil
	return true, ('Word "%s" removed from the whitelist'):format(param)
end

local function dump_whitelist()
	local lines = {"Dumping filter_caps whitelist..."}
	for word in pairs(whitelist) do
		lines[#lines + 1] = word
	end
	return true, table.concat(lines, "\n")
end

local function filter_caps_console(name, param)
	local tokens = {}
	for token in param:gmatch("[^ ]+") do
		tokens[#tokens + 1] = token
	end
	if #tokens == 0 then
		return false, usage_lines
	end
	local command = tokens[1]
	local arg = tokens[2] or ""
	if command == "add" then
		return add_to_whitelist(name, arg)
	end
	if command == "rm" then
		return remove_from_whitelist(name, arg)
	end
	if command == "dump" then
		return dump_whitelist()
	end
	if command == "capsMax" then
		return set_setting("capsMax", arg)
	end
	if command == "capsSpace" then
		return set_setting("capsSpace", arg)
	end
	if command == "capsWrap" then
		return set_setting("capsWrap", arg)
	end
	return false, usage_lines
end

core.register_chatcommand("filter_caps", {
	params = "<command> [arg]",
	description = "filter_caps console",
	privs = {filtering = true},
	func = filter_caps_console,
})

core.register_on_chat_message(function(name, message)
	if #registered_on_chat_message == 0 then
		return false
	end

	message = filter_caps.parse(name, message)
	for _, func in ipairs(registered_on_chat_message) do
		if func(name, message) then
			return true
		end
	end
end)