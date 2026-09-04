-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović
---@diagnostic disable: need-check-nil

local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)
local storage = core.get_mod_storage()
local is_essentials = core.global_exists("essentials")
local is_discord_available = core.global_exists("discord") and discord.enabled

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
local ACTION_RATE_LIMIT = nil		-- nil = unlimited
local HIDE_USERNAMES = false

local PROMPT_READY = false
local message_buffer = {}
local chat_history = {}		-- newest at the end, trimmed to HISTORY_SIZE
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

-- Message token
-- Message tokens for start and end of each message.
local msg_token_start = ""
local msg_token_end = ""
-- length of message token
local msg_token_length = 3

--Simple code generator for the message tokens.
local function generate_msg_token()
    for i = 1, msg_token_length do
        msg_token_start = msg_token_start .. tostring(math.random(0,9))
        msg_token_end = msg_token_end .. tostring(math.random(0,9))
    end
end

-- Parse "<count>/<unit>" (e.g. "10/1m", "5/60", "2/1h30m") into
-- { count, seconds, raw }. Returns nil on invalid input. Values are
-- validated here, at the chat command, so the database only ever
-- holds values this function accepts.
local function parse_action_rate_limit(value)
	local count_str, unit_str = tostring(value):match("^(%d+)/(%S+)$")
	if not count_str or not unit_str then
		return nil
	end
	-- unit must consist solely of parse_time tokens, e.g. "1m", "60", "1h30m"
	if unit_str:gsub("%d+[smhdDwWMYy]?", "") ~= "" then
		return nil
	end
	local count = tonumber(count_str)
	local seconds = algorithms.parse_time(unit_str)
	if not count or count < 1 or seconds < 1 then
		return nil
	end
	return { count = count, seconds = seconds, raw = value }
end

-- Single source of truth for settings: key -> { default, apply }.
-- update_setting_from_db iterates this table with a per-key guard like
-- filter_caps, so a new setting can't be applied live but forgotten at
-- boot (which would silently revert it on restart). Missing values
-- fall back to the setting's default.
local settings_appliers = {
	mode = {
		default = "enabled",
		apply = function(v)
			if v == "enabled" or v == "permissive" or v == "disabled" then WATCHER_MODE = v end
		end,
	},
	scan_interval = {
		default = "60",
		apply = function(v)
			local n = tonumber(v)
			if n and n >= 1 and n <= 3600 then SCAN_INTERVAL = n end
		end,
	},
	min_batch_size = {
		default = "5",
		apply = function(v)
			local n = tonumber(v)
			if n and n >= 1 and n <= 100 then MIN_BATCH_SIZE = n end
		end,
	},
	history_size = {
		default = "100",
		apply = function(v)
			local n = tonumber(v)
			if n and n >= 10 and n <= 20000 then HISTORY_SIZE = n end
		end,
	},
	history_tracking_time = {
		default = "86400",
		apply = function(v)
			local n = tonumber(v)
			if n and n >= 60 and n <= 2592000 then HISTORY_TRACKING_TIME = n end
		end,
	},
	temperature = {
		default = nil,
		apply = function(v)
			local n = tonumber(v)
			if not n or (n >= 0 and n <= 2) then TEMPERATURE = n end   -- allow nil
		end,
	},
	frequency_penalty = {
		default = nil,
		apply = function(v)
			local n = tonumber(v)
			if not n or (n >= -2 and n <= 2) then FREQUENCY_PENALTY = n end
		end,
	},
	presence_penalty = {
		default = nil,
		apply = function(v)
			local n = tonumber(v)
			if not n or (n >= -2 and n <= 2) then PRESENCE_PENALTY = n end
		end,
	},
	debug_enabled = {
		default = "false",
		apply = function(v)
			DEBUG_ENABLED = (v == "true")
		end,
	},
	hide_usernames = {
		default = "false",
		-- Changes what the AI sees mid-conversation: an active run's prompt
		-- and tool results were rendered under the old flag, so flipping it
		-- mid-run would show a name masked in one render and plaintext in
		-- the next. Queued until the run completes (see apply_setting_deferred).
		defer_while_processing = true,
		apply = function(v)
			HIDE_USERNAMES = (v == "true")
		end,
	},
	action_rate_limit = {
		default = nil,
		apply = function(v)
			ACTION_RATE_LIMIT = parse_action_rate_limit(v)
		end,
	},
}

