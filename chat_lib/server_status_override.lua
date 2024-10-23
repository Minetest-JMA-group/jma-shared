local game_title = ""
do
	local game = minetest.get_game_info()
	if game.title ~= "" then
		game_title = game.title
	else
		game_title = game.id
	end
end

local function get_server_uptime_formatted()
    local seconds = math.floor(minetest.get_server_uptime())

    if seconds == 0 then
        return "0s"
    end

    local minutes = math.floor(seconds / 60)
    seconds = seconds - (minutes * 60)

    local hours = math.floor(minutes / 60)
    minutes = minutes - (hours * 60)

    local days = math.floor(hours / 24)
    hours = hours - (days * 24)

    local result = ""
    if days > 0 then
        result = result .. string.format("%02dd:", days)
    end
    if hours > 0 or days > 0 then
        result = result .. string.format("%02dh:", hours)
    end
    if minutes > 0 or hours > 0 or days > 0 then
        result = result .. string.format("%02dm:", minutes)
    end
    result = result .. string.format("%02ds", seconds)

    return result
end

function minetest.get_server_status(name, joined)
	local msg = string.format("— %s | Version: %s | Uptime: %s | Max Lag: %.3f | ",
	game_title, minetest.get_version().string, get_server_uptime_formatted(), minetest.get_server_max_lag() or "0")

	local players = minetest.get_connected_players()
    local plist = "Players: "

    if #players == 0 then
        plist = plist .. "No connected players."
    else
        for i, p in ipairs(players) do
            plist = plist .. p:get_player_name()
            if i < #players then
                plist = plist .. ", "
            else
                plist = plist .. "."
            end
        end
    end

	msg = msg .. plist

	local motd = minetest.settings:get("motd")
	if motd and motd ~= "" then
		local motd_color = minetest.settings:get("motd_color")
		if motd_color and motd_color ~= "" then
			motd = minetest.colorize(motd_color, motd)
		end
		msg = msg .. "\n— " .. motd
	end

	return msg
end

minetest.register_chatcommand("set_motd", {
	description = "Set message of the day displayed to players connecting",
	params = "<text>",
	privs = {dev = true},
	func = function(name, text)
		minetest.settings:set("motd", text)

		minetest.log("action", "chat_lib: " .. name .. " updated the MOTD to: " .. text)
		return true, "MOTD updated"
	end,
})

minetest.register_chatcommand("set_motd_color", {
	description = "Set message of the day displayed to players connecting",
	params = "<text>",
	privs = {dev = true},
	func = function(name, color)
		minetest.settings:set("motd_color", color)

		minetest.log("action", "chat_lib: " .. name .. " updated the MOTD color to: " .. color)
		return true, "MOTD color updated"
	end,
})