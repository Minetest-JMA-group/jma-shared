-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

ipdb = { disabled = false }

local function register_dummmies()
	---@param name string?
	---@param ip string?
	ipdb.register_new_ids = function(name, ip)
		core.log("error", "[ipdb]: ipdb.register_new_ids called while ipdb is disabled")
	end
	---@param func fun(entry1: table, entry2: table): table
	ipdb.register_merger = function(func)
		local msg = "[ipdb]: ipdb.register_merger called while ipdb is disabled"
		core.log("error", msg)
		return msg
	end
	---@param func? fun(entry1: table, entry2: table): table
	ipdb.get_mod_storage = function(func)
		local msg = "[ipdb]: ipdb.get_mod_storage called while ipdb is disabled"
		core.log("error", msg)
		return nil, msg
	end
	---@param func fun(name: string, ip: string): string?
	ipdb.register_on_login = function(func)
		local msg = "[ipdb]: ipdb.register_on_login called while ipdb is disabled"
		core.log("error", msg)
		return msg
	end
	ipdb.get_internal = function(version, resource)
		return nil, "ipdb is disabled"
	end
	---@param func fun(entrysrcid: integer, entrydestid: integer)
	ipdb.register_entryid_merger = function(func)
		local msg = "[ipdb]: ipdb.register_entryid_merger called while ipdb is disabled"
		core.log("error", msg)
		return msg
	end
	ipdb.disabled = true
end
local sqlite = algorithms.require("lsqlite3")
if not sqlite then
	core.log("[ipdb]: lsqlite3 needed for operation. Make sure that the library is installed and ipdb is added to secure.c_mods or secure.trusted_mods")
	register_dummmies()
	return
end

local get_current_modname = core.get_current_modname
local modpath = core.get_modpath(get_current_modname())
local dbmanager = dofile(modpath .. "/dbmanager.lua")
---@cast dbmanager DBManager
local dbconn = dbmanager.init_ipdb(sqlite)
local no_newentries
local log_merges
local log_retention_time
local LOG_PRUNING_INTERVAL = algorithms.parse_time("3h")
local LOG_RETENTION_DEFAULT = algorithms.parse_time("15D")
local mergers = {}
local entryid_mergers = {}
if not dbconn then
	core.log("error", "[ipdb]: Database initialization failed, mod cannot function")
	register_dummmies()
	return
end

-- To be removed. Present only for DEBUGGING
ipdb.dbmanager = dbmanager

---@type integer
local version = dbconn.version
local db = dbconn.db

local function log(err)
	core.log("error", "[ipdb]: Database operation failed with code: "..tostring(err))
end

do
	local ok, err = pcall(function()
		no_newentries = dbmanager.get_meta("no_new_entries") == "true"
		log_merges = dbmanager.get_meta("log_merges") == "true"
		local retention = tonumber(dbmanager.get_meta("merge_log_retention"))
		log_retention_time = (retention and retention > 0) and retention or LOG_RETENTION_DEFAULT
	end)
	if not ok then
		log(err)
		no_newentries = true
		log_merges = true
		log_retention_time = LOG_RETENTION_DEFAULT
	end
end

-- Prune merge events older than the retention period (no-op while logging is off)
local function prune_merge_log()
	if not log_merges then return end
	local ok, err = pcall(dbmanager.prune_merge_events, log_retention_time)
	if not ok then
		log(err)
		core.log("error", "[ipdb]: Failed to prune merge log")
	end
end

-- Run the prune immediately, then keep re-arming itself every pruning
-- interval while merge logging is enabled
local cleanup_running = false
local function run_cleanup_loop()
	prune_merge_log()
	if log_merges then
		core.after(LOG_PRUNING_INTERVAL, run_cleanup_loop)
	else
		cleanup_running = false
	end
end

local function start_mergelog_cleanup()
	if log_merges and not cleanup_running then
		cleanup_running = true
		run_cleanup_loop()
	end
end
start_mergelog_cleanup()

---@param requested_version integer
---@param resource string
ipdb.get_internal = function(requested_version, resource)
	if requested_version ~= version then
		return nil, "The requested version doesn't match the currently loaded software."
	end
	local modname = get_current_modname()
	if not modname then
		return nil, "ipdb.get_internal can only be called during load time"
	end
	if not algorithms.is_trusted(modname) then
		return nil, "Permission denied"
	end
	if resource == "dbmanager" then
		return dbmanager
	end
	if resource == "database" then
		return db
	end
	return nil, "Unknown resource"
end

local function merge_modstorage(entrysrcid, entrydestid)
	for modname, merger in pairs(mergers) do
		if entryid_mergers[modname] then
			-- The merger will take userentry IDs and do whatever it wants on its own
			merger(entrysrcid, entrydestid)
			goto continue
		end
		local srctable = dbmanager.get_all_modstorage(entrysrcid, modname)
		local desttable = dbmanager.get_all_modstorage(entrydestid, modname)
		if next(srctable) == nil then goto continue end -- Destination is already the exact thing we preserve
		if next(desttable) == nil then
			-- We need to reassociate srctable to destid userentry
			dbmanager.reassociate_modstorage(modname, entrysrcid, entrydestid)
			goto continue
		end
		-- We passed the simple situations, now we need to actually call the custom merger to decide what to do
		-- First erase dest modstorage as we are about to replace it
		dbmanager.delete_modstorage(entrydestid, modname)
		local merged = merger(srctable, desttable)
		for k, v in pairs(merged) do
			dbmanager.insert_into_modstorage(entrydestid, modname, k, v)
		end
		::continue::
	end
