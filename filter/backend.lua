-- SPDX-License-Identifier: GPL-3.0-or-later

local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)
local storage = core.get_mod_storage()
local rex = algorithms.require("rex_pcre2")
local ie = algorithms.request_insecure_environment()
local io_open = (ie and ie.io and ie.io.open) or (io and io.open)

assert(rex, "[filter] rex_pcre2 is required but could not be loaded")
assert(io_open, "[filter] Insecure environment required for file I/O. Add filter to secure.trusted_mods")

local VERSION_KEY = "version"
local VERSION = 2
local BLACKLIST_KEY = "blacklist"
local blacklist = {}
local compiled_blacklist = {}
local last_match = ""

local mode = storage:contains("mode") and storage:get_int("mode") or 1
if mode ~= 0 then
	mode = 1
end
storage:set_int("mode", mode)

local function log(level, message)
	core.log(level, "[filter] " .. message)
end

local function sanitize_patterns(list)
	local sanitized = {}
	for _, pattern in ipairs(list or {}) do
		if type(pattern) == "string" and pattern ~= "" then
			table.insert(sanitized, pattern)
		end
	end
	return sanitized
end

local function persist_blacklist()
	storage:set_string(BLACKLIST_KEY, core.serialize(blacklist))
end

local function compile_blacklist()
	compiled_blacklist = {}
	last_match = ""
	for _, pattern in ipairs(blacklist) do
		local ok, matcher = pcall(rex.new, pattern, "iu")
		if ok and matcher then
			table.insert(compiled_blacklist, { pattern = pattern, matcher = matcher })
		else
			log("warning", "Regex error: " .. tostring(matcher) .. ". Skipping invalid regex: " .. pattern)
		end
	end
end

local function read_blacklist_file()
	local path = modpath .. "/blacklist"
	local file = io_open(path, "r")
	if not file then
		return nil, "Error opening filter blacklist file at " .. path
	end
	local lines = {}
	for line in file:lines() do
		line = line:gsub("\r", "")
		if line ~= "" then
			table.insert(lines, line)
		end
	end
	file:close()
	return lines
end

local function migrate_storage()
	local raw_blacklist = storage:get_string(BLACKLIST_KEY)
	local decoded = {}
	if raw_blacklist ~= "" then
		local ok = core.from_json(raw_blacklist)
		if type(ok) == "table" then
			decoded = sanitize_patterns(ok)
		else
			log("warning", "Legacy blacklist JSON failed to parse. Falling back to file.")
		end
	end
	if #decoded == 0 then
		local from_file, err = read_blacklist_file()
		if from_file then
			decoded = from_file
		else
			log("warning", err or "Unknown error while reading blacklist file")
		end
	end

	storage:set_string("whitelist", "")
	storage:set_string("words", "")
	storage:set_string("maxLen", "")
	storage:set_string("max_len", "")

	blacklist = decoded
	persist_blacklist()
	storage:set_int(VERSION_KEY, VERSION)
end

