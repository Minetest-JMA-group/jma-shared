-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

return function(internal)
	local ui_state = {}
	local function bool_from_field(value, fallback)
		if value == "true" then
			return true
		end
		if value == "false" then
			return false
		end
		return fallback
	end

	local function clamp_row_offset(offset)
		if offset < 0 then
			return 0
		end
		if offset > internal.ROW_SCROLL_MAX then
			return internal.ROW_SCROLL_MAX
		end
		return offset
	end

	local function get_ui_state(name)
		local state = ui_state[name]
		if state then
			return state
		end
		state = {
			tab = "1",
			filter = "",
			action_player = "",
			action_scope = "name",
			action_template = "other",
			action_duration = "",
			action_custom_reason = "",
			action_allow_unknown = false,
			selected_row = 1,
			row_offset = 0,
			pending_override = nil,
		}
		ui_state[name] = state
		return state
	end

	local function handle_refresh(name, tab, filter_player, action_player, action_scope, action_template, action_duration, action_custom_reason, action_allow_unknown)
		core.chat_send_player(name, "[simplemod] refreshed.")
		internal.show_gui(name, tab, filter_player, action_player, action_scope, action_template, action_duration, action_custom_reason, action_allow_unknown)
	end

	function internal.show_gui(name, tab, filter_player, action_player, action_scope, action_template, action_duration, action_custom_reason, action_allow_unknown)
		tab = tab or "1"
		filter_player = filter_player or ""
		action_player = action_player or ""
		action_scope = action_scope or "name"
		action_template = action_template or "other"
		action_duration = action_duration or ""
		action_custom_reason = action_custom_reason or ""
		action_allow_unknown = action_allow_unknown == true

		local state = get_ui_state(name)
		if state.tab ~= tab then
			state.row_offset = 0
		end
		state.tab = tab
		state.filter = filter_player
		state.action_player = action_player
		state.action_scope = action_scope
		state.action_template = action_template
		state.action_duration = action_duration
		state.action_custom_reason = action_custom_reason
		state.action_allow_unknown = action_allow_unknown

		local is_other_reason = action_template == "other"
		local can_unban = internal.has_active_punishment(action_scope, action_player, "ban")
		local can_unmute = internal.has_active_punishment(action_scope, action_player, "mute")
		local rows = internal.make_table_rows(tab, filter_player)
		local formspec = "formspec_version[6]size[13,10]" ..
			"bgcolor[#1a1a1acc;true]" ..
			"style_type[label;font_size=18]" ..
			"style[close;bgcolor=#3a3a3a;bgcolor_hovered=#4a4a4a]" ..
			"style[refresh;bgcolor=#355070;bgcolor_hovered=#42678f]" ..
			"style[row_left;bgcolor=#425e7a;bgcolor_hovered=#527494]" ..
			"style[row_right;bgcolor=#425e7a;bgcolor_hovered=#527494]" ..
			"style[quick_to_actions;bgcolor=#425e7a;bgcolor_hovered=#527494]" ..
			"style[action_ban;bgcolor=#8f2626;bgcolor_hovered=#aa2f2f]" ..
			"style[action_mute;bgcolor=#6e5a2f;bgcolor_hovered=#85703a]" ..
			"style[action_unban;bgcolor=#305f3e;bgcolor_hovered=#3a774c]" ..
			"style[action_unmute;bgcolor=#305f3e;bgcolor_hovered=#3a774c]" ..
			"style[action_unban_disabled;bgcolor=#474747;bgcolor_hovered=#474747;font_color=#9a9a9a]" ..
			"style[action_unmute_disabled;bgcolor=#474747;bgcolor_hovered=#474747;font_color=#9a9a9a]" ..
			"style_type[table;background=#151515;border=true]" ..
			"tablecolumns[color;text]" ..
			"tableoptions[highlight=#355070;border=false]" ..
			"tabheader[0.2,0.2;tabs;Active Bans,Active Mutes,Player Log,Actions;" .. tab .. ";false;false]"

		if tab == "1" or tab == "2" then
			formspec = formspec ..
				"label[0.3,1.0;" .. (tab == "1" and "Active bans (red)" or "Active mutes (yellow)") .. "]" ..
				"table[0.3,1.4;12.4,7.4;main_table;" .. internal.make_table_data(rows, state.row_offset) .. ";" .. tostring(state.selected_row or 1) .. "]" ..
				"button[7.5,9.0;2.9,1;quick_to_actions;Open In Actions]" ..
				"tooltip[quick_to_actions;Open selected entry in Actions tab with fields prefilled.]"
		elseif tab == "3" then
			local online_names, online_selected = internal.online_player_dropdown(filter_player)
			formspec = formspec ..
				"label[0.3,1.0;Player name]" ..
				"field[0.3,1.6;6.5,1;player_filter;;" .. core.formspec_escape(filter_player) .. "]" ..
				"dropdown[7.0,1.6;2.6,1;player_filter_pick;" .. online_names .. ";" .. online_selected .. "]" ..
				"field_close_on_enter[player_filter;false]" ..
				"button[9.9,1.6;2.8,1;view_log;View Log]" ..
				"table[0.3,2.8;12.4,6.2;main_table;" .. internal.make_table_data(rows, state.row_offset) .. ";" .. tostring(state.selected_row or 1) .. "]"
		elseif tab == "4" then
			local online_names, online_selected = internal.online_player_dropdown(action_player)
			formspec = formspec ..
				"box[0.2,0.9;12.6,8.0;#1f1f1fa8]" ..
				"label[0.5,1.2;Apply moderation action]" ..
				"label[0.5,1.8;Player/IP target]" ..
				"field[0.5,2.3;6.0,1;action_player;;" .. core.formspec_escape(action_player) .. "]" ..
				"field_close_on_enter[action_player;false]" ..
				"dropdown[6.7,2.3;2.6,1;action_player_pick;" .. online_names .. ";" .. online_selected .. "]" ..
				"label[9.5,1.8;Scope]" ..
				"dropdown[9.5,2.3;1.6,1;action_scope;name,ip;" .. (action_scope == "ip" and "2" or "1") .. "]" ..
				"label[11.3,1.8;Reason]" ..
				"dropdown[11.3,2.3;1.5,1;action_template;spam,grief,hack,language,other;" ..
					(internal.reason_template_index[action_template] or 1) .. "]" ..
				"label[0.5,3.9;Duration (e.g. 1h, 2d, empty = permanent)]" ..
				"field[0.5,4.4;4.0,1;action_duration;;" .. core.formspec_escape(action_duration) .. "]" ..
				"checkbox[4.8,4.5;action_allow_unknown;Ban/Mute unknown;" .. (action_allow_unknown and "true" or "false") .. "]" ..
				"tooltip[action_allow_unknown;When using IP scope, auto-register unknown name/IP target in ipdb for Ban/Mute.]"
			if is_other_reason then
				formspec = formspec ..
					"label[0.5,5.65;Custom reason]" ..
					"field[0.5,5.9;12.0,1;action_custom_reason;;" .. core.formspec_escape(action_custom_reason) .. "]"
			end
			formspec = formspec ..
				"button[0.5,7.4;2.8,1;action_ban;Ban]" ..
				"button[3.5,7.4;2.8,1;action_mute;Mute]" ..
				(can_unban
					and "button[6.5,7.4;2.8,1;action_unban;Unban]"
					or "button[6.5,7.4;2.8,1;action_unban_disabled;Unban]") ..
				(can_unmute
					and "button[9.5,7.4;2.8,1;action_unmute;Unmute]"
					or "button[9.5,7.4;2.8,1;action_unmute_disabled;Unmute]") ..
				"tooltip[action_ban;Ban and disconnect immediately.]"
		end

		if tab == "1" or tab == "2" or tab == "3" then
			formspec = formspec ..
				"button[2.6,9.0;1.2,1;row_left;<]" ..
				"button[3.9,9.0;1.2,1;row_right;>]" ..
				"label[5.2,9.3;View offset: " .. tostring(state.row_offset) .. "]"
		end

		formspec = formspec ..
			"button_exit[0.3,9.0;2.0,1;close;Close]" ..
			"button[10.5,9.0;2.2,1;refresh;Refresh]"

		core.show_formspec(name, "simplemod:main", formspec)
	end

	local function show_override_confirm_gui(name, pending)
		local state = get_ui_state(name)
		state.pending_override = pending
		local lines = {}
		for _, line in ipairs(internal.format_existing_punishment_lines(pending.action_type, pending.scope, pending.target, pending.existing)) do
			lines[#lines + 1] = line
		end
		lines[#lines + 1] = ""
		for _, line in ipairs(internal.format_new_punishment_lines(pending.action_type, pending.scope, pending.target, pending.source, pending.reason, pending.duration)) do
			lines[#lines + 1] = line
		end
		lines[#lines + 1] = ""
		lines[#lines + 1] = "Proceed with override?"

		local formspec = "formspec_version[6]size[12,8]" ..
			"bgcolor[#1a1a1acc;true]" ..
			"style_type[label;font_size=18]" ..
			"label[0.4,0.3;Confirm override]" ..
			"textarea[0.4,0.9;11.2,5.9;override_info;;" .. core.formspec_escape(table.concat(lines, "\n")) .. "]" ..
			"button[2.0,7.0;3.2,1;override_confirm_yes;Confirm]" ..
			"button[6.8,7.0;3.2,1;override_confirm_no;Abort]"
		core.show_formspec(name, "simplemod:override_confirm", formspec)
	end

	core.register_on_leaveplayer(function(player)
		local player_name = player:get_player_name()
		ui_state[player_name] = nil
		if internal.on_player_leave then
			internal.on_player_leave(player_name)
		end
	end)

	core.register_on_player_receive_fields(function(player, formname, fields)
		if formname ~= "simplemod:override_confirm" then
			return
		end
		local name = player:get_player_name()
		local state = get_ui_state(name)
		local pending = state.pending_override
		state.pending_override = nil
		if not pending then
			internal.show_gui(name, "4")
			return
		end

		if fields.override_confirm_yes then
			local success, msg = internal.run_action(
				pending.action_type,
				pending.scope,
				pending.target,
				pending.source,
				pending.reason,
				pending.duration,
				pending.allow_unknown
			)
			if success then
				core.chat_send_player(name, "Action completed")
			else
				core.chat_send_player(name, "Error: " .. (msg or "unknown"))
			end
		end
		internal.show_gui(
			name,
			"4",
			pending.filter_player,
			pending.target,
			pending.scope,
			pending.template_key,
			pending.duration_str,
			pending.custom_reason,
			pending.allow_unknown
		)
	end)

	core.register_on_player_receive_fields(function(player, formname, fields)
		if formname ~= "simplemod:main" then
			return
		end
		local name = player:get_player_name()
		if not core.check_player_privs(name, {moderator = true}) then
			return
		end
		local state = get_ui_state(name)

		if fields.close or fields.quit then
			ui_state[name] = nil
			return
		end

		if fields.main_table then
			local event = core.explode_table_event(fields.main_table)
			if event.type == "CHG" then
				state.selected_row = event.row
			elseif event.type == "DCL" then
				state.selected_row = event.row
				if state.tab == "1" or state.tab == "2" then
					local rows = internal.make_table_rows(state.tab, state.filter)
					local selected = rows[state.selected_row]
					if selected and selected.target then
						local template = internal.infer_reason_template(selected.reason)
						internal.show_gui(
							name,
							"4",
							state.filter,
							selected.target,
							selected.scope,
							template,
							state.action_duration,
							template == "other" and selected.reason or "",
							state.action_allow_unknown
						)
						return
					end
				end
			end
		end

		if fields.row_left or fields.row_right then
			local delta = fields.row_left and -internal.ROW_SCROLL_STEP or internal.ROW_SCROLL_STEP
			state.row_offset = clamp_row_offset((state.row_offset or 0) + delta)
			internal.show_gui(
				name,
				state.tab,
				fields.player_filter or state.filter,
				fields.action_player or state.action_player,
				fields.action_scope or state.action_scope,
				fields.action_template or state.action_template,
				fields.action_duration or state.action_duration,
				fields.action_custom_reason or state.action_custom_reason,
				bool_from_field(fields.action_allow_unknown, state.action_allow_unknown)
			)
			return
		end

		if fields.key_enter_field == "player_filter" then
			fields.view_log = true
		end
		if fields.key_enter_field == "action_player" then
			internal.show_gui(
				name,
				"4",
				fields.player_filter or state.filter,
				fields.action_player or "",
				fields.action_scope or state.action_scope,
				fields.action_template or state.action_template,
				fields.action_duration or state.action_duration,
				fields.action_custom_reason or state.action_custom_reason,
				bool_from_field(fields.action_allow_unknown, state.action_allow_unknown)
			)
			return
		end

		if fields.player_filter_pick and fields.player_filter_pick ~= "(select online)" then
			local dropdown_only = not fields.view_log and not fields.tabs and not fields.refresh and not fields.key_enter_field
			if dropdown_only or not fields.player_filter or fields.player_filter == "" then
				fields.player_filter = fields.player_filter_pick
			end
			if dropdown_only then
				fields.view_log = true
			end
		end

		if fields.view_log then
			local target = fields.player_filter
			if target and target ~= "" then
				state.row_offset = 0
				internal.show_gui(
					name,
					"3",
					target,
					fields.action_player,
					fields.action_scope,
					fields.action_template,
					fields.action_duration,
					fields.action_custom_reason,
					bool_from_field(fields.action_allow_unknown, state.action_allow_unknown)
				)
			else
				core.chat_send_player(name, "Please enter a player name")
			end
			return
		end

		if fields.action_player_pick and fields.action_player_pick ~= "(select online)" then
			local dropdown_only = not fields.action_ban
				and not fields.action_mute
				and not fields.action_unban
				and not fields.action_unmute
				and not fields.refresh
				and not fields.tabs
				and not fields.key_enter_field
			if dropdown_only or not fields.action_player or fields.action_player == "" then
				fields.action_player = fields.action_player_pick
			end
			if dropdown_only then
				internal.show_gui(
					name,
					"4",
					fields.player_filter or state.filter,
					fields.action_player,
					fields.action_scope or state.action_scope,
					fields.action_template or state.action_template,
					fields.action_duration or state.action_duration,
					fields.action_custom_reason or state.action_custom_reason,
					bool_from_field(fields.action_allow_unknown, state.action_allow_unknown)
				)
				return
			end
		end

		if fields.action_unban_disabled or fields.action_unmute_disabled then
			internal.show_gui(
				name,
				"4",
				fields.player_filter or state.filter,
				fields.action_player or state.action_player,
				fields.action_scope or state.action_scope,
				fields.action_template or state.action_template,
				fields.action_duration or state.action_duration,
				fields.action_custom_reason or state.action_custom_reason,
				bool_from_field(fields.action_allow_unknown, state.action_allow_unknown)
			)
			return
		end

		if fields.action_ban or fields.action_mute or fields.action_unban or fields.action_unmute then
			local target = fields.action_player
			if not target or target == "" then
				core.chat_send_player(name, "Player name required")
				internal.show_gui(name, "4", "", target, fields.action_scope, fields.action_template, fields.action_duration, fields.action_custom_reason, bool_from_field(fields.action_allow_unknown, state.action_allow_unknown))
				return
			end

			local scope = fields.action_scope or "name"
			local template_key = fields.action_template or "other"
			local custom = fields.action_custom_reason or ""
			local allow_unknown = bool_from_field(fields.action_allow_unknown, state.action_allow_unknown)
			local reason
			if template_key == "other" then
				reason = custom
			else
				reason = internal.reason_templates[template_key] or template_key
			end
			local duration_str = fields.action_duration or ""
			local duration = duration_str ~= "" and algorithms.parse_time(duration_str) or 0

			if fields.action_unban and not internal.has_active_punishment(scope, target, "ban") then
				internal.show_gui(name, "4", "", target, scope, template_key, duration_str, custom, allow_unknown)
				return
			end
			if fields.action_unmute and not internal.has_active_punishment(scope, target, "mute") then
				internal.show_gui(name, "4", "", target, scope, template_key, duration_str, custom, allow_unknown)
				return
			end

			if fields.action_ban then
				local allowed, err = internal.can_issue_ban(name, duration)
				if not allowed then
					core.chat_send_player(name, err or "Insufficient privileges")
					internal.show_gui(name, "4", "", target, scope, template_key, duration_str, custom, allow_unknown)
					return
				end
			elseif fields.action_unban then
				local allowed, err = internal.can_issue_unban(name, scope, target)
				if not allowed then
					core.chat_send_player(name, err or "Insufficient privileges")
					internal.show_gui(name, "4", "", target, scope, template_key, duration_str, custom, allow_unknown)
					return
				end
			else
				local priv = (fields.action_mute or fields.action_unmute) and "pmute" or "ban"
				if not core.check_player_privs(name, {[priv] = true}) then
					core.chat_send_player(name, "Insufficient privileges")
					internal.show_gui(name, "4", "", target, scope, template_key, duration_str, custom, allow_unknown)
					return
				end
			end

			local action_type
			if fields.action_ban then
				action_type = "ban"
			elseif fields.action_mute then
				action_type = "mute"
			elseif fields.action_unban then
				action_type = "unban"
			elseif fields.action_unmute then
				action_type = "unmute"
			end

			if action_type == "ban" or action_type == "mute" then
				local existing, existing_err = internal.get_active_punishment_entry(scope, target, action_type)
				if existing_err then
					core.chat_send_player(name, "Error: " .. existing_err)
					internal.show_gui(name, "4", "", target, scope, template_key, duration_str, custom, allow_unknown)
					return
				end
				if existing then
					local can_override, override_err = internal.can_override_punishment(action_type, name, existing, duration)
					if not can_override then
						core.chat_send_player(name, "Error: " .. (override_err or "unknown"))
						internal.show_gui(name, "4", "", target, scope, template_key, duration_str, custom, allow_unknown)
						return
					end
					show_override_confirm_gui(name, {
						action_type = action_type,
						scope = scope,
						target = target,
						source = name,
						reason = reason,
						duration = duration,
						existing = existing,
						filter_player = "",
						template_key = template_key,
						duration_str = duration_str,
						custom_reason = custom,
						allow_unknown = allow_unknown,
					})
					return
				end
			end

			local success, msg = internal.run_action(action_type, scope, target, name, reason, duration, allow_unknown)
			if success then
				core.chat_send_player(name, "Action completed")
			else
				core.chat_send_player(name, "Error: " .. (msg or "unknown"))
			end
			internal.show_gui(name, "4", "", target, scope, template_key, duration_str, custom, allow_unknown)
			return
		end

		if fields.quick_to_actions then
			local tab = fields.tabs or state.tab
			if tab ~= "1" and tab ~= "2" then
				internal.show_gui(name, tab, fields.player_filter or state.filter, fields.action_player or "", fields.action_scope or "name", fields.action_template or "other", fields.action_duration or "", fields.action_custom_reason or "", bool_from_field(fields.action_allow_unknown, state.action_allow_unknown))
				return
			end
			local rows = internal.make_table_rows(tab, fields.player_filter or state.filter)
			local selected = rows[state.selected_row or 1]
			if not selected or not selected.target then
				core.chat_send_player(name, "Select an entry first.")
				internal.show_gui(name, tab, fields.player_filter or state.filter, fields.action_player or "", fields.action_scope or "name", fields.action_template or "other", fields.action_duration or "", fields.action_custom_reason or "", bool_from_field(fields.action_allow_unknown, state.action_allow_unknown))
				return
			end
			local template = internal.infer_reason_template(selected.reason)
			internal.show_gui(
				name,
				"4",
				fields.player_filter or state.filter,
				selected.target,
				selected.scope,
				template,
				fields.action_duration or "",
				template == "other" and selected.reason or "",
				bool_from_field(fields.action_allow_unknown, state.action_allow_unknown)
			)
			return
		end

		if fields.action_template or fields.action_scope or fields.action_allow_unknown then
			internal.show_gui(
				name,
				fields.tabs or "4",
				fields.player_filter or state.filter,
				fields.action_player or state.action_player,
				fields.action_scope or state.action_scope,
				fields.action_template or state.action_template,
				fields.action_duration or state.action_duration,
				fields.action_custom_reason or state.action_custom_reason,
				bool_from_field(fields.action_allow_unknown, state.action_allow_unknown)
			)
			return
		end

		if fields.refresh then
			handle_refresh(
				name,
				state.tab,
				fields.player_filter or state.filter,
				fields.action_player or state.action_player,
				fields.action_scope or state.action_scope,
				fields.action_template or state.action_template,
				fields.action_duration or state.action_duration,
				fields.action_custom_reason or state.action_custom_reason,
				bool_from_field(fields.action_allow_unknown, state.action_allow_unknown)
			)
			return
		end

		if fields.tabs then
			state.row_offset = 0
			internal.show_gui(
				name,
				fields.tabs,
				fields.player_filter or state.filter,
				fields.action_player or state.action_player,
				fields.action_scope or state.action_scope,
				fields.action_template or state.action_template,
				fields.action_duration or state.action_duration,
				fields.action_custom_reason or state.action_custom_reason,
				bool_from_field(fields.action_allow_unknown, state.action_allow_unknown)
			)
		end
	end)
end
