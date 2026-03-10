-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

return function(shared)
	local storage = core.get_mod_storage()
	local dbmanager, dbmanager_err = ipdb.get_internal(4, "dbmanager")
	local db, db_err = ipdb.get_internal(4, "database")
	local MODNAME = core.get_current_modname()

	local META_ENTRY_NAME_BANS = "entry_name_bans"
	local META_ENTRY_NAME_MUTES = "entry_name_mutes"
	local META_ENTRY_LOGS = "entry_logs"
	local META_MIGRATION_V3_DONE = "migration_v3_done"

	local LEGACY_NAME_BANS_KEY = "name_bans"
	local LEGACY_NAME_MUTES_KEY = "name_mutes"
	local LEGACY_NAME_LOG_PREFIX = "log_name:"
	local LEGACY_IP_BAN_LIST_KEY = "ip_ban_list"
	local LEGACY_IP_MUTE_LIST_KEY = "ip_mute_list"

	if storage:get_string(META_MIGRATION_V3_DONE) == "1" then
		local has_ids = tonumber(storage:get_string(META_ENTRY_NAME_BANS))
			and tonumber(storage:get_string(META_ENTRY_NAME_MUTES))
			and tonumber(storage:get_string(META_ENTRY_LOGS))
		if has_ids then
			return
		end
		storage:set_string(META_MIGRATION_V3_DONE, "")
	end

	if not dbmanager or not db then
		shared.disabled = true
		shared.disable_reason = "ipdb internals unavailable for migration: " .. tostring(dbmanager_err or db_err or "unknown")
		return
	end

	local entry_ids = {}

	local function entry_id_exists(entry_id)
		local stmt = db:prepare("SELECT 1 FROM UserEntry WHERE id = ? LIMIT 1")
		if not stmt then
			return false
		end
		stmt:bind_values(entry_id)
		local exists = stmt:step() == 100
		stmt:finalize()
		return exists
	end

	local function get_or_create_entry_id(meta_key)
		local current = tonumber(storage:get_string(meta_key))
		if current then
			if entry_id_exists(current) then
				entry_ids[meta_key] = current
				return current
			end
		end
		local id = dbmanager.new_entry()
		dbmanager.set_merge_allowance(id, false)
		entry_ids[meta_key] = id
		return id
	end

	local function migrate_blob_map_to_entry(raw_key, entry_id)
		local raw = storage:get_string(raw_key)
		if raw == "" then
			return
		end
		local parsed = core.deserialize(raw)
		if type(parsed) ~= "table" then
			core.log("warning", "[simplemod] migration: failed to deserialize " .. raw_key .. ", skipping")
			return
		end
		for target, value in pairs(parsed) do
			if type(target) == "string" and type(value) == "table" then
				dbmanager.insert_into_modstorage(entry_id, MODNAME, target, core.serialize(value), tonumber(value.expiry))
			end
		end
	end

	local function migrate_legacy_name_logs(entry_id)
		local tbl = storage:to_table() or {}
		local fields = tbl.fields or {}
		for key, raw in pairs(fields) do
			if key:sub(1, #LEGACY_NAME_LOG_PREFIX) == LEGACY_NAME_LOG_PREFIX and type(raw) == "string" and raw ~= "" then
				local player_name = key:sub(#LEGACY_NAME_LOG_PREFIX + 1)
				local parsed = core.deserialize(raw)
				if type(parsed) == "table" then
					for _, entry in ipairs(parsed) do
						if type(entry) == "table" then
							dbmanager.insert_into_modstorage(entry_id, MODNAME, player_name, core.serialize(entry), tonumber(entry.time) or os.time())
						end
					end
				end
			end
		end
	end


	local function migrate_ip_log_blobs_to_multimap()
		local stmt = db:prepare("SELECT id,userentry_id,data FROM Modstorage WHERE modname = ? AND key = 'log'")
		if not stmt then
			return
		end
		stmt:bind_values(MODNAME)
		while stmt:step() == 100 do
			local row_id = tonumber(stmt:get_value(0))
			local userentry_id = tonumber(stmt:get_value(1))
			local data = stmt:get_value(2)
			local parsed = data and core.deserialize(data) or nil
			if row_id and userentry_id and type(parsed) == "table" and type(parsed[1]) == "table" then
				for _, entry in ipairs(parsed) do
					if type(entry) == "table" then
						dbmanager.insert_into_modstorage(userentry_id, MODNAME, "log", core.serialize(entry), tonumber(entry.time) or os.time())
					end
				end
				dbmanager.remove_modstorage(row_id)
			end
		end
		stmt:finalize()
	end

	local function backfill_ip_punishment_aux()
		local stmt = db:prepare("SELECT id,data FROM Modstorage WHERE modname = ? AND key IN ('ban','mute') AND ancillary IS NULL")
		if not stmt then
			return
		end
		stmt:bind_values(MODNAME)
		while stmt:step() == 100 do
			local row_id = tonumber(stmt:get_value(0))
			local data = stmt:get_value(1)
			local parsed = data and core.deserialize(data) or nil
			if row_id and type(parsed) == "table" and tonumber(parsed.expiry) then
				dbmanager.update_modstorage1(row_id, nil, nil, nil, data, tonumber(parsed.expiry))
			end
		end
		stmt:finalize()
	end

	local ok, migrate_err = pcall(function()
		db:exec("BEGIN")

		local name_bans_entry_id = get_or_create_entry_id(META_ENTRY_NAME_BANS)
		local name_mutes_entry_id = get_or_create_entry_id(META_ENTRY_NAME_MUTES)
		local logs_entry_id = get_or_create_entry_id(META_ENTRY_LOGS)

		migrate_blob_map_to_entry(LEGACY_NAME_BANS_KEY, name_bans_entry_id)
		migrate_blob_map_to_entry(LEGACY_NAME_MUTES_KEY, name_mutes_entry_id)
		migrate_legacy_name_logs(logs_entry_id)
		migrate_ip_log_blobs_to_multimap()
		backfill_ip_punishment_aux()

		db:exec("COMMIT")
	end)

	if not ok then
		pcall(function()
			db:exec("ROLLBACK")
		end)
		shared.disabled = true
		shared.disable_reason = "migration failed: " .. tostring(migrate_err)
		return
	end

	storage:set_string(META_ENTRY_NAME_BANS, tostring(entry_ids[META_ENTRY_NAME_BANS] or ""))
	storage:set_string(META_ENTRY_NAME_MUTES, tostring(entry_ids[META_ENTRY_NAME_MUTES] or ""))
	storage:set_string(META_ENTRY_LOGS, tostring(entry_ids[META_ENTRY_LOGS] or ""))
	storage:set_string(META_MIGRATION_V3_DONE, "1")

	storage:set_string(LEGACY_NAME_BANS_KEY, "")
	storage:set_string(LEGACY_NAME_MUTES_KEY, "")
	storage:set_string(LEGACY_IP_BAN_LIST_KEY, "")
	storage:set_string(LEGACY_IP_MUTE_LIST_KEY, "")

	local tbl = storage:to_table() or {}
	local fields = tbl.fields or {}
	for key in pairs(fields) do
		if key:sub(1, #LEGACY_NAME_LOG_PREFIX) == LEGACY_NAME_LOG_PREFIX then
			storage:set_string(key, "")
		end
	end
end