local function load_blacklist()
	if storage:get_int(VERSION_KEY) ~= VERSION then
		migrate_storage()
	else
		local serialized = storage:get_string(BLACKLIST_KEY)
		if serialized ~= "" then
			local decoded = core.deserialize(serialized)
			if type(decoded) == "table" then
				blacklist = sanitize_patterns(decoded)
			else
				log("warning", "Failed to deserialize blacklist from storage. Falling back to file.")
				local from_file, err = read_blacklist_file()
				if from_file then
					blacklist = from_file
					persist_blacklist()
				else
					log("warning", err or "Unknown error while reading blacklist file")
					blacklist = {}
				end
			end
		else
			local from_file, err = read_blacklist_file()
			if from_file then
				blacklist = from_file
				persist_blacklist()
			else
				log("warning", err or "Unknown error while reading blacklist file")
				blacklist = {}
			end
		end
	end
	compile_blacklist()
	log("action", "Loaded " .. tostring(#compiled_blacklist) .. " blacklist entries")
end

local function export_blacklist_to_file()
	local data = table.concat(blacklist, "\n")
	if data ~= "" then
		data = data .. "\n"
	end
	local ok = core.safe_file_write(modpath .. "/blacklist", data)
	if not ok then
		return false, "core.safe_file_write failed"
	end
	return true
end

local function reload_blacklist_from_file()
	local from_file, err = read_blacklist_file()
	if not from_file then
		return false, err
	end
	blacklist = from_file
	persist_blacklist()
	compile_blacklist()
	log("action", "Reloaded blacklist from file with " .. tostring(#compiled_blacklist) .. " entries")
	return true
end

local function remove_regex(pattern)
	local count = 0
	local i = 1
	while i <= #blacklist do
		if blacklist[i] == pattern then
			table.remove(blacklist, i)
			count = count + 1
		else
			i = i + 1
		end
	end
	if count > 0 then
		persist_blacklist()
		compile_blacklist()
	end
	return count
end

load_blacklist()

function filter.is_blacklisted(message)
	for i = 1, #compiled_blacklist do
		local entry = compiled_blacklist[i]
		if entry.matcher:match(message) then
			last_match = entry.pattern
			return true
		end
	end
	return false
end

function filter.export_regex(listname)
	if listname ~= "blacklist" then
		log("warning", "Tried to export a non-existent list: " .. tostring(listname))
		return
	end
	local ok, err = export_blacklist_to_file()
	if not ok then
		log("warning", "Error exporting blacklist to file: " .. tostring(err))
	else
		log("action", "Blacklist exported to file")
	end
end

function filter.get_mode()
	return mode
end

function filter.get_lastreg()
	return last_match or ""
end

local function set_mode(new_mode)
	if new_mode ~= 0 then
		new_mode = 1
	end
	if mode == new_mode then
		return false, "Filter mode already set to " .. (mode == 1 and "Enforcing" or "Permissive")
	end
	mode = new_mode
	storage:set_int("mode", mode)
	return true
end

local function extract_regex_argument(param, command)
	param = param or ""
	local escaped = command:gsub("(%W)", "%%%1")
	local _, finish = param:find("^%s*" .. escaped .. "%s*")
	if not finish then
		return ""
	end
	local regex = param:sub(finish + 1):gsub("^%s+", "")
	return regex
end

local function filter_console(name, param)
	param = param or ""
	local params = {}
	for word in param:gmatch("%S+") do
		table.insert(params, word)
	end

	if #params == 0 then
		return false, "Usage: /filter <command> <args>\nCheck /filter help"
	end

	local cmd = params[1]

	if cmd == "export" then
		if params[2] ~= "blacklist" then
			return false, "Usage: /filter export blacklist"
		end
		local ok, err = export_blacklist_to_file()
		if ok then
			log("action", name .. " exported blacklist to file")
			return true, "blacklist exported successfully to file"
		end
		return false, "Error opening filter's blacklist file."
	end

	if cmd == "getenforce" then
		return true, mode == 1 and "Enforcing" or "Permissive"
	end

	if cmd == "setenforce" then
		if params[2] then
			local value = params[2]:lower()
			if value == "1" or value == "enforcing" then
				local changed, msg = set_mode(1)
				if changed then
					log("action", name .. " set mode to Enforcing")
					return true, "New filter mode: Enforcing"
				end
				return false, msg
			elseif value == "0" or value == "permissive" then
				local changed, msg = set_mode(0)
				if changed then
					log("action", name .. " set mode to Permissive")
					return true, "New filter mode: Permissive"
				end
				return false, msg
			end
		end
		return false, "Usage: /filter setenforce [ Enforcing | Permissive | 1 | 0 ]"
	end

	if cmd == "help" then
		return true, [[The filter works by matching regex patterns from a blacklist with each message.
If a match is found, the message is blocked.

List of possible commands:
export blacklist: Export blacklist to a file in mod folder
getenforce: Get the current filter mode
setenforce <mode>: Set new filter mode
help: Print this help menu
dump: Dump current blacklist to chat
last: Get the regex pattern that was last matched from blacklist
reload: Reload blacklist from file in mod folder
add <regex>: Add regex to blacklist
rm <regex>: Remove regex from blacklist]]
	end

	if cmd == "dump" then
		if #blacklist == 0 then
			return true, "blacklist is empty"
		end
		local lines = { "blacklist contents:" }
		for _, pattern in ipairs(blacklist) do
			table.insert(lines, "\"" .. pattern .. "\"")
		end
		return true, table.concat(lines, "\n")
	end

	if cmd == "last" then
		if last_match == "" then
			return false, "No blacklist regex was matched since server startup."
		end
		return true, "Last blacklist regex: " .. last_match
	end

	if cmd == "reload" then
		local ok, err = reload_blacklist_from_file()
		if ok then
			log("action", name .. " reloaded blacklist from file")
			return true, ""
		end
		return false, err or "Error opening filter's blacklist file."
	end

	if cmd == "add" then
		local regex_param = extract_regex_argument(param, cmd)
		if regex_param == "" then
			return false, "Usage: /filter add <regex>"
		end
		local ok, matcher = pcall(rex.new, regex_param, "iu")
		if not ok or not matcher then
			return false, "Invalid regex: " .. tostring(matcher)
		end
		table.insert(blacklist, 1, regex_param)
		persist_blacklist()
		compile_blacklist()
		log("action", string.format("%s added '%s' to blacklist", name, regex_param))
		return true, "Added '" .. regex_param .. "' to blacklist"
	end

	if cmd == "rm" then
		local regex_param = extract_regex_argument(param, cmd)
		if regex_param == "" then
			return false, "Usage: /filter rm <regex>"
		end
		local count = remove_regex(regex_param)
		log("action", string.format("%s removed '%s' from blacklist. Affected %d entries", name, regex_param, count))
		return true, "Removed " .. count .. " entries from blacklist"
	end

	return false, "Unknown command. Usage: /filter <command> <args>\nCheck /filter help"
end

core.register_chatcommand("filter", {
	description = "filter management console",
	params = "<command> <args>",
	privs = { filtering = true },
	func = filter_console,
})
