-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

local storage = core.get_mod_storage()
local textTable = core.deserialize(storage:get_string("textTable")) or {}
local pollEnded = core.deserialize(storage:get_string("pollEnded")) or {}
local canceled = {}
local record_cancel_vote = core.settings:get_bool("question_record_cancel_vote", false)

local function merger(data1, data2)
	local votes1 = core.deserialize(data1.votes or "{}") or {}
	local votes2 = core.deserialize(data2.votes or "{}") or {}
	local merged = {}
	-- For each question, keep vote only if both entries have the same value
	for qid, v1 in pairs(votes1) do
		if votes2[qid] == v1 then
			merged[qid] = v1
		end
	end
	-- Also include votes from votes2 that are not in votes1 and have no conflict
	for qid, v2 in pairs(votes2) do
		if votes1[qid] == nil then
			merged[qid] = v2
		end
	end
	return { votes = core.serialize(merged) }
end

local mod_storage = ipdb.get_mod_storage(merger)
if not mod_storage then
	core.log("error", "[question]: Failed to initialize ipdb mod storage")
	return
end

local function get_user_votes(name)
	local ctx = mod_storage:get_context_by_name(name)
	if not ctx then
		return {}
	end
	local votes_str = ctx:get_string("votes")
	ctx:finalize()
	return core.deserialize(votes_str) or {}
end

local function set_user_votes(name, votes)
	local ctx = mod_storage:get_context_by_name(name)
	if not ctx then return end
	ctx:set_string("votes", core.serialize(votes))
	ctx:finalize()
end

local function show_formspec(playername, textID)
	local formspec = "size[8,3]bgcolor[#080808BB;true]" .. default.gui_bg .. default.gui_bg_img .. [[
		hypertext[2.3,0.1;5,1;title;<b>Server Polling<\b>]
		image[0,0;2,2;question.png]
		button_exit[1.5,2.3;2,0.8;yes;Yes]
		button_exit[3.5,2.3;2,0.8;no;No]
		button_exit[5.5,2.3;2,0.8;cancel;Cancel]
		]]
	formspec = formspec .. "label[2.3,0.7;" .. textTable[textID] .. "]"

	core.after(0.2, core.show_formspec, playername, "question:" .. tostring(textID), formspec)
end

local function show_questions(name)
	canceled[name] = {}
	local votes = get_user_votes(name)
	for i, _ in pairs(textTable) do
		if not pollEnded[i] and votes[i] == nil then
			show_formspec(name, i)
			return
		end
	end
end

if core.global_exists("ctf_api") then
	ctf_api.register_on_new_match(function()
		for _, player in ipairs(core.get_connected_players()) do
			show_questions(player:get_player_name())
		end
	end)
else
	core.register_on_joinplayer(function(player)
		show_questions(player:get_player_name())
	end)
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if string.match(formname, "^question:") then
		local name = player:get_player_name()
		local numericPart = string.match(formname, "%d+$")
		if not numericPart then return true end
		local qid = tonumber(numericPart)
		if not qid then return true end

		if pollEnded[qid] then return true end
		if not canceled[name] then canceled[name] = {} end

		local votes = get_user_votes(name)
		local has_vote = votes[qid] ~= nil

		if not has_vote then
			if fields["yes"] then
				votes[qid] = "y"
			elseif fields["no"] then
				votes[qid] = "n"
			elseif fields["cancel"] then
				if record_cancel_vote then
					votes[qid] = "c"
				else
					canceled[name][qid] = true
				end
			end
			set_user_votes(name, votes)
		end

		local new_votes = get_user_votes(name)
		for i, _ in pairs(textTable) do
			if not pollEnded[i] and new_votes[i] == nil and not (canceled[name] and canceled[name][i]) then
				show_formspec(name, i)
				return true
			end
		end
		return true
	end
end)

core.register_chatcommand("add_question", {
	description = "Add a new question to the in-game poll",
	params = "<question>",
	privs = { dev=true },
	func = function(name, param)
		if param == "" then
			return false, "You have to write a question."
		end
		table.insert(textTable, param)
		storage:set_string("textTable", core.serialize(textTable))
		return true, "Inserted question: " .. param
	end,
})

local function parse_id(qid_param)
	local qid = tonumber(qid_param)
	if qid_param == "" or not qid then
		return false, "You have to enter a valid question ID. See IDs with /list_questions"
	end
	qid = math.floor(qid)
	if not textTable[qid] then
		return false, "There is no question with such ID"
	end
	return qid
end

