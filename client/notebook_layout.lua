-- Where the title and the verses stand on the page of the songbook window (pure Lua: gui/notebook.lua draws what this
-- decides, tests/client/notebook_layout_test.lua checks it against every title of the game).
--
-- The page is a 556x790 sheet with a parchment drawn on it (a margin of 32 px above and below), a golden seal on the
-- right and the song under the title. A title of a finished song goes on ONE line while it can be shrunk to a readable
-- size; a longer one takes TWO lines, and the verses start lower by what the second line needs. Before, a title wider
-- than its box wrapped onto a second line that sat on the first verse: 168 of 352 English and 238 of 352 Russian titles do.
--
-- Paper coordinates: 0, 0 is the centre of the sheet, x to the right, y UP (the GUI's own).
--
--   local plan = layout.title(text, measure)
--       measure(str, size) -> the width in px of str on one line at size px, in the font that draws it
--       plan = {lines = {str, ...} (one or two), size = px, ys = {y of the centre of each line},
--               top, bottom = the block the title takes, first_row = y of the first verse row}
--   layout.last_row(first_row, total, group_count) -> y of the last row of a page of `total` rows in `group_count` groups

local M = {}

M.PAPER_W, M.PAPER_H = 556, 790
M.TOP = M.PAPER_H / 2 - 48            -- the title row; a page without a title starts its rows here
M.STEP = 28                           -- between two rows of the song
M.GROUP_GAP = 12                      -- extra between two groups (verses, choruses)
M.ROW_HALF = M.STEP / 2               -- a row takes this much above and below its centre
M.PARCHMENT_BOTTOM = -362             -- the lower edge of the parchment (paper_sheet.png has a margin of 33 px)

M.TITLE_X = -30                       -- the centre of the title; the seal stands to its right (its picture spans x 148..252)
M.TITLE_W = 352                       -- the width of the title box: x -206..146, 2 px before the seal's picture (18 px before the
                                      -- seal itself, which does not fill it), 23 px inside the parchment at the title row
M.TITLE_SIZE = 40                     -- px of a title that fits on one line
M.TITLE_MIN = 30                      -- the smallest a title is shrunk to to stay on one line (the verses are 23 px)
M.TITLE_TWO = 32                      -- the size of a title on two lines (MIN when it does not fit at this size)
M.TITLE_FLOOR = 20                    -- the smallest of all: a title with one very long word is shrunk to fit, no further
M.LINE = 1.25                         -- a line of the title takes this many sizes of height
M.TITLE_GAP = 10                      -- clear space between a two-line title and the first verse row
M.ONE_LINE_FIRST_ROW = M.TOP - 54     -- the first verse under a title of one line (where it always was)

local function one(text, size)
	local half = M.LINE * size / 2
	return { lines = { text }, size = size, ys = { M.TOP }, top = M.TOP + half, bottom = M.TOP - half,
		first_row = M.ONE_LINE_FIRST_ROW }
end

-- two lines: the first stands where a title of one line stands, the second under it
local function two(lines, size)
	local pitch = M.LINE * size
	local bottom = M.TOP - pitch - pitch / 2
	return { lines = lines, size = size, ys = { M.TOP, M.TOP - pitch }, top = M.TOP + pitch / 2, bottom = bottom,
		first_row = bottom - M.TITLE_GAP - M.ROW_HALF }
end

-- The split of text at a space into two lines whose wider line is the narrowest at `size`: {first, second}, width.
-- nil without a space.
local function split(text, size, measure)
	local best, best_w
	local from = 1
	while true do
		local at = string.find(text, " ", from, true)
		if not at then break end
		local a, b = string.sub(text, 1, at - 1), string.sub(text, at + 1)
		if a ~= "" and b ~= "" then
			local w = math.max(measure(a, size), measure(b, size))
			if not best_w or w < best_w - 1e-9 then best, best_w = { a, b }, w end
		end
		from = at + 1
	end
	return best, best_w
end

function M.title(text, measure)
	local width = measure(text, M.TITLE_SIZE)
	if width <= M.TITLE_W then return one(text, M.TITLE_SIZE) end
	local fit = M.TITLE_SIZE * M.TITLE_W / width -- the size at which it just fits on one line
	if fit >= M.TITLE_MIN then return one(text, fit) end
	for _, size in ipairs({ M.TITLE_TWO, M.TITLE_MIN }) do
		local lines, widest = split(text, size, measure)
		if lines and widest <= M.TITLE_W then return two(lines, size) end
	end
	-- too wide even on two lines at the smallest size (a very long word): shrink to fit, but not below the floor
	local lines, widest = split(text, M.TITLE_MIN, measure)
	if lines then return two(lines, math.max(M.TITLE_FLOOR, M.TITLE_MIN * M.TITLE_W / widest)) end
	return one(text, math.max(M.TITLE_FLOOR, fit))
end

-- The centre of the last row of a page whose first row is at first_row: `total` rows, a gap before every group but the first.
function M.last_row(first_row, total, group_count)
	return first_row - (total - 1) * M.STEP - (math.max(group_count, 1) - 1) * M.GROUP_GAP
end

return M
