-- Platform services behind one small interface. Loads in plain Lua too (the
-- Defold globals are looked up lazily), so pure modules and tests can use it;
-- tests replace functions with platform.stub({...}).
--
--   platform.now()          wall clock in seconds (float), for the meta and timers
--   platform.is_debug()     debug engine (bob --variant debug / editor)
--   platform.is_html5()
--   platform.language()     system language code ("en", "ru", ...)
--   platform.vibrate(ms)    haptic tick; on the web navigator.vibrate via
--                           html5.run (Android browsers), guarded by pcall;
--                           no-op when haptics are off or unsupported
--   platform.random_seed()  integer seed with |seed| < 2^53 for Meta.new/load

local M = {}

local cache = {}

local function sys_info()
	if cache.sys_info == nil then
		cache.sys_info = (sys and sys.get_sys_info and sys.get_sys_info()) or false
	end
	return cache.sys_info or {}
end

function M.now()
	if socket and socket.gettime then return socket.gettime() end
	return os.time()
end

function M.is_debug()
	if cache.debug == nil then
		cache.debug = (sys and sys.get_engine_info and sys.get_engine_info().is_debug) and true or false
	end
	return cache.debug
end

function M.system()
	return sys_info().system_name or "unknown"
end

function M.is_html5()
	return M.system() == "HTML5" and html5 ~= nil
end

function M.language()
	local info = sys_info()
	return info.language or info.device_language or "en"
end

-- Haptics on/off comes from the settings (client/app.lua keeps it in sync).
M.haptics = true

function M.vibrate(ms)
	if not M.haptics then return false end
	ms = math.max(1, math.floor(tonumber(ms) or 15))
	if M.is_html5() then
		local ok = pcall(html5.run, "(navigator.vibrate && navigator.vibrate(" .. ms .. ")) ? 1 : 0")
		return ok
	end
	-- iOS/Android: native haptics come with the native extension (client-architecture.md, 5)
	return false
end

-- Seed for the player's salt: time mixed with the Lua RNG, kept below 2^53.
function M.random_seed()
	local t = M.now()
	math.randomseed(math.floor((t * 1000) % 2147483647))
	local a = math.random(0, 2147483646)
	local b = math.random(0, 1048575)
	return a * 1048576 + b
end

-- Test hook: overrides functions or fields, returns a restore function.
function M.stub(overrides)
	local saved = {}
	for k, v in pairs(overrides) do
		saved[k] = { v = M[k] }
		M[k] = v
	end
	return function()
		for k, s in pairs(saved) do M[k] = s.v end
	end
end

function M._reset_cache()
	cache = {}
end

return M
