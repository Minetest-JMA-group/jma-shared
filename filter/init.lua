local discordCooldown = 0
filter = { registered_on_violations = {}, phrase = "Filter mod has detected the player writing a bad message: " }
local violations = {}
local last_kicked_time = os.time()
local last_bad_msg = ""

-- Define violation types and their messages
local violation_types = {
    too_long = {
        name = "message too long",
        chat_msg = "Your message is too long. Please shorten it.",
        kick_msg = "Please keep your messages concise!",
        log_msg = "VIOLATION (message too long)",
        formspec_title = "Message Too Long!",
        formspec_image = "filter_warning.png"
    },
    blacklisted = {
        name = "inappropriate content",
        chat_msg = "Watch your language!",
        kick_msg = "Please mind your language!",
        log_msg = "VIOLATION (inappropriate content)",
        formspec_title = "Please watch your language!",
        formspec_image = "filter_warning.png"
    }
}

if not core.registered_privileges["filtering"] then
	core.register_privilege("filtering", "Filter manager")
end

if not algorithms.load_library() then
    minetest.log("warning", "Filter mod requires corresponding mylibrary.so C++ module to work.")
    return
end

function filter.register_on_violation(func)
	table.insert(filter.registered_on_violations, func)
end

-- Check if the message is too long using the C++ function
local function is_message_too_long(message)
	return filter.is_message_too_long(message)
end

-- Return true if message is fine. false if it should be blocked.
-- Also returns the violation type if blocked
function filter.check_message(message)
	if type(message) ~= "string" then
		return false, "invalid_type"
	end

	-- Check message length
	if is_message_too_long(message) then
		last_bad_msg = message
		return false, "too_long"
	end

	-- Check message content
	local is_allowed = filter.is_whitelisted(message) or not filter.is_blacklisted(message)
	if not is_allowed then
		last_bad_msg = message
		return false, "blacklisted"
	end

	return true
end

function filter.mute(name, duration, violation_type)
	local v_type = violation_types[violation_type] or violation_types.blacklisted

	minetest.chat_send_all(name .. " has been temporarily muted for " .. v_type.name .. ".")
	minetest.chat_send_player(name, v_type.chat_msg)

	local reason
	if violation_type == "too_long" then
		reason = string.format("Message too long: \"%s\" (exceeds maximum length)", last_bad_msg)
	else
		reason = string.format("%s\"%s\" using blacklist regex: \"%s\"", filter.phrase, last_bad_msg, filter.get_lastreg())
	end

	xban.mute_player(name, "filter", os.time() + (duration*60), reason)
end

function filter.show_warning_formspec(name, violation_type)
	local v_type = violation_types[violation_type] or violation_types.blacklisted

	local formspec = "size[7,3]bgcolor[#080808BB;true]" .. default.gui_bg .. default.gui_bg_img ..
		"image[0,0;2,2;" .. v_type.formspec_image .. "]" ..
		"label[2.3,0.5;" .. v_type.formspec_title .. "]" ..
		"label[2.3,1.1;" .. v_type.chat_msg .. "]"

	if minetest.global_exists("rules") and rules.show then
		formspec = formspec .. [[
				button[0.5,2.1;3,1;rules;Show Rules]
				button_exit[3.5,2.1;3,1;close;Okay]
			]]
	else
		formspec = formspec .. [[
				button_exit[2,2.1;3,1;close;Okay]
			]]
	end
	minetest.show_formspec(name, "filter:warning", formspec)
end

function filter.on_violation(name, message, violation_type)
	local v_type = violation_types[violation_type] or violation_types.blacklisted
	violations[name] = (violations[name] or 0) + 1

	local resolution
	if filter.get_mode() == 0 then
		resolution = "permissive"
	end

	for _, cb in pairs(filter.registered_on_violations) do
		if cb(name, message, violations, violation_type) then
			resolution = "custom"
		end
	end

	if not resolution then
		if violations[name] == 1 and minetest.get_player_by_name(name) then
			resolution = "warned"
			filter.show_warning_formspec(name, violation_type)
			minetest.chat_send_player(name, v_type.chat_msg)
		elseif violations[name] <= 3 then
			resolution = "muted"
			filter.mute(name, 1, violation_type)
		else
			resolution = "kicked"
			minetest.kick_player(name, v_type.kick_msg)
			if discord and discord.enabled and (os.time() - last_kicked_time) > discordCooldown then
				local format_string = "***filter***: Kicked %s for %s \"%s\""
				if violation_type == "blacklisted" then
					format_string = "***filter***: Kicked %s for %s \"%s\" caught with blacklist regex \"%s\""
					discord.send_action_report(format_string, name, v_type.name, last_bad_msg, filter.get_lastreg())
				else
					discord.send_action_report(format_string, name, v_type.name, last_bad_msg)
				end
				last_kicked_time = os.time()
			end
		end
	end

	local logmsg = "[filter] " .. v_type.log_msg .. " (" .. resolution .. "): <" .. name .. "> " .. message
	minetest.log("action", logmsg)

	local email_to = minetest.settings:get("filter.email_to")
	if email_to and minetest.global_exists("email") then
		email.send_mail(name, email_to, logmsg)
	end
end

-- Insert this check after xban checks whether the player is muted
table.insert(minetest.registered_on_chat_messages, 2, function(name, message)
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

for name, def in pairs(minetest.registered_chatcommands) do
	if (def.privs and def.privs.shout) or xban.cmd_list[name] then
		def.func = make_checker(def.func)
	end
end

local old_register_chatcommand = minetest.register_chatcommand
function minetest.register_chatcommand(name, def)
	if (def.privs and def.privs.shout) or xban.cmd_list[name] then
		def.func = make_checker(def.func)
	end
	return old_register_chatcommand(name, def)
end

local old_override_chatcommand = minetest.override_chatcommand
function minetest.override_chatcommand(name, def)
	if (def.privs and def.privs.shout) or xban.cmd_list[name] then
		def.func = make_checker(def.func)
	end
	return old_override_chatcommand(name, def)
end

local function step()
	for name, v in pairs(violations) do
		violations[name] = math.floor(v * 0.5)
		if violations[name] < 1 then
			violations[name] = nil
		end
	end
	minetest.after(10*60, step)
end
minetest.after(10*60, step)

if minetest.global_exists("rules") and rules.show then
	minetest.register_on_player_receive_fields(function(player, formname, fields)
		if formname == "filter:warning" and fields.rules then
			rules.show(player)
		end
	end)
end
