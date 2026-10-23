local hud_ids = {}

vanish = {}
vanish.vanished = {}
vanish.old_armor_groups = {}

local has_mcl_potions = core.global_exists("mcl_potions")

function vanish.on(player)
	local player_name = player:get_player_name()

	if not core.get_player_by_name(player_name) then
		return
	end

	vanish.vanished[player_name] = true
	vanish.old_armor_groups[player_name] = player:get_armor_groups()

	player:override_day_night_ratio(1)
	player:set_observers({})
	player:set_hp(5000)

	local armor_groups = table.copy(vanish.old_armor_groups[player_name])
	armor_groups.immortal = 1
	player:set_armor_groups(armor_groups)

	if has_mcl_potions then
		mcl_potions.give_effect("invisibility", player, nil, "INF", true, true)
	end

	core.chat_send_player(player_name, core.colorize("red", "Note: You are currently in Vanish mode."))

	hud_ids[player_name] = player:hud_add({
		type = "text",
		position = {x = 0.5, y = 0.5},
		offset = {x = 0, y = 30},
		text = "You are vanished",
		number = 0xFF00FF,
		style = 3,
	})
end

function vanish.off(player)
	local player_name = player:get_player_name()

	if not vanish.vanished[player_name] or not core.get_player_by_name(player_name) then
		return
	end

	player:override_day_night_ratio()
	player:set_observers(nil)

	if has_mcl_potions then
		mcl_potions.clear_effect(player, "invisibility")
	end

	local old_armor_groups = vanish.old_armor_groups[player_name]
	if old_armor_groups then
		player:set_armor_groups(old_armor_groups)
	else
		player:set_armor_groups({fleshy = 100})
	end

	if hud_ids[player_name] then
		player:hud_remove(hud_ids[player_name])
		hud_ids[player_name] = nil
	end

	vanish.vanished[player_name] = nil
	vanish.old_armor_groups[player_name] = nil
end

core.register_privilege("vanish", "Allows to make players invisible")

core.register_on_leaveplayer(function(player)
	local player_name = player:get_player_name()
	vanish.vanished[player_name] = nil
	vanish.old_armor_groups[player_name] = nil
	hud_ids[player_name] = nil
end)

core.register_chatcommand("vanish", {
	description = "Toggle invisibility",
	privs = {vanish = true},
	func = function(player_name)
		local player = core.get_player_by_name(player_name)

		if not player then
			return false, "Player is not online."
		end

		if vanish.vanished[player_name] then
			return false, "You are already vanished. Use /unvanish first."
		end

		vanish.on(player)
		return true, "You are now vanished."
	end
})

core.register_chatcommand("unvanish", {
	description = "Toggle visibility",
	privs = {vanish = true},
	func = function(player_name)
		local player = core.get_player_by_name(player_name)

		if not player then
			return false, "Player is not online."
		end

		if not vanish.vanished[player_name] then
			return false, "You are not vanished."
		end

		vanish.off(player)
		return true, "You are now visible."
	end
})

core.register_chatcommand("vanished", {
	description = "Show list of vanished players",
	privs = {vanish = true},
	func = function()
		local out = {}

		for player_name in pairs(vanish.vanished) do
			table.insert(out, player_name)
		end

		table.sort(out)

		return true, "Vanished: " .. table.concat(out, ", ")
	end
})
