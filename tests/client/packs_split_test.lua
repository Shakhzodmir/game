-- The split tools/gen_defold.py makes for the web build: which loose images stay in the archive and which ship as
-- remote files (client/packs.lua downloads them). Checked on the generated outputs (client/assets_index.lua,
-- assets/gen/web.settings, assets/gen/web_packs.txt) against the rule, so a district added later is covered too.
-- Run from the repository root.
local json = require("tools.lib.json")
local index = require("client.assets_index")

local function read(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local SHARED = { backgrounds = true, bit = true, logo = true, notebook = true }

local function district_ids()
	local data = json.decode(assert(read("content/districts.json"), "content/districts.json"))
	local ids, set = {}, {}
	for _, d in ipairs(data.districts) do
		ids[#ids + 1] = d.id
		set[d.id] = true
	end
	return ids, set
end

-- the district a loose image belongs to, by the same rule as the generator (nil: shared)
local function owner(key, set)
	local top, rest = key:match("^([^/]+)/(.+)$")
	if top == "districts" then return rest:match("^([^/]+)/") end
	if top == "mapbg" then
		local did = rest:match("^[^_]+_(.+)$")
		if did and set[did] then return did end
	end
	return nil
end

local function settings()
	local text = assert(read("assets/gen/web.settings"), "assets/gen/web.settings is missing")
	text = text:gsub("\r", "")
	local list = text:match("custom_resources = ([^\n]*)")
	local entries = {}
	for e in (list or ""):gmatch("[^,]+") do entries[#entries + 1] = e end
	return text, entries
end

-- true when the archive path (file) is under one of the custom_resources entries
local function covered(path, entries)
	for _, e in ipairs(entries) do
		if path == e or path:sub(1, #e + 1) == e .. "/" then return true end
	end
	return false
end

describe("web build split of the loose images (tools/gen_defold.py)", function()
	local ids, set = district_ids()
	local first = ids[1]

	it("leaves out every loose image of every district but the first one, and nothing else", function()
		local remote, kept = 0, 0
		for key, e in pairs(index.images) do
			if e.file then
				local did = owner(key, set)
				local top = key:match("^([^/]+)/")
				if did and did ~= first then
					remote = remote + 1
					assert_true(e.remote ~= nil, key .. " should be remote")
					assert_eq(e.district, did, key)
				else
					kept = kept + 1
					assert_eq(e.remote, nil, key .. " should stay in the archive")
					assert_eq(e.bytes, nil, key)
				end
				if SHARED[top] then assert_eq(e.remote, nil, key .. ": shared pictures stay in the archive") end
			else
				assert_eq(e.remote, nil, key .. ": atlas images are always in the archive")
			end
		end
		assert_true(remote > 0, "the web build has remote pictures")
		assert_true(kept > 0)
		-- the first district is entirely in the archive: the first launch needs nothing from packs/
		for _, k in ipairs({ "districts/" .. first .. "/bg", "mapbg/bg_" .. first, "mapbg/gate_" .. first }) do
			if index.images[k] then assert_eq(index.images[k].remote, nil, k) end
		end
		assert_eq(index.packs[first], nil, "no pack for the first district")
	end)

	it("addresses each remote file next to index.html with its content hash and checks its size", function()
		for key, e in pairs(index.images) do
			if e.remote then
				local rel = e.file:match("^/assets/images/(.+)$")
				assert_true(rel ~= nil, key)
				local path, v = e.remote:match("^packs/(.+)%?v=(%x+)$")
				assert_eq(path, rel, key .. ": packs/<path under assets/images>")
				assert_eq(#v, 10, key .. ": a short content hash")
				local data = read(e.file:sub(2))
				assert_true(data ~= nil, e.file)
				assert_eq(e.bytes, #data, key .. ": bytes is the file size")
			end
		end
	end)

	it("lists the remote images of each district once, the room's background first", function()
		local seen = {}
		for did, keys in pairs(index.packs) do
			assert_true(set[did] or index.images[keys[1]].district == did, did)
			for i, key in ipairs(keys) do
				local e = index.images[key]
				assert_true(e and e.remote ~= nil, key)
				assert_eq(e.district, did, key)
				assert_eq(seen[key], nil, key .. " twice")
				seen[key] = true
				if i > 1 then assert_true(key:match("/bg$") == nil, key .. ": the background comes first") end
			end
		end
		for key, e in pairs(index.images) do
			if e.remote then assert_true(seen[key], key .. " is in no pack") end
		end
	end)

	it("assets/gen/web.settings keeps the remote files out of the archive and every other loose image in", function()
		local text, entries = settings()
		assert_true(text:find("[glow]", 1, true) ~= nil and text:find("\npacks = 1\n", 1, true) ~= nil, "glow.packs = 1")
		assert_true(#entries > 0)
		assert_true(covered("/content/districts.json", entries), "/content stays")
		for key, e in pairs(index.images) do
			if e.file then
				if e.remote then
					assert_false(covered(e.file, entries), e.file .. " must not be in the web archive")
				else
					assert_true(covered(e.file, entries), e.file .. " must be in the web archive")
				end
			end
		end
		-- bob reads no comment lines in a settings file
		for line in (text .. "\n"):gmatch("([^\n]*)\n") do
			assert_false(line:match("^%s*[#;]") ~= nil, "comment line in web.settings: " .. line)
		end
	end)

	it("assets/gen/web_packs.txt lists exactly the remote files, and tools/build_web.sh uses both files", function()
		local list = assert(read("assets/gen/web_packs.txt"), "assets/gen/web_packs.txt"):gsub("\r", "")
		local want, n = {}, 0
		for key, e in pairs(index.images) do
			if e.remote then
				want[e.file:sub(2)] = key
				n = n + 1
			end
		end
		local got = 0
		for line in list:gmatch("[^\n]+") do
			assert_true(want[line] ~= nil, line .. " is not a remote picture")
			got = got + 1
		end
		assert_eq(got, n)
		local sh = assert(read("tools/build_web.sh"))
		assert_true(sh:find("--settings assets/gen/web.settings", 1, true) ~= nil, "bob gets the web settings")
		assert_true(sh:find("assets/gen/web_packs.txt", 1, true) ~= nil, "the remote files are copied")
		assert_true(sh:find('$out/packs/', 1, true) ~= nil, "into packs/ next to index.html")
		-- the service worker that keeps them across releases: copied, registered by the page, and it stores only a
		-- versioned packs/ address whose content matches its hash
		assert_true(sh:find("web/packs_sw.js", 1, true) ~= nil, "build_web.sh copies web/packs_sw.js")
		local page = assert(read("web/engine_template.html"))
		assert_true(page:find("serviceWorker.register('packs_sw.js')", 1, true) ~= nil, "the page registers it")
		local sw = assert(read("web/packs_sw.js"))
		assert_true(sw:find("'/packs/'", 1, true) ~= nil and sw:find("searchParams.get('v')", 1, true) ~= nil, "packs/ with v= only")
		assert_true(sw:find("digest('SHA-1'", 1, true) ~= nil, "checks the content hash before storing")
	end)

	it("game.project keeps whole folders: other platforms and the tests read every picture from the archive", function()
		local gp = assert(read("game.project")):gsub("\r", "")
		local list = gp:match("custom_resources = ([^\n]*)")
		for _, dir in ipairs({ "/assets/images/districts", "/assets/images/mapbg" }) do
			assert_true(("," .. list .. ","):find("," .. dir .. ",", 1, true) ~= nil, dir)
		end
	end)
end)