end

local function register_new_ids(name, ip)
	local err = db:exec("BEGIN")
	if err ~= sqlite.OK then log(err); return end

	-- Almost every statement needs error checking. Just use pcall to catch exceptions instead of bloating the code
	local ok, err_or_ret = pcall(function()
		local user
		local ipent
		if name then user = dbmanager.user_exists(name) end
		if ip then ipent = dbmanager.ip_exists(ip) end
		if not user and not ipent then
			if no_newentries then
				return "[Access restriction]: New account from an unrecognized network detected. Please contact us on Discord: www.ctf.jma-sig.de or E-Mail loki@jma-sig.de to get whitelisted."
			end
			local entryid = dbmanager.new_entry()
			if name then dbmanager.add_name(entryid, name) end
			if ip then dbmanager.add_ip(entryid, ip) end
		end
		if user and not ipent then
			if ip then dbmanager.add_ip(user.userentry_id, ip) end
			dbmanager.update_last_seen(user.userentry_id, user.id)
		end
		if ipent and not user then
			if name then dbmanager.add_name(ipent.userentry_id, name) end
			dbmanager.update_last_seen(ipent.userentry_id, nil, ipent.id)
		end
		if ipent and user then
			if ipent.userentry_id ~= user.userentry_id then
				-- This is where we need to merge
				if not dbmanager.can_merge(ipent.userentry_id, user.userentry_id) then
					dbmanager.update_last_seen(user.userentry_id, user.id)
					dbmanager.update_last_seen(ipent.userentry_id, nil, ipent.id)
					return
				end
				if log_merges then
					dbmanager.new_merge_event(ipent.userentry_id, user.userentry_id, name, ip)
				end
				merge_modstorage(ipent.userentry_id, user.userentry_id)
				-- Move the absorbed entry's identifiers to the entry of the
				-- logged-in user. The identifier rows (and with them their
				-- created_at and last_seen) are preserved; the cleanup triggers
				-- delete the emptied source entry on their own. Only the
				-- triggering identifier's last_seen is bumped below.
				dbmanager.reassociate_entry(ipent.userentry_id, user.userentry_id)
				dbmanager.update_last_seen(user.userentry_id, user.id, ipent.id)
			else
				dbmanager.update_last_seen(user.userentry_id, user.id, ipent.id)
			end
		end
	end)
	if not ok then
		log(err_or_ret)
		db:exec("ROLLBACK")
		return "The server has experienced an internal database error, please try again..."
	end
	err = db:exec("COMMIT")
	if err ~= sqlite.OK then log(err); db:exec("ROLLBACK") end
	if err_or_ret then return err_or_ret end
end

local registered_callbacks = {}

core.register_on_authplayer(function(name, ip, is_success)
	if is_success then
		local ret = register_new_ids(name, ip)
		if ret then return ret end
		for _, func in ipairs(registered_callbacks) do
			ret = func(name, ip)
			if ret and type(ret) == "string" then return ret end
		end
	end
end)

---@param func fun(name: string, ip: string): string?
ipdb.register_on_login = function(func)
	if type(func) ~= "function" then
		return "Argument must be a function(name, ip)"
	end
	table.insert(registered_callbacks, func)
	return nil
end

---@param name string?
---@param ip string?
ipdb.register_new_ids = function(name, ip)
	-- We don't want to trigger enforcement here
	local old_no_newentries = no_newentries
	no_newentries = false
	register_new_ids(name, ip)
	no_newentries = old_no_newentries
end

local is_in_transaction = false
local merge_gui
-- A dot or a colon can appear in an address but never in a playername, so an
-- argument of this shape that resolves to nothing was meant as an address and
-- is a mistyped one. Callers check this only after the username lookup fails,
-- so a name of this shape that really is in the database still wins.
---@param arg string
---@return boolean
local function looks_like_address(arg)
	return arg:find("[.:]") ~= nil
end

-- Resolve an argument that names an entry: "#<id>" for the entry id itself,
-- an IP address, or a username. The '#' is what marks an id, and it never
-- needs to be guessed at: no playername can contain one, so every spelling
-- is unambiguous and bare digits always mean a username.
---@param arg string
---@return integer? entryid
---@return string? err
local function resolve_entry(arg)
	local id = arg:match("^#(%d+)$")
	if id then
		local entry = dbmanager.get_userentry(tonumber(id))
		if not entry then
			return nil, "Entry #"..id.." does not exist"
		end
		return entry.id
	end
	if arg:sub(1, 1) == "#" then
		return nil, "Malformed entry id: "..arg
	end
	if algorithms.is_ip(arg) then
		local ipent = dbmanager.ip_exists(arg)
		if not ipent then
			return nil, "The IP address "..arg.." is unknown to ipdb"
		end
		return ipent.userentry_id
	end
	local user = dbmanager.user_exists(arg)
	if not user then
		if looks_like_address(arg) then
			return nil, "Invalid IP address format: "..arg
		end
		return nil, "The username "..arg.." is unknown to ipdb"
	end
	return user.userentry_id
end

