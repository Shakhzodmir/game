-- Stars by score (content/levels/stars.json).
--
-- Every level has three score thresholds t = {t1, t2, t3}. A win always gives at least 1 star; the
-- score decides the rest: 2 stars from t2 on, 3 stars from t3 on. t1 is the score of a steady win (a
-- bot's lower quartile): the results window draws it as the first mark of the scale, and a win below it
-- still counts as 1 star. A level is "normal" or a "concert" (a hard level that also pays super
-- stars, meta-economy.md, section 14).
--
-- Pure Lua: the client, the meta and the tools (tools/stars.lua, tools/levels.lua) share it.

local M = {}

M.KINDS = { "normal", "concert" }
M.MAX_STARS = 3

local function is_int(v)
	return type(v) == "number" and v == math.floor(v) and v == v and v > -2 ^ 53 and v < 2 ^ 53
end

-- Stars of a win with `score`, thresholds `t` = {t1, t2, t3}. Without thresholds (a level the table
-- does not know) a win is worth 1 star.
function M.rate(t, score)
	if type(t) ~= "table" or not is_int(score) then return 1 end
	local n = 1
	if score >= t[2] then n = 2 end
	if score >= t[3] then n = 3 end
	return n
end

-- Where the score stands on the scale: {stars, from, to, frac} with from/to the thresholds around it
-- (to = nil once 3 stars are reached) and frac in [0, 1] the way from `from` to `to`.
-- With 1 star `from` is 0, with 2 stars it is t2, with 3 stars it is t3.
function M.progress(t, score)
	local stars = M.rate(t, score)
	if type(t) ~= "table" then return { stars = stars, from = 0, to = nil, frac = 1 } end
	score = is_int(score) and math.max(0, score) or 0
	local from = stars == 1 and 0 or t[stars]
	local to = t[stars + 1]
	local frac = 1
	if to then frac = math.max(0, math.min(1, (score - from) / math.max(1, to - from))) end
	return { stars = stars, from = from, to = to, frac = frac }
end

-- Entry of a decoded stars.json for a level id: {kind, t} or nil.
function M.entry(data, id)
	if type(data) ~= "table" or type(data.levels) ~= "table" then return nil end
	local e = data.levels[tostring(id)]
	if type(e) ~= "table" or type(e.t) ~= "table" then return nil end
	return e
end

function M.is_concert(data, id)
	local e = M.entry(data, id)
	return e ~= nil and e.kind == "concert"
end

-- Shape problems of one entry: array of strings (empty when fine).
function M.check_entry(e)
	local errs = {}
	if type(e) ~= "table" then return { "not an object" } end
	if e.kind ~= "normal" and e.kind ~= "concert" then errs[#errs + 1] = "kind must be normal or concert" end
	local t = e.t
	if type(t) ~= "table" or #t ~= 3 then
		errs[#errs + 1] = "t must be three thresholds"
		return errs
	end
	for i = 1, 3 do
		if not is_int(t[i]) or t[i] < 1 then errs[#errs + 1] = "threshold " .. i .. " must be a positive integer" end
	end
	if #errs == 0 and not (t[1] < t[2] and t[2] < t[3]) then errs[#errs + 1] = "thresholds must grow: t1 < t2 < t3" end
	return errs
end

return M
