-- The songbook (meta/songbook.lua): one line per beaten level, chosen from a pool by the player's salt; the finished
-- song; the silent fill of an old save; the save field. Nothing here may pay anything.

local songbook = require("meta.songbook")
local save = require("meta.save")
local C = require("meta.config")
local Meta = require("meta.meta")
local H = require("tests.meta.helper")
local json = require("tools.lib.json")

local function stats(m)
	return { coins = m:coins(), stars = m:stars(), stats = m:stats() }
end

-- a save of `m` as the first release wrote it: no songbook field
local function without_songbook(m)
	local t = H.json_round_trip(m:serialize())
	t.songbook = nil
	t.checksum = save.checksum(t)
	return t
end

describe("songbook model", function()
	it("keeps the stretches in step with the map of content/map.json", function()
		local f = assert(io.open("content/map.json", "r"))
		local map = json.decode(f:read("*a"))
		f:close()
		assert_eq(#C.songbook.districts, #map.segments)
		for i, seg in ipairs(map.segments) do
			assert_eq(C.songbook.districts[i].id, seg.district)
			assert_eq(C.songbook.districts[i].first, seg.first)
			assert_eq(C.songbook.districts[i].last, seg.last)
		end
		assert_true(C.songbook.pool >= C.songbook.districts[1].last - C.songbook.districts[1].first + 1)
	end)

	it("is the same for the same player and different for another one", function()
		local a, b, c = songbook.fresh(), songbook.fresh(), songbook.fresh()
		songbook.sync(a, 1234, 20)
		songbook.sync(b, 1234, 20)
		songbook.sync(c, 99991, 20)
		assert_same(a.lines, b.lines)
		local same = true
		for i = 1, 20 do same = same and a.lines.cafe[i] == c.lines.cafe[i] end
		assert_false(same, "two players got the same song")
	end)

	it("never repeats a line inside a song, for many players", function()
		for salt = 1, 60 do
			local st = songbook.fresh()
			songbook.sync(st, salt * 7919, 100)
			for _, d in ipairs(C.songbook.districts) do
				local seen = {}
				assert_eq(#st.lines[d.id], d.last - d.first + 1)
				for _, n in ipairs(st.lines[d.id]) do
					assert_true(n >= 1 and n <= C.songbook.pool)
					assert_false(seen[n], "line " .. n .. " twice in " .. d.id .. " (salt " .. salt .. ")")
					seen[n] = true
				end
			end
		end
	end)

	it("gives the same line whether the levels came one by one or all at once", function()
		local one, all = songbook.fresh(), songbook.fresh()
		for level = 1, 45 do songbook.sync(one, 555, level) end
		songbook.sync(all, 555, 45)
		assert_same(one.lines, all.lines)
	end)

	it("keeps a written line when the pool grows later", function()
		local st = songbook.fresh()
		songbook.sync(st, 321, 10)
		local before = {}
		for i, n in ipairs(st.lines.cafe) do before[i] = n end
		local old = C.songbook.pool
		C.songbook.pool = old + 4
		local ok, err = pcall(songbook.sync, st, 321, 20)
		C.songbook.pool = old
		assert(ok, err)
		for i = 1, 10 do assert_eq(st.lines.cafe[i], before[i]) end
	end)

	it("makes a ready song with a title, verses and a chorus", function()
		local st = songbook.fresh()
		songbook.sync(st, 77, 19)
		local part = songbook.song(st, "cafe")
		assert_false(part.ready)
		assert_eq(part.title, nil)
		assert_eq(part.count, 19)
		songbook.sync(st, 77, 20)
		local full = songbook.song(st, "cafe")
		assert_true(full.ready)
		assert_true(full.title >= 1 and full.title <= C.songbook.titles)
		assert_eq(#full.groups, 5)
		assert_eq(full.groups[1].kind, "verse")
		assert_eq(full.groups[3].kind, "chorus")
		assert_eq(full.groups[5].to, 20)
		assert_eq(songbook.song(st, "jazz").count, 0)
		assert_eq(songbook.song(st, "nowhere"), nil)
	end)

	it("restores a damaged field without inventing anything", function()
		local st = songbook.restore({ lines = { cafe = { 3, 3, 5 }, jazz = { 0, 2 }, garage = { 1, 2.5 }, nowhere = { 1 } }, seen = { "cafe", "x", 4 } })
		assert_same(st.lines.cafe, { 3 }) -- the repeat ends the song there
		assert_eq(st.lines.jazz, nil)
		assert_same(st.lines.garage, { 1 })
		assert_same(st.seen, { "cafe" })
		assert_same(songbook.restore("nope"), songbook.fresh())
		assert_same(songbook.restore({ lines = 5, seen = 5 }), songbook.fresh())
		local long = {}
		for i = 1, 40 do long[i] = i end
		assert_eq(#songbook.restore({ lines = { cafe = long } }).lines.cafe, 20)
	end)

	it("counts characters and cuts a text by letters for every language", function()
		local client = require("client.songbook")
		assert_eq(client.length("Привет"), 6)
		assert_eq(client.length("노래 수첩"), 5)
		assert_eq(client.prefix("Привет", 3), "При")
		assert_eq(client.prefix("노래 수첩", 2), "노래")
		assert_eq(client.prefix("abc", 0), "")
		assert_eq(client.prefix("abc", 9), "abc")
	end)

	it("lights lines evenly over the loop, on the beats when the tempo is known", function()
		local client = require("client.songbook")
		assert_eq(client.active_line(20, 0, 40), 1)
		assert_eq(client.active_line(20, 39.9, 40), 20)
		assert_eq(client.active_line(20, 40, 40), 1) -- the loop restarts
		assert_eq(client.active_line(20, 21, 40), 11)
		-- 120 bpm: a beat is 0.5 s, the loop has 80 beats, a line 4 beats: borders at multiples of 2 s
		assert_eq(client.active_line(20, 1.99, 40, 120), 1)
		assert_eq(client.active_line(20, 2.0, 40, 120), 2)
		assert_eq(client.active_line(20, 39.99, 40, 120), 20)
		assert_eq(client.active_line(20, nil, 40), 1)
		assert_eq(client.active_line(0, 3, 40), nil)
		-- every line gets a turn, in order
		local last = 0
		for t = 0, 399 do
			local i = client.active_line(20, t / 10, 40, 100)
			assert_true(i >= last and i <= last + 1)
			last = i
		end
		assert_eq(last, 20)
	end)
end)

describe("songbook in the meta", function()
	it("writes one line per won level and pays nothing for it", function()
		local m = H.new(5)
		local plain = H.new(5)
		local res
		for level = 1, 3 do
			res = H.win(m)
			assert_eq(res.song.district, "cafe")
			assert_eq(res.song.pos, level)
			assert_eq(res.song.total, 20)
			assert_false(res.song.ready)
		end
		assert_eq(m:song_of("cafe").count, 3)
		assert_eq(m:song_of("cafe").lines[3], res.song.line)
		-- the same wins on a meta with the songbook emptied pay the same: compare to the economy of 3 wins
		for _ = 1, 3 do H.win(plain) end
		assert_same(stats(m), stats(plain))
	end)

	it("finishes the song with level 20, once, and offers it until the player has seen it", function()
		local m = H.new(6)
		H.advance_to(m, 20)
		assert_eq(m:songbook_pending(), nil)
		local res = H.win(m)
		assert_eq(res.song.pos, 20)
		assert_true(res.song.ready)
		assert_eq(m:songbook_pending(), "cafe")
		assert_true(m:songbook_seen("cafe"))
		assert_false(m:songbook_seen("cafe"))
		assert_eq(m:songbook_pending(), nil)
		-- the next stretch starts a new song
		local next_res = H.win(m)
		assert_eq(next_res.song.district, "jazz")
		assert_eq(next_res.song.pos, 1)
	end)

	it("does not write for a replay and survives save and load", function()
		local m = H.new(7)
		H.advance_to(m, 5)
		local before = m:song_of("cafe").count
		assert(m:record_replay({ level_id = 3, difficulty = "easy", stars = 3, score = 9999, concert = false }))
		assert_eq(m:song_of("cafe").count, before)
		local t = H.json_round_trip(m:serialize())
		local back = Meta.load(H.districts(), t, nil, 1, H.T0)
		assert_same(back:song_of("cafe"), m:song_of("cafe"))
	end)

	it("fills the songs of a save from before the songbook, silently", function()
		local m = H.new(8)
		H.advance_to(m, 90) -- 89 levels beaten, like the producer's save
		local old = without_songbook(m)
		assert_eq(old.songbook, nil)
		local back = Meta.load(H.districts(), old, nil, 1, H.T0)
		assert_eq(back:song_of("cafe").count, 20)
		assert_eq(back:song_of("stadium").count, 20)
		assert_eq(back:song_of("garage").count, 9)
		assert_true(back:song_of("cafe").ready)
		assert_false(back:song_of("garage").ready)
		-- the finished songs are there, but nothing is offered and the economy is untouched
		assert_eq(back:songbook_pending(), nil)
		assert_eq(back:coins(), m:coins())
		assert_eq(back:stars(), m:stars())
		assert_eq(back:level_to_play(), m:level_to_play())
		-- the same player gets the same song as the one the live meta wrote
		assert_same(back:song_of("cafe").lines, m:song_of("cafe").lines)
		-- playing on: the 100th level finishes the last song and it IS offered
		local last
		while back:level_to_play() and back:level_to_play() <= 100 do last = H.win(back) end
		assert_true(last.song.ready)
		assert_eq(back:songbook_pending(), "garage")
	end)

	it("a save that is a clean first-release save at level 89 migrates and loads back unchanged", function()
		local m = H.new(9)
		H.advance_to(m, 90)
		local old = without_songbook(m)
		local first = Meta.load(H.districts(), old, nil, 1, H.T0)
		assert_true(first:dirty()) -- a save with a new field is written again
		local second = Meta.load(H.districts(), H.json_round_trip(first:serialize()), nil, 1, H.T0)
		assert_false(second:dirty())
		assert_same(second:songbook(), first:songbook())
		assert_eq(first:level_to_play(), 90)
		assert_eq(first:songbook()[5].count, 9)
	end)

	it("keeps the songbook of a newer save through a rollback (the field is known, the rest is kept)", function()
		local m = H.new(10)
		H.advance_to(m, 12)
		local t = H.json_round_trip(m:serialize())
		t.songbook.lines.cafe[1] = t.songbook.lines.cafe[1] -- unchanged
		t.future_field = { a = 1 }
		t.checksum = save.checksum(t)
		local back = Meta.load(H.districts(), t, nil, 1, H.T0)
		assert_same(back:song_of("cafe").lines, m:song_of("cafe").lines)
		assert_eq(back:serialize().future_field.a, 1)
	end)
end)

describe("songbook texts", function()
	local i18n = require("client.i18n")
	local function words(s)
		local n = 0
		for _ in s:gmatch("%S+") do n = n + 1 end
		return n
	end

	it("has every line and title in the three languages, as many as the pool says", function()
		local total = 0
		for _, d in ipairs(C.songbook.districts) do
			for n = 1, C.songbook.pool do
				local key = "sb." .. d.id .. "." .. n
				assert_true(i18n.has(key), "missing " .. key)
				for _, lang in ipairs({ "en", "ru", "ko" }) do
					local text = i18n.t(key, nil, lang)
					assert_true(text ~= key and #text > 0, key .. " has no " .. lang)
				end
				total = total + 1
			end
			for n = 1, C.songbook.titles do
				local key = "sbt." .. d.id .. "." .. n
				for _, lang in ipairs({ "en", "ru", "ko" }) do
					assert_true(i18n.t(key, nil, lang) ~= key, key .. " has no " .. lang)
				end
			end
		end
		assert_true(total >= 150, "only " .. total .. " lines per language")
	end)

	it("keeps the lines short (one to eight words in English and Russian) and without repeats inside a district", function()
		for _, d in ipairs(C.songbook.districts) do
			local seen = { en = {}, ru = {} }
			for n = 1, C.songbook.pool do
				for _, lang in ipairs({ "en", "ru" }) do
					local text = i18n.t("sb." .. d.id .. "." .. n, nil, lang)
					local w = words(text)
					assert_true(w >= 1 and w <= 8, d.id .. "." .. n .. " (" .. lang .. ") has " .. w .. " words")
					assert_true(require("client.songbook").length(text) <= 64, d.id .. "." .. n .. " (" .. lang .. ") is too long")
					assert_false(seen[lang][text], "repeated line " .. text)
					seen[lang][text] = true
				end
			end
		end
	end)
end)

describe("songbook glyphs", function()
	local i18n = require("client.i18n")
	local fonts = require("tests.client.font_advances")

	local function missing(text, font)
		local out = {}
		local i = 1
		while i <= #text do
			local b = text:byte(i)
			local size = (b >= 240 and 4) or (b >= 224 and 3) or (b >= 192 and 2) or 1
			local cp
			if size == 1 then
				cp = b
			elseif size == 2 then
				cp = (b % 32) * 64 + (text:byte(i + 1) % 64)
			elseif size == 3 then
				cp = (b % 16) * 4096 + (text:byte(i + 1) % 64) * 64 + (text:byte(i + 2) % 64)
			else
				cp = 0x10000
			end
			if not font.advances[cp] then out[#out + 1] = string.format("U+%04X", cp) end
			i = i + size
		end
		return out
	end

	it("has every character of every line and title in the fonts that draw them, in all three languages", function()
		local lines = { en = "body", ru = "body", ko = "body_ko" }
		local titles = { en = "title", ru = "title", ko = "title_ko" }
		for _, d in ipairs(C.songbook.districts) do
			for lang, font in pairs(lines) do -- order-free: every language is checked
				for n = 1, C.songbook.pool do
					local text = i18n.t("sb." .. d.id .. "." .. n, nil, lang)
					assert_same(missing(text, fonts[font]), {}, d.id .. "." .. n .. " (" .. lang .. ") " .. text)
				end
			end
			for lang, font in pairs(titles) do -- order-free
				for n = 1, C.songbook.titles do
					local text = i18n.t("sbt." .. d.id .. "." .. n, nil, lang)
					assert_same(missing(text, fonts[font]), {}, d.id .. " title " .. n .. " (" .. lang .. ") " .. text)
				end
			end
		end
	end)
end)
