-- Pictures the web build does not carry in its archive: downloaded when the player needs them (pure Lua).
--
-- The web archive holds the shared loose images and those of the first district only; the loose images of every
-- other district ship as plain files next to index.html (tools/gen_defold.py marks their registry entries with
-- `remote` = "packs/<path>?v=<content hash>", `bytes` and `district`; tools/build_web.sh copies them). This module
-- fetches them, keeps the bytes in memory for client/ui.lua (Scene:loose_texture decodes them like an archive
-- file) and releases the files of districts far from the player when it holds more than its budget.
--
-- The HTTP request and the clock are injected: main/app.script gives Defold's http.request and runs update()
-- every frame, so every request is made from that one script, which lives as long as the app (an answer to a
-- request made by a screen would be lost with the screen). Nothing here raises; nothing is allocated while idle.
--
--   packs.init({request = fn(url, done), base = "https://host/game/", clock = fn() -> seconds,
--               images = index.images, groups = index.packs})   -- done(status, body)
--   packs.enabled()                 --> true when remote pictures are fetched (the web build)
--   packs.remote(key)               --> true for a picture that is fetched, not read from the archive
--   packs.bytes(key)                --> its bytes | nil (not here yet)
--   packs.want(key, prio)           -- asks for it (prio: M.NOW on screen, M.FOCUS the player's district, M.NEXT ...)
--   packs.want_district(did, prio)  -- every remote picture of a district
--   packs.focus(did, order)         -- the player's district and the district order: what is far goes first
--   packs.update()                  -- starts queued requests, ends the ones past their deadline (every frame)
--   packs.progress(did)             --> got, total (bytes), pending (files queued or loading), failed (files)
--   packs.version                   -- grows by one whenever a picture arrives
--   packs.status()                  --> plain table for QA

local M = {}

M.NOW, M.FOCUS, M.NEXT, M.LATER = 1, 2, 3, 4
M.PARALLEL = 3                 -- requests at once
M.TRIES = 3                    -- attempts in a row before a file counts as failed
M.PAUSE = 1.5                  -- seconds before the second attempt (doubles each time)
M.RETRY_AFTER = 20             -- a failed file may be asked for again after this (doubles up to 16x)
M.TIMEOUT = 60                 -- seconds a request may take
M.BUDGET = 16 * 1024 * 1024    -- bytes held before files of far districts are released
M.RECENT = 30                  -- a file read in the last seconds is not released
M.LOG_MAX = 300                -- QA: the order of the first requests

local st

function M._reset()
	st = {
		request = nil, base = nil, clock = os.clock, images = {}, groups = {},
		files = {},        -- key -> {state = "queued"|"loading"|"ready"|"failed", prio, seq, tries, rounds, at, req, data, used}
		queued = 0, loading = 0, held = 0, seq = 0, req = 0,
		focus = nil, order = {}, rank = {},
		started = 0, done = 0, errors = 0, released = 0,
		log = {},
	}
	M.version = 0
end
M._reset()

local function now()
	local ok, t = pcall(st.clock)
	return ok and type(t) == "number" and t or 0
end

function M.init(opts)
	opts = opts or {}
	M._reset()
	st.request = opts.request
	st.base = opts.base
	st.clock = opts.clock or os.clock
	st.images = opts.images or {}
	st.groups = opts.groups or {}
	if opts.budget then M.BUDGET = opts.budget end
end

function M.enabled()
	return st.request ~= nil and st.base ~= nil
end

function M.remote(key)
	local e = st.images[key]
	return e ~= nil and e.remote ~= nil and M.enabled()
end

local function entry(key)
	local e = st.images[key]
	if e and e.remote then return e end
	return nil
end

-- "queued" | "loading" | "ready" | "failed" | nil (never asked for, or released)
function M.state(key)
	local f = st.files[key]
	return f and f.state or nil
end

function M.bytes(key)
	local f = st.files[key]
	if f and f.data then
		f.used = now()
		return f.data
	end
	return nil
end

local function enqueue(f, prio)
	f.state, f.prio = "queued", prio
	st.seq = st.seq + 1
	f.seq, f.at = st.seq, 0
	st.queued = st.queued + 1
end

function M.want(key, prio)
	if not M.enabled() then return nil end
	local e = entry(key)
	if not e then return nil end
	prio = prio or M.NOW
	local f = st.files[key]
	if not f then
		f = { tries = 0, rounds = 0, prio = prio }
		st.files[key] = f
		enqueue(f, prio)
		return f.state
	end
	if f.state == "ready" then
		f.used = now()
	elseif f.state == "queued" or f.state == "loading" then
		if prio < f.prio then f.prio = prio end
	elseif f.state == "failed" then
		local wait = M.RETRY_AFTER * 2 ^ math.min(f.rounds - 1, 4)
		if now() >= f.at + wait then
			f.tries = 0
			enqueue(f, prio)
		end
	end
	return f.state
end

function M.want_district(did, prio)
	local keys = did and st.groups[did]
	if not keys then return end
	for i = 1, #keys do M.want(keys[i], prio) end
end

local function distance(did)
	local a, b = st.rank[did], st.rank[st.focus]
	if not a or not b then return 1000 end
	return a >= b and (a - b) or (b - a) + 0.5 -- behind the player goes before the same distance ahead
end

-- Releases files of far districts until the held bytes fit the budget (never the one that just came).
local function trim(keep_key)
	local t = now()
	while st.held > M.BUDGET do
		local victim, vkey, vd, vused
		for key, f in pairs(st.files) do -- order-free: the farthest, then the oldest, wins
			if f.data and key ~= keep_key and t - (f.used or 0) > M.RECENT then
				local e = st.images[key]
				local d = distance(e and e.district)
				if d > 1 and (not vd or d > vd or (d == vd and (f.used or 0) < vused)) then
					victim, vkey, vd, vused = f, key, d, f.used or 0
				end
			end
		end
		if not victim then return end
		st.held = st.held - #victim.data
		st.files[vkey] = nil -- asked for again later: a new request (the browser's cache answers it if it can)
		st.released = st.released + 1
	end
end

-- The player's district and the order of the districts (ids): the files of the districts farthest from it are
-- released first when the budget is full; those of the player's district and the next one never. When the
-- player moves on, what is now far goes at once.
function M.focus(did, order)
	local moved = did ~= st.focus
	st.focus = did
	if order and order ~= st.order then
		st.order = order
		st.rank = {}
		for i, id in ipairs(order) do st.rank[id] = i end
		moved = true
	end
	if moved then trim(nil) end
end

local function failed_attempt(f)
	f.req = nil
	st.loading = st.loading - 1
	st.errors = st.errors + 1
	f.tries = f.tries + 1
	if f.tries < M.TRIES then
		f.state = "queued"
		st.queued = st.queued + 1
		f.at = now() + M.PAUSE * 2 ^ (f.tries - 1)
	else
		f.state, f.at = "failed", now()
		f.rounds = f.rounds + 1
	end
end

local function arrived(key, id, status, body)
	local f = st.files[key]
	if not f or f.req ~= id or f.state ~= "loading" then return end -- late: the request was given up
	local e = st.images[key]
	if status == 200 and type(body) == "string" and #body > 0 and (not e.bytes or #body == e.bytes) then
		f.req = nil
		st.loading = st.loading - 1
		f.state, f.data, f.used, f.tries, f.rounds = "ready", body, now(), 0, 0
		st.held = st.held + #body
		st.done = st.done + 1
		M.version = M.version + 1
		trim(key)
	else
		failed_attempt(f)
	end
end

local function start(key, f)
	st.req = st.req + 1
	local id = st.req
	f.state, f.req, f.at = "loading", id, now() + M.TIMEOUT
	st.queued = st.queued - 1
	st.loading = st.loading + 1
	st.started = st.started + 1
	if #st.log < M.LOG_MAX then st.log[#st.log + 1] = key end
	local url = st.base .. st.images[key].remote
	local ok = pcall(st.request, url, function(status, body)
		pcall(arrived, key, id, status, body)
	end)
	if not ok and f.req == id then failed_attempt(f) end
end

-- The next file to fetch: the lowest priority number, then the oldest request; nil when none is due.
local function pick(t)
	local best, bkey
	for key, f in pairs(st.files) do -- order-free: (prio, seq) decides
		if f.state == "queued" and f.at <= t and (not best or f.prio < best.prio or (f.prio == best.prio and f.seq < best.seq)) then
			best, bkey = f, key
		end
	end
	return bkey, best
end

function M.update()
	if st.queued == 0 and st.loading == 0 then return end
	local t = now()
	if st.loading > 0 then
		for _, f in pairs(st.files) do -- order-free: every request past its deadline is given up
			if f.state == "loading" and t > f.at then failed_attempt(f) end
		end
	end
	while st.loading < M.PARALLEL and st.queued > 0 do
		local key, f = pick(t)
		if not key then break end
		start(key, f)
	end
end

-- Bytes of the district's remote pictures that are here, of all of them, the files still on their way and the
-- files that failed. A district without remote pictures (the first one, or not the web build) is complete.
function M.progress(did)
	local keys = did and st.groups[did]
	if not keys or not M.enabled() then return 0, 0, 0, 0 end
	local got, total, pending, failed = 0, 0, 0, 0
	for i = 1, #keys do
		local key = keys[i]
		local e = st.images[key]
		total = total + (e and e.bytes or 0)
		local f = st.files[key]
		if f then
			if f.data then
				got = got + #f.data
			elseif f.state == "queued" or f.state == "loading" then
				pending = pending + 1
			elseif f.state == "failed" then
				failed = failed + 1
			end
		end
	end
	return got, total, pending, failed
end

-- True when every remote picture of the district is in memory (or it has none).
function M.complete(did)
	local got, total = M.progress(did)
	return got >= total
end

-- with_log: also the keys of the first requests in the order they were made (QA)
function M.status(with_log)
	local ready, failed = 0, 0
	for _, f in pairs(st.files) do
		if f.data then ready = ready + 1 elseif f.state == "failed" then failed = failed + 1 end
	end
	return {
		enabled = M.enabled(), base = st.base, ready = ready, queued = st.queued, loading = st.loading, failed = failed,
		held = st.held, budget = M.BUDGET, started = st.started, done = st.done, errors = st.errors,
		released = st.released, version = M.version, focus = st.focus, log = with_log and st.log or nil,
	}
end

return M
