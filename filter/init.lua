-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)
local worldpath = core.get_worldpath()
local storage = shareddb.get_mod_storage()

local relayCooldown = 0
local violations = {}
local last_kicked_time = os.time()
local mode = 1

filter = { registered_on_violations = {}, phrase = "Filter mod has detected the player writing a bad message: " }

-- Create regex context for blacklist management
local blacklist_ctx = regex.create({
	storage = storage,
	path = modpath .. "/blacklist",
	save_path = worldpath .. "/filter_blacklist",
	list_name = "blacklist",
	storage_key = "blacklist",
	help_prefix = "The filter works by matching regex patterns from a blacklist with each message.\nIf a match is found, the message is blocked.\n\nList of possible commands:\ngetenforce: Get the current filter mode\nsetenforce <mode>: Set new filter mode\n",
	logger = function(level, message)
		core.log(level, "[filter] " .. message)
	end
})

-- If regex context creation failed
if not blacklist_ctx then
	core.log("error", "[filter] Failed to create regex context")

	function filter.check_message()
		return true
	end

	return
end

local function load_data(key)
	if key == "mode" then
		local ctx, err = storage:get_context()
		local newmode
		if ctx then newmode, err = ctx:get_string("mode") end
		err = err or ctx:finalize()
		if err then return end
		mode = newmode == "0" and 0 or 1
	end
	if key == "blacklist" then
		blacklist_ctx:load()
	end
end
shareddb.register_listener(load_data)
load_data("mode")

-- Define violation types and their messages
local violation_types = {
	blacklisted = {
		name = "inappropriate content",
		chat_msg = "Watch your language!",
		kick_msg = "Please mind your language!",
		log_msg = "VIOLATION (inappropriate content)",
		formspec_title = "Please watch your language!",
		formspec_image = "filter_warning.png",
	},
}

if not core.registered_privileges["filtering"] then
	core.register_privilege("filtering", "Filter manager")
end

local function log(level, message)
	core.log(level, "[filter] " .. message)
end

-- ==================== Filter Core Functions ====================

function filter.register_on_violation(func)
	table.insert(filter.registered_on_violations, func)
end

function filter.check_message(message)
	if type(message) ~= "string" then
		return false, "invalid_type"
	end

	if blacklist_ctx:match(message) then
		return false, "blacklisted"
	end

	return true
end

function filter.is_blacklisted(message)
	return blacklist_ctx:match(message)
end

function filter.get_lastreg()
	return blacklist_ctx:get_last_match() or ""
end

function filter.get_mode()
	return mode
end

-- ==================== Violation Handling ====================

function filter.mute(name, duration, violation_type, message)
	local v_type = violation_types[violation_type] or violation_types.blacklisted

	core.chat_send_all(name .. " has been temporarily muted for " .. v_type.name .. ".")
	core.chat_send_player(name, v_type.chat_msg)

	local reason = string.format('%s"%s" using blacklist regex: "%s"', filter.phrase, message, filter.get_lastreg())

	if xban == nil then
		log("warning", "xban not available so not muting the player")
	else
		xban.mute_player(name, "filter", os.time() + (duration * 60), reason)
	end
end

function filter.show_warning_formspec(name, violation_type)
	local v_type = violation_types[violation_type] or violation_types.blacklisted

	local formspec = "size[7,3]bgcolor[#080808BB;true]"
		.. default.gui_bg
		.. default.gui_bg_img
		.. "image[0,0;2,2;"
		.. v_type.formspec_image
		.. "]"
		.. "label[2.3,0.5;"
		.. v_type.formspec_title
		.. "]"
		.. "label[2.3,1.1;"
		.. v_type.chat_msg
		.. "]"

	if core.global_exists("rules") and rules.show then
		formspec = formspec .. [[
				button[0.5,2.1;3,1;rules;Show Rules]
				button_exit[3.5,2.1;3,1;close;Okay]
			]]
	else
		formspec = formspec .. [[
				button_exit[2,2.1;3,1;close;Okay]
			]]
	end
	core.show_formspec(name, "filter:warning", formspec)
end

