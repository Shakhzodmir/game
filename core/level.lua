-- Level loading, validation (section 2) and canonical form (2.2).
--
-- L.load(input) takes JSON text (checked token by token by
-- core/json_strict.lua) or an already decoded table, validates it by 2.0-2.1
-- and returns the normalized level or nil, errors. Errors are strings
-- "<rule> <what> [at x,y]" with the zero-based JSON coordinates of the file.
--
-- The normalized level is read-only and shared by all games and clones:
--   id, version, W, H, N, moves, difficulty (code), colors (codes,
--   ascending), weights[code], goals = {{type, param, count}} (param: colour
--   code of collect, blocker code of break, else 0), exists[i], spawner[i],
--   exit[i] (only with a deliver goal), floor[i], wires[i] (hp),
--   chain[i] (hp of the chain the starting piece of cell i wears, 10.6),
--   ice[i] (hp of the ice the starting piece of cell i is frozen in, 10.11), has_ice,
--   seg_top[i], seg_bot[i] (rows of the segment of cell i),
--   presets = {{cell, kind, color, special, axis, blocker, hp}} by cell,
--   mic = {total, on_board_max, gap_moves} or nil,
--   coconut = {total, on_board_max, gap_moves, cols[x]} or nil (cols: may a
--   coconut enter in column x), canonical, hash.
--   exit[i] is also kept with a drop goal (10.5).
--   curtain = {at[i] (is cell i under a curtain), cells (indices, ascending),
--   closed_moves, open_moves, start_closed} or nil (10.7).
--   carpet = {at[i] (is cell i covered at the start), cells (indices, ascending)}
--   or nil (10.8); the count of a carpet goal = the cells still to cover.
--   conveyor = {belts = {{cells (indices in the order of travel), dirs (C.DIR_* of every cell), ring}},
--   at[i] (number of the belt of cell i, 0 = none), pos[i] (place of cell i in its belt, 0 = none)}
--   or nil (10.9).

local C = require("core.const")
local U = require("core.util")
local J = require("core.json_strict")
local LS = require("core.level_schema")

local L = {}

L.canonical = LS.canonical

-- Normalization and static rules (2.1.2-2.1.6, 2.1.8, 2.1.9) --------------------

local function segments(lvl)
	local W, H = lvl.W, lvl.H
	for i = 1, W * H do lvl.seg_top[i], lvl.seg_bot[i] = 0, 0 end
	for x = 1, W do
		local top = 0
		for y = 1, H do
			local i = (y - 1) * W + x
			if lvl.exists[i] then
				if top == 0 then top = y end
				lvl.seg_top[i] = top
			else
				top = 0
			end
		end
		local bot = 0
		for y = H, 1, -1 do
			local i = (y - 1) * W + x
			if lvl.exists[i] then
				if bot == 0 then bot = y end
				lvl.seg_bot[i] = bot
			else
				bot = 0
			end
		end
	end
end

local function where(W, i)
	local x, y = U.xy(W, i)
	return " at " .. (x - 1) .. "," .. (y - 1)
end

-- Normalization works on a context:
--   raw, lvl, errs, W, H, N, deliver, drop, n_coconuts, exits (all candidate exits, also
--   without deliver), slot_at[i] (preset covering cell i), counts[blocker],
--   n_tiles, n_mics, in_colors[code].

