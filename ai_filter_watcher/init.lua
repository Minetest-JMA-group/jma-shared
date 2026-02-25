-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović
---@diagnostic disable: need-check-nil

local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)
local storage = core.get_mod_storage()
local is_essentials = core.global_exists("essentials")

-- These will be overridden from shareddb
local WATCHER_MODE = "enabled"
local SCAN_INTERVAL = 60
local MIN_BATCH_SIZE = 5
local HISTORY_SIZE = 100
local HISTORY_TRACKING_TIME = 86400		-- 24 hours
local TEMPERATURE = nil		-- use API default
local FREQUENCY_PENALTY = nil
local PRESENCE_PENALTY = nil
local DEBUG_ENABLED = false

local PROMPT_READY = false
local message_buffer = {}
local chat_history = {}
local history_index = 1
local history_count = 0
local watcher_stats = { scans_performed = 0, messages_processed = 0, actions_taken = 0, last_scan_time = 0, last_action_time = 0 }
local player_history = {}
local player_history_loaded = false
local system_prompt = ""
local system_prompt_file = modpath .. "/system_prompt.txt"
local is_processing = false
local active_call_id = 0
local active_context = nil

ai_filter_watcher = {
	MODES = { ENABLED = "enabled", PERMISSIVE = "permissive", DISABLED = "disabled" }
}

local modstorage = shareddb.get_mod_storage()

local function set_local_setting(key, value_str)
	if key == "mode" then
		if value_str == "enabled" or value_str == "permissive" or value_str == "disabled" then
			WATCHER_MODE = value_str
		end
	elseif key == "scan_interval" then
		local n = tonumber(value_str)
		if n and n >= 1 and n <= 3600 then SCAN_INTERVAL = n end
	elseif key == "min_batch_size" then
		local n = tonumber(value_str)
		if n and n >= 1 and n <= 100 then MIN_BATCH_SIZE = n end
	elseif key == "history_size" then
		local n = tonumber(value_str)
		if n and n >= 10 and n <= 1000 then HISTORY_SIZE = n end
	elseif key == "history_tracking_time" then
		local n = tonumber(value_str)
		if n and n >= 60 and n <= 2592000 then HISTORY_TRACKING_TIME = n end
	elseif key == "temperature" then
		local n = tonumber(value_str)
		if not n or (n >= 0 and n <= 2) then TEMPERATURE = n end   -- allow nil
	elseif key == "frequency_penalty" then
		local n = tonumber(value_str)
		if not n or (n >= -2 and n <= 2) then FREQUENCY_PENALTY = n end
	elseif key == "presence_penalty" then
		local n = tonumber(value_str)
		if not n or (n >= -2 and n <= 2) then PRESENCE_PENALTY = n end
	elseif key == "debug_enabled" then
		DEBUG_ENABLED = (value_str == "true")
	end
end

local function update_setting_from_db(key)
	local errmsg = "[ai_filter_watcher] shareddb database error, cannot update settings"
	local ctx = modstorage:get_context()
	if not ctx then
		core.log("error", errmsg)
		return
	end

	if key then
		local val, err = ctx:get_string(key)
		if err then
			ctx:finalize()
			core.log("error", errmsg)
			return
		end
		set_local_setting(key, val)
	else
		local keys = {
			"mode", "scan_interval", "min_batch_size", "history_size",
			"history_tracking_time", "temperature", "frequency_penalty",
			"presence_penalty", "debug_enabled"
		}
		for _, k in ipairs(keys) do
			local v, err = ctx:get_string(k)
			if err then
				ctx:finalize()
				core.log("error", errmsg)
				return
			end
			if v ~= nil then
				set_local_setting(k, v)
			end
		end
	end
	ctx:finalize()
end

shareddb.register_listener(update_setting_from_db)

local function load_system_prompt()
	local file = io.open(system_prompt_file, "r")
	if file then
		system_prompt = file:read("*a")
		file:close()
		PROMPT_READY = true
		core.log("action", "[ai_filter_watcher] System prompt loaded from file")
		return true
	else
		core.log("error", "[ai_filter_watcher] System prompt file not found: " .. system_prompt_file)
		system_prompt = ""
		PROMPT_READY = false
		WATCHER_MODE = ai_filter_watcher.MODES.DISABLED
		return false
	end
end

