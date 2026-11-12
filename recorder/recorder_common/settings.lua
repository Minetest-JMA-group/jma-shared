-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- Cache startup defaults; commands update memory and persist world overrides.
local settings = {}
local storage = core.get_mod_storage()
local definitions, defaults, values, sources, default_sources = {}, {}, {}, {}, {}
local function define(name, default, kind, minimum, maximum)
	definitions[name] = {default = default, kind = kind, min = minimum, max = maximum}
end
for name, default in pairs({max_recordings = 4, diff_budget = 8,
	max_buffered = 20000, retention_count = 0}) do
	define("recorder." .. name, tostring(default), "integer", 0)
end
define("recorder.snapshot_budget", "20000", "integer", 1)
define("recorder.compression_level", "6", "integer", 1, 9)
for name, default in pairs({flush_interval = 2, max_duration = 0, max_size_mb = 0,
	retention_size_mb = 0}) do
	define("recorder." .. name, tostring(default), "number", 0)
end
define("recorder.retention_age", "0", "duration", 0)
define("recorder.directory", "", "string")
define("recorder.disabled_events", "", "events")
for _, name in ipairs({"metadata", "light", "particles", "chat"}) do
	define("recorder." .. name, "true", "boolean")
end
define("replay.max_sessions", "4", "integer", 0)
define("replay.allow_unfinished", "false", "boolean")
define("replay.chat", "true", "boolean")
define("replay.wield_item", "true", "boolean")
for _, name in ipairs({"model", "wield_bone"}) do define("replay." .. name, "", "string") end
for _, name in ipairs({"wield_pos", "wield_rot", "wield_scale"}) do
	define("replay." .. name, "", "vector")
end
define("replay.arena", "", "arena")

local function finite(n) return n and n == n and n ~= math.huge and n ~= -math.huge end
local function validate(key, raw)
	local def = definitions[key]
	if not def then return nil, "Unknown recorder setting: " .. tostring(key) end
	raw = tostring(raw)
	local kind = def.kind
	if kind == "boolean" then
		local b = raw:lower()
		if b == "true" or b == "yes" or b == "1" or b == "on" then return "true" end
		if b == "false" or b == "no" or b == "0" or b == "off" then return "false" end
		return nil, "Expected true or false"
	elseif kind == "number" or kind == "integer" or kind == "duration" then
		local n = tonumber(raw)
		if kind == "duration" and not n then
			local amount, unit = raw:match("^%s*(%d+%.?%d*)%s*([smhdw])%s*$")
			local units = {s = 1, m = 60, h = 3600, d = 86400, w = 604800}
			n = amount and tonumber(amount) * units[unit]
		end
		if not finite(n) or n < def.min or (def.max and n > def.max)
			or (kind == "integer" and n % 1 ~= 0) then
			return nil, "Expected " .. kind .. " >= " .. def.min
				.. (def.max and " and <= " .. def.max or "")
		end
		return tostring(n)
	elseif kind == "vector" or kind == "arena" then
		if raw == "" then return raw end
		local parts = {}
		for token in (raw .. ","):gmatch("(.-),") do
			local n = tonumber(token)
			if not finite(n) then return nil, "Expected comma-separated coordinates" end
			parts[#parts + 1] = n
		end
		local count = kind == "vector" and 3 or 6
		if #parts ~= count then return nil, "Expected " .. count .. " coordinates" end
		if key == "replay.wield_scale" then
			for _, n in ipairs(parts) do if n <= 0 then return nil, "Scale must be positive" end end
		end
		if kind == "arena" then
			for i = 1, 3 do
				if parts[i] > parts[i + 3] then return nil, "Arena minimum exceeds maximum" end
			end
		end
		return table.concat(parts, ",")
	elseif kind == "events" then
		local out = {}
		for event in raw:gmatch("[^,%s]+") do
			out[#out + 1] = event
		end
		return table.concat(out, ",")
	end
	if raw:find("[%z\r\n]") then return nil, "Expected a single line" end
	return raw
end

for key, def in pairs(definitions) do
	local raw = core.settings:get(key)
	local value, err
	if raw ~= nil then value, err = validate(key, raw) end
	if err then core.log("warning", "[recorder] invalid " .. key .. " default: " .. err) end
	defaults[key] = value or def.default
	sources[key] = value ~= nil and "configuration default" or "built-in default"
	default_sources[key] = sources[key]
	local saved = storage:get_string("setting:" .. key)
	-- The prefix distinguishes an explicit empty-string override from absence.
	if saved:sub(1, 1) == "=" then
		local override, override_err = validate(key, saved:sub(2))
		if override ~= nil then
			values[key], sources[key] = override, "world override"
		else
			core.log("warning", "[recorder] invalid stored " .. key .. ": " .. override_err)
		end
	end
	if values[key] == nil then values[key] = defaults[key] end
end

function settings:get(key) assert(definitions[key], "Unknown setting: " .. key); return values[key] end
function settings:get_bool(key) return self:get(key) == "true" end
function settings:set(key, raw)
	local value, err = validate(key, raw)
	if value == nil then return false, err end
	storage:set_string("setting:" .. key, "=" .. value)
	values[key], sources[key] = value, "world override"
	return true
end
function settings:reset(key)
	if not definitions[key] then return false, "Unknown recorder setting: " .. tostring(key) end
	storage:set_string("setting:" .. key, "")
	values[key] = defaults[key]
	-- Reset restores both the cached default and its source.
	sources[key] = default_sources[key]
	return true
end

function settings:snapshot(prefix)
	local out = {}
	for key, value in pairs(values) do
		if key:sub(1, #prefix) == prefix then out[key] = value end
	end
	return out
end
local function describe(key)
	local value = values[key] == "" and '""' or values[key]
	local timing = key:find("retention_", 1, true) and "next cleanup"
		or (key == "recorder.directory" and "next directory lookup"
		or (key:sub(1, 7) == "replay." and "new replays" or "new recordings"))
	return key .. " = " .. value .. " (" .. sources[key] .. "; " .. timing .. ")"
end
function settings.command(param, prefix)
	local action, rest = (param or ""):match("^%s*(%S*)%s*(.-)%s*$")
	local function qualify(key)
		return key:find(".", 1, true) and key or (prefix or "recorder.") .. key
	end
	if action == "" then
		local keys, lines = {}, {}
		for key in pairs(definitions) do keys[#keys + 1] = key end
		table.sort(keys)
		for _, key in ipairs(keys) do lines[#lines + 1] = describe(key) end
		return true, table.concat(lines, "\n")
	end
	local key = qualify(action == "reset" and rest or action)
	if not definitions[key] then return false, "Unknown recorder setting: " .. key end
	if action == "reset" then
		settings:reset(key)
	elseif rest ~= "" then
		local ok, err = settings:set(key, rest == '""' and "" or rest)
		if not ok then return false, err end
	end
	return true, describe(key)
end
core.register_chatcommand("recorder_settings", {
	params = '[<key> [<value>] | reset <key>]',
	description = "Inspect or change persistent recorder world overrides; use full recorder./replay. keys",
	privs = {server = true},
	func = function(_, param) return settings.command(param) end,
})
return settings
