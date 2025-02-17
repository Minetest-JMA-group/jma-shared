playtime = {}

local current = {}
local total = {}

local storage = minetest.get_mod_storage()

function playtime.load_playtime(name)
	return storage:get_int("playtime:" .. name)
end

function playtime.get_current_playtime(name)
	if not current[name] then
		return 0
	end
	return os.time() - current[name]
end

-- Function to get playtime
function playtime.get_total_playtime(name)
	if not minetest.get_player_by_name(name) then
		return playtime.load_playtime(name)
	end

	return total[name] + playtime.get_current_playtime(name)
end

function playtime.remove_playtime(name)
	storage:set_string(name, "")
end

local function save_playtime(player)
	local name = player:get_player_name()
	storage:set_int("playtime:" .. name, total[name] + playtime.get_current_playtime(name))
	current[name] = nil
	total[name] = nil
end

minetest.register_on_leaveplayer(function(player)
	save_playtime(player)
end)

minetest.register_on_shutdown(function(player)
	for _, p in ipairs(minetest.get_connected_players()) do
		save_playtime(p)
	end
end)

minetest.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	current[name] = os.time()
	total[name] = playtime.load_playtime(name)
end)

function playtime.seconds_to_clock(seconds)
	local seconds = tonumber(seconds)

	if seconds <= 0 then
		return "00:00:00";
	else
		local hours = string.format("%02.f", math.floor(seconds/3600));
		local mins = string.format("%02.f", math.floor(seconds/60 - (hours*60)));
		local secs = string.format("%02.f", math.floor(seconds - hours*3600 - mins *60));
		return hours..":"..mins..":"..secs
	end
end

-- Registration time functions
minetest.register_on_newplayer(function(ObjectRef)
	local name = ObjectRef:get_player_name()
	storage:set_int("regtime:" .. name, os.time())
end)

function playtime.get_registration_time(name)
	local key = "regtime:" .. name
	if storage:contains(key) then
		return storage:get_int(key)
	end
	return 0
end

minetest.register_chatcommand("regtime", {
	description = "Get registration time",
	params = "<playername>",
	privs = {moderator = true},
	func = function(name, param)
		local target_name = param:trim()
		if target_name == "" then
			return false, "No player name provided"
		end

		if not minetest.player_exists(target_name) then
			return false, "Player does not exist"
		end

		local rtime = playtime.get_registration_time(target_name)
		if rtime == 0 then
			return false, "No registration time found"
		end

		return true, os.date("%Y-%m-%d %H:%M:%S", rtime)
	end
})

minetest.register_chatcommand("playtime", {
	params = "<playername>",
	description = "Shows total and current session playtime",
	func = function(name, param)
		local target_name = param:trim()
		if target_name == "" then
			target_name = name
		elseif name ~= target_name and not minetest.check_player_privs(name, {moderator = true}) then
			return false, "You do not have permission to see other players' playtime"
		end

		if not target_name then
			return false, "Invalid player name"
		end

		if not minetest.player_exists(target_name) then
			return false, "Player does not exist"
		end

		local ptime_total = playtime.get_total_playtime(target_name)
		if ptime_total == 0 then
			return false, "Player has no playtime"
		end

		local ptime_total_clock = playtime.seconds_to_clock(ptime_total)
		local ptime_current_clock = playtime.seconds_to_clock(playtime.get_current_playtime(target_name))

		return true, "Total playtime: " .. ptime_total_clock .. "\nCurrent playtime: " .. ptime_current_clock
	end,
})
