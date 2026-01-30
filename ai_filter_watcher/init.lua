-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović
---@diagnostic disable: need-check-nil

local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)
local storage = core.get_mod_storage()
local is_discord = core.global_exists("discord")
local is_xban = core.global_exists("xban")
local is_essentials = core.global_exists("essentials")

-- Configuration with defaults
local WATCHER_ENABLED = core.settings:get_bool("ai_filter_watcher.enabled", true)
local WATCHER_MODE = core.settings:get("ai_filter_watcher.mode") or "enabled" -- "enabled", "permissive", "disabled"
local SCAN_INTERVAL = tonumber(core.settings:get("ai_filter_watcher.scan_interval")) or 60 -- seconds
local MIN_BATCH_SIZE = tonumber(core.settings:get("ai_filter_watcher.min_batch_size")) or 5 -- messages
local HISTORY_SIZE = tonumber(core.settings:get("ai_filter_watcher.history_size")) or 100

ai_filter_watcher = {
	MODES = {
		ENABLED = "enabled",	 -- AI actions are executed
		PERMISSIVE = "permissive", -- AI actions are only logged
		DISABLED = "disabled"	 -- No AI processing
	}
}

-- Message accumulation buffer
local message_buffer = {}
-- Chat history storage (circular buffer)
local chat_history = {}
local history_index = 1

-- Statistics
local watcher_stats = {
	scans_performed = 0,
	messages_processed = 0,
	actions_taken = 0,
	last_scan_time = 0,
	last_action_time = 0
}

-- Serial processing control
local is_processing = false
local pending_scan = false  -- Flag to indicate we should scan when current processing finishes
local active_call_id = 0

local function add_to_history(name, message)
	if WATCHER_MODE == ai_filter_watcher.MODES.DISABLED then
		return
	end

	local entry = {
		name = name,
		message = message,
		time = os.time()
	}

	chat_history[history_index] = entry
	history_index = (history_index % HISTORY_SIZE) + 1
end

local function get_last_messages(n)
	local result = {}
	local count = math.min(n, HISTORY_SIZE)

	for i = 1, count do
		local idx = (history_index - i - 1) % HISTORY_SIZE + 1
		if chat_history[idx] then
			table.insert(result, 1, chat_history[idx])
		end
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
		is_processing = false
		pending_scan = false
		return
	end

	if is_processing then
		core.log("verbose", "[ai_filter_watcher] Already processing, skipping")
		return
	end

	if #message_buffer < MIN_BATCH_SIZE then
		core.log("verbose", string.format(
			"[ai_filter_watcher] Skipping scan: only %d messages in buffer (need %d)",
			#message_buffer, MIN_BATCH_SIZE
		))
		is_processing = false
		return
	end

	-- Set processing flag immediately
	is_processing = true

	-- Create a copy of the buffer and clear it
	local batch_to_process = {}
	for i, msg in ipairs(message_buffer) do
		---@diagnostic disable-next-line: undefined-field
		batch_to_process[i] = table.copy(msg)
	end
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
	local context = cloudai.get_context()

	local system_prompt = [[You are an AI moderator reviewing a batch of chat messages that have already been sent.

Your task: Review the messages and determine if any players should be warned or muted for violating rules.

Available tools (use if needed):
1. get_history(messages) - Get additional chat history for context (use ONLY if necessary)
2. warn_player(name, reason) - Warn a player for a rule violation
3. mute_player(name, duration, reason) - Mute a player (duration in minutes)

Process:
1. Review the batch of messages provided below
2. If all messages are acceptable: Do nothing (no output needed)
3. If any message violates rules:
   a. Use appropriate moderation tools (warn or mute) on the offending player(s)
   b. You may take multiple actions if multiple players violated rules

Important notes:
- These messages have ALREADY been sent to chat, you cannot block them
- Your role is RETROACTIVE moderation: punish violations that already occurred
- This is a Minetest server with PvP enabled, so messages like "kill him" could be appropriate in context
- Messages are shown as [time] <username>: message
- Use get_history tool ONLY if you cannot decide without additional context
- DO NOT explain your decisions
- DO NOT engage in conversation
- When done, do not output anything - just stop]]

	context:set_system_prompt(system_prompt)

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
				else
					return {error = "Essentials mod not available"}
				end
			else
				-- Permissive mode: just log
				action_taken = false
				result_message = string.format("[PERMISSIVE] Would have warned player '%s' for: %s", player_name, reason)
			end

			watcher_stats.actions_taken = watcher_stats.actions_taken + 1
			watcher_stats.last_action_time = os.time()

			core.log("action", "[ai_filter_watcher] " .. result_message)

			if is_discord and WATCHER_MODE == ai_filter_watcher.MODES.ENABLED then
				discord.send_action_report("**AI Watcher**: " .. result_message)
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
			end

			watcher_stats.actions_taken = watcher_stats.actions_taken + 1
			watcher_stats.last_action_time = os.time()

			core.log("action", "[ai_filter_watcher] " .. result_message)

			if is_discord and WATCHER_MODE == ai_filter_watcher.MODES.ENABLED then
				discord.send_action_report("**AI Watcher**: " .. result_message)
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

	-- Format prompt with batch
	local prompt = string.format([[Batch of %d recent messages (already sent to chat):
%s

Review these messages and take moderation actions if needed.]],
		#batch_to_process,
		formatted_batch
	)

	local success, err = context:call(prompt, function(history, response, error)
		-- Mark processing as complete
		is_processing = false

		if error then
			core.log("warning", string.format(
				"[ai_filter_watcher] AI error for batch call %d: %s",
				call_id, tostring(error)
			))
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
			process_batch()
		end
	end)

	if not success then
		core.log("warning", string.format(
			"[ai_filter_watcher] Failed to call AI for batch %d: %s",
			call_id, tostring(err)
		))
		is_processing = false

		-- Still check for pending scan
		if pending_scan then
			pending_scan = false
			process_batch()
		end
	end