core.register_chatcommand("close_question", {
	description = "Close the question from accepting further answers",
	params = "<question_id>",
	privs = { dev=true },
	func = function(name, param)
		local qid, err = parse_id(param)
		if not qid then return false, err end
		pollEnded[qid] = true
		storage:set_string("pollEnded", core.serialize(pollEnded))
		return true, "Closed question with ID: " .. tostring(qid)
	end,
})

core.register_chatcommand("rm_question", {
	description = "Remove a question and its answers",
	params = "<question_id>",
	privs = { dev=true },
	func = function(name, param)
		local qid, err = parse_id(param)
		if not qid then return false, err end

		textTable[qid] = nil
		pollEnded[qid] = nil
		storage:set_string("textTable", core.serialize(textTable))
		storage:set_string("pollEnded", core.serialize(pollEnded))

		return true, "Removed question with ID: " .. tostring(qid)
	end,
})

core.register_chatcommand("list_questions", {
	description = "List all questions and their IDs",
	func = function(name, param)
		local has_questions = false
		for i, q in pairs(textTable) do
			has_questions = true
			local closed = pollEnded[i] and " (CLOSED)" or ""
			core.chat_send_player(name, tostring(i)..closed..": "..q)
		end
		if not has_questions then
			return true, "No registered questions..."
		end
	end,
})

core.register_chatcommand("change_vote", {
	description = "Change your vote on the question with given ID. See IDs with /list_questions",
	params = "<question_id>",
	func = function(name, param)
		local qid, err = parse_id(param)
		if not qid then return false, err end
		if pollEnded[qid] then
			return false, "This poll has ended. You cannot change your vote on it."
		end
		local votes = get_user_votes(name)
		votes[qid] = nil
		set_user_votes(name, votes)
		canceled[name] = {}
		show_formspec(name, qid)
		return true
	end,
})

-- Migration commands
core.register_chatcommand("question_migrate", {
	description = "Migrate old poll votes to ipdb. Use 'clean' to remove old votes after verification.",
	params = "[clean]",
	privs = { dev = true },
	func = function(name, param)
		if param == "clean" then
			-- Clean old votes from mod storage
			local storage_table = storage:to_table()
			if not storage_table then
				return false, "Could not read mod storage"
			end

			local keys_to_remove = {}
			for key, _ in pairs(storage_table.fields) do
				if key:match("^[^:]+:%d+$") then
					table.insert(keys_to_remove, key)
				end
			end

			for _, key in ipairs(keys_to_remove) do
				storage_table.fields[key] = nil
			end

			storage:from_table(storage_table)
			return true, string.format("Removed %d old vote entries.", #keys_to_remove)
		end

		-- Perform migration
		local storage_table = storage:to_table()
		if not storage_table then
			return false, "Could not read mod storage"
		end

		-- Collect votes per ipdb user entry
		local votes_by_entry = {}  -- userentry_id -> { [qid] = list of votes from all names }
		local sample_name = {}      -- userentry_id -> any player name for later context

		for key, value in pairs(storage_table.fields) do
			local playername, qid_str = key:match("^([^:]+):(%d+)$")
			if playername and qid_str then
				local qid = tonumber(qid_str)
				if qid and (value == "y" or value == "n" or value == "c") then
					local ctx = mod_storage:get_context_by_name(playername)
					if ctx then
						local uid = ctx._userentry_id
						ctx:finalize()
						votes_by_entry[uid] = votes_by_entry[uid] or {}
						votes_by_entry[uid][qid] = votes_by_entry[uid][qid] or {}
						table.insert(votes_by_entry[uid][qid], value)
						if not sample_name[uid] then
							sample_name[uid] = playername
						end
					else
						core.log("warning", "[question]: No ipdb entry for " .. playername .. " during migration, skipping.")
					end
				end
			end
		end

		local conflict_count = 0
		local migrated_count = 0

		for uid, qid_votes in pairs(votes_by_entry) do
			local final_votes = {}
			for qid, votes_list in pairs(qid_votes) do
				local first = votes_list[1]
				local all_same = true
				for i = 2, #votes_list do
					if votes_list[i] ~= first then
						all_same = false
						break
					end
				end
				if all_same then
					final_votes[qid] = first
				else
					conflict_count = conflict_count + 1
				end
			end
			if next(final_votes) then
				local ctx = mod_storage:get_context_by_name(sample_name[uid])
				if ctx then
					ctx:set_string("votes", core.serialize(final_votes))
					ctx:finalize()
					migrated_count = migrated_count + 1
				end
			end
		end

		return true, string.format("Migration complete: %d user entries migrated, %d conflicting questions discarded.", migrated_count, conflict_count)
	end,
})