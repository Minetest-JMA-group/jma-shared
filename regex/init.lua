-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

local rex = algorithms.require("rex_pcre2")
regex = {}

if not rex then
	core.log("warning", "[regex]: rex_pcre2 not available")
	regex.create = function(options) return nil, "rex_pcre2 not available" end
	return
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

-- Return a regex context or nil and error
-- options.storage: modstorage (local or shareddb) object for storing patterns
-- options.path: string, full main path to the regex list file
-- options.save_path: string, full path to where the regex list file will be saved, and reloaded from if it exists there
-- options.storage_key: string, storage key name (default: options.list_name)
-- options.list_name: string, name of the list (e.g., "blacklist", "whitelist", default "regex_list")
-- options.help_prefix: string, prefix to show before help text
-- options.logger: function(level, message), custom logger (default: core.log wrapper)
function regex.create(options)
	options = options or {}

	if not options.storage or not options.path then
		return nil, "storage object and path are required"
	end

	local context = {
		patterns = {},
		compiled_patterns = {},
		last_match = "",
		list_name = options.list_name or "regex_list",
		storage_key = options.storage_key or options.list_name,
		help_prefix = options.help_prefix or "",
		logger = options.logger or function(level, message)
			core.log(level, "[regex] " .. message)
		end,
		storage = options.storage,
		path = options.path,
		save_path = options.save_path or options.path
	}

	local template = [[
export: Export $LIST to a file in mod folder
help: Print this help menu
dump: Dump current $LIST to chat
last: Get the regex pattern that was last matched from $LIST
reload: Reload $LIST from file in mod folder
add <regex>: Add regex to $LIST
rm <regex>: Remove regex from $LIST]]
	context.internal_help = template:gsub("%$LIST", context.list_name)

	function context:compile()
		local valid_patterns = {}
		self.compiled_patterns = {}

		for _, pattern in ipairs(self.patterns) do
			local ok, matcher = pcall(rex.new, pattern, "iu")
			if ok and matcher then
				table.insert(valid_patterns, pattern)
				table.insert(self.compiled_patterns, matcher)
			else
				self.logger("warning", "Skipping invalid regex: \"" .. pattern .. "\" (" .. tostring(matcher) .. ")")
			end
		end

		self.patterns = valid_patterns
	end

	function context:load()
		local storage
		if self.storage.get_context then
			storage = self.storage:get_context()
		else
			storage = self.storage
		end
		if not storage then return self:load_file() end

		local serialized = storage:get_string(self.storage_key)
		if storage.finalize then storage:finalize() end
		if serialized ~= "" then
			local decoded = core.deserialize(serialized)
			if type(decoded) == "table" then
				self.patterns = sanitize_patterns(decoded)
				self:compile()
				return true
			end
		end

		return self:load_file()
	end

	function context:save()
		local storage, err
		if self.storage.get_context then
			storage, err = self.storage:get_context()
		else
			storage = self.storage
		end
		if not storage then return false, err end
		storage:set_string(self.storage_key, core.serialize(self.patterns))
		if storage.finalize then storage:finalize() end
		return true
	end

	function context:load_file()
		local file = io.open(self.save_path, "r")
		if not file then
			file = io.open(self.path, "r")
			if not file then
				return false, "Could not open file: " .. self.path
			end
		end

		local lines = {}
		for line in file:lines() do
			line = line:gsub("\r", ""):gsub("\n", "")
			if line ~= "" then
				table.insert(lines, line)
			end
		end
		file:close()

		self.patterns = sanitize_patterns(lines)
		self:compile()
		return true
	end

	function context:save_file()
		local data = table.concat(self.patterns, "\n")
		if data ~= "" then
			data = data .. "\n"
		end

		local ok = core.safe_file_write(self.save_path, data)
		if not ok then
			return false, "Failed to write to file"
		end
		return true
	end

	function context:match(text)
		for i, matcher in ipairs(self.compiled_patterns) do
			if matcher:match(text) then
				self.last_match = self.patterns[i]
				return true
			end
		end
		return false
	end

	function context:add(pattern)
		local ok, matcher = pcall(rex.new, pattern, "iu")
		if not ok or not matcher then
			return false, "Invalid regex: " .. tostring(matcher)
		end

		table.insert(self.patterns, 1, pattern)
		table.insert(self.compiled_patterns, 1, matcher)

		self:save()
		return true
	end

	function context:remove(pattern)
		local indices_to_remove = {}

		-- First collect indices to remove
		for i, p in ipairs(self.patterns) do
			if p == pattern then
				table.insert(indices_to_remove, i)
			end
		end

		-- Remove from highest to lowest index to avoid shifting issues
		for i = #indices_to_remove, 1, -1 do
			local index = indices_to_remove[i]
			table.remove(self.patterns, index)
			table.remove(self.compiled_patterns, index)
		end

		local count = #indices_to_remove
		if count > 0 then
			self:save()
		end
		return count
	end

	function context:get_patterns()
		return self.patterns
	end

	function context:get_last_match()
		return self.last_match
	end

	function context:handle_command(name, param)
		param = param or ""

		local cmd = param:match("^%s*(%S+)")

		if cmd == "add" then
			local regex = param:sub(#cmd + 1):match("^%s*(.-)%s*$")
			if not regex or regex == "" then
				return true, "Usage: add <regex>"
			end

			local ok, err = self:add(regex)
			if ok then
				self.logger("action", string.format("%s added pattern: %s", name, regex))
				return true, "Pattern added"
			else
				return true, err
			end

		elseif cmd == "rm" then
			local regex = param:sub(#cmd + 1):match("^%s*(.-)%s*$")
			if not regex or regex == "" then
				return true, "Usage: rm <regex>"
			end

			local count = self:remove(regex)
			self.logger("action", string.format("%s removed %d pattern(s): %s", name, count, regex))
			return true, "Removed " .. count .. " pattern(s)"

		elseif cmd == "dump" then
			if #self.patterns == 0 then
				return true, "No patterns"
			end

			local lines = {}
			for _, pattern in ipairs(self.patterns) do
				table.insert(lines, pattern)
			end
			return true, table.concat(lines, "\n")

		elseif cmd == "last" then
			local last = self:get_last_match()
			if last == "" then
				return true, "No pattern matched yet"
			end
			return true, "Last match: " .. last

		elseif cmd == "reload" then
			local ok, err = self:load_file()
			if ok then
				self.logger("action", name .. " reloaded patterns from file")
				return true, "Patterns reloaded"
			end
			return true, err or "Failed to reload"

		elseif cmd == "export" then
			local target = param:sub(#cmd + 1):match("^%s*(%S+)%s*$")
			if not target or target ~= self.storage_key then
				return true, "Usage: export " .. self.storage_key
			end

			local ok, err = self:save_file()
			if ok then
				self.logger("action", name .. " exported patterns to file")
				return true, "Patterns exported"
			end
			return true, err or "Failed to export"

		elseif cmd == "help" then
			return true, self.help_prefix .. self.internal_help
		end

		return false, nil
	end

	context:load()

	return context
end