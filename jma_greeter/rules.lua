local rules = {}
rules.version = 1
rules.list = {
    "test rule",
    "test rule",
    "test rule",
    "test rule",
    "test rule"
}
local rules_file = minetest.get_worldpath() .. "/rules.txt"

local function save_rules()
    local file = io.open(rules_file, "w")
    if file then
        file:write(minetest.serialize(rules))
        file:close()
    end
end

local function load_rules()
    local file = io.open(rules_file, "r")
    if file then
        local content = file:read("*all")
        local data = minetest.deserialize(content)
        if data and data.version == rules.version then
            rules = data
        end
        file:close()
    end
end

load_rules()

minetest.register_chatcommand("rules", {
    description = "Display the server rules",
    func = function(name)
        for _, line in ipairs(rules.list) do
            minetest.chat_send_player(name, line)
        end
    end,
})

minetest.register_chatcommand("update_rules", {
    description = "Update the server rules (privileged only)",
    privs = {server = true},
    func = function(name)
        -- Example: updating rules list
        rules.list = {
            "Welcome to the server!",
            "Be respectful to others.",
            "No cheating or exploiting bugs.",
            "Follow the staff's instructions.",
            "Have fun!",
            "New rule added!"
        }
        save_rules()
        minetest.chat_send_player(name, "Rules updated successfully.")
    end,
})

minetest.register_on_joinplayer(function(player)
    local pname = player:get_player_name()
    if not minetest.settings:get_bool("rules_accepted_" .. pname) then
        minetest.show_formspec(pname, "rules:accept", 
            "size[4,2]"..
            "label[0,0;Please accept the server rules to continue]"..
            "button[1,1;2,1;accept;Accept Rules]"
        )
    end
end)

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "rules:accept" then return end
    local pname = player:get_player_name()
    if fields.accept then
        minetest.settings:set_bool("rules_accepted_" .. pname, true)
        minetest.chat_send_player(pname, "Thank you for accepting the rules! You can now play.")
    end
end)