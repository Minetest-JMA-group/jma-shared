local discordCooldown = 0
filter = { registered_on_violations = {}, phrase = "Filter mod has detected the player writing a bad message: " }
local violations = {}
local last_kicked_time = os.time()
local last_bad_msg = ""

if not core.registered_privileges["filtering"] then
	core.register_privilege("filtering", "Filter manager")
end

assert(algorithms.load_library(), "Filter mod requires corresponding mylibrary.so C++ module to work.")

function filter.register_on_violation(func)
	table.insert(filter.registered_on_violations, func)
end

-- Return true if message is fine. false if it should be blocked.
function filter.check_message(message)
	if type(message) ~= "string" then
		return false
	end
	local res = filter.is_whitelisted(message) or not filter.is_blacklisted(message)
	if not res then
		last_bad_msg = message
	end
	return res
end

function filter.mute(name, duration)
	
	minetest.chat_send_all(name .. " has been temporarily muted for using offensive language.")
	minetest.chat_send_player(name, "Watch your language!")

	xban.mute_player(name, "filter", os.time() + (duration*60), string.format("%s\"%s\" using blacklist regex: \"%s\"", filter.phrase, last_bad_msg, filter.get_lastreg()))
end

function filter.show_warning_formspec(name)
	local formspec = "size[7,3]bgcolor[#080808BB;true]" .. default.gui_bg .. default.gui_bg_img .. [[
		image[0,0;2,2;filter_warning.png]
		label[2.3,0.5;Please watch your language!]
	]]

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

function filter.on_violation(name, message)
	violations[name] = (violations[name] or 0) + 1

	local resolution
	if filter.get_mode() == 0 then
		resolution = "permissive"
	end

	for _, cb in pairs(filter.registered_on_violations) do
		if cb(name, message, violations) then
			resolution = "custom"
		end
	end

	if not resolution then
		if violations[name] == 1 and minetest.get_player_by_name(name) then
			resolution = "warned"
			filter.show_warning_formspec(name)
		elseif violations[name] <= 3 then
			resolution = "muted"
			filter.mute(name, 1)
		else
			resolution = "kicked"
			minetest.kick_player(name, "Please mind your language!")
			if discord and discord.enabled and (os.time() - last_kicked_time) > discordCooldown then
				discord.send_action_report("***filter***: Kicked %s for saying the bad message \"%s\" catched with blacklist regex \"%s\"", name, last_bad_msg, filter.get_lastreg())
				last_kicked_time = os.time()
			end
		end
	end

	local logmsg = "[filter] VIOLATION (" .. resolution .. "): <" .. name .. "> "..  message
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

	if not filter.check_message(message) then
		filter.on_violation(name, message)
		if filter.get_mode() == 1 then
			return true
		end
	end
end)


local function make_checker(old_func)
	return function(name, param)
		if not filter.check_message(param) then
			filter.on_violation(name, param)
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
