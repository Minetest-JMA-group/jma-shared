-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović
---@diagnostic disable: need-check-nil

local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)
local storage = core.get_mod_storage()
local is_discord = core.global_exists("discord")
local is_xban = core.global_exists("xban")
local is_essentials = core.global_exists("essentials")

ai_filter = {
	HISTORY_SIZE = tonumber(core.settings:get("ai_filter.history_size")) or 100,
	INITIAL_MESSAGES = tonumber(core.settings:get("ai_filter.initial_messages")) or 5,
	SYSTEM_PROMPT = [[You are an AI moderator that reviews potentially inappropriate chat messages.
You have access to chat history and moderation tools.

Your task is to analyze messages for violations and take appropriate action.
Use minimal words, focus only on the decision.

You have access to:
1. get_history(messages) - Get additional chat history (use sparingly, max 2 calls)
2. warn_player(name, reason) - Show warning form to player
3. mute_player(name, duration, reason) - Mute player (duration in minutes)

Decision guidelines:
- Minor issues: Use warn_player with brief reason
- Serious/repeated: Use mute_player (duration: 5-60 minutes based on severity)
- Very severe: Use mute_player with long duration (60+ minutes)

DO NOT engage in conversation. DO NOT explain decisions to users.
After making decision with tools, end your response.]]
}

-- Chat history storage (circular buffer)
local chat_history = {}
local history_index = 1

local regex_ctx

local ai_calls = {}

regex_ctx = regex.create({
	storage = storage,
	path = modpath .. "/ai_triggers",
	list_name = "ai_triggers",
	storage_key = "ai_triggers",
	help_prefix = [[AI Filter - These regex patterns trigger AI moderation.

List of available commands:
stats: Show AI filter statistics
clear_history: Clear stored chat history

]],
	logger = function(level, message)
		core.log(level, "[ai_filter] " .. message)
	end
})

if not regex_ctx then
	core.log("error", "[ai_filter] Failed to create regex context")
	return
end

regex_ctx:load()

core.log("action", string.format(
	"[ai_filter] Initialized with %d trigger patterns, history size: %d",
	#regex_ctx:get_patterns(),
	ai_filter.HISTORY_SIZE
))

local function add_to_history(name, message)
	local entry = {
		name = name,
		message = message,
		time = os.time()
	}

	chat_history[history_index] = entry
	history_index = (history_index % ai_filter.HISTORY_SIZE) + 1
end

local function get_last_messages(n)
	local result = {}
	local count = math.min(n, ai_filter.HISTORY_SIZE)

	for i = 1, count do
		local idx = (history_index - i - 1) % ai_filter.HISTORY_SIZE + 1
		if chat_history[idx] then
			 -- Insert at beginning to maintain chronological order
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

local function log_ai_call(player_name, message, pattern)
	local log_msg = string.format("AI moderation triggered for <%s>: '%s' (matched pattern: '%s')",
		player_name, message, pattern
	)

	core.log("action", "[ai_filter] " .. log_msg)

	if is_discord then
		discord.send_action_report("**AI Filter**: " .. log_msg)
	end
end

local function log_skipped_call(player_name, message, pattern)
	local log_msg = string.format("AI moderation skipped for <%s>: rate limited (matched pattern: '%s')",
		player_name, pattern
	)

	core.log("verbose", "[ai_filter] " .. log_msg)

	if is_discord then
		discord.send_action_report("**AI Filter**: " .. log_msg)
	end
end

