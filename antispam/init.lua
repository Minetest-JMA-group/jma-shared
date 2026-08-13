--[[
    Anti-Spam mod for Minetest
    SPDX-License-Identifier: GPL-3.0-or-later
    Copyright (c) 2025 astra0081X (partake-kudos-only@duck.com)
    Current Date and Time (UTC): 2025-01-11 14:22:05
--]]

-- Initialize the antispam.players table as a global
antispam = { players = {} }

-- Default settings
local MIN_TIME_BETWEEN_MESSAGES = 6 -- Minimum seconds between messages
local MIN_TIME_BETWEEN_MESSAGES_USEC = MIN_TIME_BETWEEN_MESSAGES * 1e6
local MESSAGES_BEFORE_WARN = 4 -- Messages before first warning
local WARNS_BEFORE_MUTE = 2 -- Number of warnings before mute
local REPEATS_BEFORE_WARN = 3 -- Repeated messages before first warning
local REPEATS_BEFORE_MUTE = 4 -- Repeated messages before mute
local MESSAGE_RESET_TIME = 30 -- Seconds until message count resets
local MESSAGE_RESET_TIME_USEC = MESSAGE_RESET_TIME * 1e6
local MUTE_DURATION = 600 -- In seconds
-- Entropy check: long messages made of very few different letters (after
-- lowercasing) are character-level repetition, e.g. "spam spam spam spam...".
-- Only Latin and Cyrillic letters are counted; other scripts (Chinese etc.)
-- are skipped entirely, so they neither raise nor lower the entropy.
local ENTROPY_WARN_THRESHOLD = 3.0 -- bits per character
local MIN_ENTROPY_LENGTH = 24 -- message byte length before entropy is computed
local MIN_ENTROPY_LETTERS = 24 -- Latin/Cyrillic letters before entropy is judged
-- Color scheme
local COLORS = {
	WARNING = core.get_color_escape_sequence("#FFBB33"),
	SUCCESS = core.get_color_escape_sequence("#44FF44"),
	ERROR = core.get_color_escape_sequence("#FF5555"),
	TITLE = core.get_color_escape_sequence("#55CCFF"),
	TEXT = core.get_color_escape_sequence("#FFFFFF"),
	VALUE = core.get_color_escape_sequence("#FFFF55"),
}

-- Cleanup player data on leave
core.register_on_leaveplayer(function(player)
	antispam.players[player:get_player_name()] = nil
end)

local utf8_lower = utf8_simple.lower
local utf8_codes = utf8_simple.codes

local function is_latin_or_cyrillic(cp)
	return (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A)
		or (cp >= 0x400 and cp <= 0x4FF)
end

-- Shannon entropy (bits/char) over the lowercased Latin/Cyrillic letters of
-- the message; returns nil when there are too few letters to judge.
local function message_entropy(message)
	local counts, total = {}, 0
	for cp in utf8_codes(utf8_lower(message)) do
		if is_latin_or_cyrillic(cp) then
			counts[cp] = (counts[cp] or 0) + 1
			total = total + 1
		end
	end

	if total < MIN_ENTROPY_LETTERS then
		return nil
	end

	local entropy = 0
	for _, count in pairs(counts) do
		local p = count / total
		entropy = entropy - p * (math.log(p) / math.log(2))
	end
	return entropy
end

local function mute_player(name)
	local ok = simplemod.mute_ip(
		name,
		"Antispam",
		"Automatically muted by system, reason: Spamming. Please notify the server staff if you have been falsely muted.",
		MUTE_DURATION
	)
	if ok then
		core.log("action", string.format("[Antispam] Player %s muted for %d minutes.", name, MUTE_DURATION / 60))
	else
		core.log("action", string.format("[Antispam] Failed to mute player %s", name))
	end

	antispam.players[name] = nil
end

