-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

relays = {}

local is_xmpp = core.global_exists("xmpp_relay")
local is_discord = core.global_exists("discord") and discord.enabled
local xmpp_action_log = "aclog@jmaminetest.mooo.com"
local xmpp_report_log = "reportlog@jmaminetest.mooo.com"

relays.send_action_report = function(message, ...)
	local final_msg = string.format(message, ...)
	if is_xmpp then
		xmpp_relay.send(final_msg, xmpp_action_log)
	end
	if is_discord then
		discord.send_action_report("%s", final_msg)
	end
end

relays.send_report = function(message, ...)
	local final_msg = string.format(message, ...)
	if is_xmpp then
		xmpp_relay.send(final_msg, xmpp_report_log)
	end
	if is_discord then
		discord.send_report("%s", final_msg)
	end
end