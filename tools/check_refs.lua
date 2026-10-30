-- Static reference linter for the Defold client (pure Lua 5.1 / LuaJIT).
--
-- There is no Defold build in the dev container, and the unit tests run the
-- scripts on stubs, so a wrong name in a place the tests never reach (an image
-- id in a rarely opened window, a message nobody handles, a path in a
-- collection) only shows up in the real engine. This tool reads the sources
-- and cross-checks every kind of reference:
--
--   a  require("x.y") resolves to x/y.lua; runtime code never requires tools/
--      or tests/ (tooling that needs io / os, listed in .defignore); requires
--      are literals (bob bundles only the modules it can see); no load-time
--      require cycles
--   b  every image id ("ui/icons/coin", "pieces/" .. color, ...) is in
--      client/assets_index.lua; every atlas animation name ("blockers_wires_1",
--      "specials_" .. kind) is in its atlas; the art families the code builds
--      names from are complete; particle emitters name animations that exist;
--      images drawn by shared windows can be shown in every GUI that hosts them
--   c  every sound effect, note colour, layer and music stem used exists in the
--      registry, the registry's components exist in assets/gen/audio.go, every
--      district has all its stems; every jukebox song of content/districts.json
--      has its mix in the registry (and the other way round)
--   d  every i18n key used (i18n.t, key = "...", toast_key, tutorials.json, ...)
--      exists with both en and ru; key families built with .. are complete
--   e  every bus topic published has a subscriber (or an allow-list reason below)
--      and every subscribed topic has a publisher; a handler only compares the
--      topics its script subscribed to; every subscription is closed
--   f  every msg.post to the app / overlay / audio / render scripts names a
--      message the target's on_message handles; protocol replies are handled
--   g  every path referenced from a .gui / .collection / .go / .atlas / ... file,
--      from game.project, from the generated registry and from a Lua string
--      exists (and is not in .defignore); game.project is consistent with the
--      code (proxies, input actions, component ids)
--   h  module.member of a required module exists; obj:method( is defined somewhere
--      in the runtime code; meta:xxx( calls name a method of meta/meta.lua with at
--      most as many arguments as it takes and always with `now` where it wants one
--   i  Defold script contexts: a module shared by scripts does not touch an engine
--      module its context lacks (gui.* outside GUI scripts, go.* / sprite.* / ...
--      outside game object scripts); a script defines only the engine callbacks
--      as global functions
--
--   lua5.1 tools/check_refs.lua [--quiet] [--unused]       (from the repository root)
--     --quiet    print nothing when everything is fine
--     --unused   also list the i18n keys no source names (dead strings)
--
-- Exit status 1 when anything is wrong. tests/client/refs_test.lua runs it with
-- the test suite; M.run() returns the problems for it.

local M = {}

---------------------------------------------------------------------------------------------------
-- configuration: the knowledge the linter cannot read out of the sources
---------------------------------------------------------------------------------------------------

-- Lua that ships in the bundle (everything else is tooling or tests).
M.RUNTIME_DIRS = { "client", "screens", "gui", "main", "render", "core", "meta" }
-- The client proper: GUI scripts, windows, game object scripts.
M.CLIENT_DIRS = { "client", "screens", "gui", "main", "render" }

-- Bus topics that are published and (today) read by nobody, with the reason.
M.TOPICS_WITHOUT_SUBSCRIBER = {
	popup_opened = "observers only: QA reads app.ui.popup; no game code reacts to the opening",
	popup_closed = "observers only: the closing result goes to params.on_close; the topic is for QA / analytics hooks",
	screen_changed = "informational: analytics logs screen_view at the same place; the overlay reacts to screen_leaving",
	modal_result = "the answer to app.modal(); its only caller today is the QA bridge `modal` command",
	level_floor = "informational: the dance-floor art follows the link view (floor_rev); kept for observers",
}
-- Topics subscribed but not published by any code (none today).
M.TOPICS_WITHOUT_PUBLISHER = {}

-- Messages the engine itself delivers or understands (never need a handler of ours).
M.ENGINE_MESSAGES = {
	acquire_input_focus = true, release_input_focus = true, enable = true, disable = true, init = true,
	async_load = true, unload = true, final = true, set_parent = true, proxy_loaded = true, proxy_unloaded = true,
}

-- Scripts a msg.post can be addressed to, by the URL string.
M.TARGETS = {
	["main:/app"] = "main/app.script",
	["main:/overlay#overlay"] = "main/overlay.gui_script",
	["main:/audio#audio"] = "main/audio.script",
	["@render:"] = "render/glow.render_script",
	["/board#board"] = "screens/level/board.script",
	["level:/board#board"] = "screens/level/board.script",
	["level:/board"] = "screens/level/board.script",
	["/board"] = "screens/level/board.script",
}

-- Replies a script sends back (the receiver gets them with msg.post(sender, name)); the dynamic post in
-- the sender cannot be followed, so the protocol is listed here and both ends are checked.
M.REPLIES = {
	{ from = "main/overlay.gui_script", to = "main/app.script", names = { "fade_out_done", "fade_in_done" },
		why = "overlay answers every fade request (main/overlay.gui_script: reply())" },
}

-- msg.post calls whose message name is computed (the script that does it, the reason, the names it can post).
M.DYNAMIC_POSTS = {
	["main/audio.script"] = { names = { "fade_out", "fade_in" }, target = "main/overlay.gui_script",
		why = "qa_fade forwards message.kind, which main/app.script sets to fade_out or fade_in" },
}

-- Families of names the code builds with `..` and the members it needs (the art / strings must have all).
-- [prefix] = { suffixes } ; a number list or a string list. "colors", "specials", "blockers" are expanded.
M.ANIM_FAMILIES = {
	["pieces_"] = "colors",
	["specials_"] = "specials",
	["blockers_balloon_"] = "colors",
	["blockers_record_box_"] = { 1, 2, 3 },
	["blockers_concrete_"] = { 1, 2 },
	["blockers_column_"] = { 1, 2, 3 },
	["blockers_wires_"] = { 1, 2 },
}

-- Lua that runs inside the town GUI scene (ui + meta atlases, no "game" atlas): an atlas image it draws must
-- be in the ui atlas or have a copy in meta. The windows the town hosts are added from town.gui_script.
M.TOWN_IMAGE_SOURCES = { "screens/town/", "gui/kit.lua", "client/views.lua", "client/fx.lua", "client/popups.lua", "client/rewards.lua" }

---------------------------------------------------------------------------------------------------
-- small helpers
---------------------------------------------------------------------------------------------------

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function shell_lines(cmd)
	local p = io.popen(cmd)
	local out = {}
	if p then
		for line in p:lines() do out[#out + 1] = line end
		p:close()
	end
	return out
end

local function starts_with(s, prefix)
	return string.sub(s, 1, #prefix) == prefix
end

local function ends_with(s, suffix)
	return suffix == "" or string.sub(s, -#suffix) == suffix
end

local function sorted_keys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	return keys
end

local function list_to_set(list)
	local set = {}
	for _, v in ipairs(list) do set[v] = true end
	return set
end

local function in_dirs(path, dirs)
	for _, d in ipairs(dirs) do
		if starts_with(path, d .. "/") then return true end
	end
	return false
end

---------------------------------------------------------------------------------------------------
-- Lua lexer
---------------------------------------------------------------------------------------------------

local ESC = { n = "\n", t = "\t", r = "\r", a = "\a", b = "\b", f = "\f", v = "\v", ["\\"] = "\\", ['"'] = '"', ["'"] = "'" }

-- Returns tokens {k = "name" | "str" | "num" | "op", v = text / decoded string, line = n}.
local function lex(src)
	local toks, n = {}, 0
	local i, line, len = 1, 1, #src
	local sub, find, match = string.sub, string.find, string.match
	local function add(k, v, ln)
		n = n + 1
		toks[n] = { k = k, v = v, line = ln }
	end
	while i <= len do
		local c = sub(src, i, i)
		if c == "\n" then
			line = line + 1
			i = i + 1
		elseif c == " " or c == "\t" or c == "\r" then
			i = i + 1
		elseif c == "-" and sub(src, i + 1, i + 1) == "-" then
			local eq = match(src, "^%-%-%[(=*)%[", i)
			if eq then
				local s, e = find(src, "]" .. eq .. "]", i, true)
				if not s then e = len end
				for _ in string.gmatch(sub(src, i, e), "\n") do line = line + 1 end
				i = e + 1
			else
				local e = find(src, "\n", i, true)
				i = e or (len + 1)
			end
		elseif c == '"' or c == "'" then
			local start_line = line
			local j, buf = i + 1, {}
			while j <= len do
				local ch = sub(src, j, j)
				if ch == "\\" then
					local nx = sub(src, j + 1, j + 1)
					if ESC[nx] then
						buf[#buf + 1] = ESC[nx]
						j = j + 2
					elseif nx == "\n" then
						buf[#buf + 1] = "\n"
						line = line + 1
						j = j + 2
					elseif match(nx, "%d") then
						local digits = match(src, "^%d%d?%d?", j + 1)
						buf[#buf + 1] = string.char(tonumber(digits) % 256)
						j = j + 1 + #digits
					else
						buf[#buf + 1] = nx
						j = j + 2
					end
				elseif ch == c then
					break
				elseif ch == "\n" then
					break -- unfinished string: the syntax check reports it
				else
					buf[#buf + 1] = ch
					j = j + 1
				end
			end
			add("str", table.concat(buf), start_line)
			i = j + 1
		elseif c == "[" and match(src, "^%[=*%[", i) then
			local eq = match(src, "^%[(=*)%[", i)
			local s, e = find(src, "]" .. eq .. "]", i, true)
			if not s then s, e = len, len end
			local body = sub(src, i + #eq + 2, s - 1)
			if sub(body, 1, 1) == "\n" then body = sub(body, 2) end
			add("str", body, line)
			for _ in string.gmatch(sub(src, i, e), "\n") do line = line + 1 end
			i = e + 1
		elseif match(c, "[%a_]") then
			local word = match(src, "^[%w_]+", i)
			add("name", word, line)
			i = i + #word
		elseif match(c, "%d") or (c == "." and match(sub(src, i + 1, i + 1), "%d")) then
			local num = match(src, "^0[xX]%x+", i) or match(src, "^%d*%.?%d*[eE][%+%-]?%d+", i) or match(src, "^%d*%.?%d*", i)
			if num == "" or not num then num = c end
			add("num", num, line)
			i = i + #num
		else
			local three = sub(src, i, i + 2)
			local two = sub(src, i, i + 1)
			if three == "..." then
				add("op", three, line)
				i = i + 3
			elseif two == ".." or two == "==" or two == "~=" or two == "<=" or two == ">=" then
				add("op", two, line)
				i = i + 2
			else
				add("op", c, line)
				i = i + 1
			end
		end
	end
	return toks
end

-- Function nesting of every token (0 = file level) and, for every `function`, the index of its `end`.
local function structure(toks)
	local depth, fn_end = {}, {}
	local stack, fdepth, want_do = {}, 0, 0
	for i = 1, #toks do
		local t = toks[i]
		depth[i] = fdepth
		if t.k == "name" then
			local v = t.v
			if v == "function" then
				stack[#stack + 1] = { "function", i }
				fdepth = fdepth + 1
			elseif v == "if" then
				stack[#stack + 1] = { "if", i }
			elseif v == "for" or v == "while" then
				stack[#stack + 1] = { v, i }
				want_do = want_do + 1
			elseif v == "do" then
				if want_do > 0 then
					want_do = want_do - 1
				else
					stack[#stack + 1] = { "do", i }
				end
			elseif v == "repeat" then
				stack[#stack + 1] = { "repeat", i }
			elseif v == "until" then
				if #stack > 0 and stack[#stack][1] == "repeat" then stack[#stack] = nil end
			elseif v == "end" then
				local top = stack[#stack]
				if top then
					stack[#stack] = nil
					if top[1] == "function" then
						fn_end[top[2]] = i
						fdepth = fdepth - 1
					end
				end
			end
		end
	end
	return depth, fn_end
end

-- Argument ranges of the call whose "(" is at index i: { {from, to}, ... } and the index of the ")".
local function call_args(toks, i)
	local args, depth, from = {}, 0, i + 1
	local j = i
	while true do
		j = j + 1
		local t = toks[j]
		if not t then return args, j end
		if t.k == "op" then
			local v = t.v
			if v == "(" or v == "{" or v == "[" then
				depth = depth + 1
			elseif v == ")" or v == "}" or v == "]" then
				if depth == 0 then
					if j > from then args[#args + 1] = { from, j - 1 } end
					return args, j
				end
				depth = depth - 1
			elseif v == "," and depth == 0 then
				args[#args + 1] = { from, j - 1 }
				from = j + 1
			end
		end
	end
end

-- The name token of the call the token at i is an argument of (the innermost unclosed "("), or nil.
function M._callee(toks, i)
	local depth = 0
	for j = i - 1, math.max(1, i - 60), -1 do
		local t = toks[j]
		if t.k == "op" then
			if t.v == ")" or t.v == "}" or t.v == "]" then
				depth = depth + 1
			elseif t.v == "(" or t.v == "{" or t.v == "[" then
				if depth == 0 then
					if t.v == "(" and toks[j - 1] and toks[j - 1].k == "name" then return toks[j - 1] end
					return nil
				end
				depth = depth - 1
			end
		end
	end
	return nil
end

local function is_op(t, v) return t ~= nil and t.k == "op" and t.v == v end
local function is_name(t, v) return t ~= nil and t.k == "name" and (v == nil or t.v == v) end

-- true when the tokens at i, i+1, ... match the pattern list: strings are names or ops, "<str>" a string token,
-- "<name>" any name, and a function(t) a predicate
local function seq(toks, i, pattern)
	for k = 1, #pattern do
		local t, p = toks[i + k - 1], pattern[k]
		if not t then return false end
		if type(p) == "function" then
			if not p(t) then return false end
		elseif p == "<str>" then
			if t.k ~= "str" then return false end
		elseif p == "<name>" then
			if t.k ~= "name" then return false end
		elseif t.v ~= p or t.k == "str" then
			return false
		end
	end
	return true
end

---------------------------------------------------------------------------------------------------
-- the repository
---------------------------------------------------------------------------------------------------

local LUA_EXT = { lua = true, script = true, gui_script = true, render_script = true }

local function ext_of(path)
	return string.match(path, "%.([%w_]+)$")
end

-- Loads the sources and the facts every check needs.
local function load_repo(opts)
	opts = opts or {}
	local repo = { files = {}, dirs = {}, sources = {}, by_path = {}, problems = {}, opts = opts }
	if opts.files then
		-- a synthetic repository (tests): path -> text
		repo.read = function(path) return opts.files[path] end
		for path in pairs(opts.files) do
			repo.files[path] = true
			local dir = string.match(path, "^(.*)/[^/]*$")
			while dir and dir ~= "" do
				repo.dirs[dir] = true
				dir = string.match(dir, "^(.*)/[^/]*$")
			end
		end
	else
		repo.read = read_file
		local prune = "\\( -path ./.git -o -path ./dist -o -path ./build -o -path ./.internal -o -path ./node_modules \\) -prune -o"
		for _, p in ipairs(shell_lines("find . " .. prune .. " -type f -print")) do
			repo.files[(string.gsub(p, "^%./", ""))] = true
		end
		for _, p in ipairs(shell_lines("find . " .. prune .. " -type d -print")) do
			repo.dirs[(string.gsub(p, "^%./", ""))] = true
		end
		if not repo.files["game.project"] then
			error("tools/check_refs.lua: run it from the repository root (game.project not found)")
		end
	end
	for _, path in ipairs(sorted_keys(repo.files)) do
		local e = ext_of(path)
		if e and LUA_EXT[e] then
			local text = repo.read(path)
			local toks = lex(text)
			local depth, fn_end = structure(toks)
			local src = {
				path = path, text = text, toks = toks, depth = depth, fn_end = fn_end,
				runtime = in_dirs(path, M.RUNTIME_DIRS),
				client = in_dirs(path, M.CLIENT_DIRS),
				is_module = e == "lua",
			}
			repo.sources[#repo.sources + 1] = src
			repo.by_path[path] = src
		end
	end
	return repo
end

local function problem(repo, check, file, line, msg)
	repo.problems[#repo.problems + 1] = { check = check, file = file or "?", line = line or 0, msg = msg }
end

-- .defignore: prefixes (the file lists absolute paths such as /tools)
local function defignore(repo)
	local text = repo.read(".defignore") or ""
	local list = {}
	for line in string.gmatch(text, "[^\r\n]+") do
		line = string.gsub(line, "^%s+", "")
		line = string.gsub(line, "%s+$", "")
		if line ~= "" and string.sub(line, 1, 1) ~= "#" then
			list[#list + 1] = (string.gsub(line, "^/", ""))
		end
	end
	return list
end

local function ignored_path(ignore, path)
	for _, p in ipairs(ignore) do
		if path == p or starts_with(path, p .. "/") then return p end
	end
	return nil
end

-- data modules, loaded with the real loader ---------------------------------------------------------

local function load_data(repo)
	if repo.opts.data then return repo.opts.data end
	package.path = "./?.lua;" .. package.path
	local data = {}
	local function try(name, key)
		local ok, mod = pcall(require, name)
		if not ok then
			problem(repo, "setup", name, 0, "cannot load: " .. tostring(mod))
			return
		end
		data[key] = mod
	end
	try("client.assets_index", "index")
	try("client.i18n", "i18n")
	try("core.const", "const")
	try("meta.config", "config")
	try("client.level_audio", "level_audio")
	try("client.app", "app")
	local json = require("tools.lib.json")
	data.json = json
	local function json_file(path)
		local text = repo.read(path)
		if not text then
			problem(repo, "setup", path, 0, "missing")
			return nil
		end
		local ok, v = pcall(json.decode, text)
		if not ok then
			problem(repo, "setup", path, 0, "invalid JSON: " .. tostring(v))
			return nil
		end
		return v
	end
	data.districts = json_file("content/districts.json")
	data.tutorials = json_file("content/tutorials.json")
	data.json_file = json_file
	return data
end

---------------------------------------------------------------------------------------------------
-- a  requires
---------------------------------------------------------------------------------------------------

local function module_file(name)
	return (string.gsub(name, "%.", "/")) .. ".lua"
end

local function check_requires(repo, data)
	local ignore = defignore(repo)
	local graph = {} -- module path -> { [module path] = line } of load-time requires among runtime modules
	for _, src in ipairs(repo.sources) do
		local toks = src.toks
		for i = 1, #toks do
			local t = toks[i]
			if t.k == "name" and t.v == "require" and not is_op(toks[i - 1], ".") and not is_op(toks[i - 1], ":") then
				local lit
				local nx = toks[i + 1]
				if is_op(nx, "(") and toks[i + 2] and toks[i + 2].k == "str" and is_op(toks[i + 3], ")") then
					lit = toks[i + 2].v
				elseif nx and nx.k == "str" then
					lit = nx.v
				elseif is_op(nx, ",") and toks[i + 2] and toks[i + 2].k == "str" and is_op(toks[i - 1], "(")
					and is_name(toks[i - 2], "pcall") then
					lit = toks[i + 2].v -- pcall(require, "x")
				end
				if not lit then
					if src.runtime and not (is_op(nx, ",") and is_op(toks[i - 1], "(")) then
						problem(repo, "a", src.path, t.line, "require with a computed name: bob bundles only modules named by a literal")
					elseif src.runtime and is_op(nx, ",") then
						problem(repo, "a", src.path, t.line, "pcall(require, <computed>): bob bundles only modules named by a literal")
					end
				else
					local file = module_file(lit)
					if not repo.files[file] then
						problem(repo, "a", src.path, t.line, "require(\"" .. lit .. "\"): no file " .. file)
					elseif src.runtime then
						local bad = ignored_path(ignore, file)
						if bad then
							problem(repo, "a", src.path, t.line, "require(\"" .. lit .. "\"): " .. file ..
								" is excluded from the bundle by .defignore (/" .. bad .. ")")
						end
						if src.is_module and repo.by_path[file] and in_dirs(file, M.RUNTIME_DIRS) and src.depth[i] == 0 then
							graph[src.path] = graph[src.path] or {}
							graph[src.path][file] = graph[src.path][file] or t.line
						end
					end
				end
			end
		end
	end
	-- load-time cycles
	local state, stack = {}, {}
	local reported = {}
	local function visit(path)
		state[path] = 1
		stack[#stack + 1] = path
		for _, dep in ipairs(sorted_keys(graph[path] or {})) do
			if state[dep] == 1 then
				local chain, from = {}, nil
				for k = 1, #stack do
					if stack[k] == dep then from = k end
					if from then chain[#chain + 1] = stack[k] end
				end
				chain[#chain + 1] = dep
				local key = table.concat(chain, ">")
				if not reported[key] then
					reported[key] = true
					problem(repo, "a", path, graph[path][dep], "load-time require cycle: " .. table.concat(chain, " -> "))
				end
			elseif not state[dep] then
				visit(dep)
			end
		end
		stack[#stack] = nil
		state[path] = 2
	end
	for _, path in ipairs(sorted_keys(graph)) do
		if not state[path] then visit(path) end
	end
end

---------------------------------------------------------------------------------------------------
-- b  images and atlas animations
---------------------------------------------------------------------------------------------------

local IMAGE_ROOTS = list_to_set({ "ui", "pieces", "specials", "blockers", "board", "fx", "districts", "backgrounds", "bit", "logo" })
local ANIM_ROOTS = list_to_set({ "ui", "pieces", "specials", "blockers", "board", "fx" })

local function names_of(kind, data)
	if kind == "colors" then return data.const.COLOR_NAME end
	if kind == "specials" then return data.const.SPECIAL_NAME end
	if kind == "blockers" then return data.const.BLOCKER_NAME end
	return kind
end

-- the sources that draw images: the client, not the registry itself and not the strings
local function image_sources(repo)
	local out = {}
	for _, src in ipairs(repo.sources) do
		if src.client and src.path ~= "client/assets_index.lua" and src.path ~= "client/i18n.lua" then out[#out + 1] = src end
	end
	return out
end

local function anim_set(index)
	local set = {}
	for name, a in pairs(index.atlases) do
		set[name] = list_to_set(a.anims)
	end
	return set
end

local function check_images(repo, data)
	local index = data.index
	if not index then return end
	local images = index.images
	local anims = anim_set(index)
	local any_anim = {}
	for _, a in pairs(anims) do
		for name in pairs(a) do any_anim[name] = true end
	end
	local function has_prefix(set, prefix)
		for k in pairs(set) do
			if starts_with(k, prefix) then return true end
		end
		return false
	end
	local used_prefixes = {}
	for _, src in ipairs(image_sources(repo)) do
		local toks = src.toks
		for i = 1, #toks do
			local t = toks[i]
			if t.k == "str" then
				local v = t.v
				local prev, nxt = toks[i - 1], toks[i + 1]
				local after_concat = is_op(prev, "..")
				local before_concat = is_op(nxt, "..")
				local root = string.match(v, "^([a-z]+)/[%w_/]*$")
				if root and IMAGE_ROOTS[root] and not after_concat then
					if before_concat then
						used_prefixes[v] = true
						if not has_prefix(images, v) then
							problem(repo, "b", src.path, t.line, "image id family \"" .. v .. "\" .. ...: no image starts with it")
						end
					elseif not images[v] then
						problem(repo, "b", src.path, t.line, "image id \"" .. v .. "\" is not in client/assets_index.lua")
					end
				end
				local aroot = string.match(v, "^([a-z]+)_[%w_]*$")
				if aroot and ANIM_ROOTS[aroot] and not after_concat and not (is_op(prev, "[") and is_op(nxt, "]")) then
					if before_concat then
						if not has_prefix(any_anim, v) then
							problem(repo, "b", src.path, t.line, "animation family \"" .. v .. "\" .. ...: no atlas animation starts with it")
						end
					elseif not any_anim[v] then
						-- plain words that merely look like an animation (ui_root, ids, ...) are not flipbook names:
						-- only report names handed to a flipbook call or an image / carry / anim field
						local callee = M._callee(toks, i)
						local cond = callee ~= nil and (callee.v == "play_flipbook" or callee.v == "ah" or callee.v == "hash")
						local field = is_op(prev, "=") and is_name(toks[i - 2]) and (toks[i - 2].v == "image" or toks[i - 2].v == "carry" or toks[i - 2].v == "anim")
						if cond or field then
							problem(repo, "b", src.path, t.line, "atlas animation \"" .. v .. "\" does not exist")
						end
					end
				end
			end
		end
	end
	-- the art families the code builds names from are complete
	for prefix, what in pairs(data.anim_families or M.ANIM_FAMILIES) do
		for _, suffix in ipairs(names_of(what, data)) do
			local name = prefix .. suffix
			if not any_anim[name] then
				problem(repo, "b", "client/assets_index.lua", 0, "animation \"" .. name .. "\" is missing (the code builds \"" .. prefix .. "\" .. <" ..
					(type(what) == "string" and what or "n") .. ">)")
			end
		end
	end
	-- the town GUI has the ui and meta atlases, not the 8 MB game atlas: what the town (and the windows it hosts)
	-- draws must be in ui or have a copy in meta, or the image is silently missing there
	local town_only = {}
	local town = repo.by_path["screens/town/town.gui_script"]
	if town then
		local tt = town.toks
		for i = 1, #tt do
			if is_name(tt[i], "require") and is_op(tt[i + 1], "(") and tt[i + 2] and tt[i + 2].k == "str" and starts_with(tt[i + 2].v, "gui.") then
				town_only[(string.gsub(tt[i + 2].v, "%.", "/")) .. ".lua"] = true
			end
		end
	end
	for _, src in ipairs(image_sources(repo)) do
		local in_town = town_only[src.path]
		for _, p in ipairs(M.TOWN_IMAGE_SOURCES) do
			if src.path == p or (ends_with(p, "/") and starts_with(src.path, p)) then in_town = true end
		end
		if in_town then
			local toks = src.toks
			for i = 1, #toks do
				local t = toks[i]
				if t.k == "str" and not is_op(toks[i - 1], "..") and not is_op(toks[i + 1], "..") then
					local e = images[t.v]
					if e and e.atlas and e.atlas ~= "ui" then
						local ok = false
						for _, a in ipairs(e.also or {}) do
							if a == "meta" then ok = true end
						end
						if not ok then
							problem(repo, "b", src.path, t.line, "image \"" .. t.v .. "\" (atlas " .. e.atlas ..
								") is drawn in the town, whose GUI has no such atlas, and has no copy in the meta atlas")
						end
					end
				end
			end
		end
	end
	-- the registry itself: files exist and are served as custom resources
	local custom = {}
	for _, d in ipairs(M.custom_resources(repo)) do custom[#custom + 1] = d end
	for key, e in pairs(images) do
		if e.file then
			local path = string.gsub(e.file, "^/", "")
			if not repo.files[path] then
				problem(repo, "b", "client/assets_index.lua", 0, "image \"" .. key .. "\": " .. e.file .. " does not exist")
			end
			local covered = false
			for _, d in ipairs(custom) do
				if starts_with(e.file, d .. "/") or e.file == d then covered = true end
			end
			if not covered then
				problem(repo, "b", "client/assets_index.lua", 0, "image \"" .. key .. "\": " .. e.file ..
					" is not under project.custom_resources of game.project (sys.load_resource would fail)")
			end
		end
	end
	-- district art: backgrounds and every task's object (day picture; the ghost is optional art)
	for _, d in ipairs((data.districts and data.districts.districts) or {}) do
		if not images["districts/" .. d.id .. "/bg"] then
			problem(repo, "b", "content/districts.json", 0, "district " .. d.id .. ": no image districts/" .. d.id .. "/bg")
		end
		if not images["districts/" .. d.id .. "/bg_concert"] then
			problem(repo, "b", "content/districts.json", 0, "district " .. d.id .. ": no image districts/" .. d.id .. "/bg_concert")
		end
		for _, task in ipairs(d.tasks or {}) do
			if not images["districts/" .. d.id .. "/" .. task.id] then
				problem(repo, "b", "content/districts.json", 0, "district " .. d.id .. " task " .. task.id ..
					": no image districts/" .. d.id .. "/" .. task.id)
			end
			if not images["districts/" .. d.id .. "/" .. task.id .. "_ghost"] then
				problem(repo, "b", "content/districts.json", 0, "district " .. d.id .. " task " .. task.id ..
					": no image districts/" .. d.id .. "/" .. task.id .. "_ghost (the town would grey the colour one with a shader)")
			end
		end
	end
	return used_prefixes
end

---------------------------------------------------------------------------------------------------
-- c  sounds
---------------------------------------------------------------------------------------------------

local function check_sounds(repo, data)
	local index = data.index
	if not index then return end
	local snd = index.sounds
	local colors = list_to_set(data.const.COLOR_NAME)
	-- the registry's components exist in the generated audio game object
	local audio_go = repo.read("assets/gen/audio.go") or ""
	local components = {}
	for id in string.gmatch(audio_go, '\n%s*id: "([%w_]+)"') do components[id] = true end
	local function component(kind, key, id)
		if not components[id] then
			problem(repo, "c", "client/assets_index.lua", 0, kind .. " \"" .. key .. "\": component \"" .. id .. "\" is not in assets/gen/audio.go")
		end
	end
	for name, id in pairs(snd.sfx) do component("sfx", name, id) end
	for color, steps in pairs(snd.notes) do
		for n, id in pairs(steps) do component("note", color .. "/" .. tostring(n), id) end
	end
	for district, stems in pairs(snd.music) do
		for stem, id in pairs(stems) do component("music", district .. "/" .. stem, id) end
	end
	local song_assets = snd.songs or {}
	for song, entry in pairs(song_assets) do component("song", song, entry.id) end
	-- usage in the code
	local function check_sfx_name(src, line, name)
		if not snd.sfx[name] then
			problem(repo, "c", src.path, line, "sound effect \"" .. name .. "\" is not in the sound registry")
		end
	end
	for _, src in ipairs(repo.sources) do
		if src.client and src.path ~= "client/assets_index.lua" then
			local toks = src.toks
			for i = 1, #toks do
				local t = toks[i]
				if t.k == "name" and t.v == "sfx" then
					if is_op(toks[i + 1], "(") and (is_op(toks[i - 1], ":") or is_op(toks[i - 1], ".")) and not is_name(toks[i - 2], "function") then
						-- audio.sfx("x"), kit.sfx("x"), self:sfx("x", ...): every literal of the first argument
						local args = call_args(toks, i + 1)
						local a = args[1]
						if a then
							for k = a[1], a[2] do
								local s = toks[k]
								local cmp = is_op(toks[k - 1], "==") or is_op(toks[k - 1], "~=") or is_op(toks[k + 1], "==")
									or is_op(toks[k + 1], "~=") or is_op(toks[k - 1], "[")
								if s.k == "str" and string.match(s.v, "^[a-z_0-9]+$") and not cmp and not is_op(toks[k + 1], "..") then
									check_sfx_name(src, s.line, s.v)
								end
								-- "praise_" .. n: a family
								if s.k == "str" and is_op(toks[k + 1], "..") and string.match(s.v, "^[a-z_0-9]+_$") then
									local found = false
									for name in pairs(snd.sfx) do
										if starts_with(name, s.v) then found = true end
									end
									if not found then
										problem(repo, "c", src.path, s.line, "sound effect family \"" .. s.v .. "\" .. ...: none in the registry")
									end
								end
							end
						end
					elseif is_op(toks[i + 1], "=") and toks[i + 2] and toks[i + 2].k == "str" then
						check_sfx_name(src, toks[i + 2].line, toks[i + 2].v)
					end
				elseif t.k == "name" and t.v == "play_note" and is_op(toks[i + 1], "(") then
					local args = call_args(toks, i + 1)
					local a = args[1]
					if a and a[1] == a[2] and toks[a[1]].k == "str" and not colors[toks[a[1]].v] then
						problem(repo, "c", src.path, t.line, "play_note colour \"" .. toks[a[1]].v .. "\" is not a piece colour")
					end
				elseif t.k == "name" and (t.v == "layer" or t.v == "unlock_stem" or t.v == "music") and is_op(toks[i + 1], "(")
					and is_op(toks[i - 1], ".") and is_name(toks[i - 2], "audio") then
					local args = call_args(toks, i + 1)
					if t.v == "layer" then
						local a = args[1]
						if a and a[1] == a[2] and toks[a[1]].k == "str" and toks[a[1]].v ~= "tension" and toks[a[1]].v ~= "party" then
							problem(repo, "c", src.path, t.line, "audio layer \"" .. toks[a[1]].v .. "\": only tension and party exist")
						end
					else
						local a = args[1]
						-- a district (its layered theme) or, for `music`, a jukebox song (one mix)
						if a and a[1] == a[2] and toks[a[1]].k == "str" and not snd.music[toks[a[1]].v]
							and not (t.v == "music" and song_assets[toks[a[1]].v]) then
							problem(repo, "c", src.path, t.line, "audio." .. t.v .. " district \"" .. toks[a[1]].v .. "\" has no music")
						end
					end
				end
			end
		end
	end
	-- the tables of level_audio.lua (data, not calls)
	local la = data.level_audio
	if type(la) == "table" then
		for k, v in pairs(la.SPECIAL_SFX or {}) do
			if not snd.sfx[v] then problem(repo, "c", "client/level_audio.lua", 0, "SPECIAL_SFX." .. k .. " = \"" .. v .. "\": no such effect") end
		end
		for combo, list in pairs(la.COMBO_SFX or {}) do
			for _, c in ipairs(list) do
				if not snd.sfx[c[1]] then problem(repo, "c", "client/level_audio.lua", 0, "COMBO_SFX." .. combo .. ": no effect \"" .. c[1] .. "\"") end
			end
		end
		for _, tname in ipairs({ "BLOCKER_HIT", "BLOCKER_BREAK" }) do
			for k, v in pairs(la[tname] or {}) do
				if not snd.sfx[v] then problem(repo, "c", "client/level_audio.lua", 0, tname .. "." .. k .. " = \"" .. v .. "\": no such effect") end
			end
		end
		for word, n in pairs(la.PRAISE_INDEX or {}) do
			if not snd.sfx["praise_" .. n] then problem(repo, "c", "client/level_audio.lua", 0, "PRAISE_INDEX." .. word .. ": no effect praise_" .. n) end
		end
		for kind in pairs(la.SPECIAL_SFX or {}) do
			if not list_to_set(data.const.SPECIAL_NAME)[kind] then
				problem(repo, "c", "client/level_audio.lua", 0, "SPECIAL_SFX." .. kind .. " is not a special")
			end
		end
	end
	-- every note colour has all its steps; every district has its stems, tension and party
	for _, color in ipairs(data.const.COLOR_NAME) do
		for n = 1, 11 do
			if not (snd.notes[color] and snd.notes[color][n]) then
				problem(repo, "c", "client/assets_index.lua", 0, "note " .. color .. "_" .. n .. " is missing (the pentatonic runs to step 10)")
			end
		end
	end
	for _, d in ipairs((data.districts and data.districts.districts) or {}) do
		local stems = snd.music[d.id]
		if not stems then
			problem(repo, "c", "content/districts.json", 0, "district " .. d.id .. " has no music")
		else
			for _, task in ipairs(d.tasks or {}) do
				if not stems[task.stem] then
					problem(repo, "c", "content/districts.json", 0, "district " .. d.id .. " task " .. task.id .. ": stem \"" .. task.stem .. "\" is not in the registry")
				end
			end
			for _, layer in ipairs({ "tension", "party" }) do
				if not stems[layer] then
					problem(repo, "c", "content/districts.json", 0, "district " .. d.id .. " has no \"" .. layer .. "\" stem")
				end
			end
		end
		if not snd.loops[d.id] then
			problem(repo, "c", "client/assets_index.lua", 0, "district " .. d.id .. " has no loop length (the music clock needs it)")
		end
	end
	-- the jukebox catalogue: every song listed in content/districts.json has its mix and loop length, and a mix
	-- nobody lists would sit in the memory of the page for nothing
	local listed = {}
	for _, d in ipairs((data.districts and data.districts.districts) or {}) do
		if type(d.genre) ~= "table" or not (d.genre.en and d.genre.ru) then
			problem(repo, "c", "content/districts.json", 0, "district " .. d.id .. " has no genre name (en and ru) for the jukebox")
		end
		for _, song in ipairs(d.songs or {}) do
			listed[song.id] = true
			local entry = song_assets[song.id]
			if not entry then
				problem(repo, "c", "content/districts.json", 0, "song " .. tostring(song.id) .. " (" .. d.id .. ") has no mix in the sound registry (assets/music/songs/" .. tostring(song.id) .. ".ogg)")
			elseif not (type(entry.loop) == "number" and entry.loop > 0) then
				problem(repo, "c", "client/assets_index.lua", 0, "song " .. tostring(song.id) .. " has no loop length (the music clock needs it)")
			end
			if type(song.name) ~= "table" or not (song.name.en and song.name.ru) then
				problem(repo, "c", "content/districts.json", 0, "song " .. tostring(song.id) .. " has no name (en and ru)")
			end
		end
	end
	for song in pairs(song_assets) do
		if not listed[song] then
			problem(repo, "c", "client/assets_index.lua", 0, "song " .. song .. " is in the sound registry but in no genre of content/districts.json")
		end
	end
	-- the mixer contract
	local mixer = snd.mixer or {}
	if not (mixer.notes_same_tick and mixer.notes_same_tick.max_voices) then
		problem(repo, "c", "client/assets_index.lua", 0, "sounds.mixer.notes_same_tick is missing (client/audio.lua falls back to defaults)")
	end
end

---------------------------------------------------------------------------------------------------
-- d  i18n
---------------------------------------------------------------------------------------------------

local function key_families(data)
	local const = data.const
	local fam = {}
	local booster_ids = {}
	for _, b in ipairs(data.config.boosters or {}) do booster_ids[#booster_ids + 1] = b.id end
	fam["booster."] = booster_ids
	fam["piece."] = const.COLOR_NAME
	local blockers = {}
	for _, b in ipairs(const.BLOCKER_NAME) do blockers[#blockers + 1] = b end
	blockers[#blockers + 1] = "mic"
	fam["blocker."] = blockers
	fam["praise."] = { "1", "2", "3", "4", "5" }
	local stems = {}
	for _, d in ipairs((data.districts and data.districts.districts) or {}) do
		for _, task in ipairs(d.tasks or {}) do stems[#stems + 1] = task.stem end
	end
	for _, s in ipairs((data.districts and data.districts.level_stems) or {}) do
		if type(s) == "string" then stems[#stems + 1] = s end
	end
	fam["stem."] = stems
	return fam
end

local function check_i18n(repo, data)
	local S = data.i18n and data.i18n.STRINGS
	if not S then return end
	local used = {}
	-- both languages, same shape
	for key, entry in pairs(S) do
		if entry.en == nil then problem(repo, "d", "client/i18n.lua", 0, key .. " has no English text") end
		if entry.ru == nil then problem(repo, "d", "client/i18n.lua", 0, key .. " has no Russian text") end
	end
	local namespaces = {}
	for key in pairs(S) do namespaces[string.match(key, "^([^.]+)")] = true end
	local function has_prefix(prefix)
		for key in pairs(S) do
			if starts_with(key, prefix) then return true end
		end
		return false
	end
	for _, src in ipairs(repo.sources) do
		if src.client and src.path ~= "client/i18n.lua" and src.path ~= "client/assets_index.lua" then
			local toks = src.toks
			for i = 1, #toks do
				local t = toks[i]
				if t.k == "str" then
					local v = t.v
					local ns = string.match(v, "^([a-z][a-z0-9_]*)%.[a-z0-9_%.]*$")
					if ns and not namespaces[ns] and string.match(v, "^[a-z][a-z0-9_]*%.$") and is_op(toks[i + 1], "..")
						and not is_op(toks[i - 1], "..") then
						problem(repo, "d", src.path, t.line, "i18n key family \"" .. v .. "\" .. ...: no key starts with it")
					elseif ns and namespaces[ns] and not is_op(toks[i - 1], "..") then
						if is_op(toks[i + 1], "..") then
							if not has_prefix(v) then
								problem(repo, "d", src.path, t.line, "i18n key family \"" .. v .. "\" .. ...: no key starts with it")
							end
							used[v] = true
						elseif S[v] then
							used[v] = true
						elseif string.sub(v, -1) ~= "." then
							problem(repo, "d", src.path, t.line, "i18n key \"" .. v .. "\" is not in client/i18n.lua")
						end
					end
				end
			end
		end
	end
	-- the families the code builds with ..
	local fam = key_families(data)
	for prefix, members in pairs(fam) do
		for _, m in ipairs(members) do
			local key = prefix .. m
			if not S[key] then
				problem(repo, "d", "client/i18n.lua", 0, "key \"" .. key .. "\" is missing (the code builds \"" .. prefix .. "\" .. <id>)")
			end
			used[key] = true
			if prefix == "booster." and m ~= "mic" then
				if not S[key .. "_desc"] and (m == "stick" or m == "row_light" or m == "col_light" or m == "remix" or m == "riff" or m == "sub" or m == "disco") then
					problem(repo, "d", "client/i18n.lua", 0, "key \"" .. key .. "_desc\" is missing (the shop / gift windows show it)")
				end
				used[key .. "_desc"] = true
			end
		end
	end
	-- combo titles: every combo the core can fire has a title
	local la = data.level_audio
	if la and la.COMBO_SFX then
		for combo in pairs(la.COMBO_SFX) do
			if not S["combo." .. combo] then
				problem(repo, "d", "client/i18n.lua", 0, "key \"combo." .. combo .. "\" is missing (level_fx shows it when the combo fires)")
			end
			used["combo." .. combo] = true
		end
	end
	-- the tutorials
	local steps = 0
	for id, lesson in pairs(data.tutorials or {}) do
		for n, step in ipairs((type(lesson) == "table" and lesson.steps) or {}) do
			steps = steps + 1
			if step.text then
				if not S[step.text] then
					problem(repo, "d", "content/tutorials.json", 0, "lesson " .. tostring(id) .. " step " .. n .. ": key \"" .. tostring(step.text) .. "\" is not in client/i18n.lua")
				end
				used[step.text] = true
			end
		end
	end
	repo.i18n_used = used
end

---------------------------------------------------------------------------------------------------
-- e  bus topics
---------------------------------------------------------------------------------------------------

-- Returns the string literals inside the argument range of a call at toks[from..to]
local function strings_in(toks, from, to)
	local out = {}
	for k = from, to do
		if toks[k].k == "str" then out[#out + 1] = toks[k] end
	end
	return out
end

local function check_bus(repo, data)
	local published, subscribed = {}, {}
	local per_file_subs = {} -- path -> { topics = {set}, line }
	for _, src in ipairs(repo.sources) do
		if src.client and not starts_with(src.path, "tests/") then
			local toks = src.toks
			for i = 1, #toks do
				local t = toks[i]
				if t.k == "name" and t.v == "bus" and is_op(toks[i + 1], ".") and toks[i + 2] and toks[i + 2].k == "name" and is_op(toks[i + 3], "(") then
					local what = toks[i + 2].v
					local args = call_args(toks, i + 3)
					if what == "publish" then
						local a = args[1]
						if a and a[1] == a[2] and toks[a[1]].k == "str" then
							local topic = toks[a[1]].v
							published[topic] = published[topic] or {}
							published[topic][#published[topic] + 1] = { file = src.path, line = t.line }
						elseif a then
							problem(repo, "e", src.path, t.line, "bus.publish with a computed topic cannot be checked")
						end
					elseif what == "subscribe" then
						local a = args[1]
						local entry = per_file_subs[src.path] or { topics = {}, line = t.line, all = false }
						per_file_subs[src.path] = entry
						if a then
							local lits = strings_in(toks, a[1], a[2])
							if #lits == 0 then
								entry.all = true -- nil / "*" / a variable: everything
							end
							for _, s in ipairs(lits) do
								if s.v == "*" then
									entry.all = true
								else
									entry.topics[s.v] = true
									subscribed[s.v] = subscribed[s.v] or {}
									subscribed[s.v][#subscribed[s.v] + 1] = { file = src.path, line = s.line }
								end
							end
						else
							entry.all = true
						end
					end
				end
			end
		end
	end
	for _, topic in ipairs(sorted_keys(published)) do
		if not subscribed[topic] and not M.TOPICS_WITHOUT_SUBSCRIBER[topic] then
			local at = published[topic][1]
			problem(repo, "e", at.file, at.line, "topic \"" .. topic .. "\" is published but nobody subscribes (list it in TOPICS_WITHOUT_SUBSCRIBER with a reason, or remove it)")
		end
		if subscribed[topic] and M.TOPICS_WITHOUT_SUBSCRIBER[topic] then
			problem(repo, "e", "tools/check_refs.lua", 0, "topic \"" .. topic .. "\" is on TOPICS_WITHOUT_SUBSCRIBER but has a subscriber now: remove it from the list")
		end
	end
	for _, topic in ipairs(sorted_keys(subscribed)) do
		if not published[topic] and not M.TOPICS_WITHOUT_PUBLISHER[topic] then
			local at = subscribed[topic][1]
			problem(repo, "e", at.file, at.line, "topic \"" .. topic .. "\" is subscribed but nothing publishes it")
		end
	end
	for topic in pairs(M.TOPICS_WITHOUT_SUBSCRIBER) do
		if not published[topic] then
			problem(repo, "e", "tools/check_refs.lua", 0, "topic \"" .. topic .. "\" is on TOPICS_WITHOUT_SUBSCRIBER but nothing publishes it: remove it from the list")
		end
	end
	-- a handler that compares a topic its script never subscribed to; a subscription that is never closed
	for _, src in ipairs(repo.sources) do
		local entry = per_file_subs[src.path]
		if entry and not entry.all then
			local toks = src.toks
			for i = 1, #toks do
				local t = toks[i]
				if t.k == "name" and t.v == "topic" and (is_op(toks[i + 1], "==") or is_op(toks[i + 1], "~=")) and toks[i + 2] and toks[i + 2].k == "str" then
					local topic = toks[i + 2].v
					if not entry.topics[topic] and not (src.path == "client/popups.lua") then
						problem(repo, "e", src.path, t.line, "handler compares topic \"" .. topic .. "\" but this script does not subscribe to it")
					end
				end
			end
		end
		if entry then
			local closes = false
			for i = 1, #src.toks do
				if is_name(src.toks[i], "close") and is_op(src.toks[i - 1], ":") and is_op(src.toks[i + 1], "(") then closes = true end
			end
			if not closes then
				problem(repo, "e", src.path, entry.line, "bus.subscribe without a matching sub:close() (a screen that goes away must close its subscription)")
			end
		end
	end
	-- window modules (gui/*.lua on_event) only see the topics of the screens that host them
	local hosts = { "screens/town/town.gui_script", "screens/level/level.gui_script" }
	for _, src in ipairs(repo.sources) do
		if starts_with(src.path, "gui/") and src.path ~= "gui/kit.lua" and src.path ~= "gui/level_kit.lua" then
			local toks = src.toks
			for i = 1, #toks do
				local t = toks[i]
				if t.k == "name" and t.v == "topic" and is_op(toks[i + 1], "==") and toks[i + 2] and toks[i + 2].k == "str" then
					local topic = toks[i + 2].v
					for _, h in ipairs(hosts) do
						local e = per_file_subs[h]
						if e and not e.all and not e.topics[topic] then
							problem(repo, "e", src.path, t.line, "window handles topic \"" .. topic .. "\" but its host " .. h .. " does not subscribe to it")
						end
					end
				end
			end
		end
	end
	repo.bus = { published = published, subscribed = subscribed }
end

---------------------------------------------------------------------------------------------------
-- f  messages between scripts
---------------------------------------------------------------------------------------------------

-- constants of a source: NAME = "string", NAME = hash("string"), TABLE = { field = hash("string") }
local function constants(src)
	local strs, hashes = {}, {}
	local toks = src.toks
	for i = 1, #toks do
		local t = toks[i]
		if t.k == "name" and is_op(toks[i + 1], "=") then
			local v = toks[i + 2]
			if v and v.k == "str" and not is_op(toks[i + 3], "..") then
				strs[t.v] = v.v
			elseif is_name(v, "hash") and is_op(toks[i + 3], "(") and toks[i + 4] and toks[i + 4].k == "str" then
				hashes[t.v] = toks[i + 4].v
			elseif is_op(v, "{") then
				-- table constructor: fields = hash("x")
				local depth = 0
				local j = i + 2
				while toks[j] do
					local u = toks[j]
					if is_op(u, "{") then
						depth = depth + 1
					elseif is_op(u, "}") then
						depth = depth - 1
						if depth == 0 then break end
					elseif u.k == "name" and is_op(toks[j + 1], "=") and is_name(toks[j + 2], "hash") and is_op(toks[j + 3], "(")
						and toks[j + 4] and toks[j + 4].k == "str" then
						hashes[t.v .. "." .. u.v] = toks[j + 4].v
					end
					j = j + 1
				end
			end
		end
	end
	return strs, hashes
end

-- The set of message names a script's on_message handles; nil when it has none.
local function handled_messages(src)
	local toks = src.toks
	local _, hashes = constants(src)
	local start
	for i = 1, #toks - 3 do
		if is_name(toks[i], "function") and is_name(toks[i + 1], "on_message") then
			start = i
			break
		end
	end
	if not start then return nil end
	local stop = src.fn_end[start] or #toks
	local names, unresolved = {}, 0
	for i = start, stop do
		local t = toks[i]
		if is_name(t, "message_id") and is_op(toks[i + 1], "==") then
			local a, b = toks[i + 2], toks[i + 3]
			if is_name(a, "hash") and is_op(b, "(") and toks[i + 4] and toks[i + 4].k == "str" then
				names[toks[i + 4].v] = true
			elseif a and a.k == "name" and is_op(b, ".") and toks[i + 4] and toks[i + 4].k == "name" and hashes[a.v .. "." .. toks[i + 4].v] then
				names[hashes[a.v .. "." .. toks[i + 4].v]] = true
			elseif a and a.k == "name" and hashes[a.v] then
				names[hashes[a.v]] = true
			else
				unresolved = unresolved + 1
			end
		end
	end
	return names, unresolved
end

local function check_messages(repo, data)
	-- URL constants by their last identifier
	local url_by_name = {}
	for _, src in ipairs(repo.sources) do
		if src.runtime then
			local toks = src.toks
			for i = 1, #toks - 2 do
				local t = toks[i]
				if t.k == "name" and is_op(toks[i + 1], "=") and toks[i + 2].k == "str" and not is_op(toks[i + 3], "..") then
					local v = toks[i + 2].v
					if M.TARGETS[v] and (string.match(t.v, "URL") or string.match(t.v, "OVERLAY") or string.match(t.v, "APP")) then
						url_by_name[t.v] = v
					end
				end
			end
		end
	end
	-- the message names a target script handles, computed on first use (nil: it has no on_message)
	local handlers, handler_state = {}, {}
	local function handlers_of(target)
		if handler_state[target] == nil then
			local src = repo.by_path[target]
			handler_state[target] = false
			if not src then
				problem(repo, "f", target, 0, "target script does not exist")
			else
				local names, unresolved = handled_messages(src)
				if not names then
					problem(repo, "f", target, 0, "a message is posted to this script, which has no on_message")
				else
					handler_state[target] = true
					handlers[target] = names
					if unresolved > 0 then
						problem(repo, "f", target, 0, "on_message compares " .. unresolved .. " message id(s) the linter cannot resolve to a hash(\"name\") constant")
					end
				end
			end
		end
		return handlers[target]
	end
	local posted = {} -- target -> name -> {file, line}
	-- wrapper functions: local function post(id, message) msg.post(URL, id, ...) -> the literals of post("x")
	for _, src in ipairs(repo.sources) do
		if src.runtime then
			local toks = src.toks
			for i = 1, #toks do
				if is_name(toks[i], "msg") and is_op(toks[i + 1], ".") and is_name(toks[i + 2], "post") and is_op(toks[i + 3], "(") then
					local args = call_args(toks, i + 3)
					local ra, ma = args[1], args[2]
					local target
					if ra then
						local first = toks[ra[1]]
						if ra[1] == ra[2] and first.k == "str" then
							target = first.v
						elseif first.k == "name" then
							-- NAME or a.b.NAME
							local last = toks[ra[2]]
							if last.k == "name" and url_by_name[last.v] then target = url_by_name[last.v] end
						end
					end
					local file = target and (M.TARGETS[target] or (target == "#" and src.path)) or nil
					if file then
						if not ma then
							problem(repo, "f", src.path, toks[i].line, "msg.post to " .. tostring(target) .. " without a message id")
						else
							local mt = toks[ma[1]]
							if ma[1] == ma[2] and mt.k == "str" then
								posted[file] = posted[file] or {}
								posted[file][mt.v] = posted[file][mt.v] or { file = src.path, line = toks[i].line }
							elseif ma[1] == ma[2] and mt.k == "name" then
								-- an identifier: the parameter of the enclosing local function? then follow its callers
								local fname
								for k = i, 1, -1 do
									if is_name(toks[k], "function") and src.fn_end[k] and src.fn_end[k] >= i then
										if is_name(toks[k + 1]) and is_op(toks[k + 2], "(") then
											fname = toks[k + 1].v
										elseif is_name(toks[k - 1], "=") and is_name(toks[k - 2]) then
											fname = toks[k - 2].v
										end
										break
									end
								end
								local followed = false
								if fname then
									for k = 1, #toks do
										if is_name(toks[k], fname) and is_op(toks[k + 1], "(") and not is_name(toks[k - 1], "function")
											and not is_op(toks[k - 1], ".") and not is_op(toks[k - 1], ":") then
											local a2 = call_args(toks, k + 1)[1]
											if a2 and a2[1] == a2[2] and toks[a2[1]].k == "str" then
												posted[file] = posted[file] or {}
												posted[file][toks[a2[1]].v] = posted[file][toks[a2[1]].v] or { file = src.path, line = toks[k].line }
												followed = true
											end
										end
									end
								end
								if not followed then
									local dyn = M.DYNAMIC_POSTS[src.path]
									if dyn and dyn.target == file then
										for _, name in ipairs(dyn.names) do
											posted[file] = posted[file] or {}
											posted[file][name] = posted[file][name] or { file = src.path, line = toks[i].line }
										end
									else
										problem(repo, "f", src.path, toks[i].line, "msg.post to " .. tostring(target) .. " with a computed message id (list it in DYNAMIC_POSTS)")
									end
								end
							else
								local dyn = M.DYNAMIC_POSTS[src.path]
								if dyn and dyn.target == file then
									for _, name in ipairs(dyn.names) do
										posted[file] = posted[file] or {}
										posted[file][name] = posted[file][name] or { file = src.path, line = toks[i].line }
									end
								else
									problem(repo, "f", src.path, toks[i].line, "msg.post to " .. tostring(target) .. " with a computed message id (list it in DYNAMIC_POSTS)")
								end
							end
						end
					end
				end
			end
		end
	end
	for _, file in ipairs(sorted_keys(posted)) do
		local names = posted[file]
		for _, name in ipairs(sorted_keys(names)) do
			local at = names[name]
			if not M.ENGINE_MESSAGES[name] and file ~= "render/glow.render_script" then
				local h = handlers_of(file)
				if h and not h[name] then
					problem(repo, "f", at.file, at.line, "message \"" .. name .. "\" is posted to " .. file .. ", whose on_message does not handle it")
				end
			end
		end
	end
	for _, r in ipairs(M.REPLIES) do
		local h = handlers_of(r.to) or {}
		for _, name in ipairs(r.names) do
			if not h[name] then problem(repo, "f", r.to, 0, "reply \"" .. name .. "\" from " .. r.from .. " is not handled (" .. r.why .. ")") end
			local sender = repo.by_path[r.from]
			local found = false
			if sender then
				for _, t in ipairs(sender.toks) do
					if t.k == "str" and t.v == name then found = true end
				end
			end
			if not found then problem(repo, "f", r.from, 0, "reply \"" .. name .. "\" is listed in REPLIES but never named in the sender") end
		end
	end
	-- every message the target handles is posted by someone (a dead handler is a hint of a renamed message)
	repo.messages = { posted = posted, handlers = handlers }
end

---------------------------------------------------------------------------------------------------
-- g  Defold files and game.project
---------------------------------------------------------------------------------------------------

local DEFOLD_EXT = list_to_set({ "gui", "collection", "go", "atlas", "font", "material", "particlefx", "sound", "render", "input_binding",
	"factory", "collectionfactory", "sprite", "tilesource", "tilemap", "label", "model", "texture_profiles", "display_profiles", "gamepads" })

-- game.project -> { ["section.key"] = value }
local function parse_project(repo)
	local text = repo.read("game.project") or ""
	local out, section = {}, nil
	for line in string.gmatch(text, "[^\r\n]+") do
		local s = string.match(line, "^%[([%w_]+)%]%s*$")
		if s then
			section = s
		else
			local k, v = string.match(line, "^([%w_%.%-]+)%s*=%s*(.-)%s*$")
			if k and section then out[section .. "." .. k] = v end
		end
	end
	return out
end

function M.custom_resources(repo)
	local p = parse_project(repo)
	local list = {}
	for entry in string.gmatch(p["project.custom_resources"] or "", "[^,]+") do
		entry = string.gsub(entry, "^%s+", "")
		entry = string.gsub(entry, "%s+$", "")
		list[#list + 1] = entry
	end
	return list
end

local function resource_exists(repo, path)
	local p = string.gsub(path, "^/", "")
	return repo.files[p] or repo.dirs[p]
end

-- atlas file -> set of animation ids
local function atlas_anims(repo, path)
	local text = repo.read(path)
	if not text then return nil end
	local set = {}
	for id in string.gmatch(text, 'animations%s*{%s*id:%s*"([^"]+)"') do set[id] = true end
	return set
end

-- ids of the components of a .go / .collection (embedded and referenced)
local function component_ids(text)
	local ids = {}
	for id in string.gmatch(text, 'id: \\?"([%w_]+)\\?"') do ids[id] = true end
	return ids
end

local function check_defold_files(repo, data)
	local ignore = defignore(repo)
	local function check_path(file, line, path, how)
		if starts_with(path, "/builtins/") then return end
		if not resource_exists(repo, path) then
			problem(repo, "g", file, line, how .. " " .. path .. ": no such file")
			return
		end
		local bad = ignored_path(ignore, (string.gsub(path, "^/", "")))
		if bad then
			problem(repo, "g", file, line, how .. " " .. path .. ": excluded from the bundle by .defignore (/" .. bad .. ")")
		end
	end
	-- Defold text-proto files: every absolute path
	for _, path in ipairs(sorted_keys(repo.files)) do
		local e = ext_of(path)
		if e and DEFOLD_EXT[e] and not starts_with(path, "tests/") and not starts_with(path, "docs/") then
			local text = repo.read(path) or ""
			local line_no = 0
			for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
				line_no = line_no + 1
				for q, p in string.gmatch(line, '(\\?")(/[%w_%./%-]*)') do
					if string.match(p, "%.[%w_]+$") then check_path(path, line_no, p, "references") end
				end
			end
		end
	end
	-- game.project
	local proj = parse_project(repo)
	for key, value in pairs(proj) do
		if key == "project.custom_resources" then
			for _, entry in ipairs(M.custom_resources(repo)) do
				if not resource_exists(repo, entry) then
					problem(repo, "g", "game.project", 0, key .. ": " .. entry .. " does not exist")
				end
			end
		elseif string.sub(value, 1, 1) == "/" and string.match(value, "%.[%w_]+$") then
			local p = value
			if not resource_exists(repo, p) and string.sub(p, -1) == "c" and resource_exists(repo, string.sub(p, 1, -2)) then
				p = string.sub(p, 1, -2) -- compiled resource name (.collectionc)
			end
			if not resource_exists(repo, p) then
				problem(repo, "g", "game.project", 0, key .. ": " .. value .. " does not exist")
			end
		end
	end
	-- Lua strings that are resource paths
	for _, src in ipairs(repo.sources) do
		if src.client then
			local toks = src.toks
			for i = 1, #toks do
				local t = toks[i]
				if t.k == "str" and string.match(t.v, "^/[%w_%./%%%-]+$") and string.match(t.v, "%.[%w_]+$") then
					local v = t.v
					local ext = ext_of(v)
					if ext ~= "png" or not starts_with(v, "/assets/images/") or true then
						if string.find(v, "%", 1, true) then
							for _, n in ipairs({ 1, 100 }) do
								local ok, shown = pcall(string.format, v, n)
								if ok then check_path(src.path, t.line, shown, "refers to") end
							end
						elseif src.path ~= "client/assets_index.lua" then
							check_path(src.path, t.line, v, "refers to")
						end
					end
				end
			end
		end
	end
	-- particle emitters name animations of their tile source
	for _, path in ipairs(sorted_keys(repo.files)) do
		if ends_with(path, ".particlefx") then
			local text = repo.read(path) or ""
			local cache = {}
			local src_atlas
			local line_no = 0
			for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
				line_no = line_no + 1
				local ts = string.match(line, 'tile_source:%s*"([^"]+)"')
				if ts then src_atlas = ts end
				local an = string.match(line, 'animation:%s*"([^"]+)"')
				if an and src_atlas then
					cache[src_atlas] = cache[src_atlas] or atlas_anims(repo, (string.gsub(src_atlas, "^/", ""))) or {}
					if not cache[src_atlas][an] then
						problem(repo, "g", path, line_no, "emitter animation \"" .. an .. "\" is not in " .. src_atlas)
					end
				end
			end
		end
	end
	-- fonts the scripts name exist in every GUI scene that loads them
	local font_set = list_to_set({ "body", "button", "number", "small", "title" })
	if data.index then font_set = {} for name in pairs(data.index.fonts) do font_set[name] = true end end
	for _, src in ipairs(repo.sources) do
		if src.client then
			local toks = src.toks
			for i = 1, #toks do
				local t = toks[i]
				if is_name(t, "font") and is_op(toks[i + 1], "=") and toks[i + 2] and toks[i + 2].k == "str" then
					if not font_set[toks[i + 2].v] then
						problem(repo, "g", src.path, t.line, "font \"" .. toks[i + 2].v .. "\" is not one of the generated fonts")
					end
				end
			end
		end
	end
end

-- main.collection / app.script / the screens
local function check_project_wiring(repo, data)
	local coll = repo.read("main/main.collection") or ""
	-- proxies
	local proxies = {}
	for id in string.gmatch(coll, 'id: \\"([%w_]+)\\"%s*\\?n?"?%s*"?%s*type: \\"collectionproxy\\"') do proxies[id] = true end
	for id in string.gmatch(coll, 'id: \\"([%w_]+)\\"\\n"%s*"%s*type: \\"collectionproxy\\"') do proxies[id] = true end
	local screens = (data.app and data.app.SCREENS) or {}
	for _, name in ipairs(screens) do
		if not proxies[name] then
			problem(repo, "g", "main/main.collection", 0, "screen \"" .. name .. "\" (client/app.lua SCREENS) has no collection proxy of that id")
		end
		local c = "screens/" .. name .. "/" .. name .. ".collection"
		if not repo.files[c] then problem(repo, "g", c, 0, "collection of screen \"" .. name .. "\" does not exist") end
	end
	for id in pairs(proxies) do
		if not list_to_set(screens)[id] then
			problem(repo, "g", "main/main.collection", 0, "proxy \"" .. id .. "\" is not a screen of client/app.lua (SCREENS)")
		end
	end
	local proj = parse_project(repo)
	local n_proxies = 0
	for _ in pairs(proxies) do n_proxies = n_proxies + 1 end
	if tonumber(proj["collection_proxy.max_count"] or "8") < n_proxies then
		problem(repo, "g", "game.project", 0, "collection_proxy.max_count is below the number of proxies (" .. n_proxies .. ")")
	end
	-- input actions
	local bindings = repo.read("input/game.input_binding") or ""
	local actions = {}
	for a in string.gmatch(bindings, 'action:%s*"([^"]+)"') do actions[a] = true end
	for _, src in ipairs(repo.sources) do
		if src.client then
			local toks = src.toks
			local has_input = false
			for i = 1, #toks do
				if is_name(toks[i], "function") and is_name(toks[i + 1], "on_input") then has_input = true end
			end
			if has_input then
				local _, hashes = constants(src)
				for i = 1, #toks do
					if is_name(toks[i], "action_id") and (is_op(toks[i + 1], "==") or is_op(toks[i + 1], "~=")) then
						local a = toks[i + 2]
						local name
						if is_name(a, "hash") and toks[i + 4] and toks[i + 4].k == "str" then
							name = toks[i + 4].v
						elseif a and a.k == "name" then
							name = hashes[a.v]
						end
						if name and not actions[name] then
							problem(repo, "g", src.path, toks[i].line, "input action \"" .. name .. "\" is not bound in input/game.input_binding")
						end
					end
				end
				for i = 1, #toks do -- DEBUG_KEYS = { [hash("debug_town")] = ... }
					if is_op(toks[i], "[") and is_name(toks[i + 1], "hash") and is_op(toks[i + 2], "(") and toks[i + 3] and toks[i + 3].k == "str" then
						if not actions[toks[i + 3].v] then
							problem(repo, "g", src.path, toks[i].line, "input action \"" .. toks[i + 3].v .. "\" is not bound in input/game.input_binding")
						end
					end
				end
				-- a hash constant named like an action but not bound
				for name, value in pairs(hashes) do
					if (name == "TOUCH" or name == "BACK" or string.match(name, "^ACTION")) and not actions[value] then
						problem(repo, "g", src.path, 0, "input action \"" .. value .. "\" (" .. name .. ") is not bound in input/game.input_binding")
					end
				end
			end
		end
	end
	-- component ids named by scripts: msg.url(nil, id, "comp"), factory.create("#x") against the game objects they live in
	local ids = {}
	for _, path in ipairs(sorted_keys(repo.files)) do
		if starts_with(path, "screens/level/") and (ends_with(path, ".go") or ends_with(path, ".collection")) then
			for id in pairs(component_ids(repo.read(path) or "")) do ids[id] = true end
		end
	end
	for _, src in ipairs(repo.sources) do
		if src.client and starts_with(src.path, "client/level_") or src.path == "screens/level/board.script" then
			local toks = src.toks
			for i = 1, #toks do
				local t = toks[i]
				if t.k == "str" and string.match(t.v, "^#[%w_]+$") and not string.match(t.v, "^#%x%x%x%x%x%x$") then
					local id = string.sub(t.v, 2)
					if not ids[id] and not (src.path == "client/audio.lua") then
						problem(repo, "g", src.path, t.line, "component url \"" .. t.v .. "\" is not a component of screens/level/*.go|collection")
					end
				end
				if t.k == "str" and is_op(toks[i + 1], "..") and string.match(t.v, "^#$") then
					local mid, tail = toks[i + 2], toks[i + 4]
					if tail and tail.k == "str" and tail.v == "_factory" then
						for _, kind in ipairs({ "pop", "sparkle", "debris", "dust", "confetti", "spark" }) do
							if not ids[kind .. "_factory"] then
								problem(repo, "g", src.path, t.line, "burst factory \"#" .. kind .. "_factory\" is not a component of screens/level/level.collection")
							end
						end
					end
				end
			end
		end
	end
	-- msg.url(nil, id, "comp") : the component ids of the bursts / pieces
	for _, src in ipairs(repo.sources) do
		if src.client then
			local toks = src.toks
			for i = 1, #toks do
				if is_name(toks[i], "msg") and is_op(toks[i + 1], ".") and is_name(toks[i + 2], "url") and is_op(toks[i + 3], "(") then
					local args = call_args(toks, i + 3)
					if #args == 3 and args[3][1] == args[3][2] and toks[args[3][1]].k == "str" then
						local comp = toks[args[3][1]].v
						if src.path ~= "main/audio.script" and not ids[comp] then
							problem(repo, "g", src.path, toks[i].line, "msg.url(..., \"" .. comp .. "\"): no component of that id in screens/level/*.go")
						end
					end
				end
			end
		end
	end
	-- the GUI scenes in the registry are the .gui files, with the textures they load
	for path, g in pairs(data.index and data.index.guis or {}) do
		local text = repo.read((string.gsub(path, "^/", ""))) or ""
		for _, tex in ipairs(g.textures) do
			if not string.find(text, 'name: "' .. tex .. '"', 1, true) then
				problem(repo, "g", string.gsub(path, "^/", ""), 0, "registry says the GUI loads texture \"" .. tex .. "\" but the file does not")
			end
		end
	end
end


---------------------------------------------------------------------------------------------------
-- h  calls between modules: members, methods, the meta API
---------------------------------------------------------------------------------------------------

-- true when toks[i] is the NAME of a "NAME.member" that is being assigned: NAME.a = ..., NAME.a, NAME.b = ...
local function assign_target(toks, i)
	local j = i
	while true do
		if not (toks[j] and toks[j].k == "name" and (is_op(toks[j + 1], ".")) and toks[j + 2] and toks[j + 2].k == "name") then return false end
		local nxt = toks[j + 3]
		if is_op(nxt, "=") and not is_op(toks[j + 4], "=") then return true end
		if is_op(nxt, ",") then
			j = j + 4
		else
			return false
		end
	end
end

-- Names a Lua module hands out: what is assigned on the table it returns.
local function module_exports(src)
	local toks = src.toks
	local ret
	for i = #toks, 1, -1 do
		if is_name(toks[i], "return") and src.depth[i] == 0 then
			if toks[i + 1] and toks[i + 1].k == "name" then ret = toks[i + 1].v end
			break
		end
	end
	local out = {}
	if not ret then return out, false end
	for i = 1, #toks do
		local t = toks[i]
		if t.k == "name" and t.v == ret and not is_op(toks[i - 1], ".") and not is_op(toks[i - 1], ":") then
			if (is_op(toks[i + 1], ".") or is_op(toks[i + 1], ":")) and toks[i + 2] and toks[i + 2].k == "name" then
				local member = toks[i + 2].v
				if is_name(toks[i - 1], "function") or assign_target(toks, i) then
					out[member] = true
				end
				-- NAME.a, NAME.b = ...: the members after a comma
				local j = i
				while is_op(toks[j + 3], ",") and is_name(toks[j + 4], ret) and is_op(toks[j + 5], ".") and toks[j + 6] and toks[j + 6].k == "name" do
					if assign_target(toks, j + 4) then out[toks[j + 6].v] = true end
					j = j + 4
				end
			elseif is_op(toks[i + 1], "=") and is_op(toks[i + 2], "{") and src.depth[i] == 0 then
				-- local M = { a = 1, b = function() end }: fields of the constructor
				local depth, j = 0, i + 2
				while toks[j] do
					local u = toks[j]
					if is_op(u, "{") or is_op(u, "(") or is_op(u, "[") then
						depth = depth + 1
					elseif is_op(u, "}") or is_op(u, ")") or is_op(u, "]") then
						depth = depth - 1
						if depth == 0 then break end
					elseif depth == 1 and u.k == "name" and is_op(toks[j + 1], "=") and not is_op(toks[j + 1], "==") then
						out[u.v] = true
					end
					j = j + 1
				end
			end
		end
	end
	return out, true
end

M.BUILTIN_METHODS = list_to_set({
	-- strings and files
	"format", "gsub", "gmatch", "sub", "find", "match", "rep", "byte", "char", "len", "lower", "upper", "reverse",
	"read", "write", "lines", "close", "flush", "seek", "setvbuf",
})

local function check_api(repo, data)
	-- exports of every module
	local exports = {}
	local assigned = {} -- module path -> member assigned from outside (M.x = ... in another file)
	for _, src in ipairs(repo.sources) do
		if src.is_module and src.runtime then
			exports[src.path] = module_exports(src)
		end
	end
	-- aliases: local NAME = require("mod") at file level
	local aliases = {} -- src.path -> { NAME = module path }
	for _, src in ipairs(repo.sources) do
		if src.runtime then
			local toks = src.toks
			for i = 1, #toks - 5 do
				if is_name(toks[i], "local") and is_name(toks[i + 1]) and is_op(toks[i + 2], "=") and is_name(toks[i + 3], "require")
					and is_op(toks[i + 4], "(") and toks[i + 5].k == "str" and src.depth[i] == 0 then
					local file = module_file(toks[i + 5].v)
					if exports[file] then
						aliases[src.path] = aliases[src.path] or {}
						aliases[src.path][toks[i + 1].v] = file
					end
				end
			end
		end
	end
	-- members added from outside (app.ui = {...} in a screen)
	for _, src in ipairs(repo.sources) do
		local al = aliases[src.path]
		if al then
			local toks = src.toks
			for i = 1, #toks - 3 do
				if toks[i].k == "name" and al[toks[i].v] and not is_op(toks[i - 1], ".") and not is_op(toks[i - 1], ":") and assign_target(toks, i) then
					exports[al[toks[i].v]][toks[i + 2].v] = true
				end
			end
		end
	end
	-- uses (in the client; core and meta are covered by their own tests)
	for _, path in ipairs(sorted_keys(aliases)) do
		local src = repo.by_path[path]
		local toks = src.toks
		local al = aliases[path]
		for i = 1, #toks - 2 do
			local t = toks[i]
			if src.client and t.k == "name" and al[t.v] and (is_op(toks[i + 1], ".") or is_op(toks[i + 1], ":")) and toks[i + 2].k == "name"
				and not is_op(toks[i - 1], ".") and not is_op(toks[i - 1], ":") and not is_name(toks[i - 1], "local") then
				local member = toks[i + 2].v
				if not exports[al[t.v]][member] and not (is_op(toks[i + 1], ":") and M.BUILTIN_METHODS[member]) then
					problem(repo, "h", path, t.line, t.v .. "." .. member .. ": " .. al[t.v] .. " has no member \"" .. member .. "\"")
				end
			end
		end
	end
	-- method calls obj:name( : the name must be defined somewhere
	local defined = {}
	for _, src in ipairs(repo.sources) do
		if src.runtime then
			local toks = src.toks
			for i = 1, #toks do
				local t = toks[i]
				if is_name(t, "function") and toks[i + 1] and toks[i + 1].k == "name" and (is_op(toks[i + 2], ":") or is_op(toks[i + 2], "."))
					and toks[i + 3] and toks[i + 3].k == "name" then
					defined[toks[i + 3].v] = true
				elseif t.k == "name" and is_op(toks[i + 1], "=") and not is_op(toks[i + 2], "=") then
					defined[t.v] = true -- field = value (a function value, a constructor field)
				end
			end
		end
	end
	for _, src in ipairs(repo.sources) do
		if src.client then
			local toks = src.toks
			for i = 2, #toks - 2 do
				if is_op(toks[i], ":") and toks[i + 1].k == "name" and is_op(toks[i + 2], "(") and toks[i - 1].k ~= "str"
					and not is_name(toks[i - 2], "function") then
					local name = toks[i + 1].v
					if not defined[name] and not M.BUILTIN_METHODS[name] then
						problem(repo, "h", src.path, toks[i].line, "method call :" .. name .. "( : no function of that name is defined in the runtime code")
					end
				end
			end
		end
	end
	-- the meta API: method names and argument counts of meta:xxx(...) calls
	local meta_src = repo.by_path["meta/meta.lua"]
	if meta_src then
		local methods = {}
		local mt = meta_src.toks
		for i = 1, #mt - 4 do
			if is_name(mt[i], "function") and is_name(mt[i + 1], "Meta") and is_op(mt[i + 2], ":") and mt[i + 3].k == "name" and is_op(mt[i + 4], "(") then
				local params = {}
				local j = i + 5
				while mt[j] and not is_op(mt[j], ")") do
					if mt[j].k == "name" then params[#params + 1] = mt[j].v end
					j = j + 1
				end
				methods[mt[i + 3].v] = params
			end
		end
		local function check_call(src, line, name, nargs)
			local params = methods[name]
			if not params then
				problem(repo, "h", src.path, line, "meta:" .. name .. "( : no such method in meta/meta.lua")
				return
			end
			if nargs > #params then
				problem(repo, "h", src.path, line, "meta:" .. name .. "( gets " .. nargs .. " argument(s), the method takes " .. #params ..
					" (" .. table.concat(params, ", ") .. ")")
			end
			for k, p in ipairs(params) do
				if p == "now" and nargs < k then
					problem(repo, "h", src.path, line, "meta:" .. name .. "( without `now` (the meta never reads a clock itself)")
				end
			end
		end
		for _, src in ipairs(repo.sources) do
			if src.client then
				local toks = src.toks
				for i = 1, #toks - 3 do
					if is_name(toks[i], "meta") and is_op(toks[i + 1], ":") and toks[i + 2].k == "name" and is_op(toks[i + 3], "(")
						and not is_name(toks[i - 1], "function") then
						local name = toks[i + 2].v
						if string.sub(name, 1, 1) ~= "_" then
							check_call(src, toks[i].line, name, #call_args(toks, i + 3))
						end
					elseif is_name(toks[i], "pcall") and is_op(toks[i + 1], "(") and is_name(toks[i + 2], "meta") and is_op(toks[i + 3], ".")
						and toks[i + 4] and toks[i + 4].k == "name" and is_op(toks[i + 5], ",") and is_name(toks[i + 6], "meta") then
						-- pcall(meta.finish_level, meta, a, b): the arguments after the receiver
						local args = call_args(toks, i + 1)
						check_call(src, toks[i].line, toks[i + 4].v, math.max(0, #args - 2))
					end
				end
			end
		end
	end
end


---------------------------------------------------------------------------------------------------
-- i  Defold script contexts
---------------------------------------------------------------------------------------------------

-- A Lua module runs in the context of the script that requires it. The modules of the engine exist only in
-- some contexts: gui.* in GUI scripts, go.* / sprite.* / factory.* / particlefx.* / sound.* / ... in game
-- object scripts, render.* / graphics.* in the render script. A shared module may use none of them. The
-- engine's tests (stubs) define every module everywhere, so only this check sees a wrong one.
M.CONTEXT_APIS = {
	gui = { "gui" },
	go = { "go", "sprite", "factory", "collectionfactory", "particlefx", "sound", "label", "model", "tilemap", "physics",
		"collectionproxy", "spine" },
	render = { "render", "graphics" },
}
M.LIFECYCLE = list_to_set({ "init", "final", "update", "fixed_update", "on_message", "on_input", "on_reload" })

local function script_context(path)
	if ends_with(path, ".gui_script") then return "gui" end
	if ends_with(path, ".script") then return "go" end
	if ends_with(path, ".render_script") then return "render" end
	return nil
end

local function check_contexts(repo, data)
	-- which contexts load which module (through load-time and lazy requires alike)
	local uses = {} -- module path -> { gui = true, ... }
	local function visit(path, ctx, seen)
		if seen[path] then return end
		seen[path] = true
		uses[path] = uses[path] or {}
		uses[path][ctx] = true
		local src = repo.by_path[path]
		if not src then return end
		local toks = src.toks
		for i = 1, #toks do
			if is_name(toks[i], "require") then
				local lit
				if is_op(toks[i + 1], "(") and toks[i + 2] and toks[i + 2].k == "str" then lit = toks[i + 2].v
				elseif is_op(toks[i + 1], ",") and toks[i + 2] and toks[i + 2].k == "str" then lit = toks[i + 2].v end
				if lit then
					local file = module_file(lit)
					if repo.by_path[file] and in_dirs(file, M.RUNTIME_DIRS) then visit(file, ctx, seen) end
				end
			end
		end
	end
	for _, src in ipairs(repo.sources) do
		local ctx = script_context(src.path)
		if ctx and src.runtime then visit(src.path, ctx, {}) end
	end
	for _, src in ipairs(repo.sources) do
		local ctxs = uses[src.path]
		if ctxs and src.client then
			local banned = {} -- api module -> contexts it is missing in
			for ctx in pairs(ctxs) do
				for other, apis in pairs(M.CONTEXT_APIS) do
					if other ~= ctx then
						for _, api in ipairs(apis) do banned[api] = banned[api] or ctx end
					end
				end
			end
			local toks = src.toks
			for i = 1, #toks - 2 do
				local t = toks[i]
				if t.k == "name" and banned[t.v] and is_op(toks[i + 1], ".") and not is_op(toks[i - 1], ".") and not is_op(toks[i - 1], ":")
					and toks[i + 2].k == "name" then
					local where = {}
					for ctx in pairs(ctxs) do where[#where + 1] = ctx end
					table.sort(where)
					problem(repo, "i", src.path, t.line, t.v .. "." .. toks[i + 2].v .. ": the " .. t.v .. " module does not exist in a " ..
						banned[t.v] .. " script, and this code runs in: " .. table.concat(where, ", "))
				end
			end
		end
	end
	-- scripts: only the engine callbacks may be global functions
	for _, src in ipairs(repo.sources) do
		if script_context(src.path) and src.runtime then
			local toks = src.toks
			for i = 1, #toks - 2 do
				if is_name(toks[i], "function") and src.depth[i] == 0 and toks[i + 1].k == "name" and is_op(toks[i + 2], "(")
					and not is_name(toks[i - 1], "local") then
					if not M.LIFECYCLE[toks[i + 1].v] then
						problem(repo, "i", src.path, toks[i].line, "global function " .. toks[i + 1].v .. "( in a script: the engine calls only init, final, update, fixed_update, on_message, on_input, on_reload (make it local)")
					end
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- running
---------------------------------------------------------------------------------------------------

M.CHECKS = {
	{ "a", "requires", check_requires },
	{ "b", "images", check_images },
	{ "c", "sounds", check_sounds },
	{ "d", "i18n", check_i18n },
	{ "e", "bus", check_bus },
	{ "f", "messages", check_messages },
	{ "g", "defold files", check_defold_files },
	{ "g", "wiring", check_project_wiring },
	{ "h", "api", check_api },
	{ "i", "contexts", check_contexts },
}

-- Runs every check from the repository root; returns the sorted list of problems and the repo facts.
--   opts.files = { [path] = text }   a synthetic repository instead of the working directory (tests)
--   opts.data = {...}                 the data modules instead of the real ones (tests)
--   opts.only = { "a", "e" }          run only these checks (the letters above)
function M.run(opts)
	opts = opts or {}
	local repo = load_repo(opts)
	local data = load_data(repo)
	local only = opts.only and list_to_set(opts.only) or nil
	for _, c in ipairs(M.CHECKS) do
		if not only or only[c[1]] then
			local ok, err = pcall(c[3], repo, data)
			if not ok then problem(repo, "setup", "tools/check_refs.lua", 0, "check " .. c[2] .. " crashed: " .. tostring(err)) end
		end
	end
	table.sort(repo.problems, function(a, b)
		if a.check ~= b.check then return a.check < b.check end
		if a.file ~= b.file then return a.file < b.file end
		if a.line ~= b.line then return a.line < b.line end
		return a.msg < b.msg
	end)
	return repo.problems, repo, data
end

function M.format(p)
	return string.format("%s:%d: [%s] %s", p.file, p.line, p.check, p.msg)
end

-- lexer exports for tests
M._lex = lex
M._structure = structure

local function main(args)
	local quiet, unused = false, false
	for _, a in ipairs(args) do
		if a == "--quiet" then quiet = true end
		if a == "--unused" then unused = true end
	end
	local problems, repo, data = M.run()
	for _, p in ipairs(problems) do print(M.format(p)) end
	if unused and repo.i18n_used and data.i18n then
		local list = {}
		for key in pairs(data.i18n.STRINGS) do
			if not repo.i18n_used[key] then list[#list + 1] = key end
		end
		table.sort(list)
		print("-- i18n keys no source names (" .. #list .. "): " .. table.concat(list, " "))
	end
	if #problems == 0 then
		if not quiet then print("check_refs: ok") end
		return 0
	end
	print(string.format("check_refs: %d problem(s)", #problems))
	return 1
end

if arg and arg[0] and string.find(arg[0], "check_refs", 1, true) then
	os.exit(main(arg))
end

return M
