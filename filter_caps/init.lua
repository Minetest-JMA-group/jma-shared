-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2023 Marko Petrović

local get_player_by_name = core.get_player_by_name

if not core.registered_privileges.filtering then
	core.register_privilege("filtering", "Filter manager")
end

local caps_space = 2
local caps_max = 2
local whitelist = {}
local shareddb_obj = shareddb.get_mod_storage()
assert(shareddb_obj)
local function load_settings(key)
	local ctx = shareddb_obj:get_context()
	if not ctx then
		return
	end
	if not key or key == "caps_space" then
		local space_str = ctx:get_string("caps_space")
		caps_space = space_str and tonumber(space_str) or 2
	end

	if not key or key == "caps_max" then
		local max_str = ctx:get_string("caps_max")
		caps_max = max_str and tonumber(max_str) or 2
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

filter_caps = {}

function filter_caps.parse(name, message)
	if type(message) ~= "string" or message == "" then
		return ""
	end

	local processed = {}
	local curr_caps_space = caps_space + 1

	for word in message:gmatch("[^ ]+") do
		if get_player_by_name(word) then
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
	"dump: Print the current whitelist content",
	"add <word>: Add new word to the whitelist",
	"rm <word>: Remove word from the whitelist",
}, "\n")

local function save_value(key, value, oldctx)
	local ctx = oldctx or shareddb_obj:get_context()
	if not ctx then
		return "shareddb is not available"
	end

	local ok, err = ctx:set_string(key, value)
	if not ok then
		return "Failed to save: " .. tostring(err)
	end
	ok, err = ctx:finalize()
	if not ok then
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

local function set_setting(setting, param)
	local value = parse_int(param)
	if not value then
		local cur
		if setting == "capsMax" then cur = caps_max else cur = caps_space end
		return false, (setting.." is currently at value: %d\nYou have to enter a valid number to change it"):format(cur)
	end
	local err = save_value(setting, value)
	if err then return false, err end
	local numvalue = tonumber(value) or 2
	if setting == "capsMax" then caps_max = numvalue else caps_space = numvalue end
	return true, ("capsSpace set to: %s"):format(value)
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