-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović
local sqlite = algorithms.require("lsqlite3")
if not sqlite then
	core.log("[ipdb]: lsqlite3 needed for operation. Make sure that the library is installed and ipdb is added to secure.c_mods or secure.trusted_mods")
	return
end

local modpath = core.get_modpath(core.get_current_modname())
local dbmanager = dofile(modpath .. "/dbmanager.lua")
local ipdb = dbmanager.init_ipdb(sqlite)
if not ipdb then
	core.log("error", "[ipdb] Database initialization failed, mod cannot function")
	return
end

local function log(err)
	core.log("error", "[ipdb]: Database operation failed with code: "..tostring(err))
end

core.register_on_prejoinplayer(function(name, ip)
	local err = ipdb:exec("BEGIN")
	if err ~= sqlite.OK then log(err); return end

	-- Almost every statement needs error checking. Just use pcall to catch exceptions instead of bloating the code
	local ok, err = pcall(function()
		local user = dbmanager.user_exists(name)
		local ipent = dbmanager.ip_exists(ip)
		if not user and not ipent then
			local entryid = dbmanager.new_entry()
			dbmanager.add_name(entryid, name)
			dbmanager.add_ip(entryid, ip)
		end
		if user and not ipent then
			dbmanager.add_ip(user.userentry_id, ipent.ip)
			dbmanager.update_last_seen(user.userentry_id, user.id)
		end
		if ipent and not user then
			dbmanager.add_name(ipent.userentry_id, user.name)
			dbmanager.update_last_seen(ipent.userentry_id, nil, ipent.id)
		end
		if ipent and user then
			if ipent.userentry_id ~= user.userentry_id then
				-- This is where we need to merge
				local ids = dbmanager.get_all_identifiers(ipent.userentry_id)
				-- We removed the entry that came from the IP address, now we need to insert its ids into
				-- the entry that came from the username
				dbmanager.delete_entry(ipent.userentry_id)
				local newipent_id
				for old_ip in ids.ips do
					local newid = dbmanager.add_ip(user.userentry_id, old_ip)
					if old_ip == ip then
						newipent_id = newid
					end
				end
				for old_name in ids.names do
					dbmanager.add_name(user.userentry_id, old_name)
				end
				dbmanager.update_last_seen(user.userentry_id, user.id, newipent_id)
			else
				dbmanager.update_last_seen(user.userentry_id, user.id, ipent.id)
			end
		end
	end)
	if not ok then
		log(err)
		ipdb:exec("ROLLBACK")
	else
		err = ipdb:exec("COMMIT")
		if err ~= sqlite.OK then log(err) end
	end
end)