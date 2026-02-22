-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović
---@diagnostic disable: need-check-nil

local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)
local storage = core.get_mod_storage()
local is_xban = core.global_exists("xban")
local is_essentials = core.global_exists("essentials")

local WATCHER_MODE = core.settings:get("ai_filter_watcher.mode") or "enabled"
local SCAN_INTERVAL = tonumber(core.settings:get("ai_filter_watcher.scan_interval")) or 60
local MIN_BATCH_SIZE = tonumber(core.settings:get("ai_filter_watcher.min_batch_size")) or 5
local HISTORY_SIZE = tonumber(core.settings:get("ai_filter_watcher.history_size")) or 100
local HISTORY_TRACKING_TIME = tonumber(core.settings:get("ai_filter_watcher.history_tracking_time")) or 86400

local TEMPERATURE, FREQUENCY_PENALTY, PRESENCE_PENALTY
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
local pending_scan = false
local active_call_id = 0
local active_context = nil

ai_filter_watcher = {
	MODES = { ENABLED = "enabled", PERMISSIVE = "permissive", DISABLED = "disabled" }
}

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

local function abort_current_processing()
	if is_processing and active_context then
		core.log("action", "[ai_filter_watcher] Aborting ongoing AI processing")
		active_context:destroy()
		active_context = nil
	end
	is_processing = false
	pending_scan = false
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
	for name, hist in pairs(player_history) do
		local new_hist = {}
		for _, e in ipairs(hist) do
			if e.time >= cutoff then table.insert(new_hist, e) else removed = removed + 1 end
		end
		if #new_hist == 0 then player_history[name] = nil else player_history[name] = new_hist end
	end
	if removed > 0 then save_player_history() end
end

local function add_to_player_history(name, typ, dur, reason)
	if not player_history_loaded then load_player_history() end
	player_history[name] = player_history[name] or {}
	table.insert(player_history[name], { time = os.time(), type = typ, duration = dur, reason = reason })
	if #player_history[name] > 50 then table.remove(player_history[name], 1) end
	save_player_history()
end

local function get_player_moderation_history(name)
	if not player_history_loaded then load_player_history() end
	local now, cutoff = os.time(), now - HISTORY_TRACKING_TIME
	local recent = {}
	for _, e in ipairs(player_history[name] or {}) do
		if e.time >= cutoff then table.insert(recent, e) end
	end
	return recent
end

local function format_player_history(hist)
	if #hist == 0 then return "No recent moderation history." end
	local lines = {}
	for _, e in ipairs(hist) do
		local ago = os.time() - e.time
		local ts = ago < 3600 and math.floor(ago/60).." minutes ago" or
		          (ago < 86400 and math.floor(ago/3600).." hours ago" or math.floor(ago/86400).." days ago")
		if e.type == "warn" then
			table.insert(lines, ("- Warned %s for: %s"):format(ts, e.reason))
		elseif e.type == "mute" then
			table.insert(lines, ("- Muted for %d minutes %s for: %s"):format(e.duration or 0, ts, e.reason))
		end
	end
	return "Recent moderation history:\n" .. table.concat(lines, "\n")
end

local function add_to_history(name, msg)
	if WATCHER_MODE == ai_filter_watcher.MODES.DISABLED then return end
	chat_history[history_index] = { name = name, message = msg, time = os.time() }
	history_index = history_index % HISTORY_SIZE + 1
	if history_count < HISTORY_SIZE then history_count = history_count + 1 end
end

