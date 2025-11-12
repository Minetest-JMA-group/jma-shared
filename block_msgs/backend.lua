-- SPDX-License-Identifier: GPL-2.0-or-later
-- Pure Lua backend mirroring the previous native implementation.
local modname = core.get_current_modname()
local worldpath = core.get_worldpath()
local data_dir = worldpath.."/"..modname

local xattr = algorithms.get_xattr_storage()
if not xattr then
	return "algorithms.get_xattr_storage() unavailable"
end

local attr_prefix = "user."
local cache = {}
local log_prefix = "["..modname.."]"
local errno = algorithms.errno or {}
local ENODATA = errno.ENODATA
local ENOENT = errno.ENOENT

local function ensure_player_file(name)
	local fh, err = io.open(data_dir.."/"..name, "a")
	if not fh then
		core.log("error", ("%s: Failed to prepare storage for %s: %s"):format(log_prefix, name, err or "unknown error"))
		return false
	end
	fh:close()
	return true
end

local function receiver_cache(receiver)
	local entry = cache[receiver]
	if not entry then
		entry = {}
		cache[receiver] = entry
	end
	return entry
end

local function fetch_state(receiver, sender)
	local entry = receiver_cache(receiver)
	local state = entry[sender]
	if state ~= nil then
		return state
	end

	local value, err, errnum = xattr.getxattr(receiver, attr_prefix..sender)
	if value ~= nil then
		entry[sender] = true
		return true
	end

	entry[sender] = false
	if errnum ~= ENOENT and errnum ~= ENODATA then
		core.log("warning", ("%s: Failed to read xattr user.%s for %s: %s"):format(log_prefix, sender, receiver, err))
	end

	return false
end

function block_msgs.is_chat_blocked(sender_name, receiver_name)
	if type(sender_name) ~= "string" or type(receiver_name) ~= "string" then
		return false
	end
	if sender_name == receiver_name then
		return false
	end
	return fetch_state(receiver_name, sender_name)
end

local function block_command(name, param)
	local target = param:match("%S+")
	if not target then
		return false, "Usage: /block <playername>"
	end
	if name == target then
		return false, "You cannot block yourself."
	end
	if core.check_player_privs(target, "moderator") then
		return false, "You cannot block a moderator"
	end
	if not core.player_exists(target) then
		return false, "Player "..target.." doesn't exist"
	end
	if fetch_state(name, target) then
		return false, "Player "..target.." was already blocked"
	end
	if not ensure_player_file(name) then
		return false, "Failed to save the change. Error: could not access storage"
	end
	local err, errnum = xattr.setxattr(name, attr_prefix..target, "")
	if err then
		core.log("error", ("%s: Failed to save xattr user.%s for %s: %s"):format(log_prefix, target, name, err))
		return false, "Failed to save the change. Error: "..err
	end
	receiver_cache(name)[target] = true
	core.log("action", ("%s: %s has blocked %s"):format(log_prefix, name, target))
	return true, "Player "..target.." blocked. You won't see their messages anymore."
end

local function unblock_command(name, param)
	local target = param:match("%S+")
	if not target then
		return false, "Usage: /unblock <playername>"
	end
	if not core.player_exists(target) then
		return false, "Player "..target.." doesn't exist"
	end
	if not fetch_state(name, target) then
		return false, "Player "..target.." was already unblocked"
	end
	if not ensure_player_file(name) then
		return false, "Failed to save the change. Error: could not access storage"
	end
	local err, errnum = xattr.setxattr(name, attr_prefix..target, nil)
	if err then
		core.log("error", ("%s: Failed to remove xattr user.%s for %s: %s"):format(log_prefix, target, name, err))
		return false, "Failed to save the change. Error: "..err
	end
	receiver_cache(name)[target] = false
	core.log("action", ("%s: %s has unblocked %s"):format(log_prefix, name, target))
	return true, "Player "..target.." unblocked. You can chat with them again."
end

core.register_chatcommand("block", {
	params = "<playername>",
	description = "Block the player so that they can't message you",
	func = block_command,
})

core.register_chatcommand("unblock", {
	params = "<playername>",
	description = "Unblock a previously blocked player",
	func = unblock_command,
})

core.register_on_leaveplayer(function(player)
	cache[player:get_player_name()] = nil
end)
