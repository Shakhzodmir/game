-- Content validator (WP-13): the game is data. This checks that the files that describe the levels and the
-- districts agree with each other, so that a new batch of levels or a new district can be added by data only.
--
--   luajit tools/check_content.lua          # from the repository root; exit 1 when something is wrong
--
-- What is checked (the number N of levels is the last level of the last district of content/districts.json):
--   * content/districts.json: every district has an id, `first` / `last` (the stretches follow each other from
--     level 1, no gap, no overlap, at most C.songbook.pool levels each), names in ru / en / ko, a genre name in
--     ru / en / ko, tasks (names in ru / en / ko), a chest and its songs (the rules of meta/town.lua)
--   * content/levels/level_NNNN.json exists for every level 1..N, its id is NNNN, and there is no file beyond N
--   * content/levels/stars.json has the thresholds of every level 1..N and of no other
--   * content/map.json: level_count is N, there is a node for every level 1..N, the segments are the districts
--     (same id, first, last)
--   * the songbook texts: sb.<district>.<1..pool> and sbt.<district>.<1..titles> in en, ru and ko
-- Every message names the file and the number. The checks of the art and of the music of a district (images,
-- stems) are in tools/check_refs.lua; the level rules in tools/levels.lua validate --strict.
--
-- Check.run(fs) -> errors (list of strings), info {levels, districts}; fs = {
--   read = function(path) -> text | nil   (path relative to the repository root, with "/"),
--   exists = function(path) -> bool       (optional; default: read(path) ~= nil),
--   texts = function() -> songbook, ko    (the i18n tables; default: the real client files) }

local json = require("tools.lib.json")

local Check = {}

