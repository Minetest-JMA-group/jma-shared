ebpf = {}

ebpf.list_bans = function()
	local stdout, stderr, exit_code = algorithms.execute({"ebpf", "list_bans"})
	if exit_code ~= 0 then
		return stderr
	else
		return stdout
	end	
end

local function makeTrackingIterator(text, pattern)
	local pos = 1
	return function()
		if pos > #text then return nil end

		local start, finish = text:find(pattern, pos)
		if start then
			local match = text:sub(start, finish)
			pos = finish + 1
			return match
		end
		return nil
	end, function()
		-- Return remainder function
		return pos <= #text and text:sub(pos):match("^%s*(.*)") or ""
	end
end

core.register_chatcommand("ebpf", {
	params = "<subcommand> [arguments]",
	description = "Interface to the eBPFtool utility",
	privs = { server=true },
	func = function(name, params)
		local argv = {"ebpf"}
		local iter, getRemainder = makeTrackingIterator(params, "%S+")
		-- Max two arguments certainly don't have spaces or just don't exist. Inserting nil doesn't do anything
		table.insert(argv, iter())
		table.insert(argv, iter())
		if argv[2] == "ban" then
			table.insert(argv, iter())
			table.insert(argv, iter())
			table.insert(argv, getRemainder())
		end
		if argv[2] == "fetch_logs" then
			-- We won't do that here
			argv[2] = "unknown"
		end

		local stdout, stderr, exit_code = algorithms.execute(argv)
		if exit_code ~= 0 then
			return false, "Command failed\n"..stderr
		end
		if argv[2] == "unban" then
			local msg
			if name then
				msg = "[ebpf]\n"..stdout.." by"..name
			else
				msg = "[ebpf]\n"..stdout
			end
			core.log("action", msg)
			if discord then
				discord.send_action_report("%s", msg)
			end
		end
		if argv[2] == "ban" then
			local msg
			if name then
				msg = string.format("[ebpf]: %s banned %s for %s\nReason: %s", name, argv[3], algorithms.time_to_string(tonumber(argv[4])), argv[5])
			else
				msg = string.format("[ebpf]: %s banned for %s\nReason: %s", argv[3], algorithms.time_to_string(tonumber(argv[4])), argv[5])
			end
			core.log("action", msg)
			if discord then
				discord.send_action_report("%s", msg)
			end
		end
		return true, "Command successful\n"..stdout
	end
})