local function abort_current_processing(reason)
	if is_processing and active_context then
		core.log("action", "[ai_filter_watcher] Aborting ongoing AI processing" ..
			(reason and (": " .. reason) or ""))
		active_context:destroy()
		active_context = nil
	end
	is_processing = false
	active_call_id = active_call_id + 1
end

local function load_player_history()
	local data = storage:get("player_history")
	player_history = data and core.deserialize(data) or {}
	player_history_loaded = true
end

local function save_player_history()
	storage:set_string("player_history", core.serialize(player_history))
end

local function cleanup_player_history()
	local now = os.time()
	local cutoff = now - HISTORY_TRACKING_TIME
	local removed = 0
	local to_remove = {}
	for name, hist in pairs(player_history) do
		local new_hist = {}
		for _, e in ipairs(hist) do
			if e.time >= cutoff then
				table.insert(new_hist, e)
			else
				removed = removed + 1
			end
		end
		if #new_hist == 0 then
			table.insert(to_remove, name)
		else
			player_history[name] = new_hist
		end
	end
	for _, name in ipairs(to_remove) do
		player_history[name] = nil
	end
	if removed > 0 then
		save_player_history()
	end
end

local function add_to_player_history(name, typ, dur, reason)
	if not player_history_loaded then load_player_history() end
	player_history[name] = player_history[name] or {}
	table.insert(player_history[name], { time = os.time(), type = typ, duration = dur, reason = reason })
	if #player_history[name] > 50 then
		table.remove(player_history[name], 1)
	end
	save_player_history()
end

local function get_player_moderation_history(name)
	if not player_history_loaded then load_player_history() end
	local now = os.time()
	local cutoff = now - HISTORY_TRACKING_TIME
	local recent = {}
	for _, e in ipairs(player_history[name] or {}) do
		if e.time >= cutoff then
			table.insert(recent, e)
		end
	end
	return recent
end

local function format_player_history(hist)
	if #hist == 0 then
		return "No recent moderation history."
	end
	local lines = {}
	for _, e in ipairs(hist) do
		local ago = os.time() - e.time
		local time_str = algorithms.time_to_string(ago) .. " ago"
		if e.type == "warn" then
			table.insert(lines, ("- Warned %s for: %s"):format(time_str, e.reason))
		elseif e.type == "mute" then
			table.insert(lines, ("- Muted for %d minutes %s for: %s"):format(e.duration or 0, time_str, e.reason))
		end
	end
	return "Recent moderation history:\n" .. table.concat(lines, "\n")
end

local function add_to_history(name, msg)
	if WATCHER_MODE == ai_filter_watcher.MODES.DISABLED then return end
	chat_history[history_index] = { name = name, message = msg, time = os.time() }
	history_index = history_index % HISTORY_SIZE + 1
	if history_count < HISTORY_SIZE then
		history_count = history_count + 1
	end
end