local function get_last_messages(n)
	local count = math.min(n, history_count)
	if count == 0 then return {} end
	local result, idx = {}, 1
	local cur = history_index - 1
	if cur <= 0 then cur = cur + HISTORY_SIZE end
	while idx <= count do
		local entry = chat_history[cur]
		if entry then result[idx] = entry; idx = idx + 1 end
		cur = cur - 1
		if cur <= 0 then cur = cur + HISTORY_SIZE end
		if cur == history_index then break end
	end
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
	if WATCHER_MODE == ai_filter_watcher.MODES.DISABLED then abort_current_processing(); return end
	if is_processing then core.log("verbose", "[ai_filter_watcher] Already processing, skipping"); return end

	is_processing = true
	local batch = message_buffer
	message_buffer = {}
	if #batch == 0 then is_processing = false; return end

	active_call_id = active_call_id + 1
	local call_id = active_call_id
	watcher_stats.scans_performed = watcher_stats.scans_performed + 1
	watcher_stats.last_scan_time = os.time()
	watcher_stats.messages_processed = watcher_stats.messages_processed + #batch

	core.log("action", ("[ai_filter_watcher] Processing batch of %d messages (call_id: %d)"):format(#batch, call_id))

	local formatted_batch = format_history(batch)
	local context, err = cloudai.get_context()
	if not context then
		core.log("error", ("[ai_filter_watcher] Failed to get AI context for batch %d: %s"):format(call_id, tostring(err)))
		is_processing = false
		if pending_scan then pending_scan = false; process_batch() end
		return
	end

	if DEBUG_ENABLED and context.set_debug then context:set_debug(true) end
	if TEMPERATURE then context:set_temperature(TEMPERATURE) end
	if FREQUENCY_PENALTY then context:set_frequency_penalty(FREQUENCY_PENALTY) end
	if PRESENCE_PENALTY then context:set_presence_penalty(PRESENCE_PENALTY) end

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
			if not args or not args.messages then return {error = "Missing 'messages' parameter"} end
			local n = tonumber(args.messages)
			if not n or n < 1 or n > 50 then return {error = "Number of messages must be between 1 and 50"} end
			local hist = get_last_messages(n)
			return { history = format_history(hist), count = #hist }
		end,
		description = "Get additional chat history for context (use ONLY if necessary)",
		strict = false,
		properties = { messages = { type = "integer", description = "Number of previous messages to retrieve", minimum = 1, maximum = 15 } }
	})

	context:add_tool({
		name = "warn_player",
		func = function(args)
			if type(args) == "string" then return { error = "Invalid JSON string" } end
			if not args or not args.reason then return {error = "Missing 'reason' parameter"} end
			local player_name = args.name or args.name
			if not player_name then return {error = "Missing 'name' parameter"} end
			local reason = args.reason
			local ok, msg
			if WATCHER_MODE == ai_filter_watcher.MODES.ENABLED then
				if not is_essentials then return {error = "Essentials mod not available"} end
				essentials.show_warn_formspec(player_name, reason, "AI Watcher")
				add_to_player_history(player_name, "warn", nil, reason)
				ok = true; msg = ("Warned player '%s' for: %s"):format(player_name, reason)
			else -- permissive
				ok = true; msg = ("[PERMISSIVE] Would have warned player '%s' for: %s"):format(player_name, reason)
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
			local ok, msg
			if WATCHER_MODE == ai_filter_watcher.MODES.ENABLED then
				if not is_xban then return {error = "XBan mod not available"} end
				local expires = os.time() + duration * 60
				local success, err = xban.mute_player(player_name, "AI Watcher", expires, reason)
				if not success then return {error = err} end
				add_to_player_history(player_name, "mute", duration, reason)
				msg = ("Muted player '%s' for %d minutes: %s"):format(player_name, duration, reason)
			else
				msg = ("[PERMISSIVE] Would have muted player '%s' for %d minutes: %s"):format(player_name, duration, reason)
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
	for _, msg in ipairs(batch) do players[msg.name] = true end
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
		if pending_scan then
			pending_scan = false
			core.after(0.1, process_batch)
		end
	end)

	if not ok then
		core.log("warning", ("[ai_filter_watcher] Failed to call AI for batch %d: %s"):format(call_id, tostring(err)))
		relays.send_action_report("**AI Watcher**: Failed to call AI for batch %d: %s", call_id, tostring(err))
		active_context = nil
		is_processing = false
		if pending_scan then pending_scan = false; core.after(0.1, process_batch) end
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
			if is_processing then
				pending_scan = true
				core.log("verbose", "[ai_filter_watcher] Scan requested but busy, marking as pending")
			else
				process_batch()
			end
		else
			core.log("verbose", ("[ai_filter_watcher] Buffer too small (%d/%d), skipping scan"):format(#message_buffer, MIN_BATCH_SIZE))
		end
	end

	if cleanup_acc >= 3600 then
		cleanup_acc = 0
		if player_history_loaded then cleanup_player_history() end
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
				for _, h in pairs(player_history) do players = players + 1; entries = entries + #h end
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
- Pending scan: %s
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
				pending_scan and "Yes" or "No",
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
			if mode == "disabled" and WATCHER_MODE ~= "disabled" then abort_current_processing() end
			WATCHER_MODE = mode
			relays.send_action_report("**AI Watcher**: Mode changed to %s by %s", mode, name)
			return true, "Watcher mode set to: " .. mode

		elseif cmd == "interval" then
			local i = tonumber(param:match("%s+(%S+)"))
			if not i or i < 1 or i > 3600 then return false, "Usage: /ai_watcher interval <seconds> (1-3600)" end
			SCAN_INTERVAL = i; time_acc = 0
			return true, ("Scan interval set to: %d seconds"):format(i)

		elseif cmd == "batch" then
			local s = tonumber(param:match("%s+(%S+)"))
			if not s or s < 1 or s > 100 then return false, "Usage: /ai_watcher batch <size> (1-100)" end
			MIN_BATCH_SIZE = s
			return true, ("Minimum batch size set to: %d messages"):format(s)

		elseif cmd == "temperature" then
			local v = param:match("%s+(%S+)")
			if not v then return true, "Current temperature: " .. (TEMPERATURE and tostring(TEMPERATURE) or "not set") end
			local n = tonumber(v)
			if not n or n < 0 or n > 2 then return false, "Temperature must be 0-2" end
			TEMPERATURE = n
			return true, ("Temperature set to: %g"):format(TEMPERATURE)

		elseif cmd == "frequency_penalty" then
			local v = param:match("%s+(%S+)")
			if not v then return true, "Current frequency_penalty: " .. (FREQUENCY_PENALTY and tostring(FREQUENCY_PENALTY) or "not set") end
			local n = tonumber(v)
			if not n or n < -2 or n > 2 then return false, "Frequency penalty must be -2..2" end
			FREQUENCY_PENALTY = n
			return true, ("Frequency penalty set to: %g"):format(FREQUENCY_PENALTY)

		elseif cmd == "presence_penalty" then
			local v = param:match("%s+(%S+)")
			if not v then return true, "Current presence_penalty: " .. (PRESENCE_PENALTY and tostring(PRESENCE_PENALTY) or "not set") end
			local n = tonumber(v)
			if not n or n < -2 or n > 2 then return false, "Presence penalty must be -2..2" end
			PRESENCE_PENALTY = n
			return true, ("Presence penalty set to: %g"):format(PRESENCE_PENALTY)

		elseif cmd == "debug" then
			local v = param:match("%s+(%S+)")
			if not v then return true, "Debug logging is " .. (DEBUG_ENABLED and "enabled" or "disabled") end
			if v == "on" then DEBUG_ENABLED = true; return true, "Debug enabled"
			elseif v == "off" then DEBUG_ENABLED = false; return true, "Debug disabled"
			else return false, "Usage: /ai_watcher debug [on|off]" end

		elseif cmd == "history_time" then
			local v = param:match("%s+(%S+)")
			if not v then return true, ("Current history tracking time: %d seconds (%.1f hours)"):format(HISTORY_TRACKING_TIME, HISTORY_TRACKING_TIME/3600) end
			local new = tonumber(v) or (algorithms and algorithms.parse_time(v))
			if not new or new < 60 or new > 2592000 then
				return false, "Invalid time. Must be >=60 seconds or a time string like '10h', '2d' (max 30d)."
			end
			local old = HISTORY_TRACKING_TIME
			HISTORY_TRACKING_TIME = new
			if new < old then cleanup_player_history() end
			relays.send_action_report("**AI Watcher**: History tracking time changed to %d seconds by %s", new, name)
			return true, ("History tracking time set to: %d seconds (%.1f hours)"):format(new, new/3600)

		elseif cmd == "process" then
			local force = param:match("%s+force")
			if #message_buffer < MIN_BATCH_SIZE and not force then
				return false, ("Buffer has only %d messages (need %d). Use '/ai_watcher process force' to override."):format(#message_buffer, MIN_BATCH_SIZE)
			end
			if is_processing then
				pending_scan = true
				return true, ("Already processing batch %d. New scan will start when current batch finishes."):format(active_call_id)
			end
			local cnt = #message_buffer
			process_batch()
			return true, ("Processing batch of %d messages"):format(cnt)

		elseif cmd == "dump" then
			local out = ("Current message buffer (%d messages):\n"):format(#message_buffer)
			if #message_buffer == 0 then out = out .. "(empty)"
			else
				for i, m in ipairs(message_buffer) do
					out = out .. ("%d. [%s] <%s>: %s\n"):format(i, os.date("%H:%M", m.time), m.name, m.message)
				end
			end
			return true, out

		elseif cmd == "abort" then
			if is_processing then abort_current_processing()
				relays.send_action_report("**AI Watcher**: Current processing aborted by %s", name)
				return true, "Ongoing AI processing aborted"
			elseif pending_scan then pending_scan = false
				relays.send_action_report("**AI Watcher**: Pending scan cancelled by %s", name)
				return true, "Pending scan cancelled"
			else return false, "No processing or pending scan to abort" end

		elseif cmd == "clear" then
			local what = param:match("%s+(%S+)") or "buffer"
			if what == "buffer" then
				local cnt = #message_buffer; message_buffer = {}
				relays.send_action_report("**AI Watcher**: Cleared %d messages from buffer by %s", cnt, name)
				return true, ("Cleared %d messages from buffer"):format(cnt)
			elseif what == "stats" then
				watcher_stats = { scans_performed = 0, messages_processed = 0, actions_taken = 0, last_scan_time = 0, last_action_time = 0 }
				relays.send_action_report("**AI Watcher**: Statistics cleared by %s", name)
				return true, "Statistics cleared"
			elseif what == "history" then
				chat_history = {}; history_index = 1; history_count = 0
				relays.send_action_report("**AI Watcher**: Chat history cleared by %s", name)
				return true, "Chat history cleared"
			elseif what == "player_history" then
				player_history = {}; save_player_history()
				relays.send_action_report("**AI Watcher**: Player moderation history cleared by %s", name)
				return true, "Player moderation history cleared"
			else return false, "Usage: /ai_watcher clear <buffer|stats|history|player_history>" end

		elseif cmd == "player_history" then
			local p = param:match("%s+(%S+)")
			if not p then return false, "Usage: /ai_watcher player_history <player_name>" end
			local h = get_player_moderation_history(p)
			if #h == 0 then return true, ("No recent moderation history for player '%s'"):format(p) end
			return true, ("Moderation history for '%s' (last %d hours):\n%s"):format(p, math.floor(HISTORY_TRACKING_TIME/3600), format_player_history(h))

		elseif cmd == "reload_prompt" then
			if load_system_prompt() then
				relays.send_action_report("**AI Watcher**: System prompt reloaded by %s", name)
				return true, "System prompt reloaded successfully"
			else return false, "Failed to reload system prompt" end

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
		else return false, "Unknown command. Use '/ai_watcher help'." end
	end
})

core.after(0, function()
	load_system_prompt()
	load_player_history()
	cleanup_player_history()
	core.log("action", ("[ai_filter_watcher] Initialized (mode: %s, prompt: %s, interval: %ds, batch: %d, debug: %s)"):format(
		WATCHER_MODE, PROMPT_READY and "loaded" or "missing", SCAN_INTERVAL, MIN_BATCH_SIZE, DEBUG_ENABLED and "enabled" or "disabled"))
	relays.send_action_report("**AI Watcher**: Initialized (mode: %s, prompt: %s, interval: %ds, batch: %d, debug: %s)",
		WATCHER_MODE, PROMPT_READY and "loaded" or "missing", SCAN_INTERVAL, MIN_BATCH_SIZE, DEBUG_ENABLED and "enabled" or "disabled")
end)