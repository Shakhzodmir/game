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

-- The interpreter running the tests (the CLI tests use the same one).
function F.vm()
	return (jit and "luajit") or "lua5.1"
end

-- Runs a shell command with stderr merged into stdout; returns the output
-- and the exit code.
function F.sh(cmd)
	local out = F.capture("(" .. cmd .. ") 2>&1; echo \"[exit $?]\"")
	local code = tonumber(out:match("%[exit (%d+)%]%s*$"))
	return (out:gsub("%[exit %d+%]%s*$", "")), code
end

-- Writes `level_NNNN.json` fixture files into a directory; `extras[id]`
-- overrides keys of the level with that id. Returns the paths.
function F.write_levels(dir, ids, extras)
	local paths = {}
	for _, id in ipairs(ids) do
		local extra = { id = id, moves = 33, goals = { { type = "collect", color = "red", count = 6 } } }
		for k, v in pairs((extras or {})[id] or {}) do extra[k] = v end
		local path = string.format("%s/level_%04d.json", dir, id)
		assert(common.write_file(path, F.level_text(extra)))
		paths[#paths + 1] = path
	end
	return paths
end

return F