local function get_last_messages(n)
	local count = math.min(n, history_count)
	if count == 0 then return {} end
	local result, idx = {}, 1
	local cur = history_index - 1
	if cur <= 0 then cur = cur + HISTORY_SIZE end
	while idx <= count do
		local entry = chat_history[cur]
		if entry then
			result[idx] = entry
			idx = idx + 1
		end
		cur = cur - 1
		if cur <= 0 then cur = cur + HISTORY_SIZE end
		if cur == history_index then break end
	end
	-- reverse to chronological order
	for i = 1, math.floor(#result / 2) do
		local j = #result - i + 1
		result[i], result[j] = result[j], result[i]
	end
	return result
end

local function format_history(msgs)
	local lines = {}
	for _, m in ipairs(msgs) do
		table.insert(lines, ("[%s] <%s>: %s"):format(os.date("%H:%M", m.time), m.name, m.message))
	end
	return table.concat(lines, "\n")
end

local function process_batch()
	if WATCHER_MODE == ai_filter_watcher.MODES.DISABLED then
		if is_processing then abort_current_processing() end
		return
	end

	if is_processing then
		abort_current_processing("New batch started, aborting old one")
	end

	local batch = message_buffer
	message_buffer = {}
	if #batch == 0 then
		is_processing = false
		return
	end

	active_call_id = active_call_id + 1
	local call_id = active_call_id
	is_processing = true
	watcher_stats.scans_performed = watcher_stats.scans_performed + 1
	watcher_stats.last_scan_time = os.time()
	watcher_stats.messages_processed = watcher_stats.messages_processed + #batch

	core.log("action", ("[ai_filter_watcher] Processing batch of %d messages (call_id: %d)"):format(#batch, call_id))

	local formatted_batch = format_history(batch)
	local context, err = cloudai.get_context()
	if not context then
		core.log("error", ("[ai_filter_watcher] Failed to get AI context for batch %d: %s"):format(call_id, tostring(err)))
		is_processing = false
		return
	end

	if DEBUG_ENABLED and context.set_debug then
		context:set_debug(true)
	end
	if TEMPERATURE then
		context:set_temperature(TEMPERATURE)
	end
	if FREQUENCY_PENALTY then
		context:set_frequency_penalty(FREQUENCY_PENALTY)
	end
	if PRESENCE_PENALTY then
		context:set_presence_penalty(PRESENCE_PENALTY)
	end

	active_context = context
	context:set_system_prompt(system_prompt)
	context:set_max_steps(10)

	context:add_tool({
		name = "get_history",
		func = function(args)
			if type(args) == "string" then
				local first = args:match("-?%d+")
				if not first then return {error = "Missing 'messages' parameter"} end
				args = { messages = first }
			end
			if not args or not args.messages then
				return {error = "Missing 'messages' parameter"}
			end
			local n = tonumber(args.messages)
			if not n or n < 1 or n > 50 then
				return {error = "Number of messages must be between 1 and 50"}
			end
			local hist = get_last_messages(n)
			return { history = format_history(hist), count = #hist }
		end,
		description = "Get additional chat history for context (use ONLY if necessary)",
		strict = false,
		properties = {
			messages = {
				type = "integer",
				description = "Number of previous messages to retrieve",
				minimum = 1,
				maximum = 50
			}
		}
	})

	context:add_tool({
		name = "warn_player",
		func = function(args)
			if type(args) == "string" then return { error = "Invalid JSON string" } end
			if not args or not args.reason then return {error = "Missing 'reason' parameter"} end
			local player_name = args.name
			if not player_name then return {error = "Missing 'name' parameter"} end
			local reason = args.reason
			if WATCHER_MODE == ai_filter_watcher.MODES.ENABLED then
				if not is_essentials then return {error = "Essentials mod not available"} end
				essentials.show_warn_formspec(player_name, reason, "AI Watcher")
				add_to_player_history(player_name, "warn", nil, reason)
			else -- permissive
				local msg = ("[PERMISSIVE] Would have warned player '%s' for: %s"):format(player_name, reason)
				core.log("action", "[ai_filter_watcher] " .. msg)
				relays.send_action_report("**AI Watcher**: %s", msg)
			end
			watcher_stats.actions_taken = watcher_stats.actions_taken + 1
			watcher_stats.last_action_time = os.time()
			return { success = true }
		end,
		description = "Warn player for rule violation",
		strict = false,
		properties = {
			name = { type = "string", description = "Player name to warn" },
			reason = { type = "string", description = "Reason for warning" }
		}
	})

	context:add_tool({
		name = "mute_player",
		func = function(args)
			if type(args) == "string" then return { error = "Invalid JSON string" } end
			if not args or not args.reason then return {error = "Missing 'reason' parameter"} end
			local player_name = args.name
			if not player_name then return {error = "Missing 'name' parameter"} end
			local duration = math.min(math.max(tonumber(args.duration) or 10, 1), 1440)
			local reason = args.reason
			if WATCHER_MODE == ai_filter_watcher.MODES.ENABLED then
				local success, err = simplemod.mute_name(player_name, "AI Watcher", reason, duration * 60)
				if not success then return {error = err} end
				add_to_player_history(player_name, "mute", duration, reason)
			else
				local msg = ("[PERMISSIVE] Would have muted player '%s' for %d minutes: %s"):format(player_name, duration, reason)
				core.log("action", "[ai_filter_watcher] " .. msg)
				relays.send_action_report("**AI Watcher**: %s", msg)
			end
			watcher_stats.actions_taken = watcher_stats.actions_taken + 1
			watcher_stats.last_action_time = os.time()
			return { success = true }
		end,
		description = "Mute player for specified duration",
		strict = false,
		properties = {
			name = { type = "string", description = "Player name to mute" },
			duration = { type = "integer", description = "Mute duration in minutes", minimum = 1, maximum = 1440 },
			reason = { type = "string", description = "Reason for muting" }
		}
	})

	local players = {}
	for _, msg in ipairs(batch) do
		players[msg.name] = true
	end
	local hist_section = ""
	if WATCHER_MODE ~= ai_filter_watcher.MODES.PERMISSIVE then
		for p in pairs(players) do
			local h = get_player_moderation_history(p)
			if #h > 0 then
				hist_section = hist_section .. ("\n--- Moderation history for player '%s' ---\n%s"):format(p, format_player_history(h))
			end
		end
	end

	local prompt = ("Batch of %d recent messages (already sent to chat):\n%s\n%s\nReview these messages and take moderation actions if needed."):format(#batch, formatted_batch, hist_section)

	local ok, err = context:call(prompt, function(_, _, error)
		active_context = nil
		is_processing = false
		if error then
			core.log("warning", ("[ai_filter_watcher] AI error for batch call %d: %s"):format(call_id, tostring(error)))
			relays.send_action_report("**AI Watcher**: Batch %d error: %s", call_id, tostring(error))
		end
	end)

	if not ok then
		core.log("warning", ("[ai_filter_watcher] Failed to call AI for batch %d: %s"):format(call_id, tostring(err)))
		relays.send_action_report("**AI Watcher**: Failed to call AI for batch %d: %s", call_id, tostring(err))
		active_context = nil
		is_processing = false
	end
end

chat_lib.register_on_chat_message(4, function(name, msg)
	add_to_history(name, msg)
	if WATCHER_MODE ~= ai_filter_watcher.MODES.DISABLED then
		table.insert(message_buffer, { name = name, message = msg, time = os.time() })
	end
	return false
end)

local time_acc, cleanup_acc = 0, 0
core.register_globalstep(function(dtime)
	if WATCHER_MODE == ai_filter_watcher.MODES.DISABLED then return end
	time_acc = time_acc + dtime
	cleanup_acc = cleanup_acc + dtime

	if time_acc >= SCAN_INTERVAL then
		time_acc = 0
		if #message_buffer >= MIN_BATCH_SIZE then
			process_batch()
		else
			core.log("verbose", ("[ai_filter_watcher] Buffer too small (%d/%d), skipping scan"):format(#message_buffer, MIN_BATCH_SIZE))
		end
	end

	if cleanup_acc >= 3600 then
		cleanup_acc = 0
		if player_history_loaded then
			cleanup_player_history()
		end
	end
end)

if not core.registered_privileges.filtering then
	core.register_privilege("filtering", "Filter manager")
end

core.register_chatcommand("ai_watcher", {
	description = "Configure and monitor AI watcher",
	params = "<command> [args]",
	privs = { filtering = true },
	func = function(name, param)
		local cmd = param:match("^%s*(%S+)") or "status"
		local function val_or_def(v) return v ~= nil and tostring(v) or "not set (using API default)" end

		if cmd == "status" then
			local players, entries = 0, 0
			if player_history_loaded then
				for _, h in pairs(player_history) do
					players = players + 1
					entries = entries + #h
				end
			end
			return true, string.format([[
AI Watcher Status:
- Mode: %s
- System prompt: %s
- Scan interval: %d seconds
- Min batch size: %d messages
- History size: %d messages (stored: %d)
- History tracking time: %d seconds (%.1f hours)
- Currently processing: %s
- Message buffer: %d messages
- Moderation history: %d players, %d total entries
- AI parameters:
  • Temperature: %s
  • Frequency penalty: %s
  • Presence penalty: %s
- Debug logging: %s
- Statistics:
  • Scans performed: %d
  • Messages processed: %d
  • Actions taken: %d
  • Last scan: %s
  • Last action: %s
]],
				WATCHER_MODE,
				PROMPT_READY and "Loaded" or "Missing/Invalid",
				SCAN_INTERVAL,
				MIN_BATCH_SIZE,
				HISTORY_SIZE,
				history_count,
				HISTORY_TRACKING_TIME, HISTORY_TRACKING_TIME/3600,
				is_processing and ("Yes (call_id: "..active_call_id..")") or "No",
				#message_buffer,
				players,
				entries,
				val_or_def(TEMPERATURE),
				val_or_def(FREQUENCY_PENALTY),
				val_or_def(PRESENCE_PENALTY),
				DEBUG_ENABLED and "Enabled" or "Disabled",
				watcher_stats.scans_performed,
				watcher_stats.messages_processed,
				watcher_stats.actions_taken,
				os.date("%H:%M:%S", watcher_stats.last_scan_time),
				watcher_stats.last_action_time > 0 and os.date("%H:%M:%S", watcher_stats.last_action_time) or "never"
			)

		elseif cmd == "mode" then
			local mode = param:match("%s+(%S+)")
			if not mode or not (mode == "enabled" or mode == "permissive" or mode == "disabled") then
				return false, "Usage: /ai_watcher mode <enabled|permissive|disabled>"
			end
			if (mode == "enabled" or mode == "permissive") and not PROMPT_READY then
				return false, "Cannot enable: system prompt not loaded. Use '/ai_watcher reload_prompt' first."
			end
			if mode == "disabled" and WATCHER_MODE ~= "disabled" then
				abort_current_processing()
			end
			-- Write to shareddb
			local ctx = modstorage:get_context()
			if ctx then
				local err = ctx:set_string("mode", mode)
				err = err or ctx:finalize()
				if err then
					core.log("error", "[ai_filter_watcher] Failed to write mode to shareddb: " .. tostring(err))
				end
			else
				core.log("warning", "[ai_filter_watcher] shareddb unavailable, mode change not persisted")
			end
			WATCHER_MODE = mode
			relays.send_action_report("**AI Watcher**: Mode changed to %s by %s", mode, name)
			return true, "Watcher mode set to: " .. mode

		elseif cmd == "interval" then
			local i = tonumber(param:match("%s+(%S+)"))
			if not i or i < 1 or i > 3600 then
				return false, "Usage: /ai_watcher interval <seconds> (1-3600)"
			end
			local ctx = modstorage:get_context()
			if ctx then
				local err = ctx:set_string("scan_interval", tostring(i))
				err = err or ctx:finalize()
				if err then
					core.log("error", "[ai_filter_watcher] Failed to write interval to shareddb: " .. tostring(err))
				end
			else
				core.log("warning", "[ai_filter_watcher] shareddb unavailable, interval change not persisted")
			end
			SCAN_INTERVAL = i
			time_acc = 0
			return true, ("Scan interval set to: %d seconds"):format(i)

		elseif cmd == "batch" then
			local s = tonumber(param:match("%s+(%S+)"))
			if not s or s < 1 or s > 100 then
				return false, "Usage: /ai_watcher batch <size> (1-100)"
			end
			local ctx = modstorage:get_context()
			if ctx then
				local err = ctx:set_string("min_batch_size", tostring(s))
				err = err or ctx:finalize()
				if err then
					core.log("error", "[ai_filter_watcher] Failed to write batch size to shareddb: " .. tostring(err))
				end
			else
				core.log("warning", "[ai_filter_watcher] shareddb unavailable, batch size change not persisted")
			end
			MIN_BATCH_SIZE = s
			return true, ("Minimum batch size set to: %d messages"):format(s)

		elseif cmd == "temperature" then
			local v = param:match("%s+(%S+)")
			if not v then
				return true, "Current temperature: " .. (TEMPERATURE and tostring(TEMPERATURE) or "not set")
			end
			local n = tonumber(v)
			if n and (n < 0 or n > 2) then
				return false, "Temperature must be 0-2"
			end
			local ctx = modstorage:get_context()
			if ctx then
				local err = ctx:set_string("temperature", v)
				err = err or ctx:finalize()
				if err then
					core.log("error", "[ai_filter_watcher] Failed to write temperature to shareddb: " .. tostring(err))
				end
			else
				core.log("warning", "[ai_filter_watcher] shareddb unavailable, temperature change not persisted")
			end
			TEMPERATURE = n
			return true, ("Temperature set to: %s"):format(v)

		elseif cmd == "frequency_penalty" then
			local v = param:match("%s+(%S+)")
			if not v then
				return true, "Current frequency_penalty: " .. (FREQUENCY_PENALTY and tostring(FREQUENCY_PENALTY) or "not set")
			end
			local n = tonumber(v)
			if n and (n < -2 or n > 2) then
				return false, "Frequency penalty must be -2..2"
			end
			local ctx = modstorage:get_context()
			if ctx then
				local err = ctx:set_string("frequency_penalty", v)
				err = err or ctx:finalize()
				if err then
					core.log("error", "[ai_filter_watcher] Failed to write frequency penalty to shareddb: " .. tostring(err))
				end
			else
				core.log("warning", "[ai_filter_watcher] shareddb unavailable, frequency penalty change not persisted")
			end
			FREQUENCY_PENALTY = n
			return true, ("Frequency penalty set to: %s"):format(v)

		elseif cmd == "presence_penalty" then
			local v = param:match("%s+(%S+)")
			if not v then
				return true, "Current presence_penalty: " .. (PRESENCE_PENALTY and tostring(PRESENCE_PENALTY) or "not set")
			end
			local n = tonumber(v)
			if n and (n < -2 or n > 2) then
				return false, "Presence penalty must be -2..2"
			end
			local ctx = modstorage:get_context()
			if ctx then
				local err = ctx:set_string("presence_penalty", v)
				err = err or ctx:finalize()
				if err then
					core.log("error", "[ai_filter_watcher] Failed to write presence penalty to shareddb: " .. tostring(err))
				end
			else
				core.log("warning", "[ai_filter_watcher] shareddb unavailable, presence penalty change not persisted")
			end
			PRESENCE_PENALTY = n
			return true, ("Presence penalty set to: %s"):format(v)

		elseif cmd == "debug" then
			local v = param:match("%s+(%S+)")
			if not v then
				return true, "Debug logging is " .. (DEBUG_ENABLED and "enabled" or "disabled")
			end
			local new_val
			if v == "on" then
				new_val = true
			elseif v == "off" then
				new_val = false
			else
				return false, "Usage: /ai_watcher debug [on|off]"
			end
			local ctx = modstorage:get_context()
			if ctx then
				local err = ctx:set_string("debug_enabled", tostring(new_val))
				err = err or ctx:finalize()
				if err then
					core.log("error", "[ai_filter_watcher] Failed to write debug setting to shareddb: " .. tostring(err))
				end
			else
				core.log("warning", "[ai_filter_watcher] shareddb unavailable, debug change not persisted")
			end
			DEBUG_ENABLED = new_val
			return true, "Debug " .. (new_val and "enabled" or "disabled")

		elseif cmd == "history_time" then
			local v = param:match("%s+(%S+)")
			if not v then
				return true, ("Current history tracking time: %d seconds (%.1f hours)"):format(HISTORY_TRACKING_TIME, HISTORY_TRACKING_TIME/3600)
			end
			local new = tonumber(v) or (algorithms and algorithms.parse_time(v))
			if not new or new < 60 or new > 2592000 then
				return false, "Invalid time. Must be >=60 seconds or a time string like '10h', '2d' (max 30d)."
			end
			local ctx = modstorage:get_context()
			if ctx then
				local err = ctx:set_string("history_tracking_time", tostring(new))
				err = err or ctx:finalize()
				if err then
					core.log("error", "[ai_filter_watcher] Failed to write history time to shareddb: " .. tostring(err))
				end
			else
				core.log("warning", "[ai_filter_watcher] shareddb unavailable, history time change not persisted")
			end
			local old = HISTORY_TRACKING_TIME
			HISTORY_TRACKING_TIME = new
			if new < old then
				cleanup_player_history()
			end
			relays.send_action_report("**AI Watcher**: History tracking time changed to %d seconds by %s", new, name)
			return true, ("History tracking time set to: %d seconds (%.1f hours)"):format(new, new/3600)

		elseif cmd == "process" then
			local force = param:match("%s+force")
			if #message_buffer < MIN_BATCH_SIZE and not force then
				return false, ("Buffer has only %d messages (need %d). Use '/ai_watcher process force' to override."):format(#message_buffer, MIN_BATCH_SIZE)
			end
			local cnt = #message_buffer
			process_batch()
			return true, ("Processing batch of %d messages"):format(cnt)

		elseif cmd == "dump" then
			local out = ("Current message buffer (%d messages):\n"):format(#message_buffer)
			if #message_buffer == 0 then
				out = out .. "(empty)"
			else
				for i, m in ipairs(message_buffer) do
					out = out .. ("%d. [%s] <%s>: %s\n"):format(i, os.date("%H:%M", m.time), m.name, m.message)
				end
			end
			return true, out

		elseif cmd == "abort" then
			if is_processing then
				abort_current_processing("Manually aborted by " .. name)
				relays.send_action_report("**AI Watcher**: Current processing aborted by %s", name)
				return true, "Ongoing AI processing aborted"
			else
				return false, "No processing to abort"
			end

		elseif cmd == "clear" then
			local what = param:match("%s+(%S+)") or "buffer"
			if what == "buffer" then
				local cnt = #message_buffer
				message_buffer = {}
				relays.send_action_report("**AI Watcher**: Cleared %d messages from buffer by %s", cnt, name)
				return true, ("Cleared %d messages from buffer"):format(cnt)
			elseif what == "stats" then
				watcher_stats = { scans_performed = 0, messages_processed = 0, actions_taken = 0, last_scan_time = 0, last_action_time = 0 }
				relays.send_action_report("**AI Watcher**: Statistics cleared by %s", name)
				return true, "Statistics cleared"
			elseif what == "history" then
				chat_history = {}
				history_index = 1
				history_count = 0
				relays.send_action_report("**AI Watcher**: Chat history cleared by %s", name)
				return true, "Chat history cleared"
			elseif what == "player_history" then
				player_history = {}
				save_player_history()
				relays.send_action_report("**AI Watcher**: Player moderation history cleared by %s", name)
				return true, "Player moderation history cleared"
			else
				return false, "Usage: /ai_watcher clear <buffer|stats|history|player_history>"
			end

		elseif cmd == "player_history" then
			local p = param:match("%s+(%S+)")
			if not p then
				return false, "Usage: /ai_watcher player_history <player_name>"
			end
			local h = get_player_moderation_history(p)
			if #h == 0 then
				return true, ("No recent moderation history for player '%s'"):format(p)
			end
			return true, ("Moderation history for '%s' (last %d hours):\n%s"):format(p, math.floor(HISTORY_TRACKING_TIME/3600), format_player_history(h))

		elseif cmd == "reload_prompt" then
			local suffix = ", but couldn't update the git repository"
			if core.global_exists("server_restart") and server_restart.update() then
				suffix = " from an updated git repository"
			end
			if load_system_prompt() then
				relays.send_action_report("**AI Watcher**: System prompt reloaded by %s", name)
				return true, "System prompt reloaded successfully"..suffix
			else
				return false, "Failed to reload system prompt"
			end

		elseif cmd == "help" then
			return true, [[AI Watcher Commands:
  status                - Show current status and statistics
  mode <mode>           - Set mode: enabled, permissive, disabled
  interval <seconds>    - Set scan interval (1-3600)
  batch <size>          - Set minimum batch size (1-100)
  temperature [value]   - Get/set temperature (0-2)
  frequency_penalty [value] - Get/set frequency penalty (-2 to 2)
  presence_penalty [value]  - Get/set presence penalty (-2 to 2)
  debug [on|off]        - Get/set debug logging
  history_time [time]   - Get/set history retention (seconds or e.g. '10h')
  process [force]       - Process current batch immediately
  dump                  - Show messages in buffer
  abort                 - Abort ongoing processing
  clear <what>          - Clear: buffer, stats, history, or player_history
  player_history <name> - Show moderation history for a player
  reload_prompt         - Reload system prompt from file
  help                  - Show this help]]
		else
			return false, "Unknown command. Use '/ai_watcher help'."
		end
	end
})

core.after(0, function()
	-- Load initial settings from shareddb (if available)
	update_setting_from_db(nil)   -- read all keys

	load_system_prompt()
	load_player_history()
	cleanup_player_history()
	core.log("action", ("[ai_filter_watcher] Initialized (mode: %s, prompt: %s, interval: %ds, batch: %d, debug: %s)"):format(
		WATCHER_MODE, PROMPT_READY and "loaded" or "missing", SCAN_INTERVAL, MIN_BATCH_SIZE, DEBUG_ENABLED and "enabled" or "disabled"))
	relays.send_action_report("**AI Watcher**: Initialized (mode: %s, prompt: %s, interval: %ds, batch: %d, debug: %s)",
		WATCHER_MODE, PROMPT_READY and "loaded" or "missing", SCAN_INTERVAL, MIN_BATCH_SIZE, DEBUG_ENABLED and "enabled" or "disabled")
end)
