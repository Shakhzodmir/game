local qa = require("client.qa_bridge")
local json = require("tools.lib.json")

describe("client.qa_bridge", function()
	it("parses commands into a name and words", function()
		local name, args = qa.parse("  goto   town  3 ")
		assert_eq(name, "goto")
		assert_same(args, { "town", "3" })
		name, args = qa.parse("")
		assert_eq(name, nil)
		assert_same(args, {})
	end)

	it("sanitizes values that JSON cannot hold", function()
		local t = { a = 0 / 0, b = math.huge, c = { 1, 2, -math.huge }, d = "x", e = print }
		t.self = t
		local out = qa.sanitize(t)
		assert_eq(type(out.a), "string")
		assert_eq(out.b, "inf")
		assert_eq(out.c[3], "-inf")
		assert_eq(out.d, "x")
		assert_eq(type(out.e), "string")
		assert_eq(out.self, "<cycle>")
		assert_true(json.encode(out) ~= nil)
	end)

	it("stays off without a JS runner", function()
		assert_false(qa.init({ enabled = true }))
		qa.update() -- no-op
	end)

	it("reads a command, runs it and writes the state as JSON", function()
		local window = { __glowCmd = "goto town" }
		local visited
		local function run_js(code)
			if code == qa.READ_JS then
				local c = window.__glowCmd
				window.__glowCmd = nil
				return c or ""
			end
			local body = string.match(code, "^window%.__glowState=(.*);$")
			window.__glowState = json.decode(body)
			return ""
		end
		assert_true(qa.init({
			enabled = true,
			run_js = run_js,
			encode = json.encode,
			snapshot = function() return { screen = visited or "splash" } end,
			handlers = {
				["goto"] = function(args) visited = args[1] return { ok = true, screen = args[1] } end,
				boom = function() error("kaputt") end,
			},
		}))
		qa.update()
		assert_eq(window.__glowState.seq, 1)
		assert_eq(window.__glowState.cmd, "goto town")
		assert_true(window.__glowState.result.ok)
		assert_eq(window.__glowState.app.screen, "town")
		qa.update() -- no new command: seq stays
		assert_eq(window.__glowState.seq, 1)
		window.__glowCmd = "boom"
		qa.update()
		assert_false(window.__glowState.result.ok)
		assert_true(string.find(window.__glowState.result.error, "kaputt", 1, true) ~= nil)
		window.__glowCmd = "swap 1 2 1 3"
		qa.update()
		assert_true(string.find(window.__glowState.result.error, "not_implemented", 1, true) ~= nil)
		window.__glowCmd = "fly"
		qa.update()
		assert_true(string.find(window.__glowState.result.error, "unknown command", 1, true) ~= nil)
		qa.record_error("main/app.script:1: oops")
		qa.update()
		assert_eq(window.__glowState.errors[1], "main/app.script:1: oops")
	end)
end)
