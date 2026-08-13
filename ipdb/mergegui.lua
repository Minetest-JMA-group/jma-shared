-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Marko Petrović

-- Formspec GUI for browsing the merge history and rolling merges back.
-- The history of an entry is rendered as a binary tree: entry nodes are
-- buttons, the merges between them are thin lines. Clicking a node opens its
-- detail view, from which its merge can be rolled back after deciding what
-- happens to each identifier that was created after the merge.

local dbmanager
local db
local sqlite
local log
local resolve_entry

local M = {}

local gui_states = {}
local FORMNAME = "ipdb:merge_gui"

-- Escape text for use in a formspec
local function esc(s)
	return core.formspec_escape(tostring(s or ""))
end

-- Join a list of identifiers for display, capping the visible amount
---@param items string[]
---@param limit integer?
---@return string
local function format_names(items, limit)
	limit = limit or 6
	local out = {}
	for i = 1, math.min(limit, #items) do
		table.insert(out, items[i])
	end
	local s = table.concat(out, ", ")
	if #items > limit then
		s = s .. " … +" .. (#items - limit) .. " more"
	end
	return s
end

-- Label of an entry node, kept short enough to fit its button
---@param node MergeTreeNode
---@param is_root boolean
---@return string
local function node_label(node, is_root)
	local names = {}
	for i = 1, math.min(2, #node.names) do
		local n = node.names[i]
		if #n > 10 then n = n:sub(1, 10) .. "…" end
		table.insert(names, n)
	end
	local label = "#" .. node.entry_id
	if #names > 0 then label = label .. " " .. table.concat(names, ",") end
	if is_root then label = label .. " (cur)" end
	return label
end

-- Lay out the tree: the x coordinate is the depth column, the y coordinate
-- centers each node on its subtree. Returns positioned nodes, edge
-- rectangles and the total content height
local XSTEP = 2.7
local NODE_W = 2.3
local NODE_H = 0.35
local LEAF_H = 0.7
local EDGE_COLOR = "#4a6a9a"

---@param root MergeTreeNode
---@return { nodes: { node: MergeTreeNode, x: number, y: number }[], edges: { x: number, y: number, w: number, h: number }[], height: number }
local function layout_tree(root)
	local nodes = {}
	local edges = {}
	local function rec(node, depth, yoffset)
		if not node.children then
			table.insert(nodes, { node = node, x = depth * XSTEP, y = yoffset + LEAF_H / 2 - NODE_H / 2 })
			return LEAF_H
		end
		local h1 = rec(node.children[1], depth + 1, yoffset)
		local h2 = rec(node.children[2], depth + 1, yoffset + h1)
		local cy = yoffset + (h1 + h2) / 2
		local py = cy - NODE_H / 2
		local px = depth * XSTEP
		table.insert(nodes, { node = node, x = px, y = py })
		-- edges from the parent to both children
		local child_centers = { yoffset + h1 / 2, yoffset + h1 + h2 / 2 }
		for _, ccy in ipairs(child_centers) do
			table.insert(edges, { x = px + NODE_W, y = cy - 0.02, w = XSTEP - NODE_W, h = 0.04 })
			table.insert(edges, { x = px + NODE_W + (XSTEP - NODE_W) / 2 - 0.02, y = math.min(cy, ccy), w = 0.04, h = math.abs(cy - ccy) })
		end
		return h1 + h2
	end
	local height = rec(root, 0, 0.2)
	return { nodes = nodes, edges = edges, height = height }
end

---@param tree table
---@param entry_id integer
---@param merge_id integer
---@return MergeTreeNode?
local function find_node(tree, entry_id, merge_id)
	local stack = { tree.root }
	while #stack > 0 do
		local n = table.remove(stack)
		local nid = n.merge and n.merge.id or 0
		if n.entry_id == entry_id and nid == merge_id then
			return n
		end
		if n.children then
			table.insert(stack, n.children[1])
			table.insert(stack, n.children[2])
		end
	end
end

-- ═══════════════ Screens ═══════════════

local function tree_formspec(state)
	local fs = "formspec_version[6]" ..
		"size[12,8]" ..
		"field[0.4,0.35;4.6,0.8;root;" .. esc("Entry (name, IP or id)") .. ";" .. esc(state.root or "") .. "]" ..
		"field[5.2,0.35;1.4,0.8;depth;Depth;" .. esc(state.depth or "4") .. "]" ..
		"button[6.8,0.3;2.2,0.9;go;" .. esc("Show tree") .. "]" ..
		"button[9.2,0.3;2.4,0.9;close;" .. esc("Close") .. "]"
	if state.error then
		fs = fs .. "label[0.4,0.75;" .. esc(state.error) .. "]"
	end
	if not state.tree then
		return fs .. "label[0.4,1.3;Enter a name, an IP address or an entry id above and press Show tree.]"
	end
	local layout = layout_tree(state.tree.root)
	local content = {}
	for _, e in ipairs(layout.edges) do
		content[#content+1] = string.format("box[%.2f,%.2f;%.2f,%.2f;" .. EDGE_COLOR .. "]", e.x, e.y, e.w, e.h)
	end
	for _, n in ipairs(layout.nodes) do
		local mid = n.node.merge and n.node.merge.id or 0
		content[#content+1] = string.format("button[%.2f,%.2f;%.2f,%.2f;node_%d_%d;%s]",
			n.x, n.y, NODE_W, NODE_H, n.node.entry_id, mid, esc(node_label(n.node, n.node.kind == "root")))
	end
	-- notes about id reuse found along the walk
	local notes = {}
	for _, r in ipairs(state.tree.notes.reused) do
		table.insert(notes, "id #"..r.id.." is held by a different entry (created "..r.created_at..")")
	end
	for entryid, n in pairs(state.tree.notes.older_merges) do
		table.insert(notes, n.." merge(s) belong to a previous entry that had id #"..entryid)
	end
	local ny = layout.height + 0.35
	for _, note in ipairs(notes) do
		content[#content+1] = string.format("label[0.2,%.2f;%s]", ny, esc(note))
		ny = ny + 0.4
	end
	local content_h = math.max(ny, 1.5)
	return fs ..
		"scrollbar[11.5,1.15;0.4,6.45;vertical;merge_scroll]" ..
		"scroll_container[0.2,1.15;11.3,6.45;merge_scroll;vertical;0.1;" .. string.format("%.2f]", content_h) ..
		table.concat(content) ..
		"scroll_container_end[]"
end

local function detail_formspec(state)
	local node = state.node
	local m = node.merge
	local lines = {}
	table.insert(lines, "Entry #"..node.entry_id.." · "..(node.live and "live" or "pre-merge state"))
	if #node.names > 0 then table.insert(lines, "names: "..format_names(node.names)) end
	if #node.ips > 0 then table.insert(lines, "IPs: "..format_names(node.ips)) end
	if m then
		table.insert(lines, "")
		table.insert(lines, "Merge #"..m.id.." · "..os.date("!%Y-%m-%d %H:%M:%S", m.timestamp))
		table.insert(lines, "  "..m.name.." / "..m.ip.." · #"..m.entry_src.." absorbed into #"..m.entry_dst)
		if m.reverted_at then
			table.insert(lines, "  rolled back on "..os.date("!%Y-%m-%d %H:%M", m.reverted_at))
		end
	end
	local fs = "formspec_version[6]size[12,8]"
	local y = 0.3
	for i = 1, math.min(#lines, 9) do
		fs = fs .. string.format("label[0.4,%.2f;%s]", y, esc(lines[i]))
		y = y + 0.45
	end
	if m and not m.reverted_at then
		if state.info then
			local adds = state.info.additions
			local ay = y + 0.2
			if #adds == 0 then
				fs = fs .. string.format("label[0.4,%.2f;Rollback is possible.]", ay)
			else
				fs = fs .. string.format("label[0.4,%.2f;Identifiers created after the merge - choose what happens to each:]", ay)
				ay = ay + 0.45
				for i = 1, math.min(#adds, 12) do
					local a = adds[i]
					local act = state.decisions[a.value] or "keep"
					fs = fs .. string.format("label[0.4,%.2f;%s '%s' (%s) -> %s]", ay, a.type, esc(a.value), a.created_at, act) ..
						string.format("button[6.4,%.2f;1.3,0.4;ad_%d_keep;keep]", ay, i) ..
						string.format("button[7.8,%.2f;1.5,0.4;ad_%d_delete;delete]", ay, i) ..
						string.format("button[9.4,%.2f;1.3,0.4;ad_%d_move;move]", ay, i)
					ay = ay + 0.5
				end
				if #adds > 12 then
					fs = fs .. string.format("label[0.4,%.2f;%d more - they will be kept; use /ipdb unmerge %d to handle them]",
						ay, #adds - 12, state.merge_id)
				end
			end
			fs = fs .. string.format("button[8.6,7.3;3.0,0.8;rb;Roll back merge #%d]", state.merge_id)
		else
			fs = fs .. string.format("label[0.4,%.2f;Rollback unavailable: %s]", y + 0.2, esc(state.reason or "?"))
		end
	end
	fs = fs .. "button[0.4,7.3;3.0,0.8;back;Back to tree]"
	return fs
end

local function confirm_formspec(state)
	local m = state.info.merge
	local lines = {
		"Roll back merge #"..state.merge_id.."?",
		"  entry #"..m.entry_src.." will be recreated as it was at the merge",
		"  its identifiers and modstorage move back from entry #"..m.entry_dst,
		"  the destination's modstorage of the merged mods is replaced by",
		"  the pre-merge snapshot (post-merge writes to it are lost)",
	}
	local dels, moves, keeps = {}, {}, {}
	for _, a in ipairs(state.info.additions) do
		local act = state.decisions[a.value] or "keep"
		if act == "delete" then table.insert(dels, a.value)
		elseif act == "move" then table.insert(moves, a.value)
		else table.insert(keeps, a.value) end
	end
	if #dels > 0 then table.insert(lines, "  deleted: "..format_names(dels, 4)) end
	if #moves > 0 then table.insert(lines, "  moved to the recreated entry: "..format_names(moves, 4)) end
	if #keeps > 0 then table.insert(lines, "  kept at the destination: "..format_names(keeps, 4)) end
	table.insert(lines, "The merge event will be marked as reverted.")
	local fs = "formspec_version[6]size[12,8]"
	local y = 0.3
	for i = 1, math.min(#lines, 10) do
		fs = fs .. string.format("label[0.4,%.2f;%s]", y, esc(lines[i]))
		y = y + 0.45
	end
	fs = fs .. "button[3.2,7.3;3.4,0.8;rb_confirm;Confirm rollback]" ..
		"button[7.0,7.3;2.6,0.8;rb_cancel;Cancel]"
	return fs
end

local function report_formspec(state)
	local r = state.report
	local lines = {
		"Merge #"..state.merge_id.." rolled back:",
		"  entry #"..r.src_id.." recreated as it was at the merge",
		string.format("  %d name(s) and %d IP(s) moved back, %d name(s) and %d IP(s) re-added",
			r.moved_names, r.moved_ips, r.restored_names, r.restored_ips),
		string.format("  %d modstorage row(s) restored", r.modstorage_restored),
	}
	if r.dst_deleted then
		table.insert(lines, "  destination entry #"..r.dst_id.." was emptied and has been removed")
	end
	if r.modstorage_dst_skipped > 0 then
		table.insert(lines, "  "..r.modstorage_dst_skipped.." modstorage row(s) of the destination were not restored (its entry is gone)")
	end
	if r.additions_total > 0 then
		table.insert(lines, string.format("  %d post-merge identifier(s): %d deleted, %d moved, %d kept",
			r.additions_total, r.additions_deleted, r.additions_moved, r.additions_kept))
	end
	local fs = "formspec_version[6]size[12,8]"
	local y = 0.3
	for i = 1, math.min(#lines, 10) do
		fs = fs .. string.format("label[0.4,%.2f;%s]", y, esc(lines[i]))
		y = y + 0.45
	end
	fs = fs .. "button[0.4,7.3;3.0,0.8;back;Back to tree]"
	return fs
end

local function show(state, name)
	local fs
	if state.screen == "tree" then
		fs = tree_formspec(state)
	elseif state.screen == "detail" then
		fs = detail_formspec(state)
	elseif state.screen == "confirm" then
		fs = confirm_formspec(state)
	else
		fs = report_formspec(state)
	end
	core.show_formspec(name, FORMNAME, fs)
end

local function perform_rollback(state, name)
	local err = db:exec("BEGIN")
	if err ~= sqlite.OK then
		log(err)
		state.error = "Internal error"
		state.screen = "detail"
		show(state, name)
		return
	end
	local ok, report, reason = pcall(dbmanager.rollback_merge, state.merge_id, state.decisions)
	if not ok then
		log(reason)
		db:exec("ROLLBACK")
		state.error = "Internal error"
		state.screen = "detail"
		show(state, name)
		return
	end
	if not report then
		db:exec("ROLLBACK")
		state.error = reason
		state.screen = "detail"
		show(state, name)
		return
	end
	local commiterr = db:exec("COMMIT")
	if commiterr ~= sqlite.OK then
		log(commiterr)
		db:exec("ROLLBACK")
		state.error = "Internal error"
		state.screen = "detail"
		show(state, name)
		return
	end
	state.report = report
	state.screen = "report"
	-- The tree is stale now; rebuild it from the same root
	local ok2, tree = pcall(dbmanager.get_merge_tree, state.root_id, state.depth)
	if ok2 and tree then
		state.tree = tree
	end
	show(state, name)
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORMNAME then return end
	local name = player:get_player_name()
	local state = gui_states[name]
	if not state then return end
	if fields.quit or fields.close then
		gui_states[name] = nil
		return
	end
	if fields.go then
		state.root = fields.root
		local depth = tonumber(fields.depth) or 4
		if depth < 1 or depth > 8 then
			state.error = "Depth must be between 1 and 8"
			show(state, name)
			return
		end
		state.depth = depth
		local entryid = resolve_entry(fields.root)
		if not entryid then
			state.error = "Unknown identifier: "..fields.root
			show(state, name)
			return
		end
		state.error = nil
		local ok, tree, treeerr = pcall(dbmanager.get_merge_tree, entryid, depth)
		if not ok then
			log(treeerr)
			state.error = "Internal error"
			show(state, name)
			return
		end
		if not tree then
			state.error = treeerr
			show(state, name)
			return
		end
		state.tree = tree
		state.root_id = entryid
		state.screen = "tree"
		show(state, name)
		return
	end
	if fields.back then
		state.screen = "tree"
		show(state, name)
		return
	end
	for fieldname, _ in pairs(fields) do
		local eid, mid = fieldname:match("^node_(%d+)_(%d+)$")
		if eid then
			local node = find_node(state.tree, tonumber(eid), tonumber(mid))
			if node then
				state.node = node
				state.entry_id = tonumber(eid)
				state.merge_id = tonumber(mid)
				state.info, state.reason, state.decisions = nil, nil, {}
				if mid ~= "0" then
					local ok, info, reason = pcall(dbmanager.get_merge_rollback_info, tonumber(mid))
					if not ok then
						log(reason)
						state.reason = "Internal error"
					elseif info then
						state.info = info
					else
						state.reason = reason
					end
				end
				state.screen = "detail"
				show(state, name)
			end
			return
		end
		local ad_idx, action = fieldname:match("^ad_(%d+)_(keep|delete|move)$")
		if ad_idx and state.info then
			local a = state.info.additions[tonumber(ad_idx)]
			if a then state.decisions[a.value] = action end
			show(state, name)
			return
		end
		if fieldname == "rb" then
			state.screen = "confirm"
			show(state, name)
			return
		end
		if fieldname == "rb_confirm" then
			perform_rollback(state, name)
			return
		end
		if fieldname == "rb_cancel" then
			state.screen = "detail"
			show(state, name)
			return
		end
	end
end)

M.show = function(name)
	gui_states[name] = {
		screen = "tree",
		root = "",
		depth = "4",
		error = nil,
		tree = nil,
		root_id = nil,
		node = nil,
		entry_id = nil,
		merge_id = nil,
		info = nil,
		reason = nil,
		decisions = {},
		report = nil,
	}
	show(gui_states[name], name)
end

return function(dbm, dbconn, sqlite_mod, logfunc, resolver)
	dbmanager = dbm
	db = dbconn
	sqlite = sqlite_mod
	log = logfunc
	resolve_entry = resolver
	return M
end
