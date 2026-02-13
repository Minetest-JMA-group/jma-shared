-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović
local storage = core.get_mod_storage()
local textTable = core.deserialize(storage:get_string("textTable")) or {}
local pollEnded = core.deserialize(storage:get_string("pollEnded")) or {}
local canceled = {}
local record_cancel_vote = core.settings:get_bool("question_record_cancel_vote", false)

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
	for i, _ in pairs(textTable) do
		if not pollEnded[i] and storage:get_string(name .. ":" .. tostring(i)) == "" then
			show_formspec(name, i)
			return	-- on_player_receive_fields() will handle other questions in the table
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
		if not numericPart then
			return true
		end
		local qid = tonumber(numericPart)
		if not qid then
			return true
		end
		local storage_key = name .. ":" .. numericPart
		local has_vote = storage:get_string(storage_key) ~= ""

		if pollEnded[qid] then
			return true
		end
		if not canceled[name] then
			canceled[name] = {}
		end

		if not has_vote then
			if fields["yes"] then
				storage:set_string(storage_key, "y")
			elseif fields["no"] then
				storage:set_string(storage_key, "n")
			elseif fields["cancel"] then
				if record_cancel_vote then
					storage:set_string(storage_key, "c")
				else
					canceled[name][qid] = true
				end
			end
		end

		for i, _ in pairs(textTable) do
			local next_key = name .. ":" .. tostring(i)
			if not pollEnded[i] and storage:get_string(next_key) == "" and not (canceled[name] and canceled[name][i]) then
				show_formspec(name, i)
				return true	-- on_player_receive_fields() will handle other questions in the table
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
		if not qid then
			return false, err
		end
		pollEnded[qid] = true
		storage:set_string("pollEnded", core.serialize(pollEnded))
		return true, "Closed question with ID: " .. tostring(qid)
	end,
})

core.register_chatcommand("rm_question", {
	description = "Remove a question and it's answers",
	params = "<question_id>",
	privs = { dev=true },
	func = function(name, param)
		local qid, err = parse_id(param)
		if not qid then
			return false, err
		end

		textTable[qid] = nil
		pollEnded[qid] = nil
		storage:set_string("textTable", core.serialize(textTable))
		storage:set_string("pollEnded", core.serialize(pollEnded))
		local storage_table = storage:to_table()
		if not storage_table then
			return false, "Error: Question is removed, but it's answers remain"
		end
		local keysToRemove = {}
		for key, value in pairs(storage_table.fields) do
			local index = tonumber(string.match(key, "([^:]+)$"))
			if index == qid then
				table.insert(keysToRemove, key)
			end
		end
		for _, key in ipairs(keysToRemove) do
			storage_table.fields[key] = nil
		end
		storage:from_table(storage_table)
		return true, "Removed question with ID: " .. tostring(qid)
	end,
})

core.register_chatcommand("list_questions", {
	description = "List all questions and their IDs",
	func = function(name, param)
		local has_questions = false
		for i, q in pairs(textTable) do
			has_questions = true
			local closed = ""
			if pollEnded[i] then
				closed = " (CLOSED)"
			end
			core.chat_send_player(name, tostring(i)..closed..": "..q)
		end
		if not has_questions then
			return true, "No registered questions..."
		end
	end,
})

core.register_chatcommand("change_vote", {
	description = "Change your vote on the question with given ID. See IDs with /list_questions",
	param = "<question_id>",
	func = function(name, param)
		local qid, err = parse_id(param)
		if not qid then
			return false, err
		end
		if pollEnded[qid] then
			return false, "This poll has ended. You cannot change your vote on it."
		end
		storage:set_string(name .. ":" .. tostring(qid), "")
		canceled[name] = {}
		show_formspec(name, qid)
	end,
})