local pending_settings = {}	-- settings queued until the active AI run finishes

-- === Privacy: hash player names before they reach the AI ===
--
-- Every player name sent to the AI is replaced with a salted hash, so the
-- AI provider never sees plaintext usernames. The salt is regenerated every
-- server run, making the hashes per-run pseudonyms. Names are translated
-- back to real names only when the AI's tool calls are executed, so
-- moderators and the rest of the system keep seeing true usernames.
--
-- PcgRandom:range() takes signed 32-bit args, so the max usable value is
-- 2^31-1 (passing 2^32-1 wraps to -1 and throws "Invalid range (max < min)").
-- 31 bits per word, 93 bits total - plenty for per-run pseudonyms.

local privacy_rng = PcgRandom(os.time())
local privacy_salt = string.format("%08x%08x%08x",
	privacy_rng:next(0, 2147483647),
	privacy_rng:next(0, 2147483647),
	privacy_rng:next(0, 2147483647))

local name_to_hash = {}		-- name -> hash
local hash_to_name = {}		-- hash -> name
local name_tokens = {}		-- name -> { stripped whitespace tokens }
local first_token_index = {}	-- stripped first token -> { names }, longest sequence first
local pending_name_adds = {}	-- names waiting for the active AI run to finish

-- Strip non-name characters from each side of a word, so e.g. "@bob",
-- "bob!", "(bob,)" or "[LmaoRocal_]>:" all match. Mirrors filter_caps'
-- stripping, but without a wrapper-count cap: a cap would miss names
-- wrapped by more than 2 characters, and an uncapped strip cannot create
-- false matches because the result is looked up exactly in the table. The
-- same function is used on registered names and on message tokens, so
-- matching stays symmetric.
local function strip_name_wrap(word)
	while true do
		local first = utf8_simple.sub(word, 1, 1)
		if first == "" or utf8_simple.player_name_chars[utf8_simple.codepoint(first)] then
			break
		end
		word = utf8_simple.sub(word, 2)
	end
	while true do
		local last = utf8_simple.sub(word, -1)
		if last == "" or utf8_simple.player_name_chars[utf8_simple.codepoint(last)] then
			break
		end
		word = utf8_simple.sub(word, 1, -2)
	end
	return word
end

