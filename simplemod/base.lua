-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

return function(shared)
	local discordmt_available = core.global_exists("discord") and discord.enabled
	local discord_mute_log_channel = "1210689151993774180"
	local storage = core.get_mod_storage()
	local dbmanager, dbmanager_err = ipdb.get_internal(4, "dbmanager")
	local db, db_err = ipdb.get_internal(4, "database")
	local SQLITE_ROW = 100
	local LOG_LIMIT = 100
	local MODERATOR_MAX_BAN_DURATION = 15 * 60
	shared.OVERRIDE_CONFIRM_WINDOW_SEC = 30
	local BAN_APPEAL_SUFFIX = [[


If you think that you got banned by mistake, please contact us on Discord: ctf.jma-sig.de or write an email to loki@jma-sig.de.
(de) Wenn Sie denken, dass es sich um ein Missverständnis handelt, dann schreiben Sie bitte eine E-Mail an loki@jma-sig.de oder kontaktieren Sie uns auf Discord über die Website ctf.jma-sig.de.]]
	shared.ROW_SCROLL_STEP = 20
	shared.ROW_SCROLL_MAX = 600
	local ROW_VISIBLE_CHARS = 120

	local MODNAME = core.get_current_modname()
	local META_ENTRY_NAME_BANS = "entry_name_bans"
	local META_ENTRY_NAME_MUTES = "entry_name_mutes"
	local META_ENTRY_LOGS = "entry_logs"
	local META_LOG_BAN_JOIN_ATTEMPTS = "log_ban_join_attempts"

	if not dbmanager or not db then
		shared.disabled = true
		shared.disable_reason = "ipdb internals unavailable: " .. tostring(dbmanager_err or db_err or "unknown")
		return
	end

	shared.reason_templates = {
		spam = "Spamming",
		grief = "Griefing",
		hack = "Hacking / Cheating",
		language = "Offensive language",
		other = "",
	}
	shared.reason_template_index = {
		spam = 1,
		grief = 2,
		hack = 3,
		language = 4,
		other = 5,
	}
	local reason_template_by_text = {}
	for key, value in pairs(shared.reason_templates) do
		if key ~= "other" and value ~= "" then
			reason_template_by_text[value] = key
		end
	end

	function shared.log_message_to_discord(message, ...)
		if not discordmt_available then
			return
		end
		discord.send(string.format(message, ...), discord_mute_log_channel)
	end

	function shared.expand_reason(arg)
		if not arg or arg == "" then
			return ""
		end
		if shared.reason_templates[arg] then
			return shared.reason_templates[arg]
		end
		return arg
	end

	function shared.infer_reason_template(reason)
		return reason_template_by_text[reason or ""] or "other"
	end

	local function make_punishment_entry(source, reason, duration_sec)
		local now = os.time()
		return {
			source = source,
			reason = reason or "",
			time = now,
			expiry = duration_sec and duration_sec > 0 and now + duration_sec or nil,
		}
	end

	function shared.format_ban_message(scope, ban)
		local scope_text = scope == "ip"
			and "This account and IP address are banned."
			or "This account is banned by username."
		local reason = (ban and ban.reason and ban.reason ~= "") and ban.reason or "none"
		local tz = os.date("%Z")
		local issued = (ban and ban.time) and os.date("%Y-%m-%d %H:%M:%S", ban.time) or "unknown"
		local expires_in = "never"
		if ban and ban.expiry then
			local remaining = math.max(0, ban.expiry - os.time())
			expires_in = algorithms.time_to_string(remaining)
		end
		local msg = string.format(
			"%s Reason: %s. Issued: %s %s. Expires in: %s.",
			scope_text,
			reason,
			issued,
			tz,
			expires_in
		)
		return msg .. BAN_APPEAL_SUFFIX
	end

	function shared.format_duration_text(duration_sec)
		return (duration_sec and duration_sec > 0) and algorithms.time_to_string(duration_sec) or "permanent"
	end

	local function ban_extends_existing(existing_ban, duration_sec)
		if not existing_ban then
			return true
		end
		if not existing_ban.expiry then
			return false
		end
		if not duration_sec or duration_sec <= 0 then
			return true
		end
		return os.time() + duration_sec > existing_ban.expiry
	end

	function shared.can_issue_ban(name, duration_sec)
		if core.check_player_privs(name, {ban = true}) then
			return true
		end
		if not core.check_player_privs(name, {moderator = true}) then
			return false, "Insufficient privileges"
		end
		if not duration_sec or duration_sec <= 0 or duration_sec > MODERATOR_MAX_BAN_DURATION then
			return false, "Moderators without ban can only ban for up to " .. algorithms.time_to_string(MODERATOR_MAX_BAN_DURATION)
		end
		return true
	end

	local function with_txn(fn)
		local ok_begin, begin_err = pcall(function()
			db:exec("BEGIN")
		end)
		if not ok_begin then
			return false, begin_err
		end
		local ok_run, result_or_err = pcall(fn)
		if not ok_run then
			pcall(function()
				db:exec("ROLLBACK")
			end)
			return false, result_or_err
		end
		local ok_commit, commit_err = pcall(function()
			db:exec("COMMIT")
		end)
		if not ok_commit then
			pcall(function()
				db:exec("ROLLBACK")
			end)
			return false, commit_err
		end
		return true, result_or_err
	end

	local function read_entry_id(meta_key, label)
		local id = tonumber(storage:get_string(meta_key))
		if id then
			return id
		end
		shared.disabled = true
		shared.disable_reason = "missing " .. label .. " entry id (run migration first)"
		return nil
	end

	local function query_modstorage_row(userentry_id, key)
		local stmt = db:prepare("SELECT data,ancillary FROM Modstorage WHERE userentry_id = ? AND modname = ? AND key = ? LIMIT 1")
		if not stmt then
			return nil, "failed to prepare modstorage row query"
		end
		local ok, bind_err = pcall(function()
			stmt:bind_values(userentry_id, MODNAME, key)
		end)
		if not ok then
			stmt:finalize()
			return nil, bind_err
		end
		local data, aux
		local rc = stmt:step()
		if rc == SQLITE_ROW then
			data = stmt:get_value(0)
			aux = stmt:get_value(1)
		end
		stmt:finalize()
		if not data then
			return nil
		end
		return data, aux
	end

	local function delete_modstorage_key(userentry_id, key)
		local ok, err = with_txn(function()
			dbmanager.delete_modstorage(userentry_id, MODNAME, key)
		end)
		if not ok then
			return false, err
		end
		return true
	end

	local name_bans_entry_id = read_entry_id(META_ENTRY_NAME_BANS, "name-bans")
	if not name_bans_entry_id then
		return
	end
	local name_mutes_entry_id = read_entry_id(META_ENTRY_NAME_MUTES, "name-mutes")
	if not name_mutes_entry_id then
		return
	end
	local logs_entry_id = read_entry_id(META_ENTRY_LOGS, "name-logs")
	if not logs_entry_id then
		return
	end

	local function prune_log_rows(userentry_id, key)
		local ok, err = with_txn(function()
			local stmt = db:prepare([[
				DELETE FROM Modstorage
				WHERE userentry_id = ? AND modname = ? AND key = ?
				AND id IN (
					SELECT id FROM Modstorage
					WHERE userentry_id = ? AND modname = ? AND key = ?
					ORDER BY ancillary DESC, id DESC
					LIMIT -1 OFFSET ?
				)
			]])
			if not stmt then
				error("failed to prepare log prune statement")
			end
			stmt:bind_values(userentry_id, MODNAME, key, userentry_id, MODNAME, key, LOG_LIMIT)
			stmt:step()
			stmt:finalize()
		end)
		if not ok then
			core.log("warning", "[simplemod] failed pruning logs for key " .. tostring(key) .. ": " .. tostring(err))
		end
	end

	local function add_log_row(userentry_id, key, entry)
		local ok, err = with_txn(function()
			dbmanager.insert_into_modstorage(userentry_id, MODNAME, key, core.serialize(entry), tonumber(entry.time) or os.time())
		end)
		if not ok then
			return false, err
		end
		prune_log_rows(userentry_id, key)
		return true
	end

	local function choose_best_punishment_entry(current, candidate)
		if not candidate then
			return current
		end
		local now = os.time()
		local candidate_active = (not candidate.expiry) or candidate.expiry > now
		local current_active = current and ((not current.expiry) or current.expiry > now) or false
		if not candidate_active then
			return current
		end
		if not current_active then
			return candidate
		end
		if not current.expiry then
			return current
		end
		if not candidate.expiry then
			return candidate
		end
		if candidate.expiry >= current.expiry then
			return candidate
		end
		return current
	end

	local function collapse_ip_key_after_merge(entrydestid, key_name)
		local ok_rows, rows_or_err = pcall(dbmanager.get_from_modstorage, entrydestid, MODNAME, key_name)
		if not ok_rows then
			core.log("warning", "[simplemod] failed to read modstorage for merge collapse: " .. tostring(rows_or_err))
			return
		end
		local rows = rows_or_err
		local best = nil
		local best_id = nil
		local ids = {}
		for row_id, payload in pairs(rows) do
			row_id = tonumber(row_id)
			if row_id then
				ids[#ids + 1] = row_id
			end
			local data = payload and payload.value or nil
			local aux = payload and tonumber(payload.ancillary) or nil
			local parsed = data and core.deserialize(data) or nil
			if parsed then
				if aux and not parsed.expiry then
					parsed.expiry = aux
				end
				local prev_best = best
				best = choose_best_punishment_entry(best, parsed)
				if best ~= prev_best then
					best_id = row_id
				end
			end
		end

		for _, row_id in ipairs(ids) do
			if row_id ~= best_id then
				local ok_remove, remove_err = pcall(dbmanager.remove_modstorage, row_id)
				if not ok_remove then
					core.log("warning", "[simplemod] failed to remove modstorage row " .. tostring(row_id) .. ": " .. tostring(remove_err))
				end
			end
		end
	end

	local register_merger_err = ipdb.register_entryid_merger(function(entrysrcid, entrydestid)
		dbmanager.reassociate_modstorage(MODNAME, entrysrcid, entrydestid)
		collapse_ip_key_after_merge(entrydestid, "ban")
		collapse_ip_key_after_merge(entrydestid, "mute")
	end)
	if register_merger_err then
		shared.disabled = true
		shared.disable_reason = "failed to register ipdb merger: " .. tostring(register_merger_err)
		return
	end

	local ipdb_storage, ipdb_storage_err = ipdb.get_mod_storage()
	if not ipdb_storage then
		shared.disabled = true
		shared.disable_reason = "ipdb mod storage unavailable: " .. tostring(ipdb_storage_err or "unknown")
		return
	end

	local function is_ipv4(value)
		return type(value) == "string" and value:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
	end

	local function ipdb_ctx(target)
		if is_ipv4(target) then
			return ipdb_storage:get_context_by_ip(target)
		end
		return ipdb_storage:get_context_by_name(target)
	end

	local function ensure_ip_target_known(target, allow_unknown)
		local probe_ctx, probe_err = ipdb_ctx(target)
		if probe_ctx then
			probe_err = probe_err or probe_ctx:finalize()
			if probe_err then
				return false, probe_err
			end
			return true
		end
		if not allow_unknown then
			return false, probe_err or "This id is unknown to ipdb"
		end
		if is_ipv4(target) then
			ipdb.register_new_ids(nil, target)
		else
			ipdb.register_new_ids(target, nil)
		end
		probe_ctx, probe_err = ipdb_ctx(target)
		if not probe_ctx then
			return false, probe_err or "Failed to register target in ipdb"
		end
		probe_err = probe_err or probe_ctx:finalize()
		if probe_err then
			return false, probe_err
		end
		return true
	end

	local function set_ip_data(target, key, value, aux)
		local ip_ctx, err = ipdb_ctx(target)
		if not ip_ctx then
			return false, err or "This id is unknown to ipdb"
		end
		err = err or ip_ctx:set_string(key, value, aux)
		err = err or ip_ctx:finalize()
		if err then
			return false, err
		end
		return true
	end

	local function clear_ip_data(target, key)
		local ip_ctx, err = ipdb_ctx(target)
		if not ip_ctx then
			return err
		end
		err = err or ip_ctx:set_string(key, nil)
		err = err or ip_ctx:finalize()
		return err
	end

	local function get_ip_userentry_id(target)
		local ip_ctx, err = ipdb_ctx(target)
		if not ip_ctx then
			return nil, err
		end
		local userentry_id = ip_ctx._userentry_id
		err = err or ip_ctx:finalize()
		if err then
			return nil, err
		end
		return userentry_id
	end

	local function get_ip_identifiers(target)
		local ip_ctx, err = ipdb_ctx(target)
		if not ip_ctx then
			return nil, err
		end
		local ok, identifiers_or_err = pcall(dbmanager.get_all_identifiers, ip_ctx._userentry_id)
		err = err or ip_ctx:finalize()
		if not ok then
			return nil, identifiers_or_err
		end
		if err then
			return nil, err
		end
		return identifiers_or_err
	end

	local function prune_expired_name_entry_rows(userentry_id)
		local now = os.time()
		local ok, err = with_txn(function()
			local stmt = db:prepare("DELETE FROM Modstorage WHERE userentry_id = ? AND modname = ? AND ancillary IS NOT NULL AND ancillary <= ?")
			if not stmt then
				error("failed to prepare name prune statement")
			end
			stmt:bind_values(userentry_id, MODNAME, now)
			stmt:step()
			stmt:finalize()
		end)
		if not ok then
			core.log("warning", "[simplemod] failed pruning name entries for userentry " .. tostring(userentry_id) .. ": " .. tostring(err))
		end
	end

	local function get_name_entry(userentry_id, player_name)
		local data, aux_or_err = query_modstorage_row(userentry_id, player_name)
		if not data then
			return nil, aux_or_err
		end
		local aux = tonumber(aux_or_err)
		if aux and aux <= os.time() then
			delete_modstorage_key(userentry_id, player_name)
			return nil
		end
		local parsed = core.deserialize(data)
		if not parsed then
			return nil
		end
		if aux and not parsed.expiry then
			parsed.expiry = aux
		end
		return parsed
	end

	local function get_active_name_table(userentry_id)
		prune_expired_name_entry_rows(userentry_id)
		local now = os.time()
		local values = {}
		local stmt = db:prepare("SELECT key,data,ancillary FROM Modstorage WHERE userentry_id = ? AND modname = ? AND (ancillary IS NULL OR ancillary > ?)")
		if not stmt then
			return values
		end
		stmt:bind_values(userentry_id, MODNAME, now)
		while stmt:step() == SQLITE_ROW do
			local target = stmt:get_value(0)
			local data = stmt:get_value(1)
			local aux = tonumber(stmt:get_value(2))
			local parsed = data and core.deserialize(data) or nil
			if target and parsed then
				if aux and not parsed.expiry then
					parsed.expiry = aux
				end
				values[target] = parsed
			end
		end
		stmt:finalize()
		return values
	end

	function get_best_ip_punishment(userentry_id, key_name)
		local ok_rows, rows_or_err = pcall(dbmanager.get_from_modstorage, userentry_id, MODNAME, key_name)
		if not ok_rows then
			core.log("warning", "[simplemod] failed to read modstorage for key " .. tostring(key_name) .. ": " .. tostring(rows_or_err))
			return nil
		end
		local rows = rows_or_err
		local best = nil
		for _, payload in pairs(rows) do
			local data = payload and payload.value or nil
			local aux = payload and tonumber(payload.ancillary) or nil
			local parsed = data and core.deserialize(data) or nil
			if parsed then
				if aux and not parsed.expiry then
					parsed.expiry = aux
				end
				best = choose_best_punishment_entry(best, parsed)
			end
		end
		return best
	end

	function shared.get_ip_ban(target)
		local userentry_id, err = get_ip_userentry_id(target)
		if err then
			return nil, err
		end
		local ban = get_best_ip_punishment(userentry_id, "ban")
		if not ban then
			return nil
		end
		if ban and ban.expiry and ban.expiry <= os.time() then
			clear_ip_data(target, "ban")
			return nil
		end
		return ban
	end

	local function get_ip_mute(target)
		local userentry_id, err = get_ip_userentry_id(target)
		if err then
			return nil, err
		end
		local mute = get_best_ip_punishment(userentry_id, "mute")
		if not mute then
			return nil
		end
		if mute and mute.expiry and mute.expiry <= os.time() then
			clear_ip_data(target, "mute")
			return nil
		end
		return mute
	end

	local function prune_expired_ip_entry_rows(key_name)
		local now = os.time()
		local ok, err = with_txn(function()
			local stmt = db:prepare("DELETE FROM Modstorage WHERE modname = ? AND key = ? AND ancillary IS NOT NULL AND ancillary <= ?")
			if not stmt then
				error("failed to prepare IP prune statement")
			end
			stmt:bind_values(MODNAME, key_name, now)
			stmt:step()
			stmt:finalize()
		end)
		if not ok then
			core.log("warning", "[simplemod] failed pruning IP entries for key " .. tostring(key_name) .. ": " .. tostring(err))
		end
	end

	local function get_active_ip_table(key_name)
		prune_expired_ip_entry_rows(key_name)
		local values = {}
		local stmt = db:prepare("SELECT userentry_id,data,ancillary FROM Modstorage WHERE modname = ? AND key = ?")
		if not stmt then
			return values
		end
		stmt:bind_values(MODNAME, key_name)
		local best_by_entry = {}
		while stmt:step() == SQLITE_ROW do
			local userentry_id = tonumber(stmt:get_value(0))
			local data = stmt:get_value(1)
			local aux = tonumber(stmt:get_value(2))
			local parsed = data and core.deserialize(data) or nil
			if userentry_id and parsed then
				if aux and not parsed.expiry then
					parsed.expiry = aux
				end
				best_by_entry[userentry_id] = choose_best_punishment_entry(best_by_entry[userentry_id], parsed)
			end
		end
		stmt:finalize()
		for userentry_id, parsed in pairs(best_by_entry) do
			local ok_ids, ids_or_err = pcall(dbmanager.get_all_identifiers, userentry_id)
			local ids = ok_ids and (ids_or_err or {names = {}, ips = {}}) or {names = {}, ips = {}}
			local target = ids.names[1] or ids.ips[1] or ("entry:" .. tostring(userentry_id))
			values[target] = parsed
		end
		return values
	end

	function shared.get_active_name_bans()
		return get_active_name_table(name_bans_entry_id)
	end

	function shared.get_active_name_mutes()
		return get_active_name_table(name_mutes_entry_id)
	end

	function shared.get_active_ip_bans()
		return get_active_ip_table("ban")
	end

	function shared.get_active_ip_mutes()
		return get_active_ip_table("mute")
	end

	local function upsert_name_entry(userentry_id, target, value_table)
		local serialized = core.serialize(value_table)
		local aux = value_table.expiry or nil
		local ok, err = with_txn(function()
			local ok_rows, rows_or_err = pcall(dbmanager.get_from_modstorage, userentry_id, MODNAME, target, 1)
			if not ok_rows then
				error(rows_or_err)
			end
			local rows = rows_or_err
			local has_row = false
			for _ in pairs(rows) do
				has_row = true
				break
			end
			if has_row then
				dbmanager.update_modstorage2(userentry_id, MODNAME, target, serialized, aux)
			else
				dbmanager.insert_into_modstorage(userentry_id, MODNAME, target, serialized, aux)
			end
		end)
		if not ok then
			return false, err
		end
		return true
	end

	local function add_action_log(scope, action_type, target, source, reason, duration_sec)
		local entry = {
			type = action_type,
			scope = scope,
			target = target,
			source = source,
			reason = reason or "",
			duration = duration_sec,
			time = os.time(),
		}
		if scope == "name" then
			local ok, err = add_log_row(logs_entry_id, target, entry)
			if not ok then
				core.log("warning", "[simplemod] failed writing name log entry: " .. tostring(err))
			end
		else
			local ip_ctx, err = ipdb_ctx(target)
			if not ip_ctx then
				core.log("warning", "[simplemod] failed writing IP log entry for " .. tostring(target) .. ": " .. tostring(err))
			else
				local userentry_id = ip_ctx._userentry_id
				err = err or ip_ctx:finalize()
				if err then
					core.log("warning", "[simplemod] failed finalizing IP log context for " .. tostring(target) .. ": " .. tostring(err))
				else
					local ok, add_err = add_log_row(userentry_id, "log", entry)
					if not ok then
						core.log("warning", "[simplemod] failed writing IP log row for " .. tostring(target) .. ": " .. tostring(add_err))
					end
				end
			end
		end
	end

	local function should_log_ban_joins()
		return storage:get_string(META_LOG_BAN_JOIN_ATTEMPTS) == "1"
	end

	function shared.set_log_ban_join_attempts(enabled)
		storage:set_string(META_LOG_BAN_JOIN_ATTEMPTS, enabled and "1" or "")
	end

	function shared.log_ban_join_attempt(scope, target, source, reason)
		if not should_log_ban_joins() then
			return
		end
		add_action_log(scope, "ban_attempt", target, source, reason or "")
	end

	local function report_action(scope_text, action_type, target, source, reason, duration_sec)
		local has_reason = reason and reason ~= ""
		if action_type == "ban" or action_type == "mute" then
			if not has_reason then
				reason = "none"
			end
			local duration_text = (duration_sec and duration_sec > 0) and algorithms.time_to_string(duration_sec) or "permanent duration"
			relays.send_action_report(
				"simplemod %s (%s): **%s** -> **%s** for `%s` reason: `%s`",
				action_type,
				scope_text,
				source,
				target,
				duration_text,
				reason
			)
			return
		end

		if has_reason then
			relays.send_action_report(
				"simplemod %s (%s): **%s** -> **%s** reason: `%s`",
				action_type,
				scope_text,
				source,
				target,
				reason
			)
			return
		end

		relays.send_action_report(
			"simplemod %s (%s): **%s** -> **%s**",
			action_type,
			scope_text,
			source,
			target
		)
	end

	simplemod.log_message_to_discord = shared.log_message_to_discord

	function simplemod.ban_name(target, source, reason, duration_sec)
		local existing_ban, existing_err = get_name_entry(name_bans_entry_id, target)
		if existing_err then
			return false, existing_err
		end
		local can_overwrite_existing = not source or source == "" or core.check_player_privs(source, {ban = true})
		if existing_ban and not can_overwrite_existing and not ban_extends_existing(existing_ban, duration_sec) then
			return false, "Ban already exists; new ban must extend current ban duration"
		end
		local ban = make_punishment_entry(source, reason, duration_sec)
		local ok, err = upsert_name_entry(name_bans_entry_id, target, ban)
		if not ok then
			return false, err
		end
		add_action_log("name", "ban", target, source, reason, duration_sec)
		report_action("name", "ban", target, source, reason, duration_sec)
		local player = core.get_player_by_name(target)
		if player then
			local msg = shared.format_ban_message("name", ban)
			core.disconnect_player(target, msg)
		end
		return true
	end

	function simplemod.unban_name(target, source, reason)
		local existing, existing_err = get_name_entry(name_bans_entry_id, target)
		if existing_err then
			return false, existing_err
		end
		if not existing then
			return false, "Not name-banned"
		end
		local ok, err = delete_modstorage_key(name_bans_entry_id, target)
		if not ok then
			return false, err
		end
		add_action_log("name", "unban", target, source, reason)
		report_action("name", "unban", target, source, reason)
		return true
	end

	function simplemod.is_banned_name(target)
		local ban = get_name_entry(name_bans_entry_id, target)
		return ban ~= nil
	end

	function simplemod.mute_name(target, source, reason, duration_sec)
		local mute = make_punishment_entry(source, reason, duration_sec)
		local ok, err = upsert_name_entry(name_mutes_entry_id, target, mute)
		if not ok then
			return false, err
		end
		add_action_log("name", "mute", target, source, reason, duration_sec)
		report_action("name", "mute", target, source, reason, duration_sec)
		return true
	end

	function simplemod.unmute_name(target, source, reason)
		local existing, existing_err = get_name_entry(name_mutes_entry_id, target)
		if existing_err then
			return false, existing_err
		end
		if not existing then
			return false, "Not name-muted"
		end
		local ok, err = delete_modstorage_key(name_mutes_entry_id, target)
		if not ok then
			return false, err
		end
		add_action_log("name", "unmute", target, source, reason)
		report_action("name", "unmute", target, source, reason)
		return true
	end

	function simplemod.is_muted_name(target)
		local mute = get_name_entry(name_mutes_entry_id, target)
		return mute ~= nil
	end

	function simplemod.ban_ip(target, source, reason, duration_sec, allow_unknown)
		local known_ok, known_err = ensure_ip_target_known(target, allow_unknown)
		if not known_ok then
			return false, known_err
		end
		local existing_ban, err = shared.get_ip_ban(target)
		if err then
			return false, err
		end
		local can_overwrite_existing = not source or source == "" or core.check_player_privs(source, {ban = true})
		if existing_ban and not can_overwrite_existing and not ban_extends_existing(existing_ban, duration_sec) then
			return false, "Ban already exists; new ban must extend current ban duration"
		end
		local ban = make_punishment_entry(source, reason, duration_sec)
		local ok
		ok, err = set_ip_data(target, "ban", core.serialize(ban), ban.expiry)
		if not ok then
			return false, err
		end

		add_action_log("ip", "ban", target, source, reason, duration_sec)
		report_action("IP", "ban", target, source, reason, duration_sec)

		local msg = shared.format_ban_message("ip", ban)
		local ids, names_err = get_ip_identifiers(target)
		if names_err then
			core.log("warning", "[simplemod] failed to get linked names for IP ban target " .. target .. ": " .. tostring(names_err))
			if core.get_player_by_name(target) then
				core.disconnect_player(target, msg)
			end
			return true
		end
		---@cast ids -nil
		local names = ids.names or {}
		local seen = {[target] = true}
		if core.get_player_by_name(target) then
			core.disconnect_player(target, msg)
		end
		for _, linked_name in ipairs(names) do
			if not seen[linked_name] then
				seen[linked_name] = true
				if core.get_player_by_name(linked_name) then
					core.disconnect_player(linked_name, msg)
				end
			end
		end
		return true
	end

	function simplemod.unban_ip(target, source, reason)
		local existing, err = shared.get_ip_ban(target)
		if err then
			return false, err
		end
		if not existing then
			return false, "Not IP-banned"
		end
		err = clear_ip_data(target, "ban")
		if err then
			return false, err
		end
		add_action_log("ip", "unban", target, source, reason)
		report_action("IP", "unban", target, source, reason)
		return true
	end

	function simplemod.is_banned_ip(target)
		local ban = shared.get_ip_ban(target)
		return ban ~= nil
	end

	local function ban_duration_within_moderator_limit(ban)
		if not ban or not ban.time or not ban.expiry then
			return false
		end
		return (ban.expiry - ban.time) <= MODERATOR_MAX_BAN_DURATION
	end

	function shared.can_issue_unban(name, scope, target)
		if core.check_player_privs(name, {ban = true}) then
			return true
		end
		if not core.check_player_privs(name, {moderator = true}) then
			return false, "Insufficient privileges"
		end
		local ban, err
		if scope == "ip" then
			ban, err = shared.get_ip_ban(target)
			if err then
				return false, err
			end
		else
			ban = get_name_entry(name_bans_entry_id, target)
		end
		if not ban then
			return false, "Not banned"
		end
		if not ban_duration_within_moderator_limit(ban) then
			return false, "Moderators without ban can only unban bans up to " .. algorithms.time_to_string(MODERATOR_MAX_BAN_DURATION)
		end
		return true
	end

	function simplemod.mute_ip(target, source, reason, duration_sec, allow_unknown)
		local known_ok, known_err = ensure_ip_target_known(target, allow_unknown)
		if not known_ok then
			return false, known_err
		end
		local mute = make_punishment_entry(source, reason, duration_sec)
		local ok, err = set_ip_data(target, "mute", core.serialize(mute), mute.expiry)
		if not ok then
			return false, err
		end

		add_action_log("ip", "mute", target, source, reason, duration_sec)
		report_action("IP", "mute", target, source, reason, duration_sec)
		return true
	end

	function simplemod.unmute_ip(target, source, reason)
		local existing, err = get_ip_mute(target)
		if err then
			return false, err
		end
		if not existing then
			return false, "Not IP-muted"
		end
		err = clear_ip_data(target, "mute")
		if err then
			return false, err
		end
		add_action_log("ip", "unmute", target, source, reason)
		report_action("IP", "unmute", target, source, reason)
		return true
	end

	function simplemod.is_muted_ip(target)
		local mute = get_ip_mute(target)
		return mute ~= nil
	end

	function simplemod.get_player_log(player)
		local name_log = {}
		local name_stmt = db:prepare("SELECT data FROM Modstorage WHERE userentry_id = ? AND modname = ? AND key = ? ORDER BY ancillary DESC, id DESC LIMIT ?")
		if name_stmt then
			name_stmt:bind_values(logs_entry_id, MODNAME, player, LOG_LIMIT)
			while name_stmt:step() == SQLITE_ROW do
				local data = name_stmt:get_value(0)
				local entry = data and core.deserialize(data) or nil
				if entry then
					name_log[#name_log + 1] = entry
				end
			end
			name_stmt:finalize()
		end
		local ip_log = {}
		local userentry_id, ip_err = get_ip_userentry_id(player)
		if not ip_err and userentry_id then
			local ip_stmt = db:prepare("SELECT data FROM Modstorage WHERE userentry_id = ? AND modname = ? AND key = 'log' ORDER BY ancillary DESC, id DESC LIMIT ?")
			if ip_stmt then
				ip_stmt:bind_values(userentry_id, MODNAME, LOG_LIMIT)
				while ip_stmt:step() == SQLITE_ROW do
					local data = ip_stmt:get_value(0)
					local entry = data and core.deserialize(data) or nil
					if entry then
						ip_log[#ip_log + 1] = entry
					end
				end
				ip_stmt:finalize()
			end
		end
		local combined = {}
		for _, e in ipairs(name_log) do
			table.insert(combined, e)
		end
		for _, e in ipairs(ip_log) do
			table.insert(combined, e)
		end
		table.sort(combined, function(a, b)
			local at = tonumber(a and a.time) or 0
			local bt = tonumber(b and b.time) or 0
			return at > bt
		end)
		return combined
	end

	function shared.get_active_mute(name)
		local name_mute = get_name_entry(name_mutes_entry_id, name)
		if name_mute then
			return "name", name_mute
		end
		local ip_mute = get_ip_mute(name)
		if ip_mute then
			return "ip", ip_mute
		end
	end

	function shared.run_action(action_type, scope, target, source, reason, duration_sec, allow_unknown)
		if action_type == "ban" then
			if scope == "name" then
				return simplemod.ban_name(target, source, reason, duration_sec)
			end
			if scope == "ip" then
				return simplemod.ban_ip(target, source, reason, duration_sec, allow_unknown)
			end
		elseif action_type == "mute" then
			if scope == "name" then
				return simplemod.mute_name(target, source, reason, duration_sec)
			end
			if scope == "ip" then
				return simplemod.mute_ip(target, source, reason, duration_sec, allow_unknown)
			end
		elseif action_type == "unban" then
			if scope == "name" then
				return simplemod.unban_name(target, source, reason)
			end
			if scope == "ip" then
				return simplemod.unban_ip(target, source, reason)
			end
		elseif action_type == "unmute" then
			if scope == "name" then
				return simplemod.unmute_name(target, source, reason)
			end
			if scope == "ip" then
				return simplemod.unmute_ip(target, source, reason)
			end
		end
		return false, "Invalid action or scope"
	end

	function shared.format_active_entry(player, data)
		local expiry = data.expiry and " until " .. os.date("%Y-%m-%d %H:%M", data.expiry) or ""
		return string.format("%s: %s (by %s)%s", player, data.reason, data.source, expiry)
	end

	function shared.get_active_punishment_entry(scope, target, kind)
		if scope == "ip" then
			if kind == "mute" then
				return get_ip_mute(target)
			end
			return shared.get_ip_ban(target)
		end
		if kind == "mute" then
			return get_name_entry(name_mutes_entry_id, target)
		end
		return get_name_entry(name_bans_entry_id, target)
	end

	function shared.can_override_punishment(action_type, source, existing, duration_sec)
		if not existing then
			return true
		end
		if action_type ~= "ban" then
			return true
		end
		if core.check_player_privs(source, {ban = true}) then
			return true
		end
		if ban_extends_existing(existing, duration_sec) then
			return true
		end
		return false, "Ban already exists; new ban must extend current ban duration"
	end

	function shared.format_existing_punishment_lines(action_type, scope, target, data)
		local lines = {
			"Existing " .. action_type .. " details:",
			"  target: " .. target .. " (" .. scope .. ")",
			"  source: " .. (data.source or "unknown"),
			"  reason: " .. ((data.reason and data.reason ~= "") and data.reason or "none"),
			"  issued: " .. (data.time and os.date("%Y-%m-%d %H:%M:%S", data.time) or "unknown"),
		}
		if data.expiry then
			local total = data.time and math.max(0, data.expiry - data.time) or nil
			lines[#lines + 1] = "  duration: " .. shared.format_duration_text(total)
			lines[#lines + 1] = "  expires: " .. os.date("%Y-%m-%d %H:%M:%S", data.expiry)
		else
			lines[#lines + 1] = "  duration: permanent"
			lines[#lines + 1] = "  expires: never"
		end
		return lines
	end

	function shared.format_new_punishment_lines(action_type, scope, target, source, reason, duration_sec)
		return {
			"New " .. action_type .. " request:",
			"  target: " .. target .. " (" .. scope .. ")",
			"  source: " .. (source or "unknown"),
			"  reason: " .. ((reason and reason ~= "") and reason or "none"),
			"  duration: " .. shared.format_duration_text(duration_sec),
		}
	end

	function shared.has_active_punishment(scope, target, kind)
		if not target or target == "" then
			return false
		end
		if scope == "ip" then
			if kind == "mute" then
				return simplemod.is_muted_ip(target)
			end
			return simplemod.is_banned_ip(target)
		end
		if kind == "mute" then
			return simplemod.is_muted_name(target)
		end
		return simplemod.is_banned_name(target)
	end

	local function severity_color(action_type)
		if action_type == "ban" then
			return "#cc4444"
		end
		if action_type == "mute" then
			return "#b3872b"
		end
		if action_type == "unban" or action_type == "unmute" then
			return "#3f8f5b"
		end
		return "#d9d9d9"
	end

	local function apply_row_offset(text, offset)
		local width = ROW_VISIBLE_CHARS
		if #text <= width and offset <= 0 then
			return text
		end
		local start_index = math.max(1, offset + 1)
		if start_index > #text then
			start_index = #text
		end
		local out = text:sub(start_index, start_index + width - 1)
		if start_index > 1 then
			if #out >= 1 then
				out = "<" .. out:sub(2)
			else
				out = "<"
			end
		end
		if (start_index + width - 1) < #text then
			if #out >= 1 then
				out = out:sub(1, #out - 1) .. ">"
			else
				out = ">"
			end
		end
		return out
	end

	function shared.make_table_rows(tab, filter)
		local rows = {}
		if tab == "1" then
			for p, d in pairs(shared.get_active_name_bans()) do
				table.insert(rows, {
					color = severity_color("ban"),
					text = "[BAN] [Name] " .. shared.format_active_entry(p, d),
					target = p,
					scope = "name",
					kind = "ban",
					reason = d.reason or "",
				})
			end
			for p, d in pairs(shared.get_active_ip_bans()) do
				table.insert(rows, {
					color = severity_color("ban"),
					text = "[BAN] [IP] " .. shared.format_active_entry(p, d),
					target = p,
					scope = "ip",
					kind = "ban",
					reason = d.reason or "",
				})
			end
		elseif tab == "2" then
			for p, d in pairs(shared.get_active_name_mutes()) do
				table.insert(rows, {
					color = severity_color("mute"),
					text = "[MUTE] [Name] " .. shared.format_active_entry(p, d),
					target = p,
					scope = "name",
					kind = "mute",
					reason = d.reason or "",
				})
			end
			for p, d in pairs(shared.get_active_ip_mutes()) do
				table.insert(rows, {
					color = severity_color("mute"),
					text = "[MUTE] [IP] " .. shared.format_active_entry(p, d),
					target = p,
					scope = "ip",
					kind = "mute",
					reason = d.reason or "",
				})
			end
		elseif tab == "3" then
			if filter and filter ~= "" then
				local log = simplemod.get_player_log(filter)
				for i = 1, math.min(50, #log) do
					local e = log[i]
					local event_time = tonumber(e.time) or 0
					local line = ("[%s] %s (%s): %s by %s"):format(
						os.date("%Y-%m-%d %H:%M", event_time),
						e.type or "?",
						e.scope or "?",
						e.target or "?",
						e.source or "?"
					)
					if e.reason and e.reason ~= "" then
						line = line .. " (" .. e.reason .. ")"
					end
					if e.duration and e.duration > 0 then
						line = line .. " for " .. algorithms.time_to_string(e.duration)
					end
					table.insert(rows, {
						color = severity_color(e.type),
						text = line,
						target = e.target,
						scope = e.scope,
						kind = e.type,
						reason = e.reason or "",
					})
				end
			else
				table.insert(rows, {
					color = "#d9d9d9",
					text = "Enter a player name above and press View Log.",
				})
			end
		end

		if tab == "1" or tab == "2" then
			table.sort(rows, function(a, b)
				return a.text < b.text
			end)
		end
		if #rows == 0 then
			table.insert(rows, {color = "#d9d9d9", text = "(none)"})
		end
		return rows
	end

	function shared.make_table_data(rows, offset)
		local data = {}
		for _, row in ipairs(rows) do
			table.insert(data, row.color)
			table.insert(data, core.formspec_escape(apply_row_offset(row.text, offset or 0)))
		end
		return table.concat(data, ",")
	end

	function shared.online_player_dropdown(current_name)
		local names = {}
		for _, player in ipairs(core.get_connected_players()) do
			table.insert(names, player:get_player_name())
		end
		table.sort(names)
		table.insert(names, 1, "(select online)")

		local selected = 1
		for i = 2, #names do
			if names[i] == current_name then
				selected = i
				break
			end
		end
		return table.concat(names, ","), selected
	end

end
