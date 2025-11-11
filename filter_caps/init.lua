-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2023 Marko Petrović

local storage = core.get_mod_storage()
local get_player_by_name = core.get_player_by_name

if not core.registered_privileges.filtering then
	core.register_privilege("filtering", "Filter manager")
end

local function load_int(key, default)
	if storage:contains(key) then
		return storage:get_int(key)
	end
	return default
end

local caps_space = load_int("capsSpace", 2)
local caps_max = load_int("capsMax", 2)

local function load_whitelist()
	if not storage:contains("whitelist") then
		return {}
	end
	local raw = storage:get_string("whitelist")
	if raw == "" then
		return {}
	end

	return core.deserialize(raw)
end

local whitelist = load_whitelist()

local utf8_lower = utf8_simple.lower
local utf8_chars = utf8_simple.chars

local function save_caps_space()
	storage:set_int("capsSpace", caps_space)
end

local function save_caps_max()
	storage:set_int("capsMax", caps_max)
end

local function save_whitelist()
	storage:set_string("whitelist", core.serialize(whitelist))
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

filter_caps = {}

local function parse_int(param)
	if type(param) ~= "string" or param == "" then
		return nil
	end
	if not param:match("^%-?%d+$") then
		return nil
	end
	return tonumber(param)
end

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

local function set_caps_space(name, param)
	local value = parse_int(param)
	if not value then
		return false, ("capsSpace is currently at value: %d\nYou have to enter a valid number to change it"):format(caps_space)
	end
	caps_space = value
	save_caps_space()
	return true, ("capsSpace set to: %d"):format(caps_space)
end

local function set_caps_max(name, param)
	local value = parse_int(param)
	if not value then
		return false, ("capsMax is currently at value: %d\nYou have to enter a valid number to change it"):format(caps_max)
	end
	caps_max = value
	save_caps_max()
	return true, ("capsMax set to: %d"):format(caps_max)
end

local function add_to_whitelist(_, param)
	if not param or param == "" then
		return false, "You can't add empty word to the whitelist..."
	end
	param = utf8_lower(param)
	whitelist[param] = true
	save_whitelist()
	return true, "Added to whitelist: " .. param
end

local function remove_from_whitelist(_, param)
	if not param or param == "" then
		return false, "You have to enter a word to remove it from the whitelist"
	end
	param = utf8_lower(param)
	if not whitelist[param] then
		return false, ('Word "%s" hasn\'t existed in the whitelist'):format(param)
	end
	whitelist[param] = nil
	save_whitelist()
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
		return set_caps_max(name, arg)
	end
	if command == "capsSpace" then
		return set_caps_space(name, arg)
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