local function create_ai_context(player_name, message, pattern)
	local context = cloudai.get_context()

	context:set_system_prompt(ai_filter.SYSTEM_PROMPT)

	context:add_tool({
		name = "get_history",
		func = function(args)
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
		description = "Get additional chat history for context",
		strict = true,
		properties = {
			messages = {
				type = "integer",
				description = "Number of previous messages to retrieve (1-50)"
			}
		}
	})

	context:add_tool({
		name = "warn_player",
		func = function(args)
			if not args or not args.reason then
				return {error = "Missing 'reason' parameter"}
			end

			if not args.name then
				args.name = player_name
			end

			if is_essentials then
				essentials.show_warn_formspec(args.name, args.reason, "AI Moderator")
				return {success = true, action = "warned", reason = args.reason}
			else
				return {error = "Essentials mod not available"}
			end
		end,
		description = "Show warning form to player",
		strict = true,
		properties = {
			name = {
				type = "string",
				description = "Player name to warn (defaults to current player)"
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
			if not args or not args.reason then
				return {error = "Missing 'reason' parameter"}
			end

			if not args.name then
				args.name = player_name
			end

			local duration = tonumber(args.duration) or 10
			if duration < 1 then duration = 1 end
			if duration > 1440 then duration = 1440 end

			if is_xban then
				local expires = os.time() + (duration * 60)
				local success, err = xban.mute_player(args.name, "AI Moderator", expires, args.reason)

				if success then
					return {
						success = true,
						action = "muted",
						duration = duration,
						reason = args.reason
					}
				else
					return {error = err}
				end
			else
				return {error = "XBan mod not available"}
			end
		end,
		description = "Mute player for specified duration",
		strict = true,
		properties = {
			name = {
				type = "string",
				description = "Player name to mute (defaults to current player)"
			},
			duration = {
				type = "integer",
				description = "Mute duration in minutes (1-1440)"
			},
			reason = {
				type = "string",
				description = "Reason for muting"
			}
		}
	})

	local initial_history = get_last_messages(ai_filter.INITIAL_MESSAGES)
	local formatted_history = format_history(initial_history)

	local prompt = string.format([[Player "%s" sent a message that matched pattern: "%s"

Recent chat history:
%s

Current message from %s: "%s"

Analyze this situation and take appropriate moderation action if needed.
Use tools only if necessary.]],
		player_name, pattern, formatted_history, player_name, message
	)

	return context, prompt
end

local function handle_ai_response(history, response, error)
	if error then
		core.log("warning", "[ai_filter] AI error: " .. tostring(error))
	elseif response then
		core.log("verbose", "[ai_filter] AI completed moderation")
	end
end

local function process_message(name, message)
	if not regex_ctx:match(message) then
		return false
	end

	local pattern = regex_ctx:get_last_match()

	-- Rate limiting: 10 second cooldown per player
	local now = os.time()
	local last_call = ai_calls[name] or 0
	if now - last_call < 10 then
		log_skipped_call(name, message, pattern)
		return false
	end
	ai_calls[name] = now

	log_ai_call(name, message, pattern)

	local context, prompt = create_ai_context(name, message, pattern)

	local success, err = context:call(prompt, handle_ai_response)
	if not success then
		core.log("warning", "[ai_filter] Failed to call AI: " .. tostring(err))
		-- Don't clear ai_calls[name] on failure - keep rate limiting
	end

	return true
end

chat_lib.register_on_chat_message(3, function(name, message)
	if message:sub(1, 1) == "/" then
		return false
	end

	add_to_history(name, message)

	return process_message(name, message)
end)

if not core.registered_privileges.filtering then
	core.register_privilege("filtering", "Filter manager")
end

core.register_chatcommand("ai_filter", {
	description = "Manage AI filter trigger patterns",
	params = "<command> <args>",
	privs = { filtering = true },
	func = function(name, param)
		local cmd = param:match("^%s*(%S+)")

		if cmd == "stats" then
			local history_count = 0
			for _ in pairs(chat_history) do
				history_count = history_count + 1
			end

			local triggers_count = #regex_ctx:get_patterns()
			local ai_calls_count = 0
			for _, time in pairs(ai_calls) do
				if os.time() - time < 3600 then
					ai_calls_count = ai_calls_count + 1
				end
			end

			local stats = string.format([[
AI Filter Statistics:
- Stored chat messages: %d/%d
- Trigger patterns: %d
- AI calls (last hour): %d
- Config: history_size=%d, initial_messages=%d
]],
				history_count, ai_filter.HISTORY_SIZE,
				triggers_count,
				ai_calls_count,
				ai_filter.HISTORY_SIZE, ai_filter.INITIAL_MESSAGES
			)

			return true, stats

		elseif cmd == "clear_history" then
			chat_history = {}
			history_index = 1
			return true, "Chat history cleared"
		end

		local success, message = regex_ctx:handle_command(name, param)
		if not success and message == nil then
			return false, "Unknown command. Use /ai_filter help"
		end

		return success, message
	end,
})

core.register_on_leaveplayer(function(player)
	local player_name = player:get_player_name()
	if player_name and ai_calls[player_name] then
		ai_calls[player_name] = nil
	end
end)

local function cleanup_ai_calls()
	local now = os.time()
	local removed = 0

	for name, time in pairs(ai_calls) do
		if now - time > 3600 then
			ai_calls[name] = nil
			removed = removed + 1
		end
	end

	if removed > 0 then
		core.log("verbose", string.format("[ai_filter] Cleaned up %d old AI call records", removed))
	end

	core.after(300, cleanup_ai_calls)
end

core.after(300, cleanup_ai_calls)

core.log("action", "[ai_filter] Mod initialized successfully")

core.log("info", string.format([[
[ai_filter] Configuration options:
  ai_filter.history_size = %d (default: 100) - Number of messages to keep in history
  ai_filter.initial_messages = %d (default: 5) - Messages to send to AI initially

Note: AI settings (url, model, timeout, api_key) are managed by the cloudai mod
]],
	ai_filter.HISTORY_SIZE,
	ai_filter.INITIAL_MESSAGES
))