end

-- Accumulate chat messages
chat_lib.register_on_chat_message(2, function(name, message)
	if message:sub(1, 1) == "/" then
		return false
	end

	-- Always add to history
	add_to_history(name, message)

	-- Add to buffer for batch processing
	table.insert(message_buffer, {
		name = name,
		message = message,
		time = os.time()
	})

	return false -- Never block messages in watcher mode
end)

-- Periodic batch processing
local time_acc = 0
core.register_globalstep(function(dtime)
	if WATCHER_MODE == ai_filter_watcher.MODES.DISABLED then
		return
	end

	time_acc = time_acc + dtime
	if time_acc < SCAN_INTERVAL then
		return
	end

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
			local status_text = string.format([[
AI Watcher Status:
- Mode: %s
- Scan interval: %d seconds
- Min batch size: %d messages
- History size: %d messages
- Currently processing: %s
- Pending scan: %s
- Message buffer: %d messages
- Statistics:
  • Scans performed: %d
  • Messages processed: %d
  • Actions taken: %d
  • Last scan: %s
  • Last action: %s
]],
				WATCHER_MODE,
				SCAN_INTERVAL,
				MIN_BATCH_SIZE,
				HISTORY_SIZE,
				is_processing and "Yes (call_id: " .. active_call_id .. ")" or "No",
				pending_scan and "Yes" or "No",
				#message_buffer,
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

			WATCHER_MODE = mode
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
			-- Note: We can't actually abort an ongoing AI call, but we can clear the pending flag
			if pending_scan then
				pending_scan = false
				return true, "Pending scan cancelled"
			else
				return false, "No pending scan to abort"
			end

		elseif cmd == "clear" then
			local what = param:match("%s+(%S+)") or "buffer"

			if what == "buffer" then
				local count = #message_buffer
				message_buffer = {}
				return true, string.format("Cleared %d messages from buffer", count)
			elseif what == "stats" then
				watcher_stats = {
					scans_performed = 0,
					messages_processed = 0,
					actions_taken = 0,
					last_scan_time = 0,
					last_action_time = 0
				}
				return true, "Statistics cleared"
			elseif what == "history" then
				chat_history = {}
				history_index = 1
				return true, "Chat history cleared"
			else
				return false, "Usage: /ai_watcher clear <buffer|stats|history>"
			end

		elseif cmd == "help" then
			local help = [[AI Watcher Commands:
  status                - Show current status and statistics
  mode <mode>           - Set mode: enabled, permissive, disabled
  interval <seconds>    - Set scan interval (1-3600)
  batch <size>          - Set minimum batch size (1-100)
  process [force]       - Process current batch immediately
  dump                  - Show current messages waiting in buffer
  abort                 - Cancel pending scan (if not yet started)
  clear <what>          - Clear: buffer, stats, or history
  help                  - Show this help]]

			return true, help

		else
			return false, "Unknown command. Use '/ai_watcher help' for available commands."
		end
	end
})

-- Initialization
core.after(0, function()
	core.log("action", string.format(
		"[ai_filter_watcher] Initialized (mode: %s, interval: %ds, batch: %d)",
		WATCHER_MODE, SCAN_INTERVAL, MIN_BATCH_SIZE
	))

	core.log("info", string.format([[
[ai_filter_watcher] Configuration (set in minetest.conf):
  ai_filter_watcher.enabled = %s (default: true)
  ai_filter_watcher.mode = %s (default: enabled) [enabled|permissive|disabled]
  ai_filter_watcher.scan_interval = %d (default: 60) seconds
  ai_filter_watcher.min_batch_size = %d (default: 5) messages
  ai_filter_watcher.history_size = %d (default: 100)

Use /ai_watcher command to change settings at runtime.]],
		tostring(WATCHER_ENABLED),
		WATCHER_MODE,
		SCAN_INTERVAL,
		MIN_BATCH_SIZE,
		HISTORY_SIZE
	))
end)