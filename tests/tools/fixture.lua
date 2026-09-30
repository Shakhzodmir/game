-- Shared fixtures of the tools tests (not a test file itself).

local common = require("tools.bot.common")

local F = {}

-- Room for the JIT (see common.jit_opts): the bot tests run faster with it.
common.jit_opts()

-- JSON text of a small valid level; `extra` overrides top-level keys.
function F.level_table(extra)
	local lvl = {
		id = 901, version = 1, size = { 7, 7 }, moves = 20, difficulty = "easy",
		colors = { "red", "yellow", "green", "blue" },
		goals = { { type = "collect", color = "red", count = 12 } },
		cells = { "#######", "#######", "#######", "#######", "#######", "#######", "#######" },
	}
	for k, v in pairs(extra or {}) do lvl[k] = v end
	return lvl
end

function F.level_text(extra)
	return common.encode(F.level_table(extra), "  ") .. "\n"
end

function F.entry(extra)
	local e, errs = common.entry_from_text(F.level_text(extra), "fixture.json")
	if not e then error("fixture level rejected: " .. table.concat(errs, "; "), 2) end
	return e
end

function F.tmpdir()
	local p = io.popen("mktemp -d 2>/dev/null")
	local d = p:read("*l")
	p:close()
	assert(d and d ~= "", "mktemp -d failed")
	return d
end

function F.rmdir(d)
	if d and d:match("^/tmp/") then os.execute("rm -rf '" .. d .. "'") end
end

-- Path of an interpreter on PATH, or nil.
function F.have(vm)
	local p = io.popen("command -v " .. vm .. " 2>/dev/null")
	local path = p and p:read("*l")
	if p then p:close() end
	return path ~= nil and path ~= ""
end

function F.capture(cmd)
	local p = io.popen(cmd)
	local out = p:read("*a")
	p:close()
	return out
end

return F