function filter.on_violation(name, message, violation_type)
	local v_type = violation_types[violation_type] or violation_types.blacklisted
	violations[name] = (violations[name] or 0) + 1

	local resolution
	if filter.get_mode() == 0 then
		relays.send_action_report(
			'**filter**: [PERMISSIVE] Message "%s" matched using blacklist regex: "%s"',
			message,
			filter.get_lastreg()
		)
		resolution = "permissive"
	end

	if not resolution then
		for _, cb in pairs(filter.registered_on_violations) do
			if cb(name, message, violations, violation_type) then
				resolution = "custom"
			end
		end
	end

	if not resolution then
		if violations[name] == 1 and core.get_player_by_name(name) then
			resolution = "warned"
			filter.show_warning_formspec(name, violation_type)
			core.chat_send_player(name, v_type.chat_msg)
		elseif violations[name] <= 3 then
			resolution = "muted"
			filter.mute(name, 1, violation_type, message)
		else
			resolution = "kicked"
			core.kick_player(name, v_type.kick_msg)
			if (os.time() - last_kicked_time) > relayCooldown then
				local format_string = '***filter***: Kicked %s for %s "%s"'
				if violation_type == "blacklisted" then
					format_string = '***filter***: Kicked %s for %s "%s" caught with blacklist regex "%s"'
					relays.send_action_report(format_string, name, v_type.name, message, filter.get_lastreg())
				else
					relays.send_action_report(format_string, name, v_type.name, message)
				end
				last_kicked_time = os.time()
			end
		end
	end

	local logmsg = "[filter] " .. v_type.log_msg .. " (" .. resolution .. "): <" .. name .. "> " .. message
	log("action", logmsg)
end

-- ==================== Chat Message Handling ====================

chat_lib.register_on_chat_message(2, function(name, message)
	if message:sub(1, 1) == "/" then
		return
	end

	local is_valid, violation_type = filter.check_message(message)
	if not is_valid then
		filter.on_violation(name, message, violation_type)
		if filter.get_mode() == 1 then
			return true
		end
	end
end)

local function make_checker(old_func)
	return function(name, param)
		local is_valid, violation_type = filter.check_message(param)
		if not is_valid then
			filter.on_violation(name, param, violation_type)
			if filter.get_mode() == 1 then
				return true
			end
		end

		return old_func(name, param)
	end
end

for name, def in pairs(core.registered_chatcommands) do
	if (def.privs and def.privs.shout) or (xban and xban.cmd_list and xban.cmd_list[name]) then
		def.func = make_checker(def.func)
	end
end

local old_register_chatcommand = core.register_chatcommand
function core.register_chatcommand(name, def)
	if (def.privs and def.privs.shout) or (xban and xban.cmd_list and xban.cmd_list[name]) then
		def.func = make_checker(def.func)
	end
	return old_register_chatcommand(name, def)
end

local old_override_chatcommand = core.override_chatcommand
function core.override_chatcommand(name, def)
	if (def.privs and def.privs.shout) or (xban and xban.cmd_list and xban.cmd_list[name]) then
		def.func = make_checker(def.func)
	end
	return old_override_chatcommand(name, def)
end

-- ==================== Console Command Handler ====================

local function set_mode(new_mode)
	if new_mode ~= 0 then
		new_mode = 1
	end
	if mode == new_mode then
		return false, "Filter mode already set to " .. (mode == 1 and "Enforcing" or "Permissive")
	end
	mode = new_mode
	local ctx, err = storage:get_context()
	err = err or ctx:set_string("mode", tostring(mode))
	err = err or ctx:finalize()
	if err then return false, err else return true end
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

	-- Handle filter-specific commands
	if cmd == "getenforce" then
		return true, mode == 1 and "Enforcing" or "Permissive"

	elseif cmd == "setenforce" then
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

	else
		-- Delegate all other commands to the regex context
		local success, message = blacklist_ctx:handle_command(name, param)

		-- If the regex context doesn't recognize the command
		if not success and message == nil then
			return false, "Unknown command. Check /filter help"
		end

		return success, message
	end
end

core.register_chatcommand("filter", {
	description = "filter management console",
	params = "<command> <args>",
	privs = { filtering = true },
	func = filter_console,
})

-- ==================== Cleanup and UI Integration ====================

local function step()
	for name, v in pairs(violations) do
		violations[name] = math.floor(v * 0.5)
		if violations[name] < 1 then
			violations[name] = nil
		end
	end
	core.after(10 * 60, step)
end
core.after(10 * 60, step)

if core.global_exists("rules") and rules.show then
	core.register_on_player_receive_fields(function(player, formname, fields)
		if formname == "filter:warning" and fields.rules then
			rules.show(player)
		end
	end)
end

-- Log startup
log("action", "Filter mod initialized with " .. tostring(#blacklist_ctx:get_patterns()) .. " blacklist entries")