-- Chat message handler
core.register_on_chat_message(function(name, message)
	local current_time = core.get_us_time()

	-- Initialize player data if not exists
	if not antispam.players[name] then
		antispam.players[name] = {
			repeated_messages = {},
			message_count = 0,
			warned_this_burst = false,
			last_message_time = 0,
			warning_count = 0,
			last_warning_time = 0,
		}
	end

	local player = antispam.players[name]
	local time_since_last = current_time - player.last_message_time

	-- Escalates the warning counter and returns true if the player was muted
	local function escalate(warning_text)
		player.warning_count = player.warning_count + 1
		player.last_warning_time = current_time

		if player.warning_count >= WARNS_BEFORE_MUTE then
			mute_player(name)
			return true
		end

		core.chat_send_player(name, warning_text)
		return false
	end

	-- Clean old repeated messages
	for msg, data in pairs(player.repeated_messages) do
		if current_time - data.last_time >= MESSAGE_RESET_TIME_USEC then
			player.repeated_messages[msg] = nil
		end
	end

	-- Reset warning count if enough time has passed
	if current_time - player.last_warning_time >= MESSAGE_RESET_TIME_USEC then
		player.warning_count = 0
	end

	-- Entropy check, only for long messages
	local low_entropy = false
	if #message >= MIN_ENTROPY_LENGTH then
		local entropy = message_entropy(message)
		if entropy and entropy < ENTROPY_WARN_THRESHOLD then
			low_entropy = true
		end
	end

	local slow_down_text = COLORS.WARNING .. string.format(
		"[AntiSpam] Warning [%d/%d]: Please slow down! Wait %d seconds between messages.",
		player.warning_count + 1, WARNS_BEFORE_MUTE, MIN_TIME_BETWEEN_MESSAGES)
	local spam_like_text = COLORS.WARNING .. string.format(
		"[AntiSpam] Warning [%d/%d]: Message looks like spam (too few different characters).",
		player.warning_count + 1, WARNS_BEFORE_MUTE)

	-- Check message frequency. Warn only once per burst; a burst that keeps
	-- going past MESSAGES_BEFORE_WARN * WARNS_BEFORE_MUTE escalates to a mute.
	if time_since_last < MIN_TIME_BETWEEN_MESSAGES_USEC then
		player.message_count = player.message_count + 1

		if not player.warned_this_burst then
			if player.message_count >= MESSAGES_BEFORE_WARN then
				player.warned_this_burst = true
				if escalate(slow_down_text) then return true end
			elseif low_entropy then
				player.warned_this_burst = true
				if escalate(spam_like_text) then return true end
			end
		end

		if player.message_count >= MESSAGES_BEFORE_WARN * WARNS_BEFORE_MUTE then
			mute_player(name)
			return true
		end
	else
		player.message_count = 1
		player.warned_this_burst = false
		if low_entropy then
			-- a lone long low-entropy message, not part of a burst
			player.warned_this_burst = true
			if escalate(spam_like_text) then return true end
		end
	end

	-- Check repeated messages separately: warn once per repeated message,
	-- mute once the same message has been sent REPEATS_BEFORE_MUTE times
	local rep_data = player.repeated_messages[message]
	if rep_data then
		rep_data.count = rep_data.count + 1
		rep_data.last_time = current_time

		if rep_data.count >= REPEATS_BEFORE_MUTE then
			mute_player(name)
			return true
		end

		if rep_data.count >= REPEATS_BEFORE_WARN and not rep_data.warned then
			rep_data.warned = true
			if escalate(COLORS.WARNING .. string.format(
					"[AntiSpam] Warning [%d/%d]: Please avoid repeating the same message. Wait %d seconds.",
					player.warning_count + 1, WARNS_BEFORE_MUTE, MESSAGE_RESET_TIME)) then
				return true
			end
		end
	else
		player.repeated_messages[message] = {
			count = 1,
			last_time = current_time,
			warned = false,
		}
	end

	player.last_message_time = current_time

	return false
end)

