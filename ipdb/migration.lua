core.register_chatcommand("ipdb_migrate", {
	description = "Load data from older databases into ipdb",
	params = "<xban|euban>",
	privs = { dev = true },
	func = function(name, params)
		if params == "xban" then
			if not xban then return false, "Xban has to be loaded for migration to work" end
			local db = xban.db
			local entries_done = 0
			local links_created = 0
			for _, entry in ipairs(db) do
				local names = entry.names
				if names then
					local ips = {}
					local players = {}
					for key, _ in pairs(names) do
						if key:match("^%d+%.%d+%.%d+%.%d+$") then
							table.insert(ips, key)
						else
							table.insert(players, key)
						end
					end
					if #players > 0 and #ips > 0 then
						local primary_player = players[1]
						local primary_ip = ips[1]
						-- Link the primary player to every IP
						for _, ip in ipairs(ips) do
							ipdb.register_new_ids(primary_player, ip)
							links_created = links_created + 1
						end
						-- Link every other player to the primary IP
						for i = 2, #players do
							ipdb.register_new_ids(players[i], primary_ip)
							links_created = links_created + 1
						end
						entries_done = entries_done + 1
					end
				end
			end
			return true, string.format(
				"Migrated %d xban entries, created %d name-IP links.",
				entries_done, links_created
			)
		end
		if params == "euban" then
			if not EUBan then return false, "EUBan has to be loaded for migration to work" end
			local db = EUBan.Database
			local entries_done = 0
			local links_created = 0
			for player_name, entry in pairs(db) do
				if entry.ips and type(entry.ips) == "table" then
					for _, ip in ipairs(entry.ips) do
						if type(ip) == "string" and ip ~= "" then
							ipdb.register_new_ids(player_name, ip)
							links_created = links_created + 1
						end
					end
					entries_done = entries_done + 1
				end
			end
			return true, string.format(
				"Migrated %d euban entries, created %d name‑IP links.",
				entries_done, links_created
			)
		end
		return false, "Unsupported migration. Valid arguments: xban|euban"
	end
})