-- Split a name into its stripped whitespace tokens, e.g.
-- "gl4iv3 [LmaoRocal_]" -> {"gl4iv3", "LmaoRocal_"}. Multi-token names
-- come from relay authors (Discord display names).
local function name_to_tokens(name)
	local tokens = {}
	for token in name:gmatch("[^ ]+") do
		tokens[#tokens + 1] = strip_name_wrap(token)
	end
	return tokens
end

-- Compute the hash for a name (sha1 truncated to 12 hex chars, extended
-- automatically on the astronomically rare collision) and register it in
-- both directions plus the multi-token index. Idempotent per name.
local function get_or_make_hash(name)
	local existing = name_to_hash[name]
	if existing then return existing end
	local full = core.sha1(name .. privacy_salt)
	local len = 12
	local hash
	repeat
		hash = full:sub(1, len)
		if not hash_to_name[hash] or hash_to_name[hash] == name then break end
		len = len + 2
	until len > #full
	hash_to_name[hash] = name
	name_to_hash[name] = hash
	local tokens = name_to_tokens(name)
	name_tokens[name] = tokens
	local list = first_token_index[tokens[1]] or {}
	-- Keep the list sorted so longer token sequences match first
	local pos = 1
	while pos <= #list and #name_tokens[list[pos]] > #tokens do
		pos = pos + 1
	end
	table.insert(list, pos, name)
	first_token_index[tokens[1]] = list
	return hash
end

-- Add a name to the identity table. While an AI run is in flight the add
-- is deferred: the run's prompt was rendered without this name, and adding
-- it mid-run would make later renders (e.g. get_history results) show a
-- hash for a person the AI saw unmasked in the prompt. Deferring keeps the
-- whole run consistent; the next run is fully masked.
local function privacy_add_name(name)
	if not name or name == "" then return end
	if is_processing then
		pending_name_adds[name] = true
		return
	end
	get_or_make_hash(name)
end

-- Apply everything queued while the active run was in flight: name adds and
-- deferred settings. Called only with is_processing already false, so the
-- next run starts with a fully consistent view.
local function flush_pending()
	for name in pairs(pending_name_adds) do
		pending_name_adds[name] = nil
		get_or_make_hash(name)
	end
	for key, value in pairs(pending_settings) do
		pending_settings[key] = nil
		local entry = settings_appliers[key]
		if entry then entry.apply(value) end
	end
end

core.register_on_joinplayer(function(player)
	privacy_add_name(player:get_player_name())
end)

-- Stop the AI immediately, whatever is in flight. Mode gates whether the
-- watcher runs at all, so aborting must be reachable from anywhere that can
-- set it — the chat command and update_setting_from_db (the shareddb
-- listener, when another instance disables the watcher).
local function abort_current_processing(reason)
	if is_processing and active_context then
		core.log("action", "[ai_filter_watcher] Aborting ongoing AI processing" ..
			(reason and (": " .. reason) or ""))
		active_context:destroy()
		active_context = nil
	end
	is_processing = false
	active_call_id = active_call_id + 1
	flush_pending()
end

-- Settings marked defer_while_processing must not flip while a context is
-- active (same reasoning as the privacy_add_name deferral above): the run
-- started with one view of names, and switching mid-run would make tool
-- results come back differently rendered than the prompt. Queue the change
-- and apply it when the run completes; the next context starts fully
-- consistent. Non-deferred settings apply immediately.
local function apply_setting_deferred(key, value)
	local entry = settings_appliers[key]
	if not entry then return end
	if is_processing then
		pending_settings[key] = value
	else
		entry.apply(value)
	end
end

local function update_setting_from_db(key)
	local errmsg = "[ai_filter_watcher] shareddb database error, cannot update settings"
	local ctx = modstorage:get_context()
	if not ctx then
		core.log("error", errmsg)
		return
	end

	-- Like filter_caps: nil (boot) loads every setting, a specific key
	-- (shareddb listener) loads just that one, unknown keys load nothing.
	-- Missing values fall back to the setting's default.
	for k, entry in pairs(settings_appliers) do
		if not key or key == k then
			local v, err = ctx:get_string(k)
			if err then
				ctx:finalize()
				core.log("error", errmsg)
				return
			end
			local value = v ~= nil and v or entry.default
			-- mode gates whether the AI runs at all, so it can't be deferred:
			-- a switch to disabled must stop an active run immediately, even
			-- when the change arrives via shareddb from another instance
			-- (same guard as the chat command, so the command's own echo
			-- doesn't double-abort).
			if k == "mode" and value == "disabled" and WATCHER_MODE ~= "disabled" then
				abort_current_processing("Watcher mode set to disabled via shareddb")
			end
			if entry.defer_while_processing then
				apply_setting_deferred(k, value)
			else
				entry.apply(value)
			end
		end
	end
	ctx:finalize()
end

shareddb.register_listener(update_setting_from_db)

local rate_count = 0
local rate_window_start = 0

-- Rate-limited wrapper for relays.send_action_report: at most
-- ACTION_RATE_LIMIT.count reports per ACTION_RATE_LIMIT.seconds window.
-- Overflowing reports are dropped to the server log instead of the
-- action channel.
local function send_action_report(fmt, ...)
	local final_msg = string.format(fmt, ...)
	local limit = ACTION_RATE_LIMIT
	if limit then
		local now = os.time()
		if now - rate_window_start >= limit.seconds then
			rate_window_start = now
			rate_count = 0
		end
		rate_count = rate_count + 1
		if rate_count > limit.count then
			core.log("action", ("[ai_filter_watcher] Action report rate limit exceeded (%d per %ds), dropping: %s"):format(
				limit.count, limit.seconds, final_msg))
			return
		end
	end
	relays.send_action_report("%s", final_msg)
end

-- "**AI Watcher**: " prefix for action reports. Pre-formatted text must be
-- embedded with "%s" (send_action_report string.formats its arguments).
local function report(fmt, ...)
	send_action_report("**AI Watcher**: " .. fmt, ...)
end

-- Persist a setting to shareddb and log failures. The DB write is the source
-- of truth: the trigger echoes it back to update_setting_from_db, which
-- re-applies the value (queuing it if a run is in flight). Callers still
-- apply locally as a fallback for when the DB is down and no echo arrives.
local function save_setting(key, value, what)
	local ctx = modstorage:get_context()
	if not ctx then
		core.log("warning", ("[ai_filter_watcher] shareddb unavailable, %s change not persisted"):format(what))
		return false
	end
	local err = ctx:set_string(key, tostring(value)) or ctx:finalize()
	if err then
		core.log("error", ("[ai_filter_watcher] Failed to write %s to shareddb: %s"):format(what, tostring(err)))
		return false
	end
	return true
end

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

-- Replace known player names in text bound for the AI with [hash].
-- Tokenizes on spaces like filter_caps; multi-token names (relay authors)
-- match by consecutive token sequence, longest first, so the whole author
-- name collapses into one hash. A no-op while hide_usernames is off.
local function mask_names(text)
	if not HIDE_USERNAMES or not text then return text end
	local tokens, stripped = {}, {}
	for token in text:gmatch("[^ ]+") do
		tokens[#tokens + 1] = token
		stripped[#stripped + 1] = strip_name_wrap(token)
	end
	local out = {}
	local i = 1
	while i <= #tokens do
		local list = first_token_index[stripped[i]]
		local matched
		if list then
			for _, name in ipairs(list) do
				local nt = name_tokens[name]
				local ok = true
				for j = 1, #nt do
					if stripped[i + j - 1] ~= nt[j] then
						ok = false
						break
					end
				end
				if ok then
					out[#out + 1] = "[" .. name_to_hash[name] .. "]"
					i = i + #nt
					matched = true
					break
				end
			end
		end
		if not matched then
			out[#out + 1] = tokens[i]
			i = i + 1
		end
	end
	return table.concat(out, " ")
end

-- Translate [hash] (brackets optional) back to the player name in text
-- coming FROM the AI. Only hex runs that exactly match a known hash are
-- replaced, so arbitrary hex text is untouched. Bracketed forms are
-- handled first so the brackets are consumed with the hash.
local function unmask_names(text)
	if not HIDE_USERNAMES or not text then return text end
	text = text:gsub("%[([%x]+)%]", function(hash)
		return hash_to_name[hash] or ("[" .. hash .. "]")
	end)
	return (text:gsub("(%x+)", function(hash)
		return hash_to_name[hash] or hash
	end))
end

local function map_value(v, fn)
	if type(v) == "table" then
		local out = {}
		for k, val in pairs(v) do
			out[k] = map_value(val, fn)
		end
		return out
	elseif type(v) == "string" then
		return fn(v)
	end
	return v
end

-- Wrap a tool func so the AI's arguments are de-hashed before the call
-- executes (logs, action reports and moderation history see real names)
-- and the result is re-hashed before it is fed back to the AI on the next
-- round-trip.
local function privacy_wrap(func)
	return function(args)
		local result = func(map_value(args, unmask_names))
		return map_value(result, mask_names)
	end
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

-- Chat history is a plain list, newest at the end; the oldest entry is
-- trimmed once it outgrows HISTORY_SIZE. get_history reads at most 50
-- entries, and even at HISTORY_SIZE = 20000 the per-message trim is a
-- memmove of tens of microseconds — a ring buffer would only add
-- modulo/wrap complexity for no measurable gain.
local function add_to_history(name, msg, tag)
	if WATCHER_MODE == ai_filter_watcher.MODES.DISABLED then return end
	chat_history[#chat_history + 1] = { name = name, message = msg, time = os.time(), tag = tag }
	if #chat_history > HISTORY_SIZE then
		table.remove(chat_history, 1)
	end
end

local function get_last_messages(n)
	local first = math.max(1, #chat_history - math.floor(n) + 1)
	local result = {}
	for i = first, #chat_history do
		result[#result + 1] = chat_history[i]
	end
	return result
end

local function format_history(msgs)
	local lines = {}
	for msg_index, m in ipairs(msgs) do
		if m.tag then
			table.insert(lines, ("%s. {%s) [%s] <%s> [%s]: %s (%s}"):format(msg_index, msg_token_start, os.date("%H:%M", m.time), m.name, m.tag, m.message, msg_token_end))
		else
			table.insert(lines, ("%s. {%s) [%s] <%s>: %s (%s}"):format(msg_index, msg_token_start, os.date("%H:%M", m.time), m.name, m.message, msg_token_end))
		end
	end
	return table.concat(lines, "\n")
end

-- Single entry point for all captured communication: public chat, chat
-- command content, inbound relay messages and other mods' API calls.
local function record_message(name, message, tag)
	if not message then return end
	add_to_history(name, message, tag)
	if WATCHER_MODE ~= ai_filter_watcher.MODES.DISABLED then
		table.insert(message_buffer, { name = name, message = message, time = os.time(), tag = tag })
	end
end

-- Channels whose content lives in the chat command's arguments. A command is
-- wrapped only if it exists on this server, so this stays game-agnostic.
-- recv+content: param is "<recipient> <message>", the tag receives the recipient
-- content: the whole param is the message
local comm_commands = {
	msg  = { tag = "PM to %s",       mode = "recv+content" },
	t    = { tag = "TEAM",           mode = "content" },
	g    = { tag = "GLOBAL",         mode = "content" },
	-- /me broadcasts "* name <message>"; the rendered line is recorded as a
	-- regular message, no tag needed — the form is self-describing
	me   = { mode = "content", render = function(name, content)
		return "* " .. name .. " " .. content
	end },
	mail = { tag = "MAIL to %s",     mode = "recv+content" },
	bmsg = { tag = "BABEL PM to %s", mode = "recv+content" },
	xmsg = { tag = "XMPP-DM",        mode = "content" },
	xdm = { tag = "XMPP-DM to %s",   mode = "recv+content" },
}

local wrapped_funcs = {}

local function wrap_comm_command(command_name, def)
	local cfg = comm_commands[command_name]
	local func = def and def.func
	if not cfg or not func or wrapped_funcs[func] then
		return
	end
	-- Only CTF's email mod has a chat-argument /mail; the mt-mods mail command
	-- (Mineclone2/Creative) just opens a compose GUI, its content arrives via
	-- ai_filter_watcher.add_message instead. Checked at wrap time, after all
	-- mods have loaded.
	if command_name == "mail" and not core.global_exists("email") then
		return
	end
	wrapped_funcs[func] = true
	def.func = function(name, param)
		local recipient, content
		if cfg.mode == "recv+content" then
			recipient, content = tostring(param or ""):match("^%s*(%S+)%s+(.+)$")
		else
			content = tostring(param or ""):match("^%s*(.-)%s*$")
			if content == "" then content = nil end
		end
		if content then
			local tag = cfg.tag
			if recipient then tag = tag:format(recipient) end
			if cfg.render then content = cfg.render(name, content) end
			record_message(name, content, tag)
		end
		return func(name, param)
	end
end

-- Wrap communication commands registered after this mod loads
local original_register_chatcommand = core.register_chatcommand
core.register_chatcommand = function(name, def)
	wrap_comm_command(name, def)
	return original_register_chatcommand(name, def)
end

local original_override_chatcommand = core.override_chatcommand
core.override_chatcommand = function(name, redef)
	wrap_comm_command(name, redef)
	return original_override_chatcommand(name, redef)
end

-- Wrap communication commands registered before this mod loaded (engine
-- builtins and mods that load earlier than us)
for name, def in pairs(core.registered_chatcommands) do
	wrap_comm_command(name, def)
end

-- Universal API for other communication mods (e.g. GUI-composed mail) to feed
-- a message into the watcher's batch and history stream.
function ai_filter_watcher.add_message(name, message, tag)
	record_message(name, message, tag)
end

local function process_batch()
	if WATCHER_MODE == ai_filter_watcher.MODES.DISABLED then
		if is_processing then abort_current_processing() end
		return
	end

	-- A scan is already in flight: aborting it would discard its batch's
	-- review (those messages left the buffer when it started). Skip instead
	-- and let the buffer keep accumulating; the caller retries once the
	-- current run completes.
	if is_processing then
		return
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

	generate_msg_token()
    local formatted_batch = format_history(batch)
	local context, err = cloudai.get_context()
	if not context then
		core.log("error", ("[ai_filter_watcher] Failed to get AI context for batch %d: %s"):format(call_id, tostring(err)))
		is_processing = false
		flush_pending()
		-- Re-queue the batch so the messages aren't lost; the next scan
		-- retries once cloudai is available again.
		for _, m in ipairs(batch) do
			message_buffer[#message_buffer + 1] = m
		end
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
		func = privacy_wrap(function(args)
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
		end),
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
		func = privacy_wrap(function(args)
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
				report("%s", msg)
			end
			watcher_stats.actions_taken = watcher_stats.actions_taken + 1
			watcher_stats.last_action_time = os.time()
			return { success = true }
		end),
		description = "Warn player for rule violation",
		strict = false,
		properties = {
			name = { type = "string", description = "Player name to warn" },
			reason = { type = "string", description = "Reason for warning" }
		}
	})

	context:add_tool({
		name = "mute_player",
		func = privacy_wrap(function(args)
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
				report("%s", msg)
			end
			watcher_stats.actions_taken = watcher_stats.actions_taken + 1
			watcher_stats.last_action_time = os.time()
			return { success = true }
		end),
		description = "Mute player for specified duration",
		strict = false,
		properties = {
			name = { type = "string", description = "Player name to mute" },
			duration = { type = "integer", description = "Mute duration in minutes", minimum = 1, maximum = 1440 },
			reason = { type = "string", description = "Reason for muting" }
		}
	})

	context:add_tool({
		name = "report_player",
		func = privacy_wrap(function(args)
			if type(args) == "string" then return { error = "Invalid JSON string" } end
			if not args or not args.reason then return {error = "Missing 'reason' parameter"} end
			local player_name = args.name
			if not player_name then return {error = "Missing 'name' parameter"} end
			local reason = args.reason
			if not is_discord_available then return {error = "Discord relay not available. Reports won't work."} end
			watcher_stats.actions_taken = watcher_stats.actions_taken + 1
			watcher_stats.last_action_time = os.time()
			local msg = string.format("**AI Watcher**: Reported player %s to moderators: %s", player_name, reason)
			discord.send_mention(msg, "1525628775923060958")
			return { success = true, message = ("Player %s reported to moderators"):format(player_name) }
		end),
		description = "Report a player to human moderators for review",
		strict = false,
		properties = {
			name = { type = "string", description = "Player name to report" },
			reason = { type = "string", description = "Detailed reason for reporting" }
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

	local prompt = mask_names(("Batch of %d recent messages (already sent to chat):\n%s\n%s\nReview these messages and take moderation actions if needed."):format(#batch, formatted_batch, hist_section))

	local ok, err = context:call(prompt, function(_, _, error)
		active_context = nil
		is_processing = false
		flush_pending()
		if error then
			core.log("warning", ("[ai_filter_watcher] AI error for batch call %d: %s"):format(call_id, tostring(error)))
			report("Batch %d error: %s", call_id, tostring(error))
		end
	end)

	if not ok then
		core.log("warning", ("[ai_filter_watcher] Failed to call AI for batch %d: %s"):format(call_id, tostring(err)))
		report("Failed to call AI for batch %d: %s", call_id, tostring(err))
		active_context = nil
		is_processing = false
		flush_pending()
	end
end

chat_lib.register_on_chat_message(4, function(name, msg)
	record_message(name, msg)
	return false
end)

-- Inbound relay messages (Discord/XMPP -> game) never pass through the chat
-- message hook, so catch them here. Only these two sources are inbound
-- traffic; player chat arrives with a different source, so no double capture.
-- xmpp_relay's bot skips its own sends (relay.py muc_messages), so /xmsg
-- content never comes back through this hook.
chat_lib.register_on_chat_send_all(function(msg, source)
	if source ~= "discordmt" and source ~= "xmpp_relay" then return end
	local tag = source == "discordmt" and "DISCORD" or "XMPP"
	local plain = core.strip_colors(msg)
	local author, content = plain:match("^%s*<([^>]+)@Discord>%s*(.-)%s*$")
	if not author then
		author, content = plain:match("^%s*(.-)@XMPP:%s*(.-)%s*$")
	end
	if not author then
		-- Odd format: attribute the whole line to the source
		author, content = source, plain
	end
	author = author:gsub("[<>]", ""):gsub("%s+", " ")
	privacy_add_name(author)
	if content and content ~= "" then
		record_message(author, content, tag)
	end
end)

local time_acc, cleanup_acc = 0, 0
core.register_globalstep(function(dtime)
	if WATCHER_MODE == ai_filter_watcher.MODES.DISABLED then return end
	time_acc = time_acc + dtime
	cleanup_acc = cleanup_acc + dtime

	if time_acc >= SCAN_INTERVAL then
		if #message_buffer >= MIN_BATCH_SIZE and not is_processing then
			time_acc = 0
			process_batch()
		elseif not is_processing then
			-- Buffer too small: restart the interval.
			time_acc = 0
			core.log("verbose", ("[ai_filter_watcher] Buffer too small (%d/%d), skipping scan"):format(#message_buffer, MIN_BATCH_SIZE))
		end
		-- else: a scan is in flight. Leave time_acc running so the scan fires
		-- on the first tick after the current run completes instead of
		-- waiting out a full interval; the buffer keeps accumulating.
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
- Username hiding: %s
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
				#chat_history,
				HISTORY_TRACKING_TIME, HISTORY_TRACKING_TIME/3600,
				is_processing and ("Yes (call_id: "..active_call_id..")") or "No",
				#message_buffer,
				players,
				entries,
				val_or_def(TEMPERATURE),
				val_or_def(FREQUENCY_PENALTY),
				val_or_def(PRESENCE_PENALTY),
				DEBUG_ENABLED and "Enabled" or "Disabled",
				HIDE_USERNAMES and "Enabled" or "Disabled",
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
			save_setting("mode", mode, "mode")
			WATCHER_MODE = mode
			report("Mode changed to %s by %s", mode, name)
			return true, "Watcher mode set to: " .. mode

		elseif cmd == "interval" then
			local i = tonumber(param:match("%s+(%S+)"))
			if not i or i < 1 or i > 3600 then
				return false, "Usage: /ai_watcher interval <seconds> (1-3600)"
			end
			save_setting("scan_interval", i, "interval")
			SCAN_INTERVAL = i
			time_acc = 0
			return true, ("Scan interval set to: %d seconds"):format(i)

		elseif cmd == "batch" then
			local s = tonumber(param:match("%s+(%S+)"))
			if not s or s < 1 or s > 100 then
				return false, "Usage: /ai_watcher batch <size> (1-100)"
			end
			save_setting("min_batch_size", s, "batch size")
			MIN_BATCH_SIZE = s
			return true, ("Minimum batch size set to: %d messages"):format(s)

		elseif cmd == "temperature" then
			local v = param:match("%s+(%S+)")
			if not v then
				return true, "Current temperature: " .. (TEMPERATURE and tostring(TEMPERATURE) or "not set")
			end
			local n = tonumber(v)
			if not n or n < 0 or n > 2 then
				return false, "Temperature must be 0-2"
			end
			save_setting("temperature", v, "temperature")
			TEMPERATURE = n
			return true, ("Temperature set to: %s"):format(v)

		elseif cmd == "frequency_penalty" then
			local v = param:match("%s+(%S+)")
			if not v then
				return true, "Current frequency_penalty: " .. (FREQUENCY_PENALTY and tostring(FREQUENCY_PENALTY) or "not set")
			end
			local n = tonumber(v)
			if not n or n < -2 or n > 2 then
				return false, "Frequency penalty must be -2..2"
			end
			save_setting("frequency_penalty", v, "frequency penalty")
			FREQUENCY_PENALTY = n
			return true, ("Frequency penalty set to: %s"):format(v)

		elseif cmd == "presence_penalty" then
			local v = param:match("%s+(%S+)")
			if not v then
				return true, "Current presence_penalty: " .. (PRESENCE_PENALTY and tostring(PRESENCE_PENALTY) or "not set")
			end
			local n = tonumber(v)
			if not n or n < -2 or n > 2 then
				return false, "Presence penalty must be -2..2"
			end
			save_setting("presence_penalty", v, "presence penalty")
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
			save_setting("debug_enabled", new_val, "debug setting")
			DEBUG_ENABLED = new_val
			return true, "Debug " .. (new_val and "enabled" or "disabled")

		elseif cmd == "hide_usernames" then
			local v = param:match("%s+(%S+)")
			if not v then
				return true, "Username hiding is " .. (HIDE_USERNAMES and "enabled" or "disabled")
			end
			local new_val
			if v == "yes" or v == "on" then
				new_val = true
			elseif v == "no" or v == "off" then
				new_val = false
			else
				return false, "Usage: /ai_watcher hide_usernames [yes|no]"
			end
			save_setting("hide_usernames", new_val, "hide_usernames setting")
			-- Don't touch the runtime flag directly: it must only change when
			-- no AI run is active. The shareddb trigger echoes our own write
			-- back to update_setting_from_db, which queues it if a run is in
			-- flight; this direct call is the fallback when the DB is down
			-- (no echo). Either way the current context keeps the masking it
			-- started with, and the next one gets the change.
			apply_setting_deferred("hide_usernames", tostring(new_val))
			if is_processing then
				return true, ("Username hiding %s (will apply after the current AI run completes)"):format(new_val and "enabled" or "disabled")
			end
			return true, "Username hiding " .. (new_val and "enabled" or "disabled")

		elseif cmd == "history_time" then
			local v = param:match("%s+(%S+)")
			if not v then
				return true, ("Current history tracking time: %d seconds (%.1f hours)"):format(HISTORY_TRACKING_TIME, HISTORY_TRACKING_TIME/3600)
			end
			local new = tonumber(v) or (algorithms and algorithms.parse_time(v))
			if not new or new < 60 or new > 2592000 then
				return false, "Invalid time. Must be >=60 seconds or a time string like '10h', '2d' (max 30d)."
			end
			save_setting("history_tracking_time", new, "history time")
			local old = HISTORY_TRACKING_TIME
			HISTORY_TRACKING_TIME = new
			if new < old then
				cleanup_player_history()
			end
			report("History tracking time changed to %d seconds by %s", new, name)
			return true, ("History tracking time set to: %d seconds (%.1f hours)"):format(new, new/3600)

		elseif cmd == "action_rate_limit" then
			local v = param:match("%s+(%S+)")
			if not v then
				if ACTION_RATE_LIMIT then
					return true, ("Current action report rate limit: %s (max %d messages per %d seconds)"):format(
						ACTION_RATE_LIMIT.raw, ACTION_RATE_LIMIT.count, ACTION_RATE_LIMIT.seconds)
				end
				return true, "No action report rate limit set (unlimited)"
			end
			local limit = parse_action_rate_limit(v)
			if not limit then
				return false, "Invalid rate limit. Usage: /ai_watcher action_rate_limit <count>/<unit>, e.g. 10/1m or 5/60"
			end
			save_setting("action_rate_limit", v, "action rate limit")
			ACTION_RATE_LIMIT = limit
			return true, ("Action report rate limit set to: %s (max %d messages per %d seconds)"):format(v, limit.count, limit.seconds)

		elseif cmd == "process" then
			local force = param:match("%s+force")
			if #message_buffer < MIN_BATCH_SIZE and not force then
				return false, ("Buffer has only %d messages (need %d). Use '/ai_watcher process force' to override."):format(#message_buffer, MIN_BATCH_SIZE)
			end
			if is_processing then
				return false, "A scan is already in progress; it will pick up the buffered messages when it finishes"
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
					out = out .. ("%d. [%s] <%s>%s: %s\n"):format(i, os.date("%H:%M", m.time), m.name,
						m.tag and (" [" .. m.tag .. "]") or "", m.message)
				end
			end
			return true, out

		elseif cmd == "abort" then
			if is_processing then
				abort_current_processing("Manually aborted by " .. name)
				report("Current processing aborted by %s", name)
				return true, "Ongoing AI processing aborted"
			else
				return false, "No processing to abort"
			end

		elseif cmd == "clear" then
			local what = param:match("%s+(%S+)") or "buffer"
			if what == "buffer" then
				local cnt = #message_buffer
				message_buffer = {}
				report("Cleared %d messages from buffer by %s", cnt, name)
				return true, ("Cleared %d messages from buffer"):format(cnt)
			elseif what == "stats" then
				watcher_stats = { scans_performed = 0, messages_processed = 0, actions_taken = 0, last_scan_time = 0, last_action_time = 0 }
				report("Statistics cleared by %s", name)
				return true, "Statistics cleared"
			elseif what == "history" then
				chat_history = {}
				report("Chat history cleared by %s", name)
				return true, "Chat history cleared"
			elseif what == "player_history" then
				player_history = {}
				save_player_history()
				report("Player moderation history cleared by %s", name)
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
				report("System prompt reloaded by %s", name)
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
  action_rate_limit [value] - Get/set action report rate limit (e.g. '10/1m', unlimited if unset)
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
	local init_msg = ("Initialized (mode: %s, prompt: %s, interval: %ds, batch: %d, debug: %s, hide_usernames: %s)"):format(
		WATCHER_MODE, PROMPT_READY and "loaded" or "missing", SCAN_INTERVAL, MIN_BATCH_SIZE, DEBUG_ENABLED and "enabled" or "disabled", HIDE_USERNAMES and "enabled" or "disabled")
	core.log("action", "[ai_filter_watcher] " .. init_msg)
	report("%s", init_msg)
end)