-- Chat command for configuration
core.register_chatcommand("antispam", {
	description = "Configure anti-spam settings",
	params = "<setting> <value>",
	privs = { filtering = true },
	func = function(name, param)
		local option, value = param:match("^(%S+)%s+(%d+)$")

		if not option or not value then
			local help = {
				COLORS.TITLE .. "Anti-Spam Settings",
				COLORS.TEXT
					.. "• speed: "
					.. COLORS.VALUE
					.. "Seconds between messages "
					.. COLORS.TEXT
					.. "(default: "
					.. COLORS.VALUE
					.. "6"
					.. COLORS.TEXT
					.. ")",
				COLORS.TEXT
					.. "• warn: "
					.. COLORS.VALUE
					.. "Messages before warning "
					.. COLORS.TEXT
					.. "(default: "
					.. COLORS.VALUE
					.. "4"
					.. COLORS.TEXT
					.. ")",
				COLORS.TEXT
					.. "• mute: "
					.. COLORS.VALUE
					.. "Warnings before mute "
					.. COLORS.TEXT
					.. "(default: "
					.. COLORS.VALUE
					.. "2"
					.. COLORS.TEXT
					.. ")",
				COLORS.TEXT
					.. "• rwarn: "
					.. COLORS.VALUE
					.. "Repeated messages before warning "
					.. COLORS.TEXT
					.. "(default: "
					.. COLORS.VALUE
					.. "3"
					.. COLORS.TEXT
					.. ")",
				COLORS.TEXT
					.. "• rmute: "
					.. COLORS.VALUE
					.. "Repeated messages before mute "
					.. COLORS.TEXT
					.. "(default: "
					.. COLORS.VALUE
					.. "4"
					.. COLORS.TEXT
					.. ")",
				COLORS.TEXT
					.. "• duration: "
					.. COLORS.VALUE
					.. "Duration of mute "
					.. COLORS.TEXT
					.. "(default: "
					.. COLORS.VALUE
					.. "10 minutes"
					.. COLORS.TEXT
					.. ")",
				COLORS.TEXT
					.. "• reset: "
					.. COLORS.VALUE
					.. "Seconds until warnings and repeated messages reset "
					.. COLORS.TEXT
					.. "(default: "
					.. COLORS.VALUE
					.. "30"
					.. COLORS.TEXT
					.. ")",
				"",
				COLORS.TITLE .. "Usage: " .. COLORS.TEXT .. "/antispam <setting> <value>",
			}
			return false, table.concat(help, "\n")
		end

		value = tonumber(value)
		if not value or value < 1 then
			return false, COLORS.ERROR .. "Error: Value must be positive!"
		end

		local options = {
			speed = {
				update = function(v)
					MIN_TIME_BETWEEN_MESSAGES = v
					MIN_TIME_BETWEEN_MESSAGES_USEC = v * 1e6
				end,
				name = "message speed",
				desc = "seconds between messages",
			},
			warn = {
				update = function(v)
					MESSAGES_BEFORE_WARN = v
				end,
				name = "warning threshold",
				desc = "messages before warning",
			},
			mute = {
				update = function(v)
					WARNS_BEFORE_MUTE = v
				end,
				name = "warnings before mute",
				desc = "warnings before mute",
			},
			rwarn = {
				update = function(v)
					REPEATS_BEFORE_WARN = v
				end,
				name = "repeated messages before warning",
				desc = "repeated messages",
			},
			rmute = {
				update = function(v)
					REPEATS_BEFORE_MUTE = v
				end,
				name = "repeated messages before mute",
				desc = "repeated messages",
			},
			duration = {
				update = function(v)
					MUTE_DURATION = v * 60 -- Input should be in minutes
				end,
				name = "duration of mute",
				desc = "minutes",
			},
			reset = {
				update = function(v)
					MESSAGE_RESET_TIME = v
					MESSAGE_RESET_TIME_USEC = v * 1e6
				end,
				name = "reset time",
				desc = "seconds until warnings and repeated messages reset",
			},
		}

		local handler = options[option]
		if handler then
			handler.update(value)
			return true,
				COLORS.SUCCESS
					.. "[Anti-Spam] "
					.. COLORS.TEXT
					.. "Updated "
					.. COLORS.VALUE
					.. handler.name
					.. COLORS.TEXT
					.. " to "
					.. COLORS.VALUE
					.. value
					.. " "
					.. COLORS.TEXT
					.. handler.desc
		else
			return false, COLORS.ERROR .. "Error: Invalid setting! Use /antispam for help."
		end
	end,
})