local function err(ctx, rule, msg, i)
	ctx.errs[#ctx.errs + 1] = rule .. " " .. msg .. (i and where(ctx.W, i) or "")
end

local function err_at(ctx, rule, msg, at)
	-- %.0f: a coordinate from the file may be huge (0.7, rule 6)
	ctx.errs[#ctx.errs + 1] = rule .. " " .. msg .. " at " .. string.format("%.0f,%.0f", at[1], at[2])
end

-- Cell index of a zero-based [x, y], or nil if it is not an existing cell.
local function cell_of(ctx, at)
	local x, y = at[1] + 1, at[2] + 1
	if x < 1 or x > ctx.W or y < 1 or y > ctx.H then return nil end
	local i = (y - 1) * ctx.W + x
	if not ctx.lvl.exists[i] then return nil end
	return i
end

local function row_of(W, i)
	return (i - (i - 1) % W - 1) / W + 1
end

local function read_cells(ctx)
	local lvl, W = ctx.lvl, ctx.W
	for y = 1, ctx.H do
		local row = ctx.raw.cells[y]
		for x = 1, W do
			local i = (y - 1) * W + x
			lvl.exists[i] = string.sub(row, x, x) == "#"
			lvl.spawner[i], lvl.exit[i] = false, false
			lvl.floor[i], lvl.wires[i], lvl.chain[i], lvl.ice[i] = 0, 0, 0, 0
		end
	end
	segments(lvl)
end

local function read_colors_and_goals(ctx)
	local raw, lvl = ctx.raw, ctx.lvl
	for c = 1, C.NCOLORS do
		for k = 1, #raw.colors do
			if raw.colors[k] == C.COLOR_NAME[c] then lvl.colors[#lvl.colors + 1] = c end
		end
	end
	for k = 1, #lvl.colors do
		local c = lvl.colors[k]
		ctx.in_colors[c] = true
		lvl.weights[c] = raw.spawn_weights and raw.spawn_weights[C.COLOR_NAME[c]] or 1
	end
	for k = 1, #raw.goals do
		local g = raw.goals[k]
		local t = C.GOAL[g.type]
		local param = 0
		if t == C.GOAL_COLLECT then param = C.COLOR[g.color]
		elseif t == C.GOAL_BREAK then param = C.BLOCKER[g.item] or -1 end
		if t == C.GOAL_DELIVER then ctx.deliver = true end
		if t == C.GOAL_DROP then ctx.drop = true end
		if t == C.GOAL_CARPET then ctx.carpet_goal = true end
		if t == C.GOAL_ICE then ctx.ice_goal = true end
		lvl.goals[k] = { type = t, param = param, count = g.count or 1 }
	end
	if raw.mic then
		lvl.mic = { total = raw.mic.total, on_board_max = raw.mic.on_board_max, gap_moves = raw.mic.gap_moves }
	end
	if raw.coconut then
		local co = raw.coconut
		local cols = {}
		for x = 1, ctx.W do cols[x] = co.columns == nil end
		if co.columns then
			for k = 1, #co.columns do cols[co.columns[k] + 1] = true end
		end
		lvl.coconut = { total = co.total, on_board_max = co.on_board_max, gap_moves = co.gap_moves, cols = cols }
	end
end

-- Spawners ("top" = topmost existing cell of each column) and exits
-- ("bottom" = bottom of every segment; kept only with a deliver or a drop
-- goal).
local function read_spawners_and_exits(ctx)
	local raw, lvl, W, N = ctx.raw, ctx.lvl, ctx.W, ctx.N
	if raw.spawners == nil or raw.spawners == "top" then
		for x = 1, W do
			for y = 1, ctx.H do
				local i = (y - 1) * W + x
				if lvl.exists[i] then
					lvl.spawner[i] = true
					break
				end
			end
		end
	else
		for k = 1, #raw.spawners do
			local at = raw.spawners[k]
			local i = cell_of(ctx, at)
			if not i then err_at(ctx, "2.1.2", "spawner is not an existing cell", at)
			elseif lvl.spawner[i] then err_at(ctx, "2.1.2", "repeated spawner", at)
			else lvl.spawner[i] = true end
		end
	end
	for i = 1, N do
		if lvl.spawner[i] and lvl.seg_top[i] ~= row_of(W, i) then
			err(ctx, "2.1.2", "the cell above a spawner is not a void or the edge", i)
		end
	end
	local exits = ctx.exits
	if raw.exits == nil or raw.exits == "bottom" then
		for i = 1, N do
			if lvl.exists[i] and lvl.seg_bot[i] == row_of(W, i) then exits[i] = true end
		end
	else
		for k = 1, #raw.exits do
			local at = raw.exits[k]
			local i = cell_of(ctx, at)
			if not i then err_at(ctx, "2.1.2", "exit is not an existing cell", at)
			elseif exits[i] then err_at(ctx, "2.1.2", "repeated exit", at)
			else exits[i] = true end
		end
	end
	for i = 1, N do
		if exits[i] then ctx.n_exits = ctx.n_exits + 1 end
		if ctx.deliver or ctx.drop then lvl.exit[i] = exits[i] == true end
	end
end

local function read_layers(ctx)
	local lvl = ctx.lvl
	for _, layer in ipairs({ "floor", "overlay" }) do
		local list = ctx.raw[layer] or {}
		for k = 1, #list do
			local at = list[k].at
			local i = cell_of(ctx, at)
			local dst = lvl.floor
			if layer == "overlay" then
				local t = list[k].type
				dst = t == "chain" and lvl.chain or (t == "ice" and lvl.ice or lvl.wires)
			end
			if not i then err_at(ctx, "2.1.2", layer .. " is not on an existing cell", at)
			elseif (layer == "floor" and dst[i] > 0)
				or (layer == "overlay" and (lvl.wires[i] > 0 or lvl.chain[i] > 0 or lvl.ice[i] > 0)) then
				err_at(ctx, "2.1.2", "two " .. layer .. " elements in one cell", at)
			else
				dst[i] = list[k].hp
				if layer == "floor" then ctx.n_tiles = ctx.n_tiles + 1 end
				if dst == lvl.chain then ctx.n_chains = ctx.n_chains + 1 end
				if dst == lvl.ice then ctx.n_ice = ctx.n_ice + 1 end
			end
		end
	end
	-- a light goal counts the tiles of the level
	for k = 1, #lvl.goals do
		if lvl.goals[k].type == C.GOAL_LIGHT then lvl.goals[k].count = ctx.n_tiles end
	end
end

-- The timed curtain (10.7): the covered cells (geometry by 2.1.2) and the rhythm.
local function read_curtain(ctx)
	local cu = ctx.raw.curtain
	if cu == nil then return end
	local lvl = ctx.lvl
	local at, cells = {}, {}
	for i = 1, ctx.N do at[i] = false end
	for k = 1, #cu.covers do
		local c = cu.covers[k]
		local i = cell_of(ctx, c)
		if not i then err_at(ctx, "2.1.2", "curtain is not on an existing cell", c)
		elseif at[i] then err_at(ctx, "2.1.2", "two curtains in one cell", c)
		else at[i] = true end
	end
	for i = 1, ctx.N do
		if at[i] then cells[#cells + 1] = i end
	end
	lvl.curtain = {
		at = at, cells = cells, closed_moves = cu.closed_moves, open_moves = cu.open_moves,
		start_closed = cu.start == "closed",
	}
end

-- The carpet (10.8): the cells covered at the start (geometry by 2.1.2).
local function read_carpet(ctx)
	local ca = ctx.raw.carpet
	if ca == nil then return end
	local at, cells = {}, {}
	for i = 1, ctx.N do at[i] = false end
	for k = 1, #ca do
		local c = ca[k]
		local i = cell_of(ctx, c)
		if not i then err_at(ctx, "2.1.2", "carpet is not on an existing cell", c)
		elseif at[i] then err_at(ctx, "2.1.2", "two carpets in one cell", c)
		else at[i] = true end
	end
	for i = 1, ctx.N do
		if at[i] then cells[#cells + 1] = i end
	end
	ctx.lvl.carpet = { at = at, cells = cells }
end

-- The conveyor belts (10.9): the cells of every belt in the order of travel (geometry by 2.1.2, the
-- shape of the path by 2.1.14). A cell belongs to one belt at most and stands in it once.
local function read_conveyor(ctx)
	local cv = ctx.raw.conveyor
	if cv == nil then return end
	local W = ctx.W
	local at, pos, belts = {}, {}, {}
	for i = 1, ctx.N do at[i], pos[i] = 0, 0 end
	-- the direction of the step from cell a to cell c, nil if they are not neighbours by a side
	local function dir(a, c)
		local d = c - a
		if d == 1 and (a - 1) % W ~= W - 1 then return C.DIR_R end
		if d == -1 and (a - 1) % W ~= 0 then return C.DIR_L end
		if d == W then return C.DIR_D end
		if d == -W then return C.DIR_U end
		return nil
	end
	for b = 1, #cv do
		local path = cv[b].path
		local cells, ok = {}, true
		for k = 1, #path do
			local i = cell_of(ctx, path[k])
			if not i then
				err_at(ctx, "2.1.2", "conveyor is not on an existing cell", path[k])
				ok = false
			elseif at[i] ~= 0 then
				err_at(ctx, "2.1.2", "two conveyor cells in one cell", path[k])
				ok = false
			else
				at[i], pos[i] = b, k
				cells[k] = i
			end
		end
		local dirs = {}
		local n = #cells
		for k = 1, ok and n - 1 or 0 do
			dirs[k] = dir(cells[k], cells[k + 1])
			if not dirs[k] then
				err_at(ctx, "2.1.14", "conveyor cells must be neighbours by a side", path[k + 1])
				ok = false
				break
			end
		end
		if ok then
			-- a ring closes on itself; an open path points on past its last cell (its content jumps back to the first)
			local back = dir(cells[n], cells[1])
			dirs[n] = back or dirs[n - 1]
			belts[#belts + 1] = { cells = cells, dirs = dirs, ring = back ~= nil }
		end
	end
	ctx.lvl.conveyor = { belts = belts, at = at, pos = pos }
end

-- Rule 2.1.13, the carpet (10.8). The goal and the starting cells come together; no dance floor on such a
-- level; no starting carpet under a blocker; and every cell of the board can be covered by matches alone:
-- starting from the carpet, any line of three or 2x2 square of existing cells that holds a covered cell
-- covers its other cells, and that must reach the whole board.
local function carpet_rules(ctx)
	local lvl, N, W, H = ctx.lvl, ctx.N, ctx.W, ctx.H
	local errs = ctx.errs
	local goal = nil
	for k = 1, #lvl.goals do
		if lvl.goals[k].type == C.GOAL_CARPET then goal = lvl.goals[k] end
	end
	local ca = lvl.carpet
	if not ca then
		if goal then errs[#errs + 1] = "2.1.13 carpet goal without starting carpet cells (field carpet)" end
		return
	end
	if not goal then
		errs[#errs + 1] = "2.1.13 carpet cells without a carpet goal"
		return
	end
	if ctx.n_tiles > 0 then errs[#errs + 1] = "2.1.13 floor tiles on a carpet level" end
	local cov = {}
	for i = 1, N do
		cov[i] = ca.at[i]
		local p = ctx.slot_at[i]
		if ca.at[i] and p and p.kind == C.K_BLOCKER then
			err(ctx, "2.1.13", "starting carpet under a blocker", i)
		end
	end
	local ex = lvl.exists
	-- a shape a match can be made of (a line of three, a 2x2 square) spreads once one of its cells is covered
	local changed = true
	local function spread(a, b, c, d)
		if not (ex[a] and ex[b] and ex[c] and (d == nil or ex[d])) then return end
		local any = cov[a] or cov[b] or cov[c] or (d ~= nil and cov[d])
		local all = cov[a] and cov[b] and cov[c] and (d == nil or cov[d])
		if any and not all then
			cov[a], cov[b], cov[c] = true, true, true
			if d then cov[d] = true end
			changed = true
		end
	end
	while changed do
		changed = false
		for y = 1, H do
			for x = 1, W do
				local i = (y - 1) * W + x
				if x + 2 <= W then spread(i, i + 1, i + 2) end
				if y + 2 <= H then spread(i, i + W, i + 2 * W) end
				if x + 1 <= W and y + 1 <= H then spread(i, i + 1, i + W, i + W + 1) end
			end
		end
	end
	local left = 0
	for i = 1, N do
		if ex[i] then
			if not ca.at[i] then left = left + 1 end
			if not cov[i] then err(ctx, "2.1.13", "the carpet cannot reach the cell", i) end
		end
	end
	if left == 0 then errs[#errs + 1] = "2.1.13 the carpet already covers the whole board" end
	goal.count = left
end

local function preset_of(ctx, item, i)
	local ty = item.type
	local p = { cell = i, kind = 0, color = 0, special = 0, axis = 0, blocker = 0, hp = 0 }
	if C.BLOCKER[ty] then
		p.kind = C.K_BLOCKER
		p.blocker = C.BLOCKER[ty]
		p.hp = item.hp or 1
		ctx.counts[p.blocker] = ctx.counts[p.blocker] + 1
		if ty == "balloon" then p.color = C.COLOR[item.color] end
	elseif C.SPECIAL[ty] then
		p.kind = C.K_SPECIAL
		p.special = C.SPECIAL[ty]
		if ty == "riff" then p.axis = C.AXIS[item.axis] end
	elseif ty == "piece" then
		p.kind = C.K_REGULAR
		p.color = C.COLOR[item.color]
	elseif ty == "coconut" then
		p.kind = C.K_COCONUT
		ctx.n_coconuts = ctx.n_coconuts + 1
		if ctx.drop and ctx.exits[i] then err(ctx, "2.1.11", "starting coconut stands on an exit", i) end
	else -- mic
		p.kind = C.K_MIC
		ctx.n_mics = ctx.n_mics + 1
		if ctx.deliver and ctx.exits[i] then err(ctx, "2.1.8", "starting mic stands on an exit", i) end
	end
	if p.color ~= 0 and not ctx.in_colors[p.color] then
		err(ctx, "2.1.4", "colour '" .. C.COLOR_NAME[p.color] .. "' is not a level colour", i)
	end
	return p
end

local function read_slots(ctx)
	local lvl, slot_at = ctx.lvl, ctx.slot_at
	local slots = ctx.raw.slots or {}
	for k = 1, #slots do
		local item = slots[k]
		local at = item.at
		local i = cell_of(ctx, at)
		local cells = { i }
		if i and item.type == "column" then
			local x, y = at[1], at[2]
			cells = { i, cell_of(ctx, { x + 1, y }), cell_of(ctx, { x, y + 1 }), cell_of(ctx, { x + 1, y + 1 }) }
			if not (cells[2] and cells[3] and cells[4]) then
				err_at(ctx, "2.1.2", "column needs 4 existing cells", at)
				cells = nil
			end
		end
		if not i then
			err_at(ctx, "2.1.2", "slot is not on an existing cell", at)
		elseif cells then
			local clash = false
			for j = 1, #cells do
				if slot_at[cells[j]] then clash = true end
			end
			if clash then
				err_at(ctx, "2.1.2", "two slot elements in one cell", at)
			else
				local p = preset_of(ctx, item, i)
				for j = 1, #cells do slot_at[cells[j]] = p end
				lvl.presets[#lvl.presets + 1] = p
			end
		end
	end
	table.sort(lvl.presets, function(a, b) return a.cell < b.cell end)
end

-- Rules 2.1.3, 2.1.5, 2.1.6, the static part of 2.1.8 and 2.1.9.
local function static_rules(ctx)
	local lvl, N, slot_at, counts = ctx.lvl, ctx.N, ctx.slot_at, ctx.counts
	local errs = ctx.errs
	for i = 1, N do
		if lvl.wires[i] > 0 and slot_at[i] and slot_at[i].kind ~= C.K_REGULAR then
			err(ctx, "2.1.3", "wires over a cell without a regular piece", i)
		end
		if lvl.chain[i] > 0 and slot_at[i] and slot_at[i].kind ~= C.K_REGULAR then
			err(ctx, "2.1.3", "chain over a cell without a regular piece", i)
		end
		if lvl.ice[i] > 0 and slot_at[i] and slot_at[i].kind ~= C.K_REGULAR then
			err(ctx, "2.1.3", "ice over a cell without a regular piece", i)
		end
	end
	for k = 1, #lvl.goals do
		local g = lvl.goals[k]
		if g.type == C.GOAL_COLLECT and not ctx.in_colors[g.param] then
			errs[#errs + 1] = "2.1.5 collect colour is not a level colour"
		elseif g.type == C.GOAL_BREAK then
			if g.param < 1 then
				errs[#errs + 1] = "2.1.5 break item must be record_box, concrete, noise, balloon, column or boombox"
			elseif g.count > counts[g.param] then
				errs[#errs + 1] = "2.1.5 break count exceeds the " .. C.BLOCKER_NAME[g.param] .. " objects on the board"
			end
		elseif g.type == C.GOAL_LIGHT and ctx.n_tiles == 0 then
			errs[#errs + 1] = "2.1.5 light goal without floor tiles"
		elseif g.type == C.GOAL_DELIVER and (not lvl.mic or ctx.n_exits == 0) then
			errs[#errs + 1] = "2.1.5 deliver goal needs a mic block and an exit"
		elseif g.type == C.GOAL_CHAINS and g.count > ctx.n_chains then
			errs[#errs + 1] = "2.1.5 chains count exceeds the chains on the board"
		elseif g.type == C.GOAL_ICE and g.count > ctx.n_ice then
			errs[#errs + 1] = "2.1.5 ice count exceeds the frozen pieces on the board"
		elseif g.type == C.GOAL_DROP and (not lvl.coconut or ctx.n_exits == 0) then
			errs[#errs + 1] = "2.1.5 drop goal needs a coconut block and an exit"
		end
	end
	-- 2.1.12: what may stand under a curtain at the start (10.7): a regular piece (random or `piece`) and
	-- a floor tile, nothing else; never a spawner, never a cell where mics or coconuts leave the field
	if lvl.curtain then
		for i = 1, N do
			if lvl.curtain.at[i] then
				if slot_at[i] and slot_at[i].kind ~= C.K_REGULAR then
					err(ctx, "2.1.12", "only a regular piece may stand under a curtain", i)
				end
				if lvl.wires[i] > 0 or lvl.chain[i] > 0 then err(ctx, "2.1.12", "wires or a chain under a curtain", i) end
				if lvl.ice[i] > 0 then err(ctx, "2.1.12", "ice under a curtain", i) end
				if lvl.spawner[i] then err(ctx, "2.1.12", "curtain over a spawner", i) end
				if lvl.exit[i] then err(ctx, "2.1.12", "curtain over an exit", i) end
			end
		end
	end
	carpet_rules(ctx)
	-- 2.1.14: a belt carries only what moves (10.9): no blocker and no wires on it at the start
	if lvl.conveyor then
		for i = 1, N do
			if lvl.conveyor.at[i] ~= 0 then
				if slot_at[i] and slot_at[i].kind == C.K_BLOCKER then err(ctx, "2.1.14", "blocker on a conveyor", i) end
				if lvl.wires[i] > 0 then err(ctx, "2.1.14", "wires on a conveyor", i) end
				if lvl.ice[i] > 0 then err(ctx, "2.1.14", "ice on a conveyor", i) end
			end
		end
	end
	-- 2.1.6: record_box, dancefloor, wires, mic, concrete, noise, balloon, column, coconut, chain, curtain, carpet,
	-- conveyor, boombox, ice
	local n_el = 0
	for b = 1, C.NBLOCKERS do
		if counts[b] > 0 then n_el = n_el + 1 end
	end
	if ctx.n_tiles > 0 then n_el = n_el + 1 end
	for i = 1, N do
		if lvl.wires[i] > 0 then
			n_el = n_el + 1
			break
		end
	end
	if ctx.n_chains > 0 then n_el = n_el + 1 end
	if ctx.n_ice > 0 or ctx.ice_goal then n_el = n_el + 1 end
	if lvl.curtain then n_el = n_el + 1 end
	if lvl.carpet or ctx.carpet_goal then n_el = n_el + 1 end
	if lvl.conveyor then n_el = n_el + 1 end
	if ctx.deliver or ctx.raw.mic ~= nil or ctx.n_mics > 0 then n_el = n_el + 1 end
	if ctx.drop or ctx.raw.coconut ~= nil or ctx.n_coconuts > 0 then n_el = n_el + 1 end
	if n_el > 3 then errs[#errs + 1] = "2.1.6 more than three different elements" end
	-- 2.1.8, static part
	if not ctx.deliver then
		if ctx.raw.mic ~= nil then errs[#errs + 1] = "2.1.8 mic block without a deliver goal" end
		if ctx.n_mics > 0 then errs[#errs + 1] = "2.1.8 mic pieces without a deliver goal" end
	else
		for i = 1, N do
			if lvl.exit[i] and lvl.spawner[i] then err(ctx, "2.1.8", "exit is also a spawner", i) end
		end
		if lvl.mic and ctx.n_mics > math.min(lvl.mic.on_board_max, lvl.mic.total) then
			errs[#errs + 1] = "2.1.8 more starting mics than min(on_board_max, total)"
		end
	end
	-- 2.1.11: the coconuts, the mirror of 2.1.8
	if not ctx.drop then
		if ctx.raw.coconut ~= nil then errs[#errs + 1] = "2.1.11 coconut block without a drop goal" end
		if ctx.n_coconuts > 0 then errs[#errs + 1] = "2.1.11 coconut pieces without a drop goal" end
	else
		if ctx.deliver then errs[#errs + 1] = "2.1.11 drop and deliver goals in one level" end
		for i = 1, N do
			if lvl.exit[i] and lvl.spawner[i] then err(ctx, "2.1.11", "exit is also a spawner", i) end
		end
		local co = lvl.coconut
		if co and ctx.n_coconuts > math.min(co.on_board_max, co.total) then
			errs[#errs + 1] = "2.1.11 more starting coconuts than min(on_board_max, total)"
		end
		if co and ctx.raw.coconut.columns then
			for x = 1, ctx.W do
				local has = false
				for y = 1, ctx.H do
					if lvl.spawner[(y - 1) * ctx.W + x] then has = true end
				end
				if co.cols[x] and not has then
					errs[#errs + 1] = "2.1.11 coconut column " .. (x - 1) .. " has no spawner"
				end
			end
		end
	end
	-- 2.1.9
	local M = require("core.match")
	local col = {}
	for i = 1, N do
		local p = slot_at[i]
		col[i] = (p and p.kind == C.K_REGULAR) and p.color or 0
	end
	if M.any_match(col, ctx.W, ctx.H) then
		errs[#errs + 1] = "2.1.9 starting pieces form a line of 3 or a 2x2 square"
	end
end

local function normalize(raw, errs)
	local W, H = raw.size[1], raw.size[2]
	local ctx = {
		raw = raw, errs = errs, W = W, H = H, N = W * H,
		deliver = false, exits = {}, n_exits = 0, slot_at = {}, counts = { 0, 0, 0, 0, 0, 0 },
		n_chains = 0, n_ice = 0, n_tiles = 0, n_mics = 0, n_coconuts = 0, drop = false, in_colors = {},
		lvl = {
			id = raw.id, version = raw.version, W = W, H = H, N = W * H, moves = raw.moves,
			difficulty = C.DIFFICULTY[raw.difficulty],
			colors = {}, weights = {}, goals = {},
			exists = {}, spawner = {}, exit = {}, floor = {}, wires = {}, chain = {}, ice = {}, has_ice = false,
			seg_top = {}, seg_bot = {}, presets = {}, mic = nil, coconut = nil, curtain = nil, carpet = nil,
			conveyor = nil,
		},
	}
	read_cells(ctx)
	read_colors_and_goals(ctx)
	read_spawners_and_exits(ctx)
	read_layers(ctx)
	read_slots(ctx)
	read_curtain(ctx)
	read_carpet(ctx)
	read_conveyor(ctx)
	static_rules(ctx)
	ctx.lvl.has_ice = ctx.n_ice > 0
	return ctx.lvl, ctx.slot_at
end

-- Fillability (2.1.7) -----------------------------------------------------------

-- Runs steps 4-6 in turbo with colourless pieces from an empty board with
-- the fixed content of B0 (keep_fixed) or B1. Returns the state or nil if
-- it does not settle within 1000 ticks.
local function settle(lvl, slot_at, keep_fixed)
	local B = require("core.board")
	local G = require("core.gravity")
	local s = B.new_state(lvl)
	s.colorless = true
	s.timing = C.TIMING_TURBO
	s.cur_closed = false -- the curtains count as open here: every cell must be fillable once they are (10.7)
	for i = 1, s.N do s.exit[i] = false end
	-- B1 keeps only the voids: the pieces under wires are gone, and wires exist
	-- only over a regular piece (1.1), so the overlay is gone with them.
	if not keep_fixed then
		for i = 1, s.N do s.wires[i] = 0 end
	end
	if keep_fixed then
		for i = 1, lvl.N do
			local p = slot_at[i]
			if p and p.cell == i and p.kind == C.K_BLOCKER then
				local o = B.new_obj(s, C.K_BLOCKER, { blocker = p.blocker, hp = p.hp, color = p.color })
				B.place(s, o, i)
			elseif lvl.exists[i] and (lvl.wires[i] > 0 or lvl.ice[i] > 0) and s.slot[i] == 0 then
				-- (a wired or a frozen piece stays where it is, 10.11)
				local o = B.new_obj(s, C.K_REGULAR, { ice = lvl.ice[i] })
				B.place(s, o, i)
			end
		end
	end
	for t = 1, 1000 do
		s.tick, s.now = t, t
		G.assign(s)
		G.move(s)
		if s.last_assign == 0 then return s end
	end
	return nil
end

local function fill_checks(lvl, slot_at, errs)
	local W = lvl.W
	local b0 = settle(lvl, slot_at, true)
	if not b0 then
		errs[#errs + 1] = "2.1.7 board B0 does not settle within 1000 ticks"
	else
		for i = 1, lvl.N do
			if lvl.exists[i] and b0.slot[i] == 0 then
				errs[#errs + 1] = "2.1.7 cell stays empty on board B0" .. where(W, i)
			end
		end
	end
	local b1 = settle(lvl, slot_at, false)
	if not b1 then
		errs[#errs + 1] = "2.1.7 board B1 does not settle within 1000 ticks"
		return
	end
	local deliver = false
	for k = 1, #lvl.goals do
		if lvl.goals[k].type == C.GOAL_DELIVER then deliver = true end
	end
	local drop = lvl.coconut ~= nil
	for i = 1, lvl.N do
		if lvl.exists[i] then
			if b1.slot[i] == 0 then
				errs[#errs + 1] = "2.1.7 cell stays empty on board B1" .. where(W, i)
			elseif deliver and not lvl.exit[i] and lvl.seg_bot[i] == row_of(W, i) then
				errs[#errs + 1] = "2.1.8 segment bottom is not an exit" .. where(W, i)
			elseif drop and not lvl.exit[i] and lvl.seg_bot[i] == row_of(W, i) then
				errs[#errs + 1] = "2.1.11 segment bottom is not an exit" .. where(W, i)
			end
		end
	end
end

-- Loader -----------------------------------------------------------------------

function L.load(input)
	local raw
	if type(input) == "string" then
		local v, why = J.decode(input)
		if v == nil then return nil, { why } end
		raw = v
	elseif type(input) == "table" then
		raw = input
	else
		return nil, { "2.2 level must be JSON text or a decoded table" }
	end
	local errs = {}
	LS.check(raw, errs)
	if #errs > 0 then return nil, errs end
	local lvl, slot_at = normalize(raw, errs)
	if #errs > 0 then return nil, errs end
	fill_checks(lvl, slot_at, errs)
	if #errs > 0 then return nil, errs end
	-- start boards for seeds 1..10 (2.1.10)
	local ST = require("core.start")
	for seed = 1, 10 do
		local _, report = ST.build(lvl, seed, {})
		if report.shuffle >= 3 then
			errs[#errs + 1] = "2.1.10 start board for seed " .. seed .. " reaches shuffle item 3"
		end
	end
	if #errs > 0 then return nil, errs end
	lvl.canonical = LS.canonical(raw)
	lvl.hash = require("core.hash").fold_bytes(lvl.canonical)
	return lvl
end

return L
