local views = require("client.views")
local levels = require("client.levels")
local config = require("meta.config")
local iap = require("client.services.iap")
local H = require("tests.meta.helper")

local T = H.T0

-- a level file reader over a table {[n] = level table}
local function fake_levels(files)
	local json = require("tools.lib.json")
	levels._reset()
	levels.read = function(path)
		local n = tonumber(string.match(path, "level_(%d+)%.json$"))
		local f = n and files[n]
		if type(f) == "string" then return f end
		return f and json.encode(f) or nil
	end
	levels.decode = json.decode
end

describe("client.views (meta screens)", function()
	before_each(function() levels._reset() end)

	it("shows the level button with its difficulty tag and streak notes", function()
		fake_levels({ [1] = { difficulty = "hard", goals = {} } })
		local m = H.new()
		local v = views.level_button(m, levels)
		assert_eq(v.level, 1)
		assert_eq(v.tag, "town.hard")
		assert_eq(#v.notes, 3)
		assert_false(v.notes[1].lit)
		assert_false(v.all_done)
	end)

	it("has no tag for easy levels or a missing file", function()
		fake_levels({ [1] = { difficulty = "easy" } })
		local m = H.new()
		assert_eq(views.level_button(m, levels).tag, nil)
		levels._reset()
		fake_levels({})
		assert_eq(views.level_button(m, levels).tag, nil)
		assert_eq(views.level_button(m, levels).level, 1)
	end)

	it("lights the streak notes after wins from level 12", function()
		fake_levels({})
		local m = H.new()
		H.advance_to(m, 12, T)
		H.win(m, T)
		H.win(m, T)
		local v = views.level_button(m, levels)
		assert_true(v.notes[1].lit and v.notes[2].lit)
		assert_false(v.notes[3].lit)
		assert_eq(v.streak, 2)
	end)

	it("builds the start window: goals, moves, boosters, what a loss costs", function()
		fake_levels({ [1] = { difficulty = "super_hard", moves = 20,
			goals = { { type = "collect", color = "red", count = 30 }, { type = "break", item = "record_box", count = 9 } } } })
		local m = H.new()
		local info = levels.load(1)
		local v = views.start(m, 1, info, T, levels, config.levels.free_up_to)
		assert_eq(v.tag, "town.super_hard")
		assert_eq(#v.goals, 2)
		assert_eq(v.goals[1].image, "pieces/red")
		assert_eq(v.goals[2].image, "blockers/record_box_1")
		assert_eq(v.moves, 20)
		assert_eq(#v.boosters, 3)
		assert_eq(v.boosters[1].id, "riff")
		assert_false(v.boosters[1].unlocked)
		assert_false(v.life_cost) -- level 1 is free
		assert_true(v.can_start)
	end)

	it("says a loss costs a life after the free levels, not with unlimited lives", function()
		fake_levels({})
		local m = H.new()
		H.advance_to(m, config.levels.free_up_to + 1, T)
		local n = m:level_to_play()
		local later = T + 3 * 3600 -- the unlimited lives of the level 20 chest are over
		local v = views.start(m, n, nil, later, levels, config.levels.free_up_to)
		assert_true(v.life_cost)
		assert_false(v.infinite)
		assert_same(v.goals, {})
		m:grant({ infinite_minutes = 30 }, "test", later)
		assert_false(views.start(m, n, nil, later, levels, config.levels.free_up_to).life_cost)
	end)

	it("marks streak boosters free and not selectable (they are placed anyway)", function()
		fake_levels({})
		local m = H.new()
		H.advance_to(m, 13, T)
		H.win(m, T) -- streak 1 from level 12 on: a free riff at the next start
		local slots = views.start_boosters(m, m:level_to_play())
		assert_true(slots[1].unlocked)
		assert_true(slots[1].free)
		assert_false(slots[1].selectable)
		assert_same(views.picked(slots, { riff = true }), {})
	end)

	it("lists the store products in display order with their contents", function()
		local list = views.shop_products(iap.PRODUCTS, false)
		assert_eq(#list, 5)
		assert_eq(list[1].id, "starter_pack")
		assert_true(list[1].best)
		assert_eq(list[1].coins, 1000)
		assert_eq(list[1].infinite_minutes, 60)
		assert_eq(#list[1].boosters, 3)
		assert_false(list[2].available)
		assert_true(views.shop_products(iap.PRODUCTS, true)[2].available)
	end)

	it("lists what a chest holds, same boosters counted together", function()
		local items = views.chest_items({ coins = 60, boosters = { "stick", "riff", "stick" }, infinite_minutes = 15 })
		assert_eq(#items, 4)
		assert_eq(items[1].kind, "coins")
		assert_eq(items[1].amount, 60)
		assert_eq(items[2].id, "stick")
		assert_eq(items[2].amount, 2)
		assert_eq(items[3].id, "riff")
		assert_eq(items[4].kind, "infinite")
		assert_same(views.chest_items(nil), {})
		assert_eq(#views.chest_items({ coins = 0, boosters = {} }), 0)
	end)

	it("describes an unlock gift with its size from the config", function()
		local g = views.gift("riff", config)
		assert_eq(g.count, 3)
		assert_eq(g.icon, "specials/riff")
		assert_eq(views.gift("nope", config).count, 0)
	end)

	it("lists the jukebox by genre: a tab per district, its theme first, then its songs", function()
		local m = H.new()
		local by_id = {}
		for _, d in ipairs(H.districts().districts) do by_id[d.id] = d end
		local vm = views.jukebox(m, by_id)
		-- a tab per district: the fifteen of Part 1, then those of Part 2 in the order of content/districts.json
		local all = H.districts().districts
		assert_eq(#vm.tabs, #all)
		assert_eq(vm.chosen, nil)
		local ids = {}
		for i, tab in ipairs(vm.tabs) do ids[i] = tab.id end
		local part1 = {}
		for i = 1, 15 do part1[i] = ids[i] end
		assert_same(part1, { "cafe", "jazz", "square", "stadium", "garage", "beach", "carnival", "cinema", "bazaar", "skyclub",
			"block", "island", "ranch", "bluesclub", "arcade" })
		for i = 16, #all do
			assert_eq(ids[i], all[i].id)
			assert_eq(vm.tabs[i].state, "locked", all[i].id .. " is open at the start")
			assert_eq(vm.tabs[i].count, 1 + #all[i].songs, all[i].id .. ": its theme and its songs")
		end
		assert_eq(ids[16], "midnight_cafe")
		assert_same(vm.tabs[16].genre, { en = "Night Lo-fi", ru = "Ночной лоу-фай", ko = "나이트 로파이" })
		assert_same(vm.tabs[17].genre, { en = "Cool Jazz", ru = "Кул-джаз", ko = "쿨 재즈" })
		assert_same(vm.tabs[18].genre, { en = "World Parade", ru = "Парад наций", ko = "월드 퍼레이드" })
		-- (district 19: the tab is 130 px wide; "K-pop: баллада и данс" was drawn at 10 px, and a plain "K-pop" would read
		-- like the tab of the K-pop stadium)
		assert_same(vm.tabs[19].genre, { en = "K-pop Lite", ru = "К-поп лайт", ko = "발라드와 댄스" })
		for _, lang in ipairs({ "en", "ru", "ko" }) do
			local seen = {}
			for i = 1, #all do
				local name = vm.tabs[i].genre[lang]
				assert_true(seen[name] == nil, lang .. ": the tabs of " .. tostring(seen[name]) .. " and " .. vm.tabs[i].id .. " are both named '" .. name .. "'")
				seen[name] = vm.tabs[i].id
			end
		end
		local night = {}
		for i, r in ipairs(vm.songs.midnight_cafe) do night[i] = r.id end
		assert_same(night, { "midnight_cafe", "night_tram", "neon_puddles", "three_am_tea", "rooftop_stars" })
		-- the district being built: its genre is open, the rest are dark
		assert_eq(vm.tabs[1].state, "current")
		assert_eq(vm.tabs[2].state, "locked")
		assert_eq(vm.tabs[5].state, "locked")
		assert_eq(vm.tabs[6].state, "locked")
		assert_eq(vm.tabs[6].count, 5, "the sixth district has its theme and four songs too")
		assert_eq(vm.tabs[7].state, "locked")
		assert_eq(vm.tabs[7].count, 5, "and so has the seventh")
		assert_same(vm.tabs[7].genre, { en = "Salsa", ru = "Сальса", ko = "살사" })
		local carnival = {}
		for i, r in ipairs(vm.songs.carnival) do carnival[i] = r.id end
		assert_same(carnival, { "carnival", "salsa_confetti", "moonlit_cumbia", "candlelight_bolero", "mambo_fireworks" })
		assert_eq(vm.tabs[8].state, "locked")
		assert_eq(vm.tabs[8].count, 5, "and the eighth")
		assert_same(vm.tabs[8].genre, { en = "Soundtrack", ru = "Саундтрек", ko = "사운드트랙" })
		local cinema = {}
		for i, r in ipairs(vm.songs.cinema) do cinema[i] = r.id end
		assert_same(cinema, { "cinema", "adventure_overture", "balcony_waltz", "popcorn_chase", "closing_credits" })
		assert_eq(vm.tabs[9].state, "locked")
		assert_eq(vm.tabs[9].count, 5, "and the ninth")
		assert_same(vm.tabs[9].genre, { en = "Eastern Tales", ru = "Восточные сказки", ko = "동방 이야기" })
		local bazaar = {}
		for i, r in ipairs(vm.songs.bazaar) do bazaar[i] = r.id end
		assert_same(bazaar, { "bazaar", "spice_market_dance", "caravan_bells", "desert_starlight", "wedding_drums" })
		assert_eq(vm.tabs[10].state, "locked")
		assert_eq(vm.tabs[10].count, 5, "and the tenth")
		assert_same(vm.tabs[10].genre, { en = "Club Night", ru = "Клубная ночь", ko = "클럽 나이트" })
		local skyclub = {}
		for i, r in ipairs(vm.songs.skyclub) do skyclub[i] = r.id end
		assert_same(skyclub, { "skyclub", "rooftop_sunrise", "cloud_bounce", "mirrorball_groove", "afterglow_lounge" })
		assert_eq(vm.tabs[11].state, "locked")
		assert_eq(vm.tabs[11].count, 5, "and the eleventh")
		assert_same(vm.tabs[11].genre, { en = "Boom Bap", ru = "Бум-бэп", ko = "붐뱁" })
		local block = {}
		for i, r in ipairs(vm.songs.block) do block[i] = r.id end
		assert_same(block, { "block", "block_party_jam", "stoop_sunset", "hopscotch_bounce", "we_made_it" })
		assert_eq(vm.tabs[12].state, "locked")
		assert_eq(vm.tabs[12].count, 5, "and the twelfth")
		assert_same(vm.tabs[12].genre, { en = "Island Riddim", ru = "Ритмы острова", ko = "아일랜드 리듬" })
		local island = {}
		for i, r in ipairs(vm.songs.island) do island[i] = r.id end
		assert_same(island, { "island", "sunny_side_ska", "palm_shade_sway", "echo_cove_dub", "steelpan_parade" })
		assert_eq(vm.tabs[13].state, "locked")
		assert_eq(vm.tabs[13].count, 5, "and the thirteenth")
		assert_same(vm.tabs[13].genre, { en = "Hoedown", ru = "Хоудаун", ko = "호다운" })
		local ranch = {}
		for i, r in ipairs(vm.songs.ranch) do ranch[i] = r.id end
		assert_same(ranch, { "ranch", "haystack_breakdown", "campfire_waltz", "tumbleweed_swing", "barn_piano_romp" })
		assert_eq(vm.tabs[14].state, "locked")
		assert_eq(vm.tabs[14].count, 5, "and the fourteenth")
		assert_same(vm.tabs[14].genre, { en = "Evening Blues", ru = "Вечерний блюз", ko = "이브닝 블루스" })
		local bluesclub = {}
		for i, r in ipairs(vm.songs.bluesclub) do bluesclub[i] = r.id end
		assert_same(bluesclub, { "bluesclub", "riverside_jump", "lamplight_piano", "paddle_wheel_shuffle", "lantern_stroll" })
		assert_eq(vm.tabs[15].state, "locked")
		assert_eq(vm.tabs[15].count, 5, "and the fifteenth")
		assert_same(vm.tabs[15].genre, { en = "8-Bit", ru = "8 бит", ko = "8비트" })
		local arcade = {}
		for i, r in ipairs(vm.songs.arcade) do arcade[i] = r.id end
		assert_same(arcade, { "arcade", "hero_overworld_march", "bubble_level_waltz", "boss_rush_blitz", "try_again_lullaby" })
		assert_same(vm.tabs[1].genre, { en = "Lo-fi", ru = "Лоу-фай", ko = "로파이" })
		assert_eq(vm.tabs[1].color, views.district_color(1))
		-- every district has a tab colour of its own (the list is as long as the town)
		assert_eq(#views.DISTRICT_COLORS, #vm.tabs)
		local colors = {}
		for i, tab in ipairs(vm.tabs) do
			assert_eq(tab.color, views.DISTRICT_COLORS[i])
			assert_true(string.match(tab.color, "^#%x%x%x%x%x%x$") ~= nil, tab.id .. " colour " .. tostring(tab.color))
			assert_true(colors[tab.color] == nil, tab.id .. " shares its colour with " .. tostring(colors[tab.color]))
			colors[tab.color] = tab.id
		end
		assert_eq(vm.tabs[6].color, "#4FD1C5", "the beach is turquoise")
		assert_eq(vm.tabs[7].color, "#FF8A5C", "the carnival is orange-red")
		assert_eq(vm.tabs[8].color, "#E0566F", "the cinema is velvet red")
		assert_eq(vm.tabs[9].color, "#2F9FB0", "the bazaar is peacock teal")
		assert_eq(vm.tabs[10].color, "#A65CF2", "the sky club is neon violet")
		assert_eq(vm.tabs[11].color, "#F2741D", "the hip-hop block is spray-can orange")
		assert_eq(vm.tabs[12].color, "#6FBF3A", "the reggae island is palm-leaf green")
		assert_eq(vm.tabs[13].color, "#B23A2E", "the country ranch is barn red")
		assert_eq(vm.tabs[14].color, "#2E5FB8", "the blues club is deep river blue")
		assert_eq(vm.tabs[15].color, "#F02FC2", "the pixel arcade is neon magenta")
		assert_eq(vm.tabs[16].color, "#4B3FA6", "the night café is midnight indigo")
		for _, group in pairs(views.GROUP_COLORS) do
			assert_true(group ~= vm.tabs[16].color, "the night café shares its colour with a genre group")
			assert_true(group ~= vm.tabs[8].color, "the cinema shares its colour with a genre group")
			assert_true(group ~= vm.tabs[9].color, "the bazaar shares its colour with a genre group")
			assert_true(group ~= vm.tabs[10].color, "the sky club shares its colour with a genre group")
			assert_true(group ~= vm.tabs[11].color, "the hip-hop block shares its colour with a genre group")
			assert_true(group ~= vm.tabs[12].color, "the reggae island shares its colour with a genre group")
			assert_true(group ~= vm.tabs[13].color, "the country ranch shares its colour with a genre group")
			assert_true(group ~= vm.tabs[14].color, "the blues club shares its colour with a genre group")
			assert_true(group ~= vm.tabs[15].color, "the pixel arcade shares its colour with a genre group")
		end
		assert_eq(vm.tabs[2].prev_name.en, "Lo-fi Café", "what opens the jazz genre")
		assert_eq(vm.tabs[1].count, 5, "the theme and four songs")
		assert_false(vm.tabs[1].playing)
		-- the theme of the district is the first row, with its layers
		local rows = vm.songs.cafe
		assert_eq(#rows, 5)
		assert_true(rows[1].theme)
		assert_eq(rows[1].id, "cafe")
		assert_eq(rows[1].name.en, "Lo-fi Café")
		assert_eq(rows[1].bpm, 90)
		assert_false(rows[1].playable, "nothing built yet: no layer to hear")
		assert_eq(rows[1].total, 6)
		-- the songs of an open genre are playable at once, in the file order, with their own tempo
		assert_false(rows[2].theme)
		assert_eq(rows[2].id, "rainy_window")
		assert_eq(rows[2].index, 2)
		assert_eq(rows[2].bpm, 72)
		assert_true(rows[2].playable)
		assert_eq(rows[2].state, "current")
		-- a locked genre keeps its rows as dark silhouettes: nothing plays
		for _, r in ipairs(vm.songs.jazz) do
			assert_eq(r.state, "locked")
			assert_false(r.playable, r.id)
			assert_eq(r.prev_name.en, "Lo-fi Café")
		end
		assert_eq(#vm.songs.jazz, 5)
		-- the first task builds the first layer: the theme can be played
		H.win(m, T)
		local task = m:next_task()
		assert_true(m:complete_task(task.district, task.id))
		vm = views.jukebox(m, by_id)
		assert_true(vm.songs.cafe[1].playable)
		assert_eq(vm.songs.cafe[1].stems, 1)
	end)

	it("opens a genre with its district and marks the row and the tab of the pick", function()
		local m = H.new()
		local by_id = {}
		for _, d in ipairs(H.districts().districts) do by_id[d.id] = d end
		for _, d in ipairs(m:districts()) do
			if d.id == "cafe" then
				for _, task in ipairs(d.tasks) do
					H.give(m, "stars", task.cost)
					assert_true(m:complete_task("cafe", task.id))
				end
			end
		end
		local vm = views.jukebox(m, by_id)
		assert_eq(vm.tabs[1].state, "complete")
		assert_eq(vm.tabs[2].state, "current")
		assert_eq(vm.songs.cafe[1].state, "complete")
		assert_true(vm.songs.cafe[1].playable, "a finished district plays its full song")
		assert_true(vm.songs.jazz[2].playable, "every song of the genre being built plays at once")
		assert_false(vm.songs.jazz[1].playable, "its theme has no layer yet")
		assert_eq(vm.songs.jazz[2].stems, 0)
		assert_eq(vm.songs.square[1].state, "locked")
		-- the pick
		assert_true(m:set_song("scat_parade"))
		vm = views.jukebox(m, by_id)
		assert_eq(vm.chosen, "scat_parade")
		assert_true(vm.tabs[2].playing)
		assert_false(vm.tabs[1].playing)
		local playing = {}
		for _, tab in ipairs(vm.tabs) do
			for _, r in ipairs(vm.songs[tab.id]) do
				if r.playing then playing[#playing + 1] = r.id end
			end
		end
		assert_same(playing, { "scat_parade" })
		-- the theme of a district can be the pick too
		assert_true(m:set_song("cafe"))
		vm = views.jukebox(m, by_id)
		assert_true(vm.songs.cafe[1].playing)
		assert_true(vm.tabs[1].playing)
		-- without the catalogue of the content the genre is the district (a content without songs still shows its themes)
		local bare = views.jukebox(H.new(), nil)
		assert_eq(#bare.songs.cafe, 1)
		assert_eq(bare.tabs[1].genre.en, "Lo-fi Café")
	end)

	it("says what the card above the level button shows for the district on display", function()
		local m = H.new()
		local cv = views.card(m, "cafe")
		assert_eq(cv.kind, "task")
		assert_eq(cv.task.id, "turntable")
		-- the district being built is cafe: nothing else is open, so jazz is not browsable yet
		assert_eq(views.card(m, "jazz").kind, "back")
		assert_eq(views.card(m, "jazz").district, "cafe")
		assert_eq(views.card(m, "jazz").dir, -1, "the café being built lies before the jazz bar on display")
		-- a finished town has only the closing card, whatever is on display
		for _, d in ipairs(m:districts()) do
			local dd = m:district(d.id)
			H.give(m, "stars", 100)
			for _, t in ipairs(dd.tasks) do assert_true(m:complete_task(d.id, t.id)) end
		end
		assert_eq(views.card(m, "garage").kind, "done")
		assert_eq(views.card(m, "cafe").kind, "done")
	end)

	-- The card leads to the district being built. It lies after the district on display when the player looks at a finished
	-- one (the usual case, where the old words "Назад: <next district>" were wrong); after a content update that reopens an
	-- earlier district it lies before the later one the player looks at.
	it("tells which way the card to the district being built leads", function()
		local Meta = require("meta.meta")
		local m = H.new()
		H.give(m, "stars", 100)
		for _, t in ipairs(m:district("cafe").tasks) do assert_true(m:complete_task("cafe", t.id)) end
		local cv = views.card(m, "cafe")
		assert_eq(cv.kind, "back")
		assert_eq(cv.district, "jazz")
		assert_eq(cv.dir, 1, "the jazz bar lies after the café on display")
		-- a district the meta does not know (a stale id of the screen) still gets a card that leads on
		assert_eq(views.card(m, "no_such_district").dir, 1)
		-- the card of the district being built itself has no way to go
		assert_eq(views.card(m, "jazz").kind, "task")
		-- an update gives the finished café one more task: it is being built again, the jazz bar after it stays open
		local data = H.districts_copy()
		table.insert(data.districts[1].tasks, { id = "extra", name = { ru = "Ещё", en = "More", ko = "더" }, cost = 1, stem = "pad" })
		local again = Meta.load(data, m:serialize(), nil, 1, T)
		assert_eq(again:current_district(), "cafe")
		assert_true(again:district("jazz").available, "the jazz bar stays open")
		cv = views.card(again, "jazz")
		assert_eq(cv.kind, "back")
		assert_eq(cv.district, "cafe")
		assert_eq(cv.dir, -1, "the café lies before the jazz bar on display")
		assert_same(cv.name, again:district("cafe").name)
	end)

	it("lists the open districts to page through and where the district on display stands", function()
		local m = H.new()
		local b = views.browse(m, "cafe")
		assert_eq(b.count, 1)
		assert_eq(b.prev, nil)
		assert_eq(b.next, nil)
		H.give(m, "stars", 100)
		for _, t in ipairs(m:district("cafe").tasks) do assert_true(m:complete_task("cafe", t.id)) end
		b = views.browse(m, "jazz")
		assert_eq(b.count, 2)
		assert_eq(b.index, 2)
		assert_eq(b.prev, "cafe")
		assert_eq(b.next, nil)
		b = views.browse(m, "cafe")
		assert_eq(b.next, "jazz")
		assert_same(b.ids, { "cafe", "jazz" })
		assert_eq(views.browse(m, "square").index, 1) -- a locked district is not in the list: the first stands in
	end)

	it("points at the first task once, until it is built or seen", function()
		local m = H.new()
		assert_eq(views.town_hint(m, views.task(m)), nil) -- no star yet
		H.win(m, T)
		local hint = views.town_hint(m, views.task(m))
		assert_eq(hint.id, "town_first_task")
		assert_eq(hint.text.key, "tutorial.town")
		m:mark_tutorial_seen("town_first_task")
		assert_eq(views.town_hint(m, views.task(m)), nil)
		-- a town with something built needs no hint even if it was never marked
		local m2 = H.new()
		H.win(m2, T)
		H.win(m2, T)
		local t = m2:next_task()
		assert_true(m2:complete_task(t.district, t.id))
		assert_eq(views.town_hint(m2, views.task(m2)), nil)
		assert_eq(views.town_hint(m2, nil), nil)
	end)

	it("reads the regeneration rule and the time to the next life from the config", function()
		assert_eq(views.regen_minutes(config), 20)
		assert_eq(views.regen_minutes(nil), 20)
		fake_levels({})
		local m = H.new()
		H.advance_to(m, config.levels.free_up_to + 1, T)
		local later = T + 3 * 3600
		for _ = 1, 5 do H.lose(m, later) end
		local v = views.start(m, m:level_to_play(), nil, later, levels, config.levels.free_up_to)
		assert_false(v.can_start)
		assert_eq(v.why, "no_lives")
		assert_eq(v.lives, 0)
		assert_eq(v.next_life_in, config.lives.regen_seconds)
	end)

	it("reads the refill offer and the settings from the meta", function()
		local m = H.new()
		local r = views.refill(m, T)
		assert_false(r.available)
		assert_eq(r.reason, "full")
		local s = views.settings(m)
		assert_eq(s.input_mode, "swipe")
		assert_eq(s.language, "auto")
		assert_eq(#s.languages, 4)
	end)

	it("takes the booster slots, the pack order and the settings choices from the meta's config", function()
		local pre = {}
		for _, b in ipairs(config.boosters) do
			if b.kind == "pre" then pre[#pre + 1] = b.id end
		end
		assert_same(views.PRE, pre)
		assert_eq(#views.PRE, 3, "the start window lays out three slots: widen it before adding a fourth")
		local s = views.settings(H.new())
		assert_same(s.input_modes, config.input_modes)
		assert_same(s.languages, config.languages)
		local i18n = require("client.i18n")
		for _, id in ipairs(config.input_modes) do assert_true(i18n.has("settings.input_" .. id), "label of " .. id) end
		for _, id in ipairs(config.languages) do assert_true(i18n.has("settings.lang_" .. id), "label of " .. id) end
		-- the boosters of a product come in the catalogue's order
		local list = views.shop_products(iap.PRODUCTS, true)
		local starter
		for _, p in ipairs(list) do
			if p.id == "starter_pack" then starter = p end
		end
		local ids = {}
		for _, b in ipairs(starter.boosters) do ids[#ids + 1] = b.id end
		assert_same(ids, { "stick", "riff", "sub" })
	end)
end)
