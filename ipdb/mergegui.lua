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

-- Width of one character in form units, measured from the client's formspec
-- font, and the width of a line of text allowing for the left margin
local CHAR_W = 0.15
local TEXT_W = 11.4

-- A label[] does not wrap: whatever runs past the right edge is simply gone.
-- Split a list into lines that fit instead, indenting the continuation lines
-- under the prefix so it still reads as one list. At most `limit` items are
-- named; the rest are counted.
---@param lines string[] # the lines are appended here
---@param prefix string
---@param items string[]
---@param limit integer?
local function append_list(lines, prefix, items, limit)
	limit = limit or 6
	local budget = math.floor(TEXT_W / CHAR_W)
	local parts = {}
	for i = 1, math.min(limit, #items) do
		parts[#parts + 1] = items[i]
	end
	if #items > limit then
		parts[#parts + 1] = "… +" .. (#items - limit) .. " more"
	end
	local indent = string.rep(" ", #prefix)
	local cur = prefix
	for i, part in ipairs(parts) do
		local piece = (i == 1) and part or (", " .. part)
		if i > 1 and #cur + #piece > budget then
			table.insert(lines, cur .. ",")
			cur = indent .. part
		else
			cur = cur .. piece
		end
	end
	table.insert(lines, cur)
end

-- Shorten a single line of data to what the window can hold. Used as a last
-- resort on lines whose content is not bounded by the code that builds them:
-- a label[] neither wraps nor clips, so anything past the right edge is gone.
---@param text string
---@param chars integer?  # a shorter limit, when something sits to the right
---@return string
local function fit_line(text, chars)
	local budget = chars or math.floor(TEXT_W / CHAR_W)
	if #text > budget then
		return text:sub(1, budget - 1) .. "…"
	end
	return text
end

-- Split prose across lines that fit, on word boundaries. Truncating a
-- sentence would lose its end, which is usually the part that says what to do
-- about it; wrapping keeps all of it readable.
---@param lines string[] # the lines are appended here
---@param text string
---@param indent string? # prefix for the continuation lines
local function append_wrapped(lines, text, indent)
	local budget = math.floor(TEXT_W / CHAR_W)
	local pad = indent or ""
	local cur = ""
	for word in text:gmatch("%S+") do
		if #word > budget then
			word = word:sub(1, budget - 1) .. "…"
		end
		if cur == "" then
			cur = word
		elseif #cur + 1 + #word <= budget then
			cur = cur .. " " .. word
		else
			table.insert(lines, cur)
			cur = pad .. word
		end
	end
	if cur ~= "" then
		table.insert(lines, cur)
	end
end

-- Split text into lines that fit, breaking inside a word when it has to. A
-- minified JSON value is one enormous token with nothing to break on, and
-- shortening it would lose the very content the value screen exists to show.
-- Newlines already in the text stay line breaks. Returns true if the line
-- limit cut the text short.
---@param lines string[] # the lines are appended here
---@param text string
---@param indent string? # prefix for the continuation lines
---@param max_lines integer?
---@return boolean truncated
local function append_hard_wrapped(lines, text, indent, max_lines)
	local budget = math.floor(TEXT_W / CHAR_W)
	local pad = indent or ""
	local started = false
	for raw in (text .. "\n"):gmatch("(.-)\n") do
		local rest = raw
		repeat
			local chunk = rest:sub(1, budget)
			rest = rest:sub(budget + 1)
			table.insert(lines, (started and pad or "") .. chunk)
			started = true
			if max_lines and #lines >= max_lines then
				return true
			end
		until rest == ""
	end
	return false
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
-- rectangles, the total content height, and the node width they were laid
-- out for.
local MIN_NODE_W = 2.3
local MAX_NODE_W = 6.5
local NODE_PAD = 0.3
local NODE_GAP = 0.45
local NODE_H = 0.35
local LEAF_H = 0.7
local EDGE_COLOR = "#4a6a9a"

---@param root MergeTreeNode
---@return { nodes: { node: MergeTreeNode, x: number, y: number }[], edges: { x: number, y: number, w: number, h: number }[], height: number, node_w: number }
local function layout_tree(root)
	-- Every node is sized to the widest label in this tree: the engine cuts
	-- off a label wider than its button, which would hide exactly the
	-- identifiers the tree exists to show
	local widest = MIN_NODE_W
	local function scan(node)
		local w = #node_label(node, node.kind == "root") * CHAR_W + NODE_PAD
		if w > widest then widest = w end
		if node.children then
			scan(node.children[1])
			scan(node.children[2])
		end
	end
	scan(root)
	local node_w = math.min(widest, MAX_NODE_W)
	local xstep = node_w + NODE_GAP

	local nodes = {}
	local edges = {}
	local function rec(node, depth, yoffset)
		if not node.children then
			table.insert(nodes, { node = node, x = depth * xstep, y = yoffset + LEAF_H / 2 - NODE_H / 2 })
			return LEAF_H
		end
		local h1 = rec(node.children[1], depth + 1, yoffset)
		local h2 = rec(node.children[2], depth + 1, yoffset + h1)
		local cy = yoffset + (h1 + h2) / 2
		local py = cy - NODE_H / 2
		local px = depth * xstep
		table.insert(nodes, { node = node, x = px, y = py })
		-- edges from the parent to both children
		local child_centers = { yoffset + h1 / 2, yoffset + h1 + h2 / 2 }
		for _, ccy in ipairs(child_centers) do
			table.insert(edges, { x = px + node_w, y = cy - 0.02, w = xstep - node_w, h = 0.04 })
			table.insert(edges, { x = px + node_w + (xstep - node_w) / 2 - 0.02, y = math.min(cy, ccy), w = 0.04, h = math.abs(cy - ccy) })
		end
		return h1 + h2
	end
	local height = rec(root, 0, 0.2)
	return { nodes = nodes, edges = edges, height = height, node_w = node_w }
end

---@param root MergeTreeNode
---@param entry_id integer
---@param merge_id integer
---@return MergeTreeNode?
local function find_node(root, entry_id, merge_id)
	local stack = { root }
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

-- The canvas is a rectangular viewport below the input row. The tree is drawn
-- in canvas coordinates (origin at the viewport's top left). When the tree
-- does not fit, scrollbars are added and the content is wrapped in matching
-- scroll_containers; containers are nested when both axes overflow. Since
-- Luanti 5.14 the 6th scroll_container argument is a content padding for the
-- automatic max/thumbsize calculation, and scrollbar[] always takes a value
-- argument - both are satisfied below.
local VIEW_X, VIEW_Y = 0.2, 1.15
local VIEW_W, VIEW_H = 11.3, 6.3
local VBAR_X = 11.5
local VBAR_H = VIEW_H
local HBAR_Y = 7.55
local HBAR_H = 0.4

local function scrollbar(x, y, w, h, orientation, name, value)
	return string.format("scrollbar[%.2f,%.2f;%.2f,%.2f;%s;%s;%d]",
		x, y, w, h, orientation, name, value or 0)
end

local function tree_formspec(state)
	local fs = "formspec_version[6]" ..
		"size[12,8]" ..
		"field[0.4,0.35;4.6,0.8;root;" .. esc("Entry (name, IP or #id)") .. ";" .. esc(state.root or "") .. "]" ..
		"field[5.2,0.35;1.4,0.8;depth;Depth;" .. esc(state.depth or "4") .. "]" ..
		-- Enter submits the tree rather than closing the window, which is
		-- what a text field does by default; the handler reads key_enter
		"field_close_on_enter[root;false]" ..
		"field_close_on_enter[depth;false]" ..
		"button[6.8,0.3;2.2,0.9;go;" .. esc("Show tree") .. "]" ..
		"button[9.2,0.3;2.4,0.9;close;" .. esc("Close") .. "]"
	-- The one free line is the one below the input row. An error drawn level
	-- with the fields runs under the Show tree and Close buttons, which start
	-- at x=6.8, and the engine paints the text over them.
	if not state.tree then
		return fs .. string.format("label[0.4,1.3;%s]", esc(
			state.error or "Enter a name, an IP address or an entry id as #12 above and press Show tree."))
	end
	if state.error then
		fs = fs .. string.format("label[0.4,1.3;%s]", esc(state.error))
	end
	local layout = layout_tree(state.tree)
	local content = {}
	local canvas_w, canvas_h = 0, 0
	for _, e in ipairs(layout.edges) do
		content[#content+1] = string.format("box[%.2f,%.2f;%.2f,%.2f;" .. EDGE_COLOR .. "]", e.x, e.y, e.w, e.h)
	end
	for _, n in ipairs(layout.nodes) do
		local mid = n.node.merge and n.node.merge.id or 0
		content[#content+1] = string.format("button[%.2f,%.2f;%.2f,%.2f;node_%d_%d;%s]",
			n.x, n.y, layout.node_w, NODE_H, n.node.entry_id, mid, esc(node_label(n.node, n.node.kind == "root")))
		canvas_w = math.max(canvas_w, n.x + layout.node_w)
		canvas_h = math.max(canvas_h, n.y + NODE_H)
	end
	canvas_h = canvas_h + 0.2
	-- notes about history cut off by the depth limit, drawn below the canvas
	for _, n in ipairs(layout.nodes) do
		if n.node.hidden_merges then
			local note = string.format("entry #%d has %d older merge(s) - increase the depth to see them",
				n.node.entry_id, n.node.hidden_merges)
			content[#content+1] = string.format("label[0,%.2f;%s]", canvas_h, esc(note))
			-- the note is wider than a narrow tree: widen the canvas to it, or
			-- a scroll container would clip the note away
			canvas_w = math.max(canvas_w, #note * CHAR_W)
			canvas_h = canvas_h + 0.4
		end
	end
	canvas_h = canvas_h + 0.1
	local body = table.concat(content)
	local needs_v = canvas_h > VIEW_H - 0.1
	local needs_h = canvas_w > VIEW_W - 0.1
	if needs_v then
		fs = fs .. scrollbar(VBAR_X, VIEW_Y, 0.4, VBAR_H, "vertical", "merge_scroll", state.sv)
		fs = fs .. string.format("scroll_container[%.2f,%.2f;%.2f,%.2f;merge_scroll;vertical;0.1;0]",
			VIEW_X, VIEW_Y, VIEW_W, VIEW_H)
		if needs_h then
			-- the horizontal container is the vertical container's only child,
			-- sized to the full canvas; its own scrollbar sits below the canvas
			fs = fs .. string.format("scroll_container[0,0;%.2f,%.2f;merge_scroll_h;horizontal;0.1;0]",
				canvas_w, canvas_h) .. body .. "scroll_container_end[]"
		else
			fs = fs .. body
		end
		fs = fs .. "scroll_container_end[]"
		if needs_h then
			fs = fs .. scrollbar(VIEW_X, HBAR_Y, VIEW_W, HBAR_H, "horizontal", "merge_scroll_h", state.sh)
		end
	elseif needs_h then
		fs = fs .. scrollbar(VIEW_X, HBAR_Y, VIEW_W, HBAR_H, "horizontal", "merge_scroll_h", state.sh)
		fs = fs .. string.format("scroll_container[%.2f,%.2f;%.2f,%.2f;merge_scroll_h;horizontal;0.1;0]",
			VIEW_X, VIEW_Y, VIEW_W, VIEW_H) .. body .. "scroll_container_end[]"
	else
		-- everything fits: draw the canvas plainly
		fs = fs .. "container[" .. string.format("%.2f,%.2f", VIEW_X, VIEW_Y) .. "]" .. body .. "container_end[]"
	end
	return fs
end

-- Where the keep/delete/move buttons of a decision row start. The row's label
-- stops before this: a label[] is painted wherever it is put, so a value long
-- enough to reach the buttons would be drawn underneath them.
local DECISION_X = 7.3

-- What the three decision buttons do, spelled out with the entry ids they act
-- on: the entry the identifiers are on now, and the one the rollback brings
-- back for them to move to.
---@param here integer
---@param recreated integer
---@return string[]
local function action_help(here, recreated)
	return {
		"keep: stays on entry #"..here..", where it is now",
		"delete: removed from the database entirely",
		"move: moves to entry #"..recreated..", which the rollback recreates",
	}
end

-- One decision row: the identifier and the decision made about it so far,
-- shortened if it would otherwise reach the buttons. The value is what
-- identifies the row, so only its very end is ever given up, and the full
-- name or address with both timestamps is in the table above.
---@param a table  -- an addition from get_merge_rollback_info
---@param action string
---@return string
local function decision_label(a, action)
	local head = a.type.." "
	-- the date is enough here: the rows are post-merge by construction, and
	-- the whole time is on the merge line above
	local tail = string.format(" (%s) -> %s", a.created_at:sub(1, 10), action)
	local room = math.floor((DECISION_X - 0.4) / CHAR_W) - #head - #tail
	local value = a.value
	if #value > room then
		value = value:sub(1, math.max(1, room - 1)) .. "…"
	end
	return head..value..tail
end

-- Sort keys the detail screen offers, in the order its buttons are drawn.
-- "seen" is the default, so the most recently active identifier leads.
local SORT_KEYS = { "created", "seen", "value" }
local SORT_LABELS = { created = "Created", seen = "Last seen", value = "Value" }

-- Rows drawn at once. The table scrolls, but its cell data is one string that
-- the client re-parses on every interaction, so an entry with thousands of
-- identifiers would be slow to open. Far above any entry seen in practice.
local MAX_ROWS = 200

-- Cell contents for table[]. Every cell is escaped on its own: formspec_escape
-- turns a comma into "\," while the engine reads a bare comma as the separator
-- between cells, so escaping the joined string would collapse the whole table
-- into a single column.
---@param rows IdentifierRow[]
---@return string
local function identifier_cells(rows)
	local cells = { "kind", "value", "created", "last seen" }
	for _, row in ipairs(rows) do
		cells[#cells + 1] = esc(row.kind)
		cells[#cells + 1] = esc(row.value)
		cells[#cells + 1] = esc(row.created_at)
		cells[#cells + 1] = esc(row.last_seen)
	end
	return table.concat(cells, ",")
end

-- Re-derive the rows on display from the node being shown. The node carries
-- the identifier rows, with their timestamps, for whichever point in the
-- entry's history it represents - so sorting again costs no query.
---@param state table
local function refresh_rows(state)
	local node = state.node
	if not node then
		state.rows = {}
		return
	end
	state.rows = dbmanager.order_identifiers(node.name_rows or {}, node.ip_rows or {}, state.sort, state.desc)
end

local function detail_formspec(state)
	local node = state.node
	local m = node.merge
	local rows = state.rows or {}
	local shown = math.min(#rows, MAX_ROWS)
	local visible = {}
	for i = 1, shown do visible[i] = rows[i] end

	local fs = "formspec_version[6]size[12,8]" ..
		string.format("label[0.4,0.25;%s]",
			esc("Entry #"..node.entry_id.." · "..(node.live and "live" or "pre-merge state")))

	-- Sorting controls: the active key carries an arrow. Pressing it flips the
	-- direction, pressing a different one switches the key.
	fs = fs .. "label[0.4,0.72;Sort by:]"
	for i, key in ipairs(SORT_KEYS) do
		local label = SORT_LABELS[key]
		if state.sort == key then
			label = label .. (state.desc and " ▼" or " ▲")
		end
		fs = fs .. string.format("button[%.2f,0.65;2.1,0.6;sort_%s;%s]",
			1.5 + (i - 1) * 2.2, key, esc(label))
	end
	fs = fs .. "button[9.0,0.65;2.6,0.6;storage;Storage]"

	-- The identifiers themselves: one per row, each with both timestamps. The
	-- table is taller when there is no merge to talk about below it.
	local table_h = m and 2.2 or 4.4
	fs = fs .. "tableoptions[color=#dddddd;background=#1b1b1b;border=true;highlight=#466432]" ..
		"tablecolumns[text,width=1.2;text,width=4.2;text,width=3.4;text,width=3.4]" ..
		string.format("table[0.4,1.3;11.2,%.2f;ids;%s;]", table_h, identifier_cells(visible))

	local y = 1.3 + table_h + 0.2
	if #rows > shown then
		fs = fs .. string.format("label[0.4,%.2f;%s]", y, esc(string.format(
			"showing %d of %d - the rest are listed by /ipdb list", shown, #rows)))
		y = y + 0.4
	elseif #rows == 0 then
		fs = fs .. string.format("label[0.4,%.2f;No identifiers at this point in the entry's history.]", y)
		y = y + 0.4
	end
	if m then
		fs = fs .. string.format("label[0.4,%.2f;%s]", y,
			esc("Merge #"..m.id.." · "..os.date("!%Y-%m-%d %H:%M:%S", m.timestamp)))
		y = y + 0.45
		fs = fs .. string.format("label[0.4,%.2f;%s]", y,
			esc(fit_line("  "..m.name.." / "..m.ip.." · #"..m.entry_src.." absorbed into #"..m.entry_dst)))
		y = y + 0.45
		if m.reverted_at then
			fs = fs .. string.format("label[0.4,%.2f;%s]", y,
				esc(fit_line("  rolled back on "..os.date("!%Y-%m-%d %H:%M", m.reverted_at))))
			y = y + 0.45
		end
	end
	if m and not m.reverted_at then
		if state.info then
			local adds = state.info.additions
			local ay = y + 0.15
			if #adds == 0 then
				fs = fs .. string.format("label[0.4,%.2f;Rollback is possible.]", ay)
			else
				fs = fs .. string.format("label[0.4,%.2f;Identifiers created after the merge:]", ay) ..
					string.format("button[6.4,%.2f;3.2,0.4;help;%s]", ay - 0.05, esc("what do these do?"))
				ay = ay + 0.45
				if state.help then
					-- the identifiers being decided are the destination's, and
					-- they move to the entry the rollback recreates - both are
					-- properties of the merge, not of the node it is shown on
					for _, line in ipairs(action_help(m.entry_dst, m.entry_src)) do
						fs = fs .. string.format("label[0.4,%.2f;%s]", ay, esc(line))
						ay = ay + 0.4
					end
					ay = ay + 0.05
				end
				-- only as many decision rows as fit above the button at 7.3
				local room = math.max(0, math.floor((7.15 - ay) / 0.5))
				if room < #adds then
					fs = fs .. string.format("label[0.4,%.2f;%d more - they will be kept; use /ipdb unmerge %d to handle them]",
						ay + room * 0.5, #adds - room, state.merge_id)
				end
				for i = 1, math.min(#adds, room) do
					local a = adds[i]
					local act = state.decisions[a.value] or "keep"
					fs = fs .. string.format("label[0.4,%.2f;%s]", ay, esc(decision_label(a, act))) ..
						string.format("button[%.2f,%.2f;1.3,0.4;ad_%d_keep;keep]", DECISION_X, ay, i) ..
						string.format("button[%.2f,%.2f;1.5,0.4;ad_%d_delete;delete]", DECISION_X + 1.4, ay, i) ..
						string.format("button[%.2f,%.2f;1.3,0.4;ad_%d_move;move]", DECISION_X + 3.0, ay, i)
					ay = ay + 0.5
				end
			end
			fs = fs .. string.format("button[8.6,7.3;3.0,0.8;rb;Roll back merge #%d]", state.merge_id)
		else
			-- these reasons run to a sentence, and the end of one says which
			-- merges to roll back first, so it is wrapped rather than cut
			local wrapped = {}
			append_wrapped(wrapped, "Rollback unavailable: "..(state.reason or "?"), "  ")
			for _, line in ipairs(wrapped) do
				fs = fs .. string.format("label[0.4,%.2f;%s]", y + 0.15, esc(line))
				y = y + 0.4
			end
		end
	end
	fs = fs .. "button[0.4,7.3;3.0,0.8;back;Back to tree]"
	return fs
end

-- Storage rows shown at once, for the same reason the identifier table is
-- capped: the cell data is a single string the client re-parses.
local MAX_STORAGE_ROWS = 200
-- Lines of a picked row's value that fit under the table
local MAX_VALUE_LINES = 6

-- A cell's text for the table. A stored value is often a whole JSON blob that
-- would swamp the row, so it is flattened and shortened; the picked row is
-- shown in full underneath.
---@param value string|number
---@return string
local function cell_text(value)
	local s = tostring(value):gsub("%s+", " ")
	if #s > 60 then
		s = s:sub(1, 59) .. "…"
	end
	return s
end

-- Cell contents for the storage table. Each cell is escaped on its own, for
-- the same reason as the identifier table: a bare comma separates cells.
---@param rows ModstorageRow[]
---@return string
local function storage_cells(rows)
	local cells = { "mod", "key", "ancillary", "value" }
	for _, r in ipairs(rows) do
		cells[#cells + 1] = esc(r.modname)
		cells[#cells + 1] = esc(r.key)
		cells[#cells + 1] = r.ancillary and esc(r.ancillary) or ""
		cells[#cells + 1] = esc(cell_text(r.data))
	end
	return table.concat(cells, ",")
end

-- The storage a node represents, as the mod names to offer and the rows of the
-- selected one. A node that came from a merge reads that merge's log, which
-- recorded both entries at the time; only the live entry has a "now" to read
-- from the table itself.
---@param node MergeTreeNode
---@param modname string?
---@return string[] modnames, ModstorageRow[] rows
local function load_storage(node, modname)
	if node.kind == "root" then
		return dbmanager.get_modstorage_modnames(node.entry_id),
			dbmanager.get_modstorage_rows(node.entry_id, modname)
	end
	local log = dbmanager.get_merge_log(node.merge.id)
	local all = dbmanager.select_logged_modstorage(log, node.entry_id)
	local names, seen = {}, {}
	for _, r in ipairs(all) do
		if not seen[r.modname] then
			seen[r.modname] = true
			names[#names + 1] = r.modname
		end
	end
	if not modname then
		return names, all
	end
	local rows = {}
	for _, r in ipairs(all) do
		if r.modname == modname then
			rows[#rows + 1] = r
		end
	end
	return names, rows
end

local function storage_formspec(state)
	local node = state.node
	local heading
	if node.live then
		heading = "Storage of entry #"..node.entry_id.." · live"
	else
		heading = "Storage of entry #"..node.entry_id.." · as of merge #"..node.merge.id
	end
	local fs = "formspec_version[6]size[12,8]" ..
		string.format("label[0.4,0.25;%s]", esc(fit_line(heading)))

	-- The filter list: every mod is one query, so the dropdown can show what
	-- is actually there instead of asking you to remember a mod name.
	local items = { "all mods" }
	for _, name in ipairs(state.ms_names or {}) do
		items[#items + 1] = name
	end
	local sel = 1
	for i, name in ipairs(items) do
		if name == state.ms_mod then sel = i end
	end
	-- The height is given rather than left to the engine: left out, a dropdown
	-- is drawn m_btn_height * 2 tall - about a whole unit - and covers the
	-- first row of the table below it.
	fs = fs .. "label[0.4,0.62;Mod:]" ..
		string.format("dropdown[1.2,0.57;4.6,0.6;ms_mod;%s;%d]", esc(table.concat(items, ",")), sel)

	local rows = state.ms_rows or {}
	local shown = math.min(#rows, MAX_STORAGE_ROWS)
	local visible = {}
	for i = 1, shown do visible[i] = rows[i] end
	fs = fs .. "tableoptions[color=#dddddd;background=#1b1b1b;border=true;highlight=#466432]" ..
		"tablecolumns[text,width=2.0;text,width=2.8;text,width=1.5;text,width=4.9]" ..
		string.format("table[0.4,1.25;11.2,3.1;ms;%s;%d]", storage_cells(visible), state.ms_sel or 0)

	local y = 4.5
	if #rows == 0 then
		fs = fs .. string.format("label[0.4,%.2f;%s]", y, esc("No storage for "..
			(state.ms_mod and ("mod "..state.ms_mod) or "this entry").."."))
	elseif #rows > shown then
		fs = fs .. string.format("label[0.4,%.2f;%s]", y, esc(string.format(
			"showing %d of %d rows - pick a mod to narrow it down", shown, #rows)))
	end
	-- The picked row in full: the cell above is shortened, and a stored value
	-- is often exactly the thing you opened this screen to read.
	local pick = state.ms_sel and rows[state.ms_sel - 1]
	if pick then
		local wrapped = {}
		append_hard_wrapped(wrapped, tostring(pick.data), "  ", MAX_VALUE_LINES)
		fs = fs .. string.format("label[0.4,%.2f;%s]", y, esc(fit_line(
			"mod "..pick.modname.." · key "..pick.key..
			(pick.ancillary and (" · ancillary "..pick.ancillary) or ""), 52))) ..
			"button[8.6,4.45;3.0,0.5;ms_full;Show the whole value]"
		y = y + 0.45
		for _, line in ipairs(wrapped) do
			fs = fs .. string.format("label[0.4,%.2f;%s]", y, esc(fit_line(line)))
			y = y + 0.4
		end
	end
	fs = fs .. "button[0.4,7.3;3.0,0.8;ms_back;Back]"
	return fs
end

-- Lines the value screen will show before it stops. The list scrolls; the cap
-- is there because every line is one string in the formspec the client parses.
local MAX_FULL_LINES = 400

-- The stored text prettified as JSON. Nothing here is written back to the
-- database: the conversions exist to make a stored blob readable.
---@param text string
---@return string? pretty
---@return string? err
local function value_as_json(text)
	local parsed, err = core.parse_json(text, nil, true)
	if parsed == nil then
		return nil, "not JSON: "..tostring(err)
	end
	local pretty, werr = core.write_json(parsed, true)
	if not pretty then
		return nil, "parsed as JSON, but could not be written back: "..tostring(werr)
	end
	return pretty
end

-- The stored text read as Lua data. It is handed to the sandboxed form of
-- deserialize: the text came out of the database, and the engine's own
-- documentation says not to pass it untrusted data.
---@param text string
---@return string? pretty
---@return string? err
local function value_as_deserialized(text)
	local ok, parsed = pcall(core.deserialize, text, true)
	if not ok then
		return nil, "not a serialized value: "..tostring(parsed)
	end
	if parsed == nil then
		return nil, "not a serialized value: it evaluates to nothing"
	end
	if type(parsed) ~= "table" then
		return nil, "not a serialized value: it evaluates to a "..type(parsed)
	end
	-- Shown the same way as JSON where JSON can hold it. When it cannot -
	-- mixed or non-string keys, say - the engine's own dump renders it, which
	-- is human-readable in a way the data may not otherwise get to be.
	-- serialize is not the fallback: it would write back the very "return
	-- { ... }" text the value was stored as, so the button would look as if it
	-- had done nothing at all.
	local pretty = core.write_json(parsed, true)
	if pretty then
		return pretty
	end
	return dump(parsed)
end

local VALUE_MODE_LABEL = {
	raw = "as stored",
	json = "reformatted as JSON",
	ser = "deserialized, shown as JSON",
}

-- Work out what the value screen should show for the row and mode it is in,
-- and wrap it to fit.
---@param state table
local function load_value(state)
	local row = state.value_row
	local text = tostring(row.data)
	local mode = state.value_mode or "raw"
	local body, err
	if mode == "json" then
		body, err = value_as_json(text)
	elseif mode == "ser" then
		body, err = value_as_deserialized(text)
	else
		body = text
	end
	if err then
		state.value_label = err
		body = text
	elseif mode == "raw" then
		state.value_label = "as stored, "..#text.." bytes"
	else
		state.value_label = VALUE_MODE_LABEL[mode]
	end
	local lines = {}
	if append_hard_wrapped(lines, body, "  ", MAX_FULL_LINES) then
		lines[#lines + 1] = "… stopped at "..MAX_FULL_LINES.." lines"
	end
	state.value_lines = lines
end

local function value_formspec(state)
	local row = state.value_row
	local fs = "formspec_version[6]size[12,8]" ..
		string.format("label[0.4,0.25;%s]", esc(fit_line(
			"mod "..row.modname.." · key "..row.key..
			(row.ancillary and (" · ancillary "..row.ancillary) or "")))) ..
		string.format("label[0.4,0.62;%s]", esc(fit_line(state.value_label or "as stored")))
	-- one list element per line, so the list scrolls; each element is escaped
	-- on its own, and a leading # would otherwise be read as a colour
	local items = {}
	for _, line in ipairs(state.value_lines or {}) do
		items[#items + 1] = esc(line:sub(1, 1) == "#" and ("#"..line) or line)
	end
	fs = fs .. string.format("textlist[0.4,1.05;11.2,5.7;value;%s;0;false]", table.concat(items, ","))
	fs = fs .. "button[0.4,7.3;2.2,0.8;value_json;JSON]" ..
		"button[2.8,7.3;3.0,0.8;value_raw;As stored]" ..
		"button[6.0,7.3;3.4,0.8;value_ser;Serialization]" ..
		"button[9.6,7.3;2.0,0.8;value_back;Back]"
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
	if #dels > 0 then append_list(lines, "  deleted: ", dels, 4) end
	if #moves > 0 then append_list(lines, "  moved to the recreated entry: ", moves, 4) end
	if #keeps > 0 then append_list(lines, "  kept at the destination: ", keeps, 4) end
	table.insert(lines, "The merge event will be marked as reverted.")
	local fs = "formspec_version[6]size[12,8]"
	local y = 0.3
	for i = 1, math.min(#lines, 10) do
		fs = fs .. string.format("label[0.4,%.2f;%s]", y, esc(fit_line(lines[i])))
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
		fs = fs .. string.format("label[0.4,%.2f;%s]", y, esc(fit_line(lines[i])))
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
	elseif state.screen == "storage" then
		fs = storage_formspec(state)
	elseif state.screen == "value" then
		fs = value_formspec(state)
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
		-- on a throw pcall puts the error object in `report`
		log(report)
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
	-- Remember where the user had scrolled to, so a re-render keeps the position
	if fields.merge_scroll then
		state.sv = tonumber(fields.merge_scroll) or state.sv or 0
	end
	if fields.merge_scroll_h then
		state.sh = tonumber(fields.merge_scroll_h) or state.sh or 0
	end
	-- Enter in a text field submits the form. A client that still has the
	-- default close-on-enter reports quit along with it, so this has to be
	-- claimed before the close check reads it. key_enter_field is only sent
	-- when a text field had the focus - with the focus nowhere or on a
	-- button, Enter really is a close and key_enter_field is absent.
	local enter_in_field = fields.key_enter and fields.key_enter_field
	if fields.quit or fields.close then
		if not enter_in_field then
			-- Forget the state *and* tell the client to close the window.
			-- Dropping the state on its own closes nothing: the formspec stays
			-- on screen, which is what made the Close button look broken.
			gui_states[name] = nil
			core.close_formspec(name, FORMNAME)
			return
		end
	end
	if fields.go or enter_in_field then
		state.sv, state.sh = 0, 0
		state.root = fields.root
		local depth = tonumber(fields.depth) or 4
		if depth < 1 or depth > 20 then
			state.error = "Depth must be between 1 and 20"
			show(state, name)
			return
		end
		state.depth = depth
		local ok_res, entryid, resolveerr = pcall(resolve_entry, fields.root)
		if not ok_res then
			-- on a throw pcall puts the error object in `entryid`
			log(entryid)
			state.error = "Internal error"
			show(state, name)
			return
		end
		if not entryid then
			state.error = resolveerr
			show(state, name)
			return
		end
		state.error = nil
		local ok, tree, treeerr = pcall(dbmanager.get_merge_tree, entryid, depth)
		if not ok then
			-- on a throw pcall puts the error object in `tree`
			log(tree)
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
	if fields.help then
		state.help = not state.help
		show(state, name)
		return
	end
	-- The storage viewer: a screen of its own, reached from the detail screen.
	-- Opening it and changing the filter both re-read the rows, because which
	-- rows are wanted is what the filter decides.
	local function refresh_storage()
		local ok, names, rows = pcall(load_storage, state.node, state.ms_mod)
		if not ok then
			-- on a throw pcall puts the error object in `names`
			log(names)
			state.error = "Internal error"
			return false
		end
		state.ms_names, state.ms_rows = names, rows
		state.ms_sel = nil
		return true
	end
	if fields.storage then
		if refresh_storage() then
			state.screen = "storage"
		end
		show(state, name)
		return
	end
	if fields.ms_back then
		state.screen = "detail"
		show(state, name)
		return
	end
	-- The value screen: the picked row's value, with the two conversions that
	-- make a stored blob readable. Only the display changes, never the row.
	if fields.ms_full and state.ms_rows then
		local row = state.ms_rows[(state.ms_sel or 0) - 1]
		if row then
			state.value_row = row
			state.value_mode = "raw"
			load_value(state)
			state.screen = "value"
		end
		show(state, name)
		return
	end
	if fields.value_json or fields.value_ser or fields.value_raw then
		state.value_mode = fields.value_json and "json" or (fields.value_ser and "ser" or "raw")
		load_value(state)
		show(state, name)
		return
	end
	if fields.value_back then
		state.screen = "storage"
		show(state, name)
		return
	end
	if fields.ms_mod then
		-- the dropdown sends the item text; "all mods" is the unfiltered one
		state.ms_mod = (fields.ms_mod ~= "all mods") and fields.ms_mod or nil
		refresh_storage()
		show(state, name)
		return
	end
	if fields.ms then
		local ev, row = core.explode_table_event(fields.ms)
		if ev == "CHG" then
			state.ms_sel = row
		end
		show(state, name)
		return
	end
	-- Pressing the active sort key flips the direction; pressing another one
	-- switches the key and keeps the direction.
	for _, key in ipairs(SORT_KEYS) do
		if fields["sort_"..key] then
			if state.sort == key then
				state.desc = not state.desc
			else
				state.sort = key
			end
			refresh_rows(state)
			show(state, name)
			return
		end
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
				refresh_rows(state)
				if mid ~= "0" then
					local ok, info, reason = pcall(dbmanager.get_merge_rollback_info, tonumber(mid))
					if not ok then
						-- on a throw pcall puts the error object in `info`
						log(info)
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
		sv = 0,
		sh = 0,
		-- identifier list: how it is ordered and the rows currently shown
		sort = "seen",
		desc = true,
		rows = {},
		-- whether the rollback actions are explained on the detail screen
		help = false,
		-- storage viewer: the filter, the mod names on offer, the rows shown
		ms_mod = nil,
		ms_names = {},
		ms_rows = {},
		ms_sel = nil,
		-- value screen: the row being read, how it is being shown, and what
		-- that comes out as
		value_row = nil,
		value_mode = "raw",
		value_label = nil,
		value_lines = {},
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
