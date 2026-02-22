-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović
---@diagnostic disable: need-check-nil

local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)
local storage = core.get_mod_storage()
local is_xban = core.global_exists("xban")
local is_essentials = core.global_exists("essentials")

-- Configuration with defaults
local WATCHER_MODE = core.settings:get("ai_filter_watcher.mode") or "enabled" -- "enabled", "permissive", "disabled"
local SCAN_INTERVAL = tonumber(core.settings:get("ai_filter_watcher.scan_interval")) or 60 -- seconds
local MIN_BATCH_SIZE = tonumber(core.settings:get("ai_filter_watcher.min_batch_size")) or 5 -- messages
local HISTORY_SIZE = tonumber(core.settings:get("ai_filter_watcher.history_size")) or 100
local HISTORY_TRACKING_TIME = tonumber(core.settings:get("ai_filter_watcher.history_tracking_time")) or 86400 -- seconds (default: 1 day)

-- Global AI parameters (nil = use API default)
local TEMPERATURE = nil
local FREQUENCY_PENALTY = nil
local PRESENCE_PENALTY = nil

-- NEW: Debug flag for cloudai conversation logging
local DEBUG_ENABLED = false

-- State variables
local PROMPT_READY = false
local message_buffer = {}
local chat_history = {}
local history_index = 1
local history_count = 0
local watcher_stats = {
	scans_performed = 0,
	messages_processed = 0,
	actions_taken = 0,
	last_scan_time = 0,
	last_action_time = 0
}
local player_history = {}
local player_history_loaded = false
local system_prompt = ""
local system_prompt_file = modpath .. "/system_prompt.txt"
local is_processing = false
local pending_scan = false
local active_call_id = 0
local active_context = nil

ai_filter_watcher = {
	MODES = {
		ENABLED = "enabled",	 -- AI actions are executed
		PERMISSIVE = "permissive", -- AI actions are only logged
		DISABLED = "disabled"	 -- No AI processing
	}
}

-- Load system prompt from file
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

-- Abort any ongoing AI processing
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

-- Load player history from storage
local function load_player_history()
	local data = storage:get("player_history")
	if data then
		player_history = core.deserialize(data) or {}
		core.log("verbose", string.format(
			"[ai_filter_watcher] Loaded moderation history for %d players",
			#player_history
		))
	else
		player_history = {}
	end
	player_history_loaded = true
end

-- Save player history to storage
local function save_player_history()
	storage:set_string("player_history", core.serialize(player_history))
end

-- Clean up old player history entries
local function cleanup_player_history()
	local now = os.time()
	local cutoff = now - HISTORY_TRACKING_TIME
	local removed = 0

	for player_name, history in pairs(player_history) do
		local new_history = {}
		for _, entry in ipairs(history) do
			if entry.time >= cutoff then
				table.insert(new_history, entry)
			else
				removed = removed + 1
			end
		end

		if #new_history == 0 then
			player_history[player_name] = nil
		else
			player_history[player_name] = new_history
		end
	end

	if removed > 0 then
		save_player_history()
		core.log("verbose", string.format(
			"[ai_filter_watcher] Cleaned up %d old moderation history entries",
			removed
		))
	end
end

-- Add a moderation action to player history
local function add_to_player_history(player_name, action_type, duration, reason)
	if not player_history_loaded then
		load_player_history()
	end

	if not player_history[player_name] then
		player_history[player_name] = {}
	end

	table.insert(player_history[player_name], {
		time = os.time(),
		type = action_type,
		duration = duration,
		reason = reason
	})

	-- Keep only recent history
	if #player_history[player_name] > 50 then
		table.remove(player_history[player_name], 1)
	end

	save_player_history()
end

-- Get player's recent moderation history
local function get_player_moderation_history(player_name)
	if not player_history_loaded then
		load_player_history()
	end

	local now = os.time()
	local cutoff = now - HISTORY_TRACKING_TIME
	local player_data = player_history[player_name] or {}
	local recent_history = {}

	for _, entry in ipairs(player_data) do
		if entry.time >= cutoff then
			table.insert(recent_history, entry)
		end
	end

	return recent_history
end