-- Look up the single name or IP row an argument refers to. Unlike
-- resolve_entry this never takes an entry id: an id names an entry, not one
-- of its identifiers, so there is no row here for "#N" to select.
---@param arg string
---@return { id: integer, kind: "name"|"ip" }? ident
---@return string? err
local function resolve_identifier(arg)
	if arg:sub(1, 1) == "#" then
		return nil, "Expected a name or an IP address, not an entry id ("..arg..")"
	end
	if algorithms.is_ip(arg) then
		local ipent = dbmanager.ip_exists(arg)
		if not ipent then
			return nil, "The IP address "..arg.." is unknown to ipdb"
		end
		return { id = ipent.id, kind = "ip" }
	end
	local user = dbmanager.user_exists(arg)
	if not user then
		if looks_like_address(arg) then
			return nil, "Invalid IP address format: "..arg
		end
		return nil, "The username "..arg.." is unknown to ipdb"
	end
	return { id = user.id, kind = "name" }
end

-- Join a list of identifiers for display, capping the visible amount
---@param items string[]
---@param limit integer?
---@return string
local function format_list(items, limit)
	limit = limit or 5
	local out = {}
	for i = 1, math.min(limit, #items) do
		table.insert(out, items[i])
	end
	local s = table.concat(out, ", ")
	if #items > limit then
		s = s .. " … and " .. (#items - limit) .. " more"
	end
	return s
end

-- The sort keys /ipdb list takes, the same three the merge GUI offers
local LIST_SORT_KEYS = { created = true, seen = true, value = true }

-- Rows /ipdb list prints, matching the merge GUI's table. The output is a
-- single chat message the client has to print, so an entry that accumulated
-- thousands of identifiers would be a wall of text. Sorting happens first,
-- so the cap never hides both ends of the list: sorting the other way and
-- reading it backwards reaches the same identifiers.
local LIST_MAX_ROWS = 200

-- Render identifier rows as aligned columns. SQLite always writes
-- created_at/last_seen as "YYYY-MM-DD HH:MM:SS", so those two columns have a
-- fixed width while the value column grows to the longest name or address.
---@param rows IdentifierRow[]
---@param order string
---@param descending boolean
---@return string
local function format_identifier_rows(rows, order, descending)
	if #rows == 0 then
		return "The entry has no identifiers."
	end
	local shown = math.min(#rows, LIST_MAX_ROWS)
	local width = #"value"
	for i = 1, shown do
		if #rows[i].value > width then width = #rows[i].value end
	end
	local fmt = "%-5s %-"..width.."s  %-19s  %-19s"
	local out = {
		string.format("%d identifier(s), by %s, %s", #rows, order,
			descending and "descending" or "ascending"),
		string.format(fmt, "kind", "value", "created", "last seen"),
	}
	for i = 1, shown do
		local r = rows[i]
		out[#out + 1] = string.format(fmt, r.kind, r.value, r.created_at, r.last_seen)
	end
	if #rows > shown then
		out[#out + 1] = string.format("… and %d more (showing %d - sort the other way to see the far end)",
			#rows - shown, shown)
	end
	return table.concat(out, "\n")
end

-- Label of a tree node for the CLI output
---@param node MergeTreeNode
---@param is_root boolean
---@return string
local function tree_label(node, is_root)
	local names = {}
	for i = 1, math.min(2, #node.names) do
		local n = node.names[i]
		if #n > 12 then n = n:sub(1, 12) .. "…" end
		table.insert(names, n)
	end
	local label = "#" .. node.entry_id
	if #names > 0 then label = label .. " · " .. table.concat(names, ", ") end
	if is_root then
		return label .. " (current)"
	end
	local m = node.merge
	if not m then return label end
	local date = os.date("!%Y-%m-%d %H:%M", m.timestamp)
	if node.kind == "src" then
		return label .. " — absorbed by #" .. m.id .. " · " .. date
	end
	return label .. " — before #" .. m.id
end

local help_string = [[
  • ipdb console:
  • Entry ids are written #<id>, e.g. "#12". A bare number is always a username.
help: Print this text
add_name <username>: Record the given username in the database
add_ip <IP Address>: Record the given IP address in the database
rm_name <username>: Remove the given username from the database
rm_ip <IP Address>: Remove the given IP address from the database
isolate <name|IP>: Create an isolated entry (no_merging flag set) and move or add the specified name/IP to it
unisolate <name|IP|#entryid>: Clear the no_merging flag, so the entry may be merged again
newentries [yes|no]: If the argument is given, change whether new user entries are allowed or not. Otherwise print current value.
list <name|IP|#entryid> [created|seen|value] [asc|desc]: List an entry's names and IPs with their first-seen and last-seen times (default: last seen, newest first)
log_merges [yes|no]: If the argument is given, change whether entry merge events are logged. Otherwise print the current value.
log_retention [<time>]: Show or change how long merge events are kept before they are pruned (e.g. 15D, 48h, 1800 seconds)
move <name|IP> <name|IP|#entryid>: Move a name/IP to the entry that the second given name/IP belongs to, or to the entry with the given id
merges [N]: List the last N merge events
merge <id>: Show the details of a merge event
tree <name|IP|#entryid> [depth]: Show the merge history of an entry as a binary tree
unmerge <id> [keep|forget]: Roll back a merge event; identifiers created after the merge are kept unless `forget` is given
merge_gui [auto|<W>x<H>]: Open the merge history GUI, sized to the window by default
]]
core.register_chatcommand("ipdb", {
	description = "Interface to the IP-based player entry database",
	params = "<subcommand> args",
	privs = { ban = true },
	---@param name string
	---@param params string
	func = function(name, params)
		local iter = params:gmatch("%S+")
		local cmd = iter()
		if cmd == "help" then
			return true, help_string
		end

		if cmd == "move" then
			local what = iter()
			local where  = iter()
			if not what or not where then
				return false, "Usage: /ipdb move <name|IP> <name|IP|#entryid>"
			end
			local err = db:exec("BEGIN")
			if err ~= sqlite.OK then log(err); return false, "Internal error" end
			local ok, res = pcall(function()
				local ident, identerr = resolve_identifier(what)
				if not ident then
					return identerr
				end
				local where_entryid, whereerr = resolve_entry(where)
				if not where_entryid then
					return whereerr
				end
				if ident.kind == "ip" then
					dbmanager.reassociate_ids(where_entryid, nil, ident.id)
				else
					dbmanager.reassociate_ids(where_entryid, ident.id, nil)
				end
			end)
			if not ok then
				log(res)
				db:exec("ROLLBACK")
				return false, "Internal error"
			end
			local commiterr = db:exec("COMMIT")
			if commiterr ~= sqlite.OK then
				log(commiterr)
				db:exec("ROLLBACK")
				return false, "Internal error"
			end
			if res then
				return true, res
			end
			return true, "Move successful"
		end

		if cmd == "add_name" then
			local newname = iter()
			if not newname then
				return false, "Usage: /ipdb add_name <username>"
			end
			ipdb.register_new_ids(newname)
			return true, "Name recorded"
		end

		if cmd == "add_ip" then
			local newip = iter()
			if not newip then
				return false, "Usage: /ipdb add_ip <IP Address>"
			end
			if not algorithms.is_ip(newip) then
				return false, "Invalid IP address format: "..newip
			end
			ipdb.register_new_ids(nil, newip)
			return true, "IP recorded"
		end

		if cmd == "newentries" then
			local arg = iter()
			if arg then
				if arg ~= "yes" and arg ~= "no" then
					return false, "Usage: /ipdb newentries [yes|no]"
				end
				no_newentries = (arg == "no")
				local ok, err = pcall(dbmanager.set_meta, "no_new_entries", no_newentries)
				if not ok then
					log(err)
					return false, "Internal error"
				end
				if no_newentries then
					return true, "Auto-generation of new user entries is not allowed now."
				else
					return true, "Auto-generation of new user entries is allowed now."
				end
			else
				local state = no_newentries and "not allowed" or "allowed"
				return true, "Auto-generation of new user entries is currently " .. state .. "."
			end
		end

		if cmd == "log_merges" then
			local arg = iter()
			if arg then
				if arg ~= "yes" and arg ~= "no" then
					return false, "Usage: /ipdb log_merges [yes|no]"
				end
				log_merges = (arg == "yes")
				local ok, err = pcall(dbmanager.set_meta, "log_merges", log_merges)
				if not ok then
					log(err)
					return false, "Internal error"
				end
				if log_merges then
					start_mergelog_cleanup()
					return true, "Entry merges will be logged from now on."
				else
					return true, "Logging of entry merges is disabled."
				end
			else
				local state = log_merges and "logged" or "not logged"
				return true, "Entry merges are currently " .. state .. "."
			end
		end

		if cmd == "log_retention" then
			local arg = iter()
			if arg then
				local secs = algorithms.parse_time(arg)
				if secs <= 0 then
					return false, "Usage: /ipdb log_retention <time>  (e.g. 15D, 48h, 1800)"
				end
				local ok, err = pcall(dbmanager.set_meta, "merge_log_retention", tostring(secs))
				if not ok then
					log(err)
					return false, "Internal error"
				end
				log_retention_time = secs
				local msg = string.format("Merge events will now be kept for %s (%d seconds).", arg, secs)
				if log_merges then
					prune_merge_log()
					msg = msg .. " Older events were pruned."
				end
				return true, msg
			end
			return true, "Merge events are currently kept for "..algorithms.time_to_string(log_retention_time)
		end

		if cmd == "list" then
			local arg = iter()
			if not arg then
				return false, "Usage: /ipdb list <name|IP|#entryid> [created|seen|value] [asc|desc]"
			end
			-- The most recently seen identifier first is what an admin is
			-- usually after, so both arguments are optional. A direction on
			-- its own keeps that key: "list #12 asc" is what a user reaches
			-- for, and rejecting it over an omitted sort key would be unkind.
			local order, descending = "seen", true
			local word = iter()
			if word then
				word = word:lower()
				if word == "asc" or word == "desc" then
					descending = (word == "desc")
				elseif not LIST_SORT_KEYS[word] then
					return false, "Sort by 'created', 'seen' or 'value', not '"..word.."'"
				else
					order = word
					local dir = iter()
					if dir then
						dir = dir:lower()
						if dir ~= "asc" and dir ~= "desc" then
							return false, "Direction must be 'asc' or 'desc', not '"..dir.."'"
						end
						descending = (dir == "desc")
					end
				end
			end
			if is_in_transaction then
				return true, "Some mod is holding the context open. Cannot lock the database."
			end
			local err = db:exec("BEGIN")
			if err ~= sqlite.OK then
				log(err)
				return true, "Internal error"
			end
			local ok, ret = pcall(function()
				local entryid, resolveerr = resolve_entry(arg)
				if not entryid then
					return resolveerr
				end
				-- get_identifiers_at with no timestamp is every identifier of
				-- the entry, each with the timestamps the GUI also shows
				local ids = dbmanager.get_identifiers_at(entryid)
				return dbmanager.order_identifiers(ids.names, ids.ips, order, descending)
			end)
			if not ok then
				log(ret)
				db:exec("ROLLBACK")
				return false, "Internal error"
			end
			err = db:exec("COMMIT")
			if err ~= sqlite.OK then log(err); db:exec("ROLLBACK") end

			if type(ret) == "string" then
				return true, ret
			end
			core.chat_send_player(name, format_identifier_rows(ret, order, descending))
			return true
		end

		if cmd == "rm_name" then
			local delname = iter()
			if not delname then
				return false, "Usage: /ipdb rm_name <username>"
			end
			local err = db:exec("BEGIN")
			if err ~= sqlite.OK then log(err); return false, "Internal error" end
			local ok, res = pcall(function()
				local user = dbmanager.user_exists(delname)
				if not user then return "No such username" end
				dbmanager.remove_name(user.id)
			end)
			if not ok then
				log(res)
				db:exec("ROLLBACK")
				return false, "Internal error"
			else
				err = db:exec("COMMIT")
				if err ~= sqlite.OK then log(err); db:exec("ROLLBACK"); return false, "Internal error" end
				if res then return res end
				return true, "Name removed"
			end
		end

		if cmd == "rm_ip" then
			local delip = iter()
			if not delip then
				return false, "Usage: /ipdb rm_ip <IP Address>"
			end
			if not algorithms.is_ip(delip) then
				return false, "Invalid IP address format: "..delip
			end
			local err = db:exec("BEGIN")
			if err ~= sqlite.OK then log(err); return false, "Internal error" end
			local ok, res = pcall(function()
				local ipent = dbmanager.ip_exists(delip)
				if not ipent then return "No such IP" end
				dbmanager.remove_ip(ipent.id)
			end)
			if not ok then
				log(res)
				db:exec("ROLLBACK")
				return false, "Internal error"
			else
				err = db:exec("COMMIT")
				if err ~= sqlite.OK then log(err); db:exec("ROLLBACK"); return false, "Internal error" end
				if res then return res end
				return true, "IP removed"
			end
		end

		if cmd == "isolate" then
			local identifier = iter()
			if not identifier then
				return false, "Usage: /ipdb isolate <name|IP>"
			end

			-- Resolved before the transaction opens, so a rejected identifier
			-- cannot leave an empty isolated entry behind
			local is_address = algorithms.is_ip(identifier)
			local user
			if not is_address then
				local ok, found = pcall(dbmanager.user_exists, identifier)
				if not ok then
					log(found)
					return false, "Internal error"
				end
				user = found
				-- A name of this shape that really is in the database was
				-- added deliberately, so it still wins
				if not user and looks_like_address(identifier) then
					return false, "Invalid IP address format: "..identifier
				end
			end

			local err = db:exec("BEGIN")
			if err ~= sqlite.OK then log(err); return false, "Internal error" end

			local ok, res = pcall(function()
				local entryid = dbmanager.new_entry()
				dbmanager.set_merge_allowance(entryid, false)

				if is_address then
					local ipent = dbmanager.ip_exists(identifier)
					if ipent then
						dbmanager.reassociate_ids(entryid, nil, ipent.id)
					else
						dbmanager.add_ip(entryid, identifier)
					end
				elseif user then
					dbmanager.reassociate_ids(entryid, user.id)
				else
					dbmanager.add_name(entryid, identifier)
				end
			end)

			if not ok then
				log(res)
				db:exec("ROLLBACK")
				return false, "Internal error"
			else
				err = db:exec("COMMIT")
				if err ~= sqlite.OK then log(err); db:exec("ROLLBACK"); return false, "Internal error" end
				return true, "Isolated entry created"
			end
		end

		if cmd == "unisolate" then
			local arg = iter()
			if not arg then
				return false, "Usage: /ipdb unisolate <name|IP|#entryid>"
			end
			local ok, ret = pcall(function()
				local entryid, resolveerr = resolve_entry(arg)
				if not entryid then
					return resolveerr
				end
				if not dbmanager.get_userentry(entryid).no_merging then
					return "Entry #"..entryid.." is not isolated"
				end
				dbmanager.set_merge_allowance(entryid, true)
				return "Entry #"..entryid.." is no longer isolated"
			end)
			if not ok then
				log(ret)
				return false, "Internal error"
			end
			return true, ret
		end

		if cmd == "merges" then
			local count = tonumber(iter() or "15") or 15
			if count < 1 or count > 100 then
				return false, "Usage: /ipdb merges [count]"
			end
			local ok, ret = pcall(function()
				local events = dbmanager.get_merge_events(count)
				if #events == 0 then
					return "No merge events have been recorded."
				end
				local lines = {}
				for _, ev in ipairs(events) do
					local state = ev.reverted_at and " [reverted]" or ""
					table.insert(lines, string.format("%6d  %s  #%d→#%d  %s / %s  (%d names, %d ips)%s",
						ev.id, os.date("!%Y-%m-%d %H:%M", ev.timestamp), ev.entry_src, ev.entry_dst,
						ev.name, ev.ip, ev.name_count, ev.ip_count, state))
				end
				return table.concat(lines, "\n")
			end)
			if not ok then
				log(ret)
				return false, "Internal error"
			end
			return true, ret
		end

		if cmd == "merge" then
			local mid = tonumber(iter() or "")
			if not mid then
				return false, "Usage: /ipdb merge <id>"
			end
			local ok, ret = pcall(function()
				local ev = dbmanager.get_merge_event(mid)
				if not ev then return "No such merge event" end
				local logt = dbmanager.get_merge_log(mid)
				local info, reason = dbmanager.get_merge_rollback_info(mid)
				local lines = {}
				table.insert(lines, string.format("Merge #%d · %s · triggered by %s / %s",
					ev.id, os.date("!%Y-%m-%d %H:%M:%S", ev.timestamp), ev.name, ev.ip))
				table.insert(lines, string.format("  entry #%d was absorbed into entry #%d", ev.entry_src, ev.entry_dst))
				local names = {}
				local ips = {}
				for _, row in ipairs(logt.names) do table.insert(names, row.name) end
				for _, row in ipairs(logt.ips) do table.insert(ips, row.ip) end
				table.insert(lines, "  snapshot: "..#names.." name(s) ("..format_list(names)..")")
				table.insert(lines, "  snapshot: "..#ips.." IP(s) ("..format_list(ips)..")")
				local mods = {}
				for _, row in ipairs(logt.modstorage) do mods[row.modname] = (mods[row.modname] or 0) + 1 end
				local modlines = {}
				for modname, n in pairs(mods) do table.insert(modlines, modname.." ("..n..")") end
				table.sort(modlines)
				table.insert(lines, "  modstorage: "..(#modlines > 0 and table.concat(modlines, ", ") or "none"))
				local dst = dbmanager.get_userentry(ev.entry_dst)
				if dst then
					local ids = dbmanager.get_all_identifiers(ev.entry_dst)
					table.insert(lines, string.format("  destination #%d is live: %s / %s",
						ev.entry_dst, format_list(ids.names), format_list(ids.ips)))
				else
					table.insert(lines, "  destination #"..ev.entry_dst.." no longer exists")
				end
				if ev.reverted_at then
					table.insert(lines, "  state: rolled back on "..os.date("!%Y-%m-%d %H:%M", ev.reverted_at))
				elseif info then
					if #info.additions > 0 then
						local adds = {}
						for _, a in ipairs(info.additions) do table.insert(adds, a.type.." '"..a.value.."'") end
						table.insert(lines, "  rollback possible; "..#info.additions..
							" identifier(s) created after the merge: "..table.concat(adds, ", "))
					else
						table.insert(lines, "  rollback possible")
					end
				else
					table.insert(lines, "  rollback unavailable: "..reason)
				end
				return table.concat(lines, "\n")
			end)
			if not ok then
				log(ret)
				return false, "Internal error"
			end
			return true, ret
		end

		if cmd == "tree" then
			local arg = iter()
			if not arg then
				return false, "Usage: /ipdb tree <name|IP|#entryid> [depth]"
			end
			local depth = tonumber(iter() or "4") or 4
			if depth < 1 or depth > 20 then
				return false, "Depth must be between 1 and 20"
			end
			local ok, ret = pcall(function()
				local entryid, resolveerr = resolve_entry(arg)
				if not entryid then
					return resolveerr
				end
				local root = dbmanager.get_merge_tree(entryid, depth)
				if not root then
					return "No merge history for entry #"..entryid
				end
				local lines = {}
				local notes = {}
				local function render(node, prefix, is_root, is_last)
					table.insert(lines, prefix .. (is_root and "" or (is_last and "└─ " or "├─ ")) .. tree_label(node, is_root))
					if node.hidden_merges then
						table.insert(notes, string.format("note: entry #%d has %d older merge(s) not shown; increase the depth to see them",
							node.entry_id, node.hidden_merges))
					end
					if node.children then
						local child_prefix = prefix .. (is_root and "" or (is_last and "   " or "│  "))
						render(node.children[1], child_prefix, false, false)
						render(node.children[2], child_prefix, false, true)
					end
				end
				render(root, "", true, false)
				for _, note in ipairs(notes) do
					table.insert(lines, note)
				end
				return table.concat(lines, "\n")
			end)
			if not ok then
				log(ret)
				return false, "Internal error"
			end
			return true, ret
		end

		if cmd == "unmerge" then
			local mid = tonumber(iter() or "")
			if not mid then
				return false, "Usage: /ipdb unmerge <id> [keep|forget]"
			end
			local flag = iter()
			if flag and flag ~= "keep" and flag ~= "forget" then
				return false, "Usage: /ipdb unmerge <id> [keep|forget]"
			end
			local ok, info, reason = pcall(dbmanager.get_merge_rollback_info, mid)
			if not ok then
				log(reason)
				return false, "Internal error"
			end
			if not info then
				return false, reason
			end
			if #info.additions > 0 and not flag then
				local adds = {}
				for _, a in ipairs(info.additions) do table.insert(adds, a.type.." '"..a.value.."'") end
				return false, #info.additions.." identifier(s) were created after this merge: "..
					table.concat(adds, ", ")..". Pass `keep` to leave them at the merged entry or `forget` to delete them."
			end
			local plan = {}
			if flag then
				-- rollback_merge knows "keep", "delete" and "move"; this
				-- command says "forget" for the second, which reads better
				-- next to "keep" but has to be translated to be acted on
				local action = (flag == "forget") and "delete" or "keep"
				for _, a in ipairs(info.additions) do plan[a.value] = action end
			end
			local err = db:exec("BEGIN")
			if err ~= sqlite.OK then log(err); return false, "Internal error" end
			local ok2, report, reason2 = pcall(dbmanager.rollback_merge, mid, plan)
			if not ok2 then
				log(reason2)
				db:exec("ROLLBACK")
				return false, "Internal error"
			end
			if not report then
				db:exec("ROLLBACK")
				return false, reason2
			end
			local commiterr = db:exec("COMMIT")
			if commiterr ~= sqlite.OK then
				log(commiterr)
				db:exec("ROLLBACK")
				return false, "Internal error"
			end
			local lines = {}
			table.insert(lines, string.format("Merge #%d rolled back: entry #%d recreated as it was at the merge",
				mid, report.src_id))
			table.insert(lines, string.format("  %d name(s) and %d IP(s) moved back, %d name(s) and %d IP(s) re-added",
				report.moved_names, report.moved_ips, report.restored_names, report.restored_ips))
			table.insert(lines, string.format("  %d modstorage row(s) restored", report.modstorage_restored))
			if report.dst_deleted then
				table.insert(lines, "  destination entry #"..report.dst_id.." was emptied and has been removed")
			end
			if report.modstorage_dst_skipped > 0 then
				table.insert(lines, "  "..report.modstorage_dst_skipped..
					" modstorage row(s) of the destination were not restored (its entry is gone)")
			end
			if report.additions_total > 0 then
				table.insert(lines, string.format("  %d post-merge identifier(s): %d deleted, %d moved, %d kept",
					report.additions_total, report.additions_deleted, report.additions_moved, report.additions_kept))
			end
			return true, table.concat(lines, "\n")
		end

		if cmd == "merge_gui" then
			-- no argument keeps whatever size was asked for before, so
			-- reopening the screen does not silently undo it
			local sizerr = merge_gui.show(name, iter())
			if sizerr then
				return false, sizerr
			end
			return true, "Merge history GUI opened."
		end

		return false, "Usage: /ipdb <subcommand> args"
	end
})

dofile(modpath .. "/migration.lua")

---@param func fun(entry1: table, entry2: table): table
ipdb.register_merger = function(func)
	if type(func) ~= "function" then
		return "Argument must be a function(entry1, entry2)"
	end
	local modname = get_current_modname()
	if not modname then
		return "ipdb.register_merger can only be called at load time"
	end
	mergers[modname] = func
	return nil
end

---@param func fun(entrysrcid: integer, entrydestid: integer)
ipdb.register_entryid_merger = function(func)
	if type(func) ~= "function" then
		return "Argument must be a function(entrysrcid, entrydestid)"
	end
	local modname = get_current_modname()
	if not modname then
		return "ipdb.register_entryid_merger can only be called at load time"
	end
	mergers[modname] = func
	entryid_mergers[modname] = true
	return nil
end

---@class IPDBContext
---@field _modname string
---@field _userentry_id integer
local DBContext = {}

---@param key string
---@param value string?
---@param ancillary integer?
function DBContext:set_string(key, value, ancillary)
	if type(self) ~= "table" or type(key) ~= "string" or (type(value) ~= "string" and type(value) ~= "nil") or
	   type(self._userentry_id) ~= "number" or type(self._modname) ~= "string" or
	   self._userentry_id ~= math.floor(self._userentry_id) or not is_in_transaction or
	   (ancillary ~= nil and (type(ancillary) ~= "number" or math.floor(ancillary) ~= ancillary)) then
		return "Invalid argument"
	end
	local ok, ret
	if value then
		ok, ret = pcall(function()
			local existing_val = dbmanager.get_from_modstorage(self._userentry_id, self._modname, key, 1)
			if next(existing_val) == nil then
				dbmanager.insert_into_modstorage(self._userentry_id, self._modname, key, value, ancillary)
			else
				dbmanager.update_modstorage2(self._userentry_id, self._modname, key, value, ancillary)
			end
		end)
	else
		ok, ret = pcall(dbmanager.delete_modstorage, self._userentry_id, self._modname, key)
	end
	if not ok then
		log(ret)
		db:exec("ROLLBACK")
		is_in_transaction = false
		return "Internal error"
	end
	return nil
end

function DBContext.finalize()
	if not is_in_transaction then return end
	local err = db:exec("COMMIT")
	if err ~= sqlite.OK then log(err); db:exec("ROLLBACK"); return "Internal error" end
	is_in_transaction = false
end

---@param key string
---@param value string
---@param ancillary integer?
function DBContext:add_string(key, value, ancillary)
	if type(self) ~= "table" or type(key) ~= "string" or type(value) ~= "string" or
	   type(self._userentry_id) ~= "number" or type(self._modname) ~= "string" or
	   self._userentry_id ~= math.floor(self._userentry_id) or not is_in_transaction or
	   (ancillary ~= nil and (type(ancillary) ~= "number" or math.floor(ancillary) ~= ancillary)) then
		return "Invalid argument"
	end
	local ok, ret = pcall(dbmanager.insert_into_modstorage, self._userentry_id, self._modname, key, value, ancillary)
	if not ok then
		log(ret)
		db:exec("ROLLBACK")
		is_in_transaction = false
		return "Internal error"
	end
	return nil
end

---@param key string
---@param limit integer?
---@return table<integer, ModstorageValue>
---@overload fun(self, key: string, limit?: integer): nil, string
function DBContext:get_strings(key, limit)
	if type(self) ~= "table" or type(key) ~= "string" or
	   (limit and (type(limit) ~= "number" or limit ~= math.floor(limit))) or
	   type(self._userentry_id) ~= "number" or type(self._modname) ~= "string" or
	   self._userentry_id ~= math.floor(self._userentry_id) or not is_in_transaction then
		return nil, "Invalid argument"
	end
	local ok, ret = pcall(dbmanager.get_from_modstorage, self._userentry_id, self._modname, key, limit)
	if not ok then
		log(ret)
		db:exec("ROLLBACK")
		is_in_transaction = false
		return nil, "Internal error"
	end
	return ret
end

-- nil, errstring is returned on error
---@param key string
---@return string, integer? -- Value and optional ancillary
---@overload fun(self, key: string): nil, string -- Error
---@overload fun(seld, key: string): nil -- Key not found
function DBContext:get_string(key)
	local ret, err = self:get_strings(key, 1)
	if err then return nil, err end
	---@cast ret -nil
	local _, v = next(ret)
	if not v then
		return nil
	end
	return v.value, v.ancillary
end

-- Update key (if not nil), value (if not nil) and optionally ancillary on the given modstorage row
---@param modstorage_id integer
---@param key string?
---@param value string?
---@param ... integer? -- Supply ancillary if you want to modify it; nil gets turned to sqlite.NULL
function DBContext:update_value(modstorage_id, key, value, ...)
	if type(modstorage_id) ~= "number" or modstorage_id ~= math.floor(modstorage_id) or
	   (key ~= nil and type(key) ~= "string") or (value ~= nil and type(value) ~= "string") then
		return "Invalid argument"
	end
	local _, err = pcall(function(...)
		local modstorage_info = dbmanager.get_modstorage_info(modstorage_id)
		if not modstorage_info then
			return "Value doesn't exist"
		end
		if modstorage_info.modname ~= self._modname or modstorage_info.userentry_id ~= self._userentry_id then
			return "Value doesn't belong to you"
		end
		dbmanager.update_modstorage1(modstorage_id, nil, nil, key, value, ...)
	end, ...)
	if err then
		---@cast err string
		return err
	end
	return nil
end

-- Remove the value from modstorage based on id
---@param modstorage_id integer
function DBContext:remove(modstorage_id)
	if type(modstorage_id) ~= "number" or modstorage_id ~= math.floor(modstorage_id) then
		return "Invalid argument"
	end
	local _, err = pcall(function()
		local modstorage_info = dbmanager.get_modstorage_info(modstorage_id)
		if not modstorage_info then
			return "Value doesn't exist"
		end
		if modstorage_info.modname ~= self._modname or modstorage_info.userentry_id ~= self._userentry_id then
			return "Value doesn't belong to you"
		end
		dbmanager.remove_modstorage(modstorage_id)
	end)
	if err then
		---@cast err string
		return err
	end
	return nil
end

-- Get a table with names and IPs belonging to this entry
---@return { ips: string[], names: string[] }
---@overload fun(): nil, string
function DBContext:get_linked_ids()
	if type(self._userentry_id) ~= "number" or self._userentry_id ~= math.floor(self._userentry_id) then
		return nil, "Invalid context"
	end
	local ok, ret = pcall(dbmanager.get_all_identifiers, self._userentry_id)
	if not ok then
		---@cast ret unknown
		return nil, ret
	end
	return ret
end

---@return IPDBContext
---@overload fun(modname, id, getter): nil, string
local function modstorage_getcontext(modname, id, getter)
	if is_in_transaction then
		return nil, "Database locked by another context"
	end
	is_in_transaction = true
	local err = db:exec("BEGIN")
	if err ~= sqlite.OK then log(err); return nil, "Internal error" end

	local ok, ident = pcall(getter, id)
	if not ok then
		log(ident)
		db:exec("ROLLBACK")
		return nil, "Internal error"
	end
	if not ident then
		DBContext.finalize()
		return nil, "This id is unknown to ipdb"
	end
	local context = table.copy_with_metatables(DBContext)
	context._modname = modname
	context._userentry_id = ident.userentry_id
	return context
end

---@param func? fun(entry1: table, entry2: table): table
---@return IPDBStorage
---@overload fun(func?: fun(entry1: table, entry2: table): table): nil, string
ipdb.get_mod_storage = function(func)
	if func and type(func) ~= "function" then
		return nil, "If supplied, the argument must be a function(entry1, entry2)"
	end
	local modname = get_current_modname()
	if not modname then
		return nil, "ipdb.get_mod_storage can only be called at load time"
	end
	if func then mergers[modname] = func end
	if not mergers[modname] then
		return nil, "A merger function must be registered before you can use the modstorage"
	end
	return {
		_modname = modname,
		get_context_by_name = function(self, name)
			if type(name) ~= "string" then
				return nil, "Argument must be a username"
			end
			if type(self) ~= "table" or type(self._modname) ~= "string" then
				return nil, "Corrupted modstorage"
			end
			return modstorage_getcontext(self._modname, name, dbmanager.user_exists)
		end,
		get_context_by_ip = function(self, ip)
			if type(ip) ~= "string" or not algorithms.is_ip(ip) then
				return nil, "Argument must be an IP address"
			end
			if type(self) ~= "table" or type(self._modname) ~= "string" then
				return nil, "Corrupted modstorage"
			end
			return modstorage_getcontext(self._modname, ip, dbmanager.ip_exists)
		end,
	}
end

merge_gui = dofile(modpath .. "/mergegui.lua")(dbmanager, db, sqlite, log, resolve_entry)
