local refs = require("tools.check_refs")

-- The linter (tools/check_refs.lua) reads every source of the client and cross-checks the references the unit
-- tests cannot see: requires, image ids, sounds, i18n keys, bus topics, messages between scripts and the paths
-- in Defold files. The first test runs it on the repository; the others feed it small synthetic repositories to
-- prove that each rule fires.

local function report(problems)
	local lines = {}
	for i, p in ipairs(problems) do
		if i > 40 then
			lines[#lines + 1] = "... and " .. (#problems - 40) .. " more"
			break
		end
		lines[#lines + 1] = refs.format(p)
	end
	return "\n" .. table.concat(lines, "\n")
end

-- problems of a synthetic repository: files = {path = text}, only = {check letters}
local function lint(files, data, only)
	files["game.project"] = files["game.project"] or "[project]\ntitle = T\n"
	local problems = refs.run({ files = files, data = data or {}, only = only })
	return problems
end

local function messages(problems)
	local out = {}
	for _, p in ipairs(problems) do out[#out + 1] = p.check .. ": " .. p.msg end
	return table.concat(out, "\n")
end

local function has(problems, check, text)
	for _, p in ipairs(problems) do
		if p.check == check and string.find(p.msg, text, 1, true) then return true end
	end
	return false
end

describe("tools/check_refs.lua on the repository", function()
	it("finds no dangling reference", function()
		local problems = refs.run()
		assert_eq(#problems, 0, report(problems))
	end)
end)

describe("tools/check_refs.lua lexer", function()
	it("reads strings, comments and long strings with their lines", function()
		local toks = refs._lex('local a = "x\\ty" -- "no"\n--[[ "no" \n]] local b = [[l1\nl2]] c = \'q\\\'r\'\nd = 1..2')
		local strs = {}
		for _, t in ipairs(toks) do
			if t.k == "str" then strs[#strs + 1] = t.v .. "@" .. t.line end
		end
		assert_same(strs, { "x\ty@1", "l1\nl2@3", "q'r@4" })
	end)

	it("knows which tokens are inside a function", function()
		local toks = refs._lex("local x = 1\nlocal function f()\n\tfor i = 1, 2 do if i then y() end end\nend\nz()")
		local depth, fn_end = refs._structure(toks)
		local at = {}
		for i, t in ipairs(toks) do at[t.v .. "@" .. t.line] = depth[i] end
		assert_eq(at["x@1"], 0)
		assert_eq(at["y@3"], 1)
		assert_eq(at["z@5"], 0)
		local count = 0
		for _ in pairs(fn_end) do count = count + 1 end
		assert_eq(count, 1)
	end)
end)

describe("tools/check_refs.lua rules", function()
	it("a: unresolved, computed, tools/ and cyclic requires", function()
		local p = lint({
			[".defignore"] = "/tools\n/tests\n",
			["client/a.lua"] = 'local b = require("client.b")\nlocal c = require("client.nope")\nlocal j = require("tools.lib.json")\nlocal n = "x"\nlocal d = require(n)\nreturn {}',
			["client/b.lua"] = 'local a = require("client.a")\nreturn {}',
			["client/ok.lua"] = 'local function f() return require("client.a") end\nreturn {}',
			["tools/lib/json.lua"] = "return {}",
		}, {}, { "a" })
		assert_true(has(p, "a", 'no file client/nope.lua'), messages(p))
		assert_true(has(p, "a", "excluded from the bundle"), messages(p))
		assert_true(has(p, "a", "computed name"), messages(p))
		assert_true(has(p, "a", "require cycle"), messages(p))
		-- a require inside a function is not a load-time edge: client/ok.lua does not make a cycle by itself
		assert_false(has(p, "a", "client/ok.lua -> "), messages(p))
		assert_eq(#p, 4, messages(p))
	end)

	it("a: pcall(require, literal) is followed", function()
		local p = lint({ ["client/a.lua"] = 'local ok = pcall(require, "client.missing")\nreturn {}' }, {}, { "a" })
		assert_true(has(p, "a", "no file client/missing.lua"), messages(p))
	end)

	local data_b = {
		anim_families = {},
		const = { COLOR_NAME = { "red" }, SPECIAL_NAME = { "riff" }, BLOCKER_NAME = {} },
		index = {
			atlases = { game = { anims = { "white", "pieces_red", "specials_riff" } }, ui = { anims = { "white", "ui_icons_coin" } } },
			images = {
				["ui/icons/coin"] = { atlas = "ui", anim = "ui_icons_coin", w = 1, h = 1 },
				["pieces/red"] = { atlas = "game", anim = "pieces_red", w = 1, h = 1 },
			},
		},
	}

	it("b: image ids, families and animations", function()
		local p = lint({
			["gui/w.lua"] = 'local a = "ui/icons/coin"\nlocal b = "ui/icons/gone"\nlocal c = "pieces/" .. x\nlocal d = "board/" .. y\n' ..
				'sprite.play_flipbook(u, "pieces_red")\nsprite.play_flipbook(u, "pieces_gone")\nlocal e = { image = "specials_riff" }\nlocal f = "blockers_" .. z',
		}, data_b, { "b" })
		assert_true(has(p, "b", 'image id "ui/icons/gone"'), messages(p))
		assert_true(has(p, "b", 'image id family "board/"'), messages(p))
		assert_true(has(p, "b", 'atlas animation "pieces_gone"'), messages(p))
		assert_true(has(p, "b", 'animation family "blockers_"'), messages(p))
		assert_false(has(p, "b", '"ui/icons/coin"'), messages(p))
		assert_false(has(p, "b", '"pieces/"'), messages(p))
	end)

	it("b: an image the town draws needs a copy in the meta atlas", function()
		local data = {
			anim_families = {},
			const = data_b.const,
			index = {
				atlases = { game = { anims = { "white", "specials_riff", "specials_bird" } }, ui = { anims = { "white" } } },
				images = {
					["specials/riff"] = { atlas = "game", anim = "specials_riff", w = 1, h = 1, also = { "meta" } },
					["specials/bird"] = { atlas = "game", anim = "specials_bird", w = 1, h = 1 },
				},
			},
		}
		local p = lint({
			["screens/town/town.gui_script"] = 'local s = require("gui.start")',
			["gui/start.lua"] = 'local a = "specials/riff"\nlocal b = "specials/bird"',
			["gui/moves.lua"] = 'local b = "specials/bird"',
		}, data, { "b" })
		assert_true(has(p, "b", 'image "specials/bird" (atlas game) is drawn in the town'), messages(p))
		assert_eq(#p, 1, messages(p))
	end)

	local data_c = {
		const = { COLOR_NAME = { "red" }, SPECIAL_NAME = { "riff" }, BLOCKER_NAME = {} },
		index = { sounds = { sfx = { tap = "sfx_tap" }, notes = {}, music = {}, loops = {}, mixer = {} } },
		districts = { districts = {} },
	}

	it("c: sound effects, note colours, layers, districts", function()
		local p = lint({
			["assets/gen/audio.go"] = 'embedded_components {\n  id: "sfx_tap"\n}\n',
			["gui/w.lua"] = 'kit.sfx("tap")\nkit.sfx("gone")\nlocal b = { sfx = "gone2" }\nself:sfx(x == "coins" and "tap" or "gone3")\n' ..
				'audio.play_note("mauve", 1)\naudio.layer("loud", true)\naudio.music("nowhere")',
		}, data_c, { "c" })
		assert_true(has(p, "c", 'effect "gone"'), messages(p))
		assert_true(has(p, "c", 'effect "gone2"'), messages(p))
		assert_true(has(p, "c", 'effect "gone3"'), messages(p))
		assert_false(has(p, "c", '"coins"'), messages(p))
		assert_true(has(p, "c", 'colour "mauve"'), messages(p))
		assert_true(has(p, "c", 'layer "loud"'), messages(p))
		assert_true(has(p, "c", 'district "nowhere"'), messages(p))
	end)

	it("c: a registry component missing from audio.go", function()
		local p = lint({ ["assets/gen/audio.go"] = "" }, data_c, { "c" })
		assert_true(has(p, "c", 'component "sfx_tap" is not in assets/gen/audio.go'), messages(p))
	end)

	local data_d = {
		const = { COLOR_NAME = { "red" }, SPECIAL_NAME = {}, BLOCKER_NAME = {} },
		config = { boosters = { { id = "stick" } } },
		i18n = { STRINGS = {
			["common.ok"] = { en = "OK", ru = "ОК" },
			["common.half"] = { en = "half" },
			["booster.stick"] = { en = "Stick", ru = "Палочка" },
		} },
		districts = { districts = {} },
		tutorials = { ["1"] = { steps = { { text = "common.ok" }, { text = "common.nope" } } } },
	}

	it("d: keys exist with both languages, families are complete", function()
		local p = lint({
			["gui/w.lua"] = 'local a = i18n.t("common.ok")\nlocal b = i18n.t("common.gone")\nlocal c = i18n.t("booster." .. id)\n' ..
				'local d = { key = "common.ok" }\nlocal e = "zzz." .. id\nlocal f = i18n.t("common.half")',
		}, data_d, { "d" })
		assert_true(has(p, "d", 'common.half has no Russian text'), messages(p))
		assert_true(has(p, "d", 'key "common.gone"'), messages(p))
		assert_true(has(p, "d", 'key family "zzz."'), messages(p))
		assert_true(has(p, "d", 'lesson 1 step 2: key "common.nope"'), messages(p))
		assert_true(has(p, "d", 'key "booster.stick_desc" is missing'), messages(p))
		assert_false(has(p, "d", 'key family "booster."'), messages(p))
	end)

	it("e: topics need a publisher and a subscriber, handlers match their subscription, subscriptions close", function()
		local p = lint({
			["client/a.lua"] = 'bus.publish("alpha", {})\nbus.publish("lonely", {})\nbus.publish("popup_opened", {})',
			["screens/s.gui_script"] = 'function init(self)\n\tself.sub = bus.subscribe({ "alpha", "beta" }, "s")\nend\n' ..
				'local function on_bus(self, topic)\n\tif topic == "alpha" then elseif topic == "gamma" then end\nend\n',
		}, {}, { "e" })
		assert_true(has(p, "e", 'topic "lonely" is published but nobody subscribes'), messages(p))
		assert_true(has(p, "e", 'topic "beta" is subscribed but nothing publishes it'), messages(p))
		assert_true(has(p, "e", 'handler compares topic "gamma"'), messages(p))
		assert_true(has(p, "e", "without a matching sub:close()"), messages(p))
		-- the allow-list: popup_opened is published without a subscriber on purpose
		assert_false(has(p, "e", '"popup_opened" is published'), messages(p))
	end)

	it("f: a posted message needs a handler; replies; computed ids", function()
		local app = [[
local MSG_A = hash("alpha")
function on_message(self, message_id, message)
	if message_id == MSG_A then
	elseif message_id == hash("beta") then
	end
end
]]
		local p = lint({
			["main/app.script"] = app,
			["main/overlay.gui_script"] = 'function on_message(self, message_id) end',
			["client/x.lua"] = 'local APP_URL = "main:/app"\nmsg.post(APP_URL, "alpha", {})\nmsg.post("main:/app", "beta", {})\n' ..
				'msg.post("main:/app", "gamma", {})\nmsg.post("main:/app", kind, {})\nmsg.post("main:/app", "acquire_input_focus")',
		}, {}, { "f" })
		assert_true(has(p, "f", 'message "gamma" is posted to main/app.script'), messages(p))
		assert_true(has(p, "f", "computed message id"), messages(p))
		assert_false(has(p, "f", '"alpha"'), messages(p))
		assert_false(has(p, "f", '"beta"'), messages(p))
		assert_false(has(p, "f", "acquire_input_focus"), messages(p))
	end)

	it("f: a wrapper function posts the literals of its callers", function()
		local p = lint({
			["main/audio.script"] = 'local MSG = { play = hash("play") }\nfunction on_message(self, message_id)\n\tif message_id == MSG.play then end\nend',
			["client/audio.lua"] = 'local M = {}\nM.URL = "main:/audio#audio"\nlocal function post(id, message)\n\tmsg.post(M.URL, id, message or {})\nend\n' ..
				'function M.play() post("play", {}) end\nfunction M.stop() post("stop", {}) end\nreturn M',
		}, {}, { "f" })
		assert_true(has(p, "f", 'message "stop" is posted to main/audio.script'), messages(p))
		assert_false(has(p, "f", '"play"'), messages(p))
	end)

	it("g: paths in Defold files, game.project, Lua strings and emitters", function()
		local p = lint({
			[".defignore"] = "/tools\n",
			["game.project"] = "[project]\ncustom_resources = /content,/gone\n[bootstrap]\nmain_collection = /main/main.collectionc\nrender = /render/x.renderc\n",
			["main/main.collection"] = 'name: "main"\nembedded_instances {\n  data: "components {\\n"\n  "  component: \\"/main/app.script\\"\\n"\n  "  component: \\"/main/missing.gui\\"\\n"\n}',
			["main/app.script"] = 'local a = "/main/main.collection"\nlocal b = "/content/levels/level_%04d.json"',
			["content/levels/level_0001.json"] = "{}",
			["content/levels/level_0100.json"] = "{}",
			["render/x.render"] = "",
			["assets/gen/game.atlas"] = 'animations {\n  id: "fx_spark"\n}\n',
			["assets/fx_defold/x.particlefx"] = 'emitters {\n  tile_source: "/assets/gen/game.atlas"\n  animation: "fx_spark"\n}\nemitters {\n  tile_source: "/assets/gen/game.atlas"\n  animation: "fx_gone"\n}\n',
			["tools/t.lua"] = "",
			["main/other.go"] = 'component: "/tools/t.lua"\n',
		}, { index = { fonts = { body = {} }, guis = {} } }, { "g" })
		assert_true(has(p, "g", "custom_resources: /gone does not exist"), messages(p))
		assert_true(has(p, "g", "/main/missing.gui: no such file"), messages(p))
		assert_true(has(p, "g", 'emitter animation "fx_gone"'), messages(p))
		assert_true(has(p, "g", "/tools/t.lua: excluded from the bundle"), messages(p))
		assert_false(has(p, "g", "level_%04d"), messages(p)) -- the format is tried with real numbers
		assert_false(has(p, "g", "main.collectionc"), messages(p))
		assert_false(has(p, "g", "x.renderc"), messages(p))
	end)

	it("g: screens need a collection proxy and a collection; input actions must be bound", function()
		local coll = 'embedded_instances {\n  id: "screens"\n  data: "embedded_components {\\n"\n  "  id: \\"town\\"\\n"\n  "  type: \\"collectionproxy\\"\\n"\n}\n'
		local p = lint({
			["main/main.collection"] = coll,
			["input/game.input_binding"] = 'key_trigger {\n  input: KEY_ESC\n  action: "back"\n}\n',
			["screens/town/town.collection"] = "",
			["screens/a.gui_script"] = 'local TOUCH = hash("touch")\nfunction on_input(self, action_id, action)\n\tif action_id == TOUCH then end\nend',
		}, { app = { SCREENS = { "town", "level" } }, index = { fonts = {}, guis = {} } }, { "g" })
		assert_true(has(p, "g", 'screen "level" (client/app.lua SCREENS) has no collection proxy'), messages(p))
		assert_true(has(p, "g", 'collection of screen "level" does not exist'), messages(p))
		assert_true(has(p, "g", 'input action "touch" (TOUCH) is not bound'), messages(p))
		assert_false(has(p, "g", 'screen "town"'), messages(p))
	end)

	it("h: module members, method names and the meta API", function()
		local p = lint({
			["client/m.lua"] = "local M = {}\nM.a = 1\nfunction M.f() end\nfunction M:g() end\nM.x, M.y = 1, 2\nreturn M",
			["gui/w.lua"] = 'local m = require("client.m")\nm.f()\nm.zzz()\nlocal v = m.y\nm.late = 3\nlocal q = m.late\nm:g()\n' ..
				'self:g()\nself:nothing()\nlocal s = x:format()',
			["meta/meta.lua"] = "local Meta = {}\nfunction Meta:coins() end\nfunction Meta:lives(now) end\nreturn Meta",
			["client/c.lua"] = 'local a = app.meta:coins(1)\nlocal b = meta:lives()\nlocal c = meta:gone()\nlocal d = meta:lives(now)\n' ..
				'local ok = pcall(meta.lives, meta, now, 2)',
		}, {}, { "h" })
		assert_true(has(p, "h", 'm.zzz: client/m.lua has no member "zzz"'), messages(p))
		assert_true(has(p, "h", ":nothing("), messages(p))
		assert_true(has(p, "h", "meta:coins( gets 1 argument"), messages(p))
		assert_true(has(p, "h", "meta:lives( without `now`"), messages(p))
		assert_true(has(p, "h", "meta:gone( : no such method"), messages(p))
		assert_true(has(p, "h", "meta:lives( gets 2 argument"), messages(p))
		-- fine: assigned members, multiple assignment, methods, string methods
		assert_false(has(p, "h", "m.y"), messages(p))
		assert_false(has(p, "h", "m.late"), messages(p))
		assert_false(has(p, "h", ":format"), messages(p))
		assert_false(has(p, "h", ":g("), messages(p))
	end)

	it("i: engine modules exist only in their script context", function()
		local p = lint({
			["screens/a.gui_script"] = 'local k = require("client.k")\nfunction init(self) end\nfunction helper() end',
			["client/k.lua"] = 'local x = go.get_id()\nreturn {}',
			["screens/b.script"] = 'local v = require("client.v")\nlocal y = gui.get_node("n")',
			["client/v.lua"] = 'local z = sprite.play_flipbook()\nreturn {}',
			["client/shared.lua"] = 'local z = gui.get_node("x")\nreturn {}',
			["screens/c.gui_script"] = 'local s = require("client.shared")',
			["screens/d.script"] = 'local s = require("client.shared")',
		}, {}, { "i" })
		assert_true(has(p, "i", "go.get_id: the go module does not exist in a gui script"), messages(p))
		assert_true(has(p, "i", "gui.get_node: the gui module does not exist in a go script"), messages(p))
		assert_true(has(p, "i", "global function helper("), messages(p))
		assert_false(has(p, "i", "sprite.play_flipbook"), messages(p))
		local shared = 0
		for _, q in ipairs(p) do
			if q.file == "client/shared.lua" then shared = shared + 1 end
		end
		assert_eq(shared, 1, messages(p))
	end)
end)
