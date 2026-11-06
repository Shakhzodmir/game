-- Text layout audit for the strict GUI stub (not a test file itself): for every visible text node it measures
-- the string with the real font advances of the project (tests/client/font_advances.lua) and checks that
--   1. the text (wrapped like the engine wraps it, when it has a line-break width) lies inside the nearest
--      sized box it sits on (a button, a card, a pill, a plate), and
--   2. it does not overlap another visible text in a way that makes it unreadable, and
--   3. it lies inside the panel of the window and the logical screen (the same test as G.overflows).
-- All numbers are logical px (720x1280 design area), slack `tol`.
--
--   local A = require("tests.client.layout_audit")
--   local problems = A.check(c, { tol = 1.5, up = 110 })   -- c: a G.with_town / G.with_level context
--   local rows = A.texts(c)                               -- the measured texts, for tools and reports

local advances = require("tests.client.font_advances")

local A = {}

local LINE = 1.25 -- line height as a part of the font size (the same as the stub's resource.get_text_metrics)

local function codepoints(s)
	local out = {}
	local i, n = 1, #s
	while i <= n do
		local b = s:byte(i)
		local len = b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
		local cp
		if len == 1 then cp = b
		elseif len == 2 then cp = (b % 0x20) * 0x40 + (s:byte(i + 1) % 0x40)
		elseif len == 3 then cp = (b % 0x10) * 0x1000 + (s:byte(i + 1) % 0x40) * 0x40 + (s:byte(i + 2) % 0x40)
		else cp = (b % 0x08) * 0x40000 + (s:byte(i + 1) % 0x40) * 0x1000 + (s:byte(i + 2) % 0x40) * 0x40 + (s:byte(i + 3) % 0x40) end
		out[#out + 1] = cp
		i = i + len
	end
	return out
end

local function width_of(font, s)
	local f = advances[font] or advances.body
	local w = 0
	for _, cp in ipairs(codepoints(s)) do w = w + (f.advances[cp] or f.size * 0.55) end
	return w
end

-- Greedy word wrap at `limit` (font px, unscaled): returns the number of lines and the longest line.
function A.wrap(font, text, limit)
	local lines, longest = 0, 0
	for para in (text .. "\n"):gmatch("(.-)\n") do
		local cur, curw = nil, 0
		local space = width_of(font, " ")
		local any = false
		for word in para:gmatch("%S+") do
			any = true
			local w = width_of(font, word)
			if cur and curw + space + w <= limit then
				curw = curw + space + w
			else
				if cur then lines = lines + 1; longest = math.max(longest, curw) end
				cur, curw = word, w
			end
		end
		if cur then lines = lines + 1; longest = math.max(longest, curw) end
		if not any then lines = lines + 1 end
	end
	return lines, longest
end

-- One text node -> its rectangle in logical px {x0, y0, x1, y1} plus facts.
local function measure(E, n)
	local f = advances[n.font or "body"] or advances.body
	local wx, wy, sx, sy = E.world(n)
	local pivot = E.pivot_fraction(n)
	local w, h, lines = E.text_width(n), f.size, 1
	local longest = w
	if n.line_break and n.size.x > 0 then
		lines, longest = A.wrap(n.font or "body", n.text, n.size.x)
		w = math.min(n.size.x, longest)
		h = lines * f.size * LINE
		-- a single word wider than the box cannot wrap: the line sticks out
		if longest > n.size.x then w = longest end
	end
	-- horizontal: lines are aligned by the pivot inside the box (or around the pivot for a free text)
	local boxw = (n.line_break and n.size.x > 0) and n.size.x or w
	local x0 = wx + pivot[1] * boxw * sx
	local x1 = x0 + boxw * sx
	if longest > boxw then -- spills on both sides of the box for centred text, to the right otherwise
		local extra = (longest - boxw) * sx
		if pivot[1] == -0.5 then x0, x1 = x0 - extra / 2, x1 + extra / 2 else x1 = x1 + extra end
	end
	-- for text narrower than its box, the glyphs themselves span `w`
	if n.line_break and w < boxw then
		local gx0 = x0 + (boxw - w) * sx * (pivot[1] == -0.5 and 0.5 or (pivot[1] == 0 and 0 or 1))
		x0, x1 = gx0, gx0 + w * sx
	end
	local y0 = wy + pivot[2] * h * sy
	local y1 = y0 + h * sy
	local ax, ay = E.to_logical(x0, y0)
	local bx, by = E.to_logical(x1, y1)
	return { math.min(ax, bx), math.min(ay, by), math.max(ax, bx), math.max(ay, by) }, { lines = lines, font_px = f.size * sx / E.fit_scale() }
end

local function lrect(E, n)
	local x0, y0, x1, y1 = E.rect(n)
	local ax, ay = E.to_logical(x0, y0)
	local bx, by = E.to_logical(x1, y1)
	return math.min(ax, bx), math.min(ay, by), math.max(ax, bx), math.max(ay, by)
end

-- The nearest ancestor that is a sized, visible box (the thing the text is printed on); nil on the root layers.
local function container(E, n)
	local p = n.parent
	while p do
		if p.kind == "box" and E.visible(p) and p.size.x > 0 and p.size.y > 0 and E.opacity(p) > 0.05 then
			local x0, y0, x1, y1 = lrect(E, p)
			if x1 - x0 < 700 then return p end
			return nil
		end
		p = p.parent
	end
	return nil
end

local function under(n, anc)
	local p = n
	while p do
		if p == anc then return true end
		p = p.parent
	end
	return false
end

-- The holder node of the top window (client/popups.lua) of the town or of the level screen, or nil.
function A.window_root(c)
	local host
	if c.town then host = c.town.self.t.popups else host = c.hud.self.l.popups end
	local top = host and host.stack and host.stack[#host.stack]
	return top and top.holder or nil
end

-- All measured visible texts of the scene of context c (of the top window only, when opts.window): {node, text,
-- rect, lines, font_px, box (rect or nil)}.
function A.texts(c, opts)
	local E = c.E
	local rows = {}
	local panel = opts and opts.window and A.window_root(c)
	if opts and opts.window and not panel then error("layout_audit: no window on the screen") end
	for _, n in ipairs(E.alive_nodes((opts and opts.scene) or (c.town or c.hud).scene)) do
		if n.kind == "text" and (not panel or under(n, panel)) and (n.text or "") ~= "" and E.visible(n) and E.opacity(n) > 0.05 then
			local r, facts = measure(E, n)
			local row = { node = n, text = n.text, rect = r, lines = facts.lines, font_px = facts.font_px }
			local box = container(E, n)
			if box then
				local x0, y0, x1, y1 = lrect(E, box)
				row.box, row.box_node = { x0, y0, x1, y1 }, box
			end
			rows[#rows + 1] = row
		end
	end
	return rows
end

local function short(s)
	s = s:gsub("\n", "/")
	if #s > 40 then s = s:sub(1, 37) .. "..." end
	return "'" .. s .. "'"
end

local function ancestor_of(a, b)
	local p = b
	while p do
		if p == a then return true end
		p = p.parent
	end
	return false
end

-- Problems of the current scene of c ("text: what"). opts: tol (px, default 1.5), window (only the texts on the window
-- panel: the town behind a window is dimmed), skip_overlap
function A.check(c, opts)
	opts = opts or {}
	local tol = opts.tol or 1.5
	local rows = A.texts(c, opts)
	local out = {}
	-- a window lives in the 720x1280 design area (inside every window shape); a screen anchors to the window edges
	local sx0, sy0, sx1, sy1 = 0, 0, 720, 1280
	if not opts.window then
		local E = c.E
		local ax, ay = E.to_logical(0, 0)
		local bx, by = E.to_logical(E.window.w, E.window.h)
		sx0, sy0, sx1, sy1 = math.min(ax, bx), math.min(ay, by), math.max(ax, bx), math.max(ay, by)
	end
	for _, r in ipairs(rows) do
		local x0, y0, x1, y1 = r.rect[1], r.rect[2], r.rect[3], r.rect[4]
		if r.box then
			local d = math.max(r.box[1] - x0, x1 - r.box[3], r.box[2] - y0, y1 - r.box[4])
			if d > tol then out[#out + 1] = string.format("%s sticks out of its box by %.1f px", short(r.text), d) end
		end
		local d = math.max(sx0 - x0, x1 - sx1, sy0 - y0, y1 - sy1)
		if d > tol then out[#out + 1] = string.format("%s is %.1f px out of the screen", short(r.text), d) end
		if r.font_px < 15 - 0.01 then out[#out + 1] = string.format("%s is only %.1f px tall", short(r.text), r.font_px) end
	end
	if not opts.skip_overlap then
		for i = 1, #rows do
			for j = i + 1, #rows do
				local a, b = rows[i], rows[j]
				if not ancestor_of(a.node, b.node) and not ancestor_of(b.node, a.node) then
					local ix = math.min(a.rect[3], b.rect[3]) - math.max(a.rect[1], b.rect[1])
					local iy = math.min(a.rect[4], b.rect[4]) - math.max(a.rect[2], b.rect[2])
					if ix > 3 and iy > 3 then
						local area = ix * iy
						local small = math.min((a.rect[3] - a.rect[1]) * (a.rect[4] - a.rect[2]), (b.rect[3] - b.rect[1]) * (b.rect[4] - b.rect[2]))
						if small > 0 and area / small > 0.12 then
							out[#out + 1] = string.format("%s overlaps %s (%.0f%% of the smaller)", short(a.text), short(b.text), 100 * area / small)
						end
					end
				end
			end
		end
	end
	table.sort(out)
	return out
end

return A
