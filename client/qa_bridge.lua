-- Debug bridge for automated browser tests (client-architecture.md, 8).
-- Only active in a debug build running in HTML5, and only when the page is
-- served from this machine (localhost / 127.0.0.1) or opened with ?glowqa in
-- the URL: a debug bundle uploaded by mistake does not hand every page
-- script set_coins / reset_save. Debug bundles must still never be
-- published (tools/build_web.sh marks them).
--
-- Each frame the bridge reads window.__glowCmd (and clears it), runs the
-- command and writes the result plus an app snapshot as JSON to
-- window.__glowState:
--   {seq, cmd, result = {ok, error?, ...}, frame, t, errors = {...}, app = snapshot}
-- seq grows by one per executed command, so a test sets __glowCmd and waits
-- until __glowState.seq changes and __glowState.app.transitioning is false.
--
-- Commands (words separated by spaces):
--   state | goto <splash|town|level> [n] | level <n> | set_coins <n> |
--   lang <auto|en|ru> | reset_save | toast <text...> | music <district> |
--   sfx <name> | note <color> <wave> |
--   hint_move | swap x1 y1 x2 y2 | tap x y | skip | win   (need the board: not yet)
-- Handlers are supplied by main/app.script; parse/execute are pure and tested.

local M = {}

M.READ_JS = "(function(){var c=window.__glowCmd;window.__glowCmd=null;"
	.. "return (c===undefined||c===null)?'':String(c);})()"
M.LOCATION_JS = "(function(){try{return location.hostname+' '+location.search;}catch(e){return '';}})()"

-- Is the bridge allowed on a page at `hostname` with query `search`?
function M.host_allowed(hostname, search)
	hostname = string.lower(tostring(hostname or ""))
	if hostname == "localhost" or hostname == "127.0.0.1" or hostname == "[::1]" or hostname == "::1" then return true end
	return string.find(tostring(search or ""), "glowqa", 1, true) ~= nil
end

-- Reads the page location through run_js and applies host_allowed.
function M.page_allowed(run_js)
	if not run_js then return false end
	local ok, loc = pcall(run_js, M.LOCATION_JS)
	if not ok or type(loc) ~= "string" then return false end
	local host, search = string.match(loc, "^(%S*)%s?(.*)$")
	return M.host_allowed(host, search)
end
M.MAX_ERRORS = 20

local state = {
	enabled = false,
	run_js = nil,     -- fn(code) -> string (html5.run)
	encode = nil,     -- fn(table) -> json string (json.encode)
	handlers = {},    -- name -> fn(args, cmd) -> result table
	snapshot = nil,   -- fn() -> table
	seq = 0,
	frame = 0,
	last_cmd = nil,
	last_result = nil,
	errors = {},
}

-- opts: {enabled, run_js, encode, handlers, snapshot}
function M.init(opts)
	opts = opts or {}
	state.enabled = opts.enabled and opts.run_js ~= nil and opts.encode ~= nil
	state.run_js, state.encode = opts.run_js, opts.encode
	state.handlers = opts.handlers or {}
	state.snapshot = opts.snapshot
	state.seq, state.frame = 0, 0
	state.last_cmd, state.last_result = nil, nil
	state.errors = {}
	return state.enabled
end

function M.enabled()
	return state.enabled
end

-- "goto  town 3" -> "goto", {"town", "3"}
function M.parse(cmd)
	if type(cmd) ~= "string" then return nil, {} end
	local words = {}
	for w in string.gmatch(cmd, "%S+") do words[#words + 1] = w end
	local name = table.remove(words, 1)
	return name, words
end

M.NOT_YET = { hint_move = true, swap = true, tap = true, skip = true, win = true }

-- Runs one command; returns a result table (never raises).
function M.execute(cmd)
	local name, args = M.parse(cmd)
	if not name then return { ok = false, error = "empty command" } end
	local h = state.handlers[name]
	if not h then
		if M.NOT_YET[name] then return { ok = false, error = "not_implemented: needs the board" } end
		return { ok = false, error = "unknown command '" .. name .. "'" }
	end
	local ok, res = pcall(h, args, cmd)
	if not ok then return { ok = false, error = tostring(res) } end
	if type(res) ~= "table" then res = { ok = res ~= false } end
	if res.ok == nil then res.ok = true end
	return res
end

-- Lua errors reported by sys.set_error_handler end up in the state.
function M.record_error(message)
	local e = state.errors
	e[#e + 1] = tostring(message)
	if #e > M.MAX_ERRORS then table.remove(e, 1) end
end

function M.errors()
	return state.errors
end

-- JSON-safe deep copy: NaN / infinite numbers become strings, functions and
-- userdata become their tostring(), cycles are cut.
function M.sanitize(v, seen)
	local t = type(v)
	if t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return tostring(v) end
		return v
	elseif t == "string" or t == "boolean" or t == "nil" then
		return v
	elseif t == "table" then
		seen = seen or {}
		if seen[v] then return "<cycle>" end
		seen[v] = true
		local out = {}
		for k, x in pairs(v) do
			local key = type(k) == "number" and k or tostring(k)
			out[key] = M.sanitize(x, seen)
		end
		seen[v] = nil
		return out
	end
	return tostring(v)
end

local function write_state()
	local snap = state.snapshot and state.snapshot() or {}
	local ok, js = pcall(state.encode, M.sanitize({
		seq = state.seq,
		cmd = state.last_cmd,
		result = state.last_result,
		frame = state.frame,
		errors = state.errors,
		app = snap,
	}))
	if not ok then js = "{\"encode_error\":" .. string.format("%q", tostring(js)) .. "}" end
	pcall(state.run_js, "window.__glowState=" .. js .. ";")
end

-- Call once per frame (app.script update).
function M.update()
	if not state.enabled then return end
	state.frame = state.frame + 1
	local ok, cmd = pcall(state.run_js, M.READ_JS)
	if ok and type(cmd) == "string" and cmd ~= "" then
		state.last_cmd = cmd
		state.last_result = M.execute(cmd)
		state.seq = state.seq + 1
	end
	write_state()
end

return M