-- Format player history for AI (optimized with table.concat)
local function format_player_history(history)
	if #history == 0 then
		return "No recent moderation history."
	end

	local lines = {}
	for _, entry in ipairs(history) do
		local time_ago = os.time() - entry.time
		local time_str = ""

		if time_ago < 3600 then
			time_str = string.format("%d minutes ago", math.floor(time_ago / 60))
		elseif time_ago < 86400 then
			time_str = string.format("%d hours ago", math.floor(time_ago / 3600))
		else
			time_str = string.format("%d days ago", math.floor(time_ago / 86400))
		end

		if entry.type == "warn" then
			table.insert(lines, string.format("- Warned %s for: %s", time_str, entry.reason))
		elseif entry.type == "mute" then
			table.insert(lines, string.format("- Muted for %d minutes %s for: %s",
				entry.duration or 0, time_str, entry.reason))
		end
	end

	return "Recent moderation history:\n" .. table.concat(lines, "\n")
end

local function add_to_history(name, message)
	if WATCHER_MODE == ai_filter_watcher.MODES.DISABLED then
		return
	end

	chat_history[history_index] = {
		name = name,
		message = message,
		time = os.time()
	}

	history_index = history_index % HISTORY_SIZE + 1

	-- Update the count (but don't exceed the buffer size)
	if history_count < HISTORY_SIZE then
		history_count = history_count + 1
	end
end

-- Optimized get_last_messages with direct array assignment
local function get_last_messages(n)
	local count = math.min(n, history_count)
	if count == 0 then
		return {}
	end

	local result = {}
	local result_index = 1

	-- Start from the most recent message and work backwards
	local current_idx = history_index - 1
	if current_idx <= 0 then
		current_idx = current_idx + HISTORY_SIZE
	end

	-- Collect messages in reverse chronological order
	while result_index <= count do
		local entry = chat_history[current_idx]
		if entry then  -- Only include if not nil (slot was written to)
			result[result_index] = entry
			result_index = result_index + 1
		end

		-- Move to previous position with wrap-around
		current_idx = current_idx - 1
		if current_idx <= 0 then
			current_idx = current_idx + HISTORY_SIZE
		end

		-- Safety check: prevent infinite loop
		if current_idx == history_index then
			-- We've wrapped all the way around
			break
		end
	end

	-- Reverse the array to get chronological order (oldest to newest)
	for i = 1, math.floor(#result / 2) do
		local j = #result - i + 1
		result[i], result[j] = result[j], result[i]
	end

	return result
end

local function format_history(messages)
	local formatted = {}
	for _, msg in ipairs(messages) do
		table.insert(formatted, string.format("[%s] <%s>: %s",
			os.date("%H:%M", msg.time),
			msg.name,
			msg.message
		))
	end
	return table.concat(formatted, "\n")
end

local function process_batch()
	if WATCHER_MODE == ai_filter_watcher.MODES.DISABLED then
		abort_current_processing()
		return
	end

	if is_processing then
		core.log("verbose", "[ai_filter_watcher] Already processing, skipping")
		return
	end

	-- Set processing flag immediately
	is_processing = true

	-- Move the buffer reference and clear it
	local batch_to_process = message_buffer
	message_buffer = {}

	if #batch_to_process == 0 then
		is_processing = false
		return
	end

	active_call_id = active_call_id + 1
	local call_id = active_call_id

	watcher_stats.scans_performed = watcher_stats.scans_performed + 1
	watcher_stats.last_scan_time = os.time()
	watcher_stats.messages_processed = watcher_stats.messages_processed + #batch_to_process

	core.log("action", string.format(
		"[ai_filter_watcher] Processing batch of %d messages (call_id: %d)",
		#batch_to_process, call_id
	))

	local formatted_batch = format_history(batch_to_process)

	-- Create AI context
	local context, err = cloudai.get_context()
	if not context then
		core.log("error", string.format("[ai_filter_watcher] Failed to get AI context for batch %d: %s",
			call_id, tostring(err)))
		is_processing = false
		if pending_scan then
			pending_scan = false
			process_batch()
		end
		return
	end

	-- NEW: Enable debug logging if flag is set
	if DEBUG_ENABLED and context.set_debug then
		context:set_debug(true)
	end

	-- Apply global AI parameters if set
	if TEMPERATURE ~= nil then
		context:set_temperature(TEMPERATURE)
	end
	if FREQUENCY_PENALTY ~= nil then
		context:set_frequency_penalty(FREQUENCY_PENALTY)
	end
	if PRESENCE_PENALTY ~= nil then
		context:set_presence_penalty(PRESENCE_PENALTY)
	end

	active_context = context

	-- Use the loaded system prompt
	context:set_system_prompt(system_prompt)

	context:set_max_steps(10)

	-- Add tools
	context:add_tool({
		name = "get_history",
		func = function(args)
			-- Parse manually
			if type(args) == "string" then
				local first_number = args:match("-?%d+")
				if not first_number then
					return {error = "Missing 'messages' parameter"}
				end
				args = { messages = first_number }
			end
			if not args or not args.messages then
				return {error = "Missing 'messages' parameter"}
			end

			local num_messages = tonumber(args.messages)
			if not num_messages or num_messages < 1 or num_messages > 50 then
				return {error = "Number of messages must be between 1 and 50"}
			end

			local history = get_last_messages(num_messages)
			return {
				history = format_history(history),
				count = #history
			}
		end,
		description = "Get additional chat history for context (use ONLY if necessary)",
		strict = false,
		properties = {
			messages = {
				type = "integer",
				description = "Number of previous messages to retrieve",
				minimum = 1,
				maximum = 15
			}
		}
	})

	context:add_tool({
		name = "get_player_history",
		func = function(args)
			if type(args) == "string" then
				return { error = "Invalid JSON string" }
			end

			local player_name = args.name
			if not player_name then
				return {error = "Missing 'name' parameter"}
			end

			local history = get_player_moderation_history(player_name)
			return {
				success = true,
				player = player_name,
				history = format_player_history(history),
				count = #history
			}
		end,
		description = "Get recent moderation history (warns and mutes) for a player",
		strict = false,
		properties = {
			name = {
				type = "string",
				description = "Player name to get history for"
			}
		}
	})

	context:add_tool({
		name = "warn_player",
		func = function(args)
			if type(args) == "string" then
				return { error = "Invalid JSON string" }
			end
			if not args or not args.reason then
				return {error = "Missing 'reason' parameter"}
			end

			local player_name = args.name
			if not player_name then
				return {error = "Missing 'name' parameter"}
			end

			local reason = args.reason
			local action_taken = false
			local result_message = ""

			if WATCHER_MODE == ai_filter_watcher.MODES.ENABLED then
				if is_essentials then
					essentials.show_warn_formspec(player_name, reason, "AI Watcher")
					action_taken = true
					result_message = string.format("Warned player '%s' for: %s", player_name, reason)
					-- Add to player history
					add_to_player_history(player_name, "warn", nil, reason)
				else
					return {error = "Essentials mod not available"}
				end
			else
				-- Permissive mode: just log
				action_taken = false
				result_message = string.format("[PERMISSIVE] Would have warned player '%s' for: %s", player_name, reason)
				-- Still add to history for consistency
				add_to_player_history(player_name, "warn", nil, reason)
			end

			watcher_stats.actions_taken = watcher_stats.actions_taken + 1
			watcher_stats.last_action_time = os.time()

			-- In enabled mode, essentials logs on its own
			if WATCHER_MODE == ai_filter_watcher.MODES.PERMISSIVE then
				core.log("action", "[ai_filter_watcher] " .. result_message)
				relays.send_action_report("**AI Watcher**: %s", result_message)
			end

			return {
				success = true,
				action = action_taken and "warned" or "logged_warning",
				reason = reason,
				message = result_message
			}
		end,
		description = "Warn player for rule violation",
		strict = false,
		properties = {
			name = {
				type = "string",
				description = "Player name to warn"
			},
			reason = {
				type = "string",
				description = "Reason for warning"
			}
		}
	})

	context:add_tool({
		name = "mute_player",
		func = function(args)
			if type(args) == "string" then
				return { error = "Invalid JSON string" }
			end
			if not args or not args.reason then
				return {error = "Missing 'reason' parameter"}
			end

			local player_name = args.name
			if not player_name then
				return {error = "Missing 'name' parameter"}
			end

			local duration = tonumber(args.duration) or 10
			if duration < 1 then duration = 1 end
			if duration > 1440 then duration = 1440 end

			local reason = args.reason
			local action_taken = false
			local result_message = ""

			if WATCHER_MODE == ai_filter_watcher.MODES.ENABLED then
				if is_xban then
					local expires = os.time() + (duration * 60)
					local success, err = xban.mute_player(player_name, "AI Watcher", expires, reason)

					if success then
						action_taken = true
						result_message = string.format("Muted player '%s' for %d minutes: %s",
							player_name, duration, reason)
						-- Add to player history
						add_to_player_history(player_name, "mute", duration, reason)
					else
						return {error = err}
					end
				else
					return {error = "XBan mod not available"}
				end
			else
				-- Permissive mode: just log
				action_taken = false
				result_message = string.format("[PERMISSIVE] Would have muted player '%s' for %d minutes: %s",
					player_name, duration, reason)
				-- Still add to history for consistency
				add_to_player_history(player_name, "mute", duration, reason)
			end

			watcher_stats.actions_taken = watcher_stats.actions_taken + 1
			watcher_stats.last_action_time = os.time()

			-- In enabled mode, xban logs on its own
			if WATCHER_MODE == ai_filter_watcher.MODES.PERMISSIVE then
				core.log("action", "[ai_filter_watcher] " .. result_message)
				relays.send_action_report("**AI Watcher**: %s", result_message)
			end

			return {
				success = true,
				action = action_taken and "muted" or "logged_mute",
				duration = duration,
				reason = reason,
				message = result_message
			}
		end,
		description = "Mute player for specified duration",
		strict = false,
		properties = {
			name = {
				type = "string",
				description = "Player name to mute"
			},
			duration = {
				type = "integer",
				description = "Mute duration in minutes",
				minimum = 1,
				maximum = 1440
			},
			reason = {
				type = "string",
				description = "Reason for muting"
			}
		}
	})

	-- Format prompt with batch - automatically include moderation history for players in the batch
	-- Collect unique player names from the batch
	local unique_players = {}
	for _, msg in ipairs(batch_to_process) do
		unique_players[msg.name] = true
	end

	-- Build player history section for the prompt (with caching)
	local player_history_section = ""
	local history_cache = {}  -- Cache for this batch

	for player_name in pairs(unique_players) do
		-- Check cache first
		if not history_cache[player_name] then
			history_cache[player_name] = get_player_moderation_history(player_name)
		end

		local history = history_cache[player_name]
		if #history > 0 then
			player_history_section = player_history_section ..
				string.format("\n--- Moderation history for player '%s' ---\n%s",
					player_name, format_player_history(history))
		end
	end

	-- Create the final prompt
	local prompt = string.format([[Batch of %d recent messages (already sent to chat):
%s
%s

Review these messages and take moderation actions if needed.]],
		#batch_to_process,
		formatted_batch,
		player_history_section
	)

	local success, err = context:call(prompt, function(history, response, error)
		-- Clear the active context reference
		active_context = nil

		-- Mark processing as complete
		is_processing = false

		if error then
			core.log("warning", string.format(
				"[ai_filter_watcher] AI error for batch call %d: %s",
				call_id, tostring(error)
			))
			-- Also send error to relays
			relays.send_action_report("**AI Watcher**: Batch %d error: %s", call_id, tostring(error))
		elseif response and response.content then
			core.log("verbose", string.format(
				"[ai_filter_watcher] AI completed processing batch %d",
				call_id
			))
		end

		-- If there's a pending scan request, process it now
		if pending_scan then
			pending_scan = false
			core.log("verbose", "[ai_filter_watcher] Processing pending scan after completion")
			core.after(0.1, function()
				process_batch()
			end)
		end
	end)

	if not success then
		core.log("warning", string.format(
			"[ai_filter_watcher] Failed to call AI for batch %d: %s",
			call_id, tostring(err)
		))
		-- Send failure to relays
		relays.send_action_report("**AI Watcher**: Failed to call AI for batch %d: %s", call_id, tostring(err))

		active_context = nil
		is_processing = false

		-- Still check for pending scan
		if pending_scan then
			pending_scan = false
			core.after(0.1, function()
				process_batch()
			end)
		end
	end
end

-- Accumulate chat messages
chat_lib.register_on_chat_message(4, function(name, message)
	-- Always add to history
	add_to_history(name, message)

	-- Only add to buffer for batch processing if not disabled
	if WATCHER_MODE ~= ai_filter_watcher.MODES.DISABLED then
		table.insert(message_buffer, {
			name = name,
			message = message,
			time = os.time()
		})
	end

	return false -- Never block messages in watcher mode
end)

-- Periodic batch processing
local time_acc = 0
local cleanup_acc = 0
core.register_globalstep(function(dtime)
	if WATCHER_MODE == ai_filter_watcher.MODES.DISABLED then
		return
	end

	time_acc = time_acc + dtime
	cleanup_acc = cleanup_acc + dtime

	-- Check for batch processing
	if time_acc >= SCAN_INTERVAL then
		time_acc = 0

		-- Check if we should process
		if #message_buffer >= MIN_BATCH_SIZE then
			if is_processing then
				-- Mark that we have pending work for when current processing finishes
				pending_scan = true
				core.log("verbose", "[ai_filter_watcher] Scan requested but busy, marking as pending")
			else
				-- Start processing immediately
				process_batch()
			end
		else
			core.log("verbose", string.format(
				"[ai_filter_watcher] Buffer too small (%d/%d), skipping scan",
				#message_buffer, MIN_BATCH_SIZE
			))
		end
	end

	-- Clean up old history every hour
	if cleanup_acc >= 3600 then
		cleanup_acc = 0
		if player_history_loaded then
			cleanup_player_history()
		end
	end
end)

-- Chat command for configuration and status
if not core.registered_privileges.filtering then
	core.register_privilege("filtering", "Filter manager")
end

core.register_chatcommand("ai_watcher", {
	description = "Configure and monitor AI watcher",
	params = "<command> [args]",
	privs = { filtering = true },
	func = function(name, param)
		local cmd = param:match("^%s*(%S+)") or "status"

		if cmd == "status" then
			-- Count unique players in history
			local unique_players = 0
			local total_entries = 0
			if player_history_loaded then
				for player_name, history in pairs(player_history) do
					unique_players = unique_players + 1
					total_entries = total_entries + #history
				end
			end

			local function val_or_default(v)
				return v ~= nil and tostring(v) or "not set (using API default)"
			end

			local status_text = string.format([[
AI Watcher Status:
- Mode: %s
- System prompt: %s
- Scan interval: %d seconds
- Min batch size: %d messages
- History size: %d messages (stored: %d)
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
				is_processing and "Yes (call_id: " .. active_call_id .. ")" or "No",
				pending_scan and "Yes" or "No",
				#message_buffer,
				unique_players,
				total_entries,
				val_or_default(TEMPERATURE),
				val_or_default(FREQUENCY_PENALTY),
				val_or_default(PRESENCE_PENALTY),
				DEBUG_ENABLED and "Enabled" or "Disabled",
				watcher_stats.scans_performed,
				watcher_stats.messages_processed,
				watcher_stats.actions_taken,
				os.date("%H:%M:%S", watcher_stats.last_scan_time),
				watcher_stats.last_action_time > 0 and os.date("%H:%M:%S", watcher_stats.last_action_time) or "never"
			)

			return true, status_text

		elseif cmd == "mode" then
			local mode = param:match("%s+(%S+)")
			if not mode or not (mode == "enabled" or mode == "permissive" or mode == "disabled") then
				return false, "Usage: /ai_watcher mode <enabled|permissive|disabled>"
			end

			-- If trying to enable but prompt isn't ready
			if (mode == "enabled" or mode == "permissive") and not PROMPT_READY then
				return false, "Cannot enable watcher: system prompt not loaded. Use '/ai_watcher reload_prompt' first."
			end

			-- If disabling, abort any ongoing processing
			if mode == "disabled" and WATCHER_MODE ~= "disabled" then
				abort_current_processing()
			end

			WATCHER_MODE = mode
			relays.send_action_report("**AI Watcher**: Mode changed to %s by %s", mode, name)
			return true, string.format("Watcher mode set to: %s", mode)

		elseif cmd == "interval" then
			local interval = tonumber(param:match("%s+(%S+)"))
			if not interval or interval < 1 or interval > 3600 then
				return false, "Usage: /ai_watcher interval <seconds> (1-3600)"
			end

			SCAN_INTERVAL = interval
			time_acc = 0 -- Reset timer
			return true, string.format("Scan interval set to: %d seconds", interval)

		elseif cmd == "batch" then
			local size = tonumber(param:match("%s+(%S+)"))
			if not size or size < 1 or size > 100 then
				return false, "Usage: /ai_watcher batch <size> (1-100)"
			end

			MIN_BATCH_SIZE = size
			return true, string.format("Minimum batch size set to: %d messages", size)

		elseif cmd == "temperature" then
			local val = param:match("%s+(%S+)")
			if not val then
				return true, "Current temperature: " .. (TEMPERATURE ~= nil and tostring(TEMPERATURE) or "not set (using API default)")
			end
			local num = tonumber(val)
			if not num or num < 0 or num > 2 then
				return false, "Temperature must be a number between 0 and 2"
			end
			TEMPERATURE = num
			return true, string.format("Temperature set to: %g", TEMPERATURE)

		elseif cmd == "frequency_penalty" then
			local val = param:match("%s+(%S+)")
			if not val then
				return true, "Current frequency_penalty: " .. (FREQUENCY_PENALTY ~= nil and tostring(FREQUENCY_PENALTY) or "not set (using API default)")
			end
			local num = tonumber(val)
			if not num or num < -2 or num > 2 then
				return false, "Frequency penalty must be a number between -2 and 2"
			end
			FREQUENCY_PENALTY = num
			return true, string.format("Frequency penalty set to: %g", FREQUENCY_PENALTY)

		elseif cmd == "presence_penalty" then
			local val = param:match("%s+(%S+)")
			if not val then
				return true, "Current presence_penalty: " .. (PRESENCE_PENALTY ~= nil and tostring(PRESENCE_PENALTY) or "not set (using API default)")
			end
			local num = tonumber(val)
			if not num or num < -2 or num > 2 then
				return false, "Presence penalty must be a number between -2 and 2"
			end
			PRESENCE_PENALTY = num
			return true, string.format("Presence penalty set to: %g", PRESENCE_PENALTY)

		elseif cmd == "debug" then
			local val = param:match("%s+(%S+)")
			if not val then
				return true, "Debug logging is currently " .. (DEBUG_ENABLED and "enabled" or "disabled")
			end
			if val == "on" then
				DEBUG_ENABLED = true
				return true, "Debug logging enabled"
			elseif val == "off" then
				DEBUG_ENABLED = false
				return true, "Debug logging disabled"
			else
				return false, "Usage: /ai_watcher debug [on|off]"
			end

		elseif cmd == "process" then
			local force = param:match("%s+force")
			if #message_buffer < MIN_BATCH_SIZE and not force then
				return false, string.format(
					"Buffer has only %d messages (need %d). Use '/ai_watcher process force' to override.",
					#message_buffer, MIN_BATCH_SIZE
				)
			end

			if is_processing then
				pending_scan = true
				return true, string.format(
					"Already processing batch %d. New scan will start when current batch finishes.",
					active_call_id
				)
			end

			local count = #message_buffer
			process_batch()
			return true, string.format("Processing batch of %d messages", count)

		elseif cmd == "dump" then
			local dump_text = string.format("Current message buffer (%d messages):\n", #message_buffer)

			if #message_buffer == 0 then
				dump_text = dump_text .. "(empty)"
			else
				for i, msg in ipairs(message_buffer) do
					dump_text = dump_text .. string.format("%d. [%s] <%s>: %s\n",
						i,
						os.date("%H:%M", msg.time),
						msg.name,
						msg.message
					)
				end
			end

			return true, dump_text

		elseif cmd == "abort" then
			if is_processing then
				abort_current_processing()
				relays.send_action_report("**AI Watcher**: Current processing aborted by %s", name)
				return true, "Ongoing AI processing aborted"
			elseif pending_scan then
				pending_scan = false
				relays.send_action_report("**AI Watcher**: Pending scan cancelled by %s", name)
				return true, "Pending scan cancelled"
			else
				return false, "No processing or pending scan to abort"
			end

		elseif cmd == "clear" then
			local what = param:match("%s+(%S+)") or "buffer"

			if what == "buffer" then
				local count = #message_buffer
				message_buffer = {}
				relays.send_action_report("**AI Watcher**: Cleared %d messages from buffer by %s", count, name)
				return true, string.format("Cleared %d messages from buffer", count)
			elseif what == "stats" then
				watcher_stats = {
					scans_performed = 0,
					messages_processed = 0,
					actions_taken = 0,
					last_scan_time = 0,
					last_action_time = 0
				}
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
			local player_name = param:match("%s+(%S+)")
			if not player_name then
				return false, "Usage: /ai_watcher player_history <player_name>"
			end

			local history = get_player_moderation_history(player_name)
			if #history == 0 then
				return true, string.format("No recent moderation history for player '%s'", player_name)
			end

			local history_text = string.format("Moderation history for '%s' (last %d hours):\n",
				player_name, math.floor(HISTORY_TRACKING_TIME / 3600))
			history_text = history_text .. format_player_history(history)
			return true, history_text

		elseif cmd == "reload_prompt" then
			if load_system_prompt() then
				relays.send_action_report("**AI Watcher**: System prompt reloaded by %s", name)
				return true, "System prompt reloaded successfully"
			else
				return false, "Failed to reload system prompt"
			end

		elseif cmd == "help" then
			local help = [[AI Watcher Commands:
  status                - Show current status and statistics
  mode <mode>           - Set mode: enabled, permissive, disabled
  interval <seconds>    - Set scan interval (1-3600)
  batch <size>          - Set minimum batch size (1-100)
  temperature [value]   - Get/set temperature (0-2, omit to show current)
  frequency_penalty [value] - Get/set frequency penalty (-2 to 2)
  presence_penalty [value]  - Get/set presence penalty (-2 to 2)
  debug [on|off]        - Get/set debug logging for AI conversations
  process [force]       - Process current batch immediately
  dump                  - Show current messages waiting in buffer
  abort                 - Abort ongoing processing or cancel pending scan
  clear <what>          - Clear: buffer, stats, history, or player_history
  player_history <name> - Show moderation history for a player
  reload_prompt         - Reload the system prompt from file
  help                  - Show this help]]

			return true, help

		else
			return false, "Unknown command. Use '/ai_watcher help' for available commands."
		end
	end
})

-- Initialization
core.after(0, function()
	-- Load system prompt - if fails, watcher starts disabled
	load_system_prompt()

	-- Load player history
	load_player_history()

	-- Initial cleanup
	cleanup_player_history()

	core.log("action", string.format(
		"[ai_filter_watcher] Initialized (mode: %s, prompt: %s, interval: %ds, batch: %d, debug: %s)",
		WATCHER_MODE, PROMPT_READY and "loaded" or "missing", SCAN_INTERVAL, MIN_BATCH_SIZE,
		DEBUG_ENABLED and "enabled" or "disabled"
	))

	-- Send initialization message to relays
	relays.send_action_report("**AI Watcher**: Initialized (mode: %s, prompt: %s, interval: %ds, batch: %d, debug: %s)",
		WATCHER_MODE, PROMPT_READY and "loaded" or "missing", SCAN_INTERVAL, MIN_BATCH_SIZE,
		DEBUG_ENABLED and "enabled" or "disabled")

	core.log("info", string.format([[
[ai_filter_watcher] Configuration (set in minetest.conf):
  ai_filter_watcher.mode = %s (default: enabled) [enabled|permissive|disabled]
  ai_filter_watcher.scan_interval = %d (default: 60) seconds
  ai_filter_watcher.min_batch_size = %d (default: 5) messages
  ai_filter_watcher.history_size = %d (default: 100)
  ai_filter_watcher.history_tracking_time = %d (default: 86400) seconds

Use /ai_watcher command to change settings at runtime.]],
		WATCHER_MODE,
		SCAN_INTERVAL,
		MIN_BATCH_SIZE,
		HISTORY_SIZE,
		HISTORY_TRACKING_TIME
	))
end)