local function add(errors, msg)
	errors[#errors + 1] = msg
end

local function decode(text)
	local ok, t = pcall(json.decode, text)
	if ok and type(t) == "table" then return t end
	return nil
end

local function is_int(v)
	return type(v) == "number" and v % 1 == 0
end

local function localized(errors, where, v)
	if type(v) ~= "table" then
		add(errors, where .. ": a name in ru, en and ko is missing")
		return
	end
	for _, lang in ipairs({ "ru", "en", "ko" }) do
		if type(v[lang]) ~= "string" or v[lang] == "" then add(errors, where .. ": no '" .. lang .. "' text") end
	end
end

local function default_texts()
	return require("client.i18n_songbook"), require("client.i18n_ko")
end

function Check.run(fs)
	local errors, info = {}, { levels = 0, districts = 0 }
	local exists = fs.exists or function(path) return fs.read(path) ~= nil end
	local config = require("meta.config")
	local town = require("meta.town")

	-- districts.json ---------------------------------------------------------------------------------------------
	local dtext = fs.read("content/districts.json")
	if not dtext then
		add(errors, "content/districts.json: the file is missing")
		return errors, info
	end
	local districts = decode(dtext)
	if not districts or type(districts.districts) ~= "table" or #districts.districts == 0 then
		add(errors, "content/districts.json: not JSON, or no 'districts' list")
		return errors, info
	end
	local list = districts.districts
	info.districts = #list
	local stretches, ids = {}, {}
	for i, d in ipairs(list) do
		local id = type(d) == "table" and d.id or nil
		local where = "content/districts.json district " .. i .. (type(id) == "string" and (" (" .. id .. ")") or "")
		if type(id) ~= "string" or id == "" then
			add(errors, where .. ": no id")
		else
			if ids[id] then add(errors, where .. ": the id repeats district " .. ids[id]) end
			ids[id] = i
			localized(errors, where .. " name", d.name)
			localized(errors, where .. " genre", d.genre)
			if type(d.bpm) ~= "number" or d.bpm < 40 or d.bpm > 220 then add(errors, where .. ": bpm must be 40..220") end
			if d.map_tint ~= nil and (type(d.map_tint) ~= "string" or not d.map_tint:match("^#%x%x%x%x%x%x$")) then
				add(errors, where .. ": map_tint must look like #RRGGBB")
			end
			for j, t in ipairs(type(d.tasks) == "table" and d.tasks or {}) do
				if type(t) == "table" then localized(errors, where .. " task " .. j, t.name) end
			end
			for j, s in ipairs(type(d.songs) == "table" and d.songs or {}) do
				if type(s) == "table" then localized(errors, where .. " song " .. j, s.name) end
			end
		end
		stretches[i] = { id = id, first = type(d) == "table" and d.first or nil, last = type(d) == "table" and d.last or nil }
	end
	local bound, why = config.check_districts(stretches)
	if not bound then
		add(errors, "content/districts.json: " .. why)
		return errors, info
	end
	local ok, err = pcall(town.validate, districts)
	if not ok then add(errors, "content/districts.json: " .. tostring(err):gsub("^.-meta: districts: ", "")) end
	local n = bound[#bound].last
	info.levels = n

	-- level files ------------------------------------------------------------------------------------------------
	for id = 1, n do
		local path = string.format("content/levels/level_%04d.json", id)
		local text = fs.read(path)
		if not text then
			add(errors, path .. ": level " .. id .. " has no file (the last level of districts.json is " .. n .. ")")
		else
			local lv = decode(text)
			if not lv then
				add(errors, path .. ": not JSON")
			elseif lv.id ~= id then
				add(errors, path .. ": level " .. id .. " says id " .. tostring(lv.id))
			end
		end
	end
	for id = n + 1, n + 1000 do
		local path = string.format("content/levels/level_%04d.json", id)
		if exists(path) then
			add(errors, path .. ": level " .. id .. " is after the last level of districts.json (" .. n .. "): add a district stretch for it")
		end
	end

	-- stars.json -------------------------------------------------------------------------------------------------
	local stext = fs.read("content/levels/stars.json")
	local stars = stext and decode(stext)
	if not stars or type(stars.levels) ~= "table" then
		add(errors, "content/levels/stars.json: missing, or not JSON with a 'levels' table")
	else
		for id = 1, n do
			local e = stars.levels[tostring(id)]
			if type(e) ~= "table" then
				add(errors, "content/levels/stars.json: level " .. id .. " has no star thresholds")
			elseif type(e.t) ~= "table" or #e.t ~= 3 or type(e.t[1]) ~= "number" or type(e.t[2]) ~= "number"
				or type(e.t[3]) ~= "number" or e.t[1] >= e.t[2] or e.t[2] >= e.t[3] then
				add(errors, "content/levels/stars.json: level " .. id .. ": t must be three growing score thresholds")
			elseif e.kind ~= "normal" and e.kind ~= "concert" then
				add(errors, "content/levels/stars.json: level " .. id .. ": kind must be normal or concert")
			end
		end
		local extra = {}
		for key in pairs(stars.levels) do -- order-free: collected, then sorted
			local id = tonumber(key)
			if not is_int(id) or id < 1 or id > n or key ~= tostring(id) then extra[#extra + 1] = key end
		end
		table.sort(extra)
		for _, key in ipairs(extra) do
			add(errors, "content/levels/stars.json: names level " .. key .. ", which is not in 1.." .. n)
		end
	end

	-- map.json ---------------------------------------------------------------------------------------------------
	local mtext = fs.read("content/map.json")
	local map = mtext and decode(mtext)
	if not map then
		add(errors, "content/map.json: missing or not JSON (python3 tools/gen_map.py)")
	else
		if map.level_count ~= n then
			add(errors, "content/map.json: level_count is " .. tostring(map.level_count) .. ", the districts have " .. n
				.. " levels (python3 tools/gen_map.py)")
		end
		local seen, count = {}, 0
		for _, node in ipairs(type(map.nodes) == "table" and map.nodes or {}) do
			count = count + 1
			seen[node.level] = true
		end
		if count ~= n then add(errors, "content/map.json: " .. count .. " nodes, the districts have " .. n .. " levels (python3 tools/gen_map.py)") end
		for id = 1, n do
			if not seen[id] then add(errors, "content/map.json: level " .. id .. " has no node") end
		end
		local segs = type(map.segments) == "table" and map.segments or {}
		if #segs ~= #bound then
			add(errors, "content/map.json: " .. #segs .. " segments, the districts are " .. #bound .. " (python3 tools/gen_map.py)")
		end
		for i, d in ipairs(bound) do
			local s = segs[i]
			if s and (s.district ~= d.id or s.first ~= d.first or s.last ~= d.last) then
				add(errors, "content/map.json: segment " .. i .. " is " .. tostring(s.district) .. " " .. tostring(s.first) .. "-"
					.. tostring(s.last) .. ", districts.json says " .. d.id .. " " .. d.first .. "-" .. d.last .. " (python3 tools/gen_map.py)")
			end
		end
	end

	-- songbook texts -----------------------------------------------------------------------------------------------
	local sb, ko = (fs.texts or default_texts)()
	local function text_of(entry, lang)
		if lang == "ko" then return type(entry) == "string" and entry ~= "" end
		return type(entry) == "table" and type(entry[lang]) == "string" and entry[lang] ~= ""
	end
	for _, d in ipairs(bound) do
		for _, family in ipairs({ { "sb", config.songbook.pool }, { "sbt", config.songbook.titles } }) do
			for k = 1, family[2] do
				local key = family[1] .. "." .. d.id .. "." .. k
				for _, lang in ipairs({ "en", "ru" }) do
					if not text_of(sb[key], lang) then
						add(errors, "client/i18n_songbook.lua: " .. key .. " has no '" .. lang .. "' text")
					end
				end
				if not text_of(ko[key], "ko") then add(errors, "client/i18n_ko.lua: " .. key .. " is missing") end
			end
		end
	end
	return errors, info
end

-- The real files of the repository.
function Check.real_fs(root)
	root = root or "."
	local function read(path)
		local f = io.open(root .. "/" .. path, "rb")
		if not f then return nil end
		local text = f:read("*a")
		f:close()
		return text
	end
	return { read = read, exists = function(path)
		local f = io.open(root .. "/" .. path, "rb")
		if f then f:close() end
		return f ~= nil
	end }
end

-- command line ---------------------------------------------------------------------------------------------------

local function main()
	package.path = "./?.lua;./?/init.lua;" .. package.path
	local errors, info = Check.run(Check.real_fs("."))
	for _, e in ipairs(errors) do print("FAIL " .. e) end
	if #errors == 0 then
		print(string.format("ok   content: %d levels in %d districts; levels, stars, map and songbook texts agree",
			info.levels, info.districts))
		return 0
	end
	print(string.format("%d problem(s) in the content", #errors))
	return 1
end

if arg and arg[0] and arg[0]:match("check_content%.lua$") then
	os.exit(main())
end

return Check
