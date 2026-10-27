-- A strict headless Defold GUI for the meta screens: runs the real GUI scripts (screens/town,
-- screens/splash, main/overlay) and every window of gui/*.lua in the pure-Lua test suite, so
-- they are executed, not only parsed. There is no Defold build tool in the dev container; this is
-- the guard against wrong API calls, missing fonts / textures / materials / animations, blown
-- engine limits and cross-scene node use. It builds on the board harness (level_defold_stub.lua:
-- hash, vmath, msg, the text-proto parser, script loading) and replaces its GUI with a model of
-- the engine's GUI that keeps the node tree, the transforms and the animations.
--
--   local town = require("tests.client.town_defold_stub")
--   local E = town.boot({window = {720, 1280}, language = "en"})   -- app + stub installed
--   local t = E.script("screens/town/town.gui_script", "/screens/town/town.gui")
--   t:init()                       -- init(self) in the scene's context (self is userdata)
--   t:step(30)                     -- 30 frames: animations, then update(self, dt)
--   t:tap(360, 226)                -- a tap at logical coordinates (720x1280, y up)
--   t:tap_text("Level 1")          -- a tap on the centre of the first visible text
--   t:texts()                      -- the live texts of the scene
--   E.audit()                      -- {problems...}: glyphs a font lacks, limits, ...
--   E.shutdown()                   -- finals, globals restored
--
-- STRICT, like the engine (or stricter where the engine would silently misbehave):
--   * gui.set_font / set_texture / set_material of a name the .gui file does not declare, and
--     gui.play_flipbook of an animation the node's atlas does not have, raise;
--   * gui.new_texture raises on a buffer of the wrong size; the node and animation limits of the
--     .gui file / game.project (max_nodes, gui.max_animation_count) raise;
--   * a node of another scene (another script's gui) used from this context raises, a deleted
--     node raises;
--   * values are type checked (vector4 for colours, string for text, a gui.EASING_* constant);
--   * a new gui.animate on a property replaces the running one WITHOUT calling its callback, as the
--     engine does; looping animations never complete;
--   * sys.load_resource only finds files under the custom_resources of game.project;
--   * E.audit() lists texts with glyphs the font does not contain (the engine draws nothing for
--     them) and the live text characters against gui max_characters;
--   * `self` of a script is userdata, like the engine's: setmetatable(self, ...) raises.
-- Text widths come from the real fonts (tests/client/font_advances.lua, written by
-- tests/client/font_advances.py), so shrink-to-fit behaves like it does on the device.
-- Not a renderer: nothing is drawn. Easing is approximated; positions are exact at the end.

local base = require("tests.client.level_defold_stub")

local M = {}

local ROOT = "."

-- Defold GUI constants (the engine's complete lists).
local EASINGS = {
	"LINEAR", "INBACK", "OUTBACK", "INOUTBACK", "OUTINBACK", "INBOUNCE", "OUTBOUNCE", "INOUTBOUNCE", "OUTINBOUNCE",
	"INELASTIC", "OUTELASTIC", "INOUTELASTIC", "OUTINELASTIC", "INSINE", "OUTSINE", "INOUTSINE", "OUTINSINE",
	"INEXPO", "OUTEXPO", "INOUTEXPO", "OUTINEXPO", "INCIRC", "OUTCIRC", "INOUTCIRC", "OUTINCIRC",
	"INQUAD", "OUTQUAD", "INOUTQUAD", "OUTINQUAD", "INCUBIC", "OUTCUBIC", "INOUTCUBIC", "OUTINCUBIC",
	"INQUART", "OUTQUART", "INOUTQUART", "OUTINQUART", "INQUINT", "OUTQUINT", "INOUTQUINT", "OUTINQUINT",
}
local BLENDS = { "ALPHA", "ADD", "ADD_ALPHA", "MULT", "SCREEN" }
local PIVOTS = { "CENTER", "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
local PLAYBACKS = { "ONCE_FORWARD", "ONCE_BACKWARD", "ONCE_PINGPONG", "LOOP_FORWARD", "LOOP_BACKWARD", "LOOP_PINGPONG" }

-- pivot -> fractions of the size the node extends right / up from its position
local PIVOT_FRACTION = {
	CENTER = { -0.5, -0.5 }, N = { -0.5, -1 }, NE = { -1, -1 }, E = { -1, -0.5 }, SE = { -1, 0 },
	S = { -0.5, 0 }, SW = { 0, 0 }, W = { 0, -0.5 }, NW = { 0, -1 },
}

local function read_file(path)
	local f = io.open(ROOT .. path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function utf8_codepoints(s)
	local out, i, n = {}, 1, #s
	while i <= n do
		local c = s:byte(i)
		local cp, len
		if c < 0x80 then cp, len = c, 1
		elseif c >= 0xF0 then cp, len = ((c % 8) * 262144) + ((s:byte(i + 1) or 0) % 64) * 4096 + ((s:byte(i + 2) or 0) % 64) * 64 + ((s:byte(i + 3) or 0) % 64), 4
		elseif c >= 0xE0 then cp, len = ((c % 16) * 4096) + ((s:byte(i + 1) or 0) % 64) * 64 + ((s:byte(i + 2) or 0) % 64), 3
		elseif c >= 0xC0 then cp, len = ((c % 32) * 64) + ((s:byte(i + 1) or 0) % 64), 2
		else cp, len = c, 1 end
		out[#out + 1] = cp
		i = i + len
	end
	return out
end
M.utf8_codepoints = utf8_codepoints

-- install ------------------------------------------------------------------------------------

local EXTRA_GLOBALS = { "sound", "collectionproxy" }
local extra_saved = nil
local current_env = nil

local function parse_custom_resources(project)
	local list = {}
	for part in string.gmatch(project["project.custom_resources"] or "", "[^,%s]+") do list[#list + 1] = part end
	return list
end

local function under(path, dirs)
	for _, d in ipairs(dirs) do
		if path == d or string.sub(path, 1, #d + 1) == d .. "/" then return true end
	end
	return false
end

local function font_data()
	return require("tests.client.font_advances")
end

-- opts: {window = {w, h}, safe = {left, top, right, bottom} (window pixels), clock = seconds,
--        root = "."}. Returns the environment E (also M.env).
function M.install(opts)
	opts = opts or {}
	ROOT = opts.root or "."
	if current_env then M.restore() end
	local E = base.install({ window = opts.window, root = ROOT, collections = {} })
	local vmath, hash = _G.vmath, E.hash
	local V3, V4 = getmetatable(vmath.vector3(0, 0, 0)), getmetatable(vmath.vector4(0, 0, 0, 0))
	local function is_v3(v) return getmetatable(v) == V3 end
	local function is_v4(v) return getmetatable(v) == V4 end
	local function is_vec(v) return is_v3(v) or is_v4(v) end
	local function name_of(v)
		if type(v) == "string" then return v end
		if type(v) == "table" and v.s ~= nil and tostring(v):sub(1, 6) == "hash: " then return v.s end
		return nil
	end

	E.safe = opts.safe or { left = 0, top = 0, right = 0, bottom = 0 }
	E.clock = opts.clock or 1700000000
	E.scenes = {}          -- gui path -> scene
	E.scripts = {}         -- scripts made through E.script
	E.receivers = {}       -- url text -> script (messages posted to it are delivered by E.pump)
	E.input_stack = {}     -- scripts that took input focus, the last one is asked first
	E.unrouted = {}        -- messages nobody receives (main:/app, main:/audio#audio, ...)
	E.sounds = { played = {}, stopped = {}, gains = {}, group_gains = {} }
	E.limits.animations = tonumber(E.project["gui.max_animation_count"]) or 1024
	E.limits.characters = tonumber(E.project["graphics.max_characters"]) or 8192
	E.custom_resources = parse_custom_resources(E.project)
	local current = nil    -- the scene whose script is running (the engine's GUI context)

	function E.now() return E.clock end

	-- window ------------------------------------------------------------------------------------
	local window = rawget(_G, "window")
	window.get_size = function() return E.window.w, E.window.h end
	window.get_safe_area = function()
		local s = E.safe
		return { x = s.left, y = s.bottom, width = E.window.w - s.left - s.right, height = E.window.h - s.top - s.bottom,
			inset_left = s.left, inset_top = s.top, inset_right = s.right, inset_bottom = s.bottom }
	end
	function E.set_window(w, h) E.window.w, E.window.h = w, h end

	-- sys: resources only where the build bundles them (custom_resources) ------------------------------
	local sys = rawget(_G, "sys")
	sys.load_resource = function(path)
		if type(path) ~= "string" then error("sys.load_resource: a path string was expected", 2) end
		if not under(path, E.custom_resources) then
			return nil, "resource not found (not in custom_resources of game.project): " .. path
		end
		local text = read_file(path)
		if not text then return nil, "resource not found: " .. path end
		E.resources[path] = true
		return text
	end

	-- sound: recorded, no mixing ---------------------------------------------------------------------------
	local sound = {}
	function sound.play(url, props, cb) E.sounds.played[#E.sounds.played + 1] = { url = tostring(url), props = props } end
	function sound.stop(url) E.sounds.stopped[#E.sounds.stopped + 1] = tostring(url) end
	function sound.set_gain(url, g) E.sounds.gains[tostring(url)] = g end
	function sound.set_group_gain(group, g) E.sounds.group_gains[name_of(group) or tostring(group)] = g end
	function sound.get_rms(group, window_s) return 0, 0 end
	rawset(_G, "sound", sound)
	rawset(_G, "socket", { gettime = function() return E.clock end })

	-- GUI ---------------------------------------------------------------------------------------------------
	local gui = {}
	for i, n in ipairs(EASINGS) do gui["EASING_" .. n] = i end
	local EASING_SET = {}
	for i = 1, #EASINGS do EASING_SET[i] = EASINGS[i] end
	for i, n in ipairs(BLENDS) do gui["BLEND_" .. n] = 100 + i end
	local PIVOT_NAME = {}
	for i, n in ipairs(PIVOTS) do
		gui["PIVOT_" .. n] = 200 + i
		PIVOT_NAME[200 + i] = n
	end
	local PLAYBACK_NAME = {}
	for i, n in ipairs(PLAYBACKS) do
		gui["PLAYBACK_" .. n] = 300 + i
		PLAYBACK_NAME[300 + i] = n
	end
	gui.RESULT_OK, gui.RESULT_TEXTURE_ALREADY_EXISTS, gui.RESULT_OUT_OF_RESOURCES, gui.RESULT_DATA_ERROR = 0, -1, -2, -3
	gui.SIZE_MODE_MANUAL, gui.SIZE_MODE_AUTO = 400, 401

	local NODE = {}
	NODE.__index = NODE
	local CURVE_KEYS = {}

	local function ease(id, k)
		if k <= 0 then return 0 end
		if k >= 1 then return 1 end
		local name = EASING_SET[id] or "LINEAR"
		if name == "LINEAR" then return k end
		if name == "INQUAD" then return k * k end
		if name == "OUTQUAD" then return 1 - (1 - k) * (1 - k) end
		if name == "INOUTQUAD" then return k < 0.5 and 2 * k * k or 1 - (-2 * k + 2) ^ 2 / 2 end
		if name == "INSINE" then return 1 - math.cos(k * math.pi / 2) end
		if name == "OUTSINE" then return math.sin(k * math.pi / 2) end
		if name == "INOUTSINE" then return -(math.cos(math.pi * k) - 1) / 2 end
		if name == "OUTCUBIC" then return 1 - (1 - k) ^ 3 end
		if name == "INCUBIC" then return k ^ 3 end
		if name == "INOUTCUBIC" then return k < 0.5 and 4 * k ^ 3 or 1 - (-2 * k + 2) ^ 3 / 2 end
		if name == "OUTBACK" then
			local c1, c3 = 1.70158, 2.70158
			return 1 + c3 * (k - 1) ^ 3 + c1 * (k - 1) ^ 2
		end
		if name == "INBACK" then
			local c1, c3 = 1.70158, 2.70158
			return c3 * k ^ 3 - c1 * k ^ 2
		end
		return k
	end

	local function scene_of(n)
		return n.scene
	end

	local function live(n, level)
		if type(n) ~= "table" or getmetatable(n) ~= NODE then
			error("gui: a node was expected, got " .. tostring(n), (level or 2) + 1)
		end
		if n.dead then error("gui: the node " .. tostring(n.id or "?") .. " was deleted", (level or 2) + 1) end
		if not current then error("gui: no GUI script is running (call it through the script object)", (level or 2) + 1) end
		if n.scene ~= current then
			error("gui: a node of " .. n.scene.path .. " was used from the context of " .. current.path, (level or 2) + 1)
		end
		return n
	end

	local function vec_arg(v, what, level)
		if not is_vec(v) then error("gui." .. what .. ": a vector3 or vector4 was expected, got " .. tostring(v), level or 3) end
		return v
	end

	-- scenes: one per .gui file -------------------------------------------------------------------------
	local atlas_cache = {}
	local function atlas_anims(path)
		local a = atlas_cache[path]
		if not a then
			local text = read_file(path)
			if not text then error("atlas not found: " .. tostring(path)) end
			local doc = base.parse_proto(text)
			a = {}
			for _, an in ipairs(doc.animations or {}) do a[base.one(an, "id")] = true end
			atlas_cache[path] = a
		end
		return a
	end

	local font_cache = {}
	local function font_for(name)
		local f = font_cache[name]
		if f == nil then
			local d = font_data()[name]
			if not d then
				f = false
			else
				local chars = {}
				for cp in pairs(d.advances) do chars[cp] = true end -- order-free: a set
				f = { name = name, size = d.size, advances = d.advances, chars = chars }
			end
			font_cache[name] = f
		end
		return f or nil
	end

	local function new_scene(path)
		local text = read_file(path)
		if not text then error("stub: the gui file " .. path .. " does not exist") end
		local doc = base.parse_proto(text)
		local scene = {
			path = path, max_nodes = base.one(doc, "max_nodes") or 512, nodes = {}, n = 0, peak = 0,
			anims = {}, n_anims = 0, peak_anims = 0, order = nil,
			fonts = {}, font_list = {}, textures = {}, materials = {}, dyn = {}, ids = {},
			script_path = base.one(doc, "script"),
		}
		for _, f in ipairs(doc.fonts or {}) do
			local name = base.one(f, "name")
			scene.fonts[name] = true
			scene.font_list[#scene.font_list + 1] = name
			if not font_for(name) then error("stub: no advance table for the font '" .. name .. "'; run tests/client/font_advances.py") end
		end
		for _, t in ipairs(doc.textures or {}) do
			local name = base.one(t, "name")
			scene.textures[name] = { atlas = true, path = base.one(t, "texture") }
		end
		for _, m in ipairs(doc.materials or {}) do scene.materials[base.one(m, "name")] = true end
		return scene
	end

	-- A scene (GUI component) exists once per .gui path, like a loaded screen.
	function E.scene(path)
		local s = E.scenes[path]
		if not s then
			s = new_scene(path)
			E.scenes[path] = s
		end
		return s
	end

	local function new_node(kind, pos, size)
		if not current then error("gui: no GUI script is running", 3) end
		local scene = current
		if scene.n + 1 > scene.max_nodes then
			error("gui: the node buffer is full (max_nodes " .. scene.max_nodes .. " of " .. scene.path .. ")", 3)
		end
		local n = setmetatable({
			kind = kind, scene = scene, children = {}, parent = nil,
			pos = vmath.vector3(pos and pos.x or 0, pos and pos.y or 0, pos and pos.z or 0),
			size = size and vmath.vector3(size.x, size.y, size.z or 0) or vmath.vector3(0, 0, 0),
			scale = vmath.vector3(1, 1, 1), euler = vmath.vector3(0, 0, 0),
			color = vmath.vector4(1, 1, 1, 1), outline = vmath.vector4(1, 1, 1, 1), shadow = vmath.vector4(1, 1, 1, 1),
			enabled = true, pivot = gui.PIVOT_CENTER, blend = gui.BLEND_ALPHA, text = nil, font = scene.font_list[1],
		}, NODE)
		scene.nodes[#scene.nodes + 1] = n
		scene.n = scene.n + 1
		if scene.n > scene.peak then scene.peak = scene.n end
		return n
	end

	local function detach(n)
		if n.parent then
			local sib = n.parent.children
			for i = #sib, 1, -1 do
				if sib[i] == n then table.remove(sib, i) end
			end
		end
		n.parent = nil
	end

	local function drop_anims_of(scene, n)
		for i = #scene.anims, 1, -1 do
			if scene.anims[i].node == n then
				table.remove(scene.anims, i)
				scene.n_anims = scene.n_anims - 1
			end
		end
	end

	local function remove_tree(scene, n)
		for _, c in ipairs(n.children) do
			if not c.dead then remove_tree(scene, c) end
		end
		n.dead = true
		scene.n = scene.n - 1
		drop_anims_of(scene, n)
	end

	function gui.new_box_node(pos, size)
		vec_arg(pos, "new_box_node")
		vec_arg(size, "new_box_node")
		return new_node("box", pos, size)
	end
	function gui.new_text_node(pos, text)
		vec_arg(pos, "new_text_node")
		if type(text) ~= "string" then error("gui.new_text_node: a string was expected, got " .. type(text), 2) end
		local n = new_node("text", pos)
		n.text = text
		return n
	end
	function gui.delete_node(n)
		live(n)
		detach(n)
		remove_tree(n.scene, n)
	end
	function gui.set_parent(n, parent)
		live(n)
		if parent ~= nil then
			live(parent)
			local p = parent
			while p do
				if p == n then error("gui.set_parent: a node cannot become its own descendant", 2) end
				p = p.parent
			end
		end
		detach(n)
		n.parent = parent
		if parent then parent.children[#parent.children + 1] = n end
	end
	function gui.get_parent(n) return live(n).parent end
	function gui.set_position(n, v) live(n).pos = vmath.vector3(vec_arg(v, "set_position").x, v.y, v.z or 0) end
	function gui.get_position(n) return vmath.vector3(live(n).pos) end
	function gui.set_scale(n, v) live(n).scale = vmath.vector3(vec_arg(v, "set_scale").x, v.y, v.z or 1) end
	function gui.get_scale(n) return vmath.vector3(live(n).scale) end
	function gui.set_euler(n, v) live(n).euler = vmath.vector3(vec_arg(v, "set_euler").x, v.y, v.z or 0) end
	function gui.get_euler(n) return vmath.vector3(live(n).euler) end
	function gui.set_size(n, v) live(n).size = vmath.vector3(vec_arg(v, "set_size").x, v.y, v.z or 0) end
	function gui.get_size(n) return vmath.vector3(live(n).size) end
	function gui.set_color(n, v)
		live(n)
		if not is_v4(v) then error("gui.set_color: a vector4 was expected, got " .. tostring(v), 2) end
		n.color = vmath.vector4(v)
	end
	function gui.get_color(n) return vmath.vector4(live(n).color) end
	function gui.set_outline(n, v)
		live(n)
		if not is_v4(v) then error("gui.set_outline: a vector4 was expected, got " .. tostring(v), 2) end
		n.outline = vmath.vector4(v)
	end
	function gui.set_shadow(n, v)
		live(n)
		if not is_v4(v) then error("gui.set_shadow: a vector4 was expected, got " .. tostring(v), 2) end
		n.shadow = vmath.vector4(v)
	end
	function gui.set_enabled(n, on)
		live(n)
		if type(on) ~= "boolean" then error("gui.set_enabled: a boolean was expected, got " .. type(on), 2) end
		n.enabled = on
	end
	function gui.is_enabled(n, recursive)
		live(n)
		if not recursive then return n.enabled end
		local p = n
		while p do
			if not p.enabled then return false end
			p = p.parent
		end
		return true
	end
	function gui.set_pivot(n, p)
		live(n)
		if not PIVOT_NAME[p] then error("gui.set_pivot: a gui.PIVOT_* constant was expected, got " .. tostring(p), 2) end
		n.pivot = p
	end
	function gui.get_pivot(n) return live(n).pivot end
	function gui.set_blend_mode(n, m)
		live(n)
		if type(m) ~= "number" or m < 101 or m > 105 then error("gui.set_blend_mode: a gui.BLEND_* constant was expected, got " .. tostring(m), 2) end
		n.blend = m
	end
	function gui.set_id(n, id)
		live(n)
		n.id = name_of(id) or id
	end
	function gui.get_id(n) return hash(live(n).id or "") end
	function gui.get_node(id)
		local key = name_of(id)
		if not current then error("gui: no GUI script is running", 2) end
		for _, n in ipairs(current.nodes) do
			if not n.dead and n.id == key then return n end
		end
		error("gui.get_node: the node '" .. tostring(key) .. "' was not found", 2)
	end
	function gui.set_text(n, t)
		live(n)
		if n.kind ~= "text" then error("gui.set_text: not a text node", 2) end
		if type(t) == "number" then t = tostring(t) end
		if type(t) ~= "string" then error("gui.set_text: a string was expected, got " .. type(t), 2) end
		n.text = t
	end
	function gui.get_text(n)
		live(n)
		if n.kind ~= "text" then error("gui.get_text: not a text node", 2) end
		return n.text
	end
	function gui.set_font(n, f)
		live(n)
		local name = name_of(f)
		if not name or not n.scene.fonts[name] then
			error("gui.set_font: Font '" .. tostring(name) .. "' not found in " .. n.scene.path, 2)
		end
		n.font = name
	end
	function gui.get_font(n) return hash(live(n).font or "") end
	function gui.get_font_resource(f)
		local name = name_of(f)
		if not current or not name or not current.fonts[name] then
			error("gui.get_font_resource: Font '" .. tostring(name) .. "' not found", 2)
		end
		return setmetatable({ font = name }, { __tostring = function() return "font_resource:" .. name end })
	end
	function gui.set_line_break(n, on)
		live(n)
		if type(on) ~= "boolean" then error("gui.set_line_break: a boolean was expected", 2) end
		n.line_break = on
	end
	function gui.set_slice9(n, v)
		live(n)
		if not is_v4(v) then error("gui.set_slice9: a vector4 was expected, got " .. tostring(v), 2) end
		n.slice9 = vmath.vector4(v)
	end
	function gui.get_slice9(n) return vmath.vector4(live(n).slice9 or vmath.vector4(0, 0, 0, 0)) end
	function gui.set_texture(n, name)
		live(n)
		local key = name_of(name)
		local scene = n.scene
		if not key or not (scene.textures[key] or scene.dyn[key]) then
			error("gui.set_texture: Texture '" .. tostring(key) .. "' not found in " .. scene.path, 2)
		end
		n.texture = key
		n.anim = nil
	end
	function gui.play_flipbook(n, anim, complete)
		live(n)
		local id = name_of(anim)
		if not id then error("gui.play_flipbook: an animation id (string or hash) was expected", 2) end
		local tex = n.texture and (n.scene.textures[n.texture] or n.scene.dyn[n.texture])
		if not tex or not tex.atlas then
			error("gui.play_flipbook: the node has no atlas texture (set one with gui.set_texture first)", 2)
		end
		if not atlas_anims(tex.path)[id] then
			error("gui.play_flipbook: Animation '" .. id .. "' invalid (not found in " .. tex.path .. ")", 2)
		end
		n.anim = id
	end
	function gui.set_material(n, name)
		live(n)
		local key = name_of(name)
		if not key or not n.scene.materials[key] then
			error("gui.set_material: Material '" .. tostring(key) .. "' not found in " .. n.scene.path, 2)
		end
		n.material = key
	end
	function gui.set_render_order(o)
		if type(o) ~= "number" or o < 0 or o > 15 then error("gui.set_render_order: 0..15 expected", 2) end
		if current then current.order = o end
	end
	local function move_check(n, ref, what)
		live(n)
		if ref ~= nil then
			live(ref)
			if n.parent ~= ref.parent then error("gui." .. what .. ": the nodes must have the same parent", 3) end
		end
	end
	function gui.move_below(n, ref) move_check(n, ref, "move_below") end
	function gui.move_above(n, ref) move_check(n, ref, "move_above") end

	local TEXTURE_BYTES = { rgb = 3, rgba = 4, l = 1 }
	function gui.new_texture(name, w, h, kind, buf, flip)
		if not current then error("gui: no GUI script is running", 2) end
		if type(name) ~= "string" then error("gui.new_texture: the name must be a string", 2) end
		if type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then error("gui.new_texture: bad size", 2) end
		local bpp = TEXTURE_BYTES[kind]
		if not bpp then error("gui.new_texture: unknown type '" .. tostring(kind) .. "'", 2) end
		if type(buf) ~= "string" then error("gui.new_texture: the buffer must be a string", 2) end
		if #buf ~= w * h * bpp then
			error("gui.new_texture: the buffer of '" .. name .. "' has " .. #buf .. " bytes, " .. w .. "x" .. h .. " " .. kind ..
				" needs " .. (w * h * bpp), 2)
		end
		if current.dyn[name] or current.textures[name] then return false, gui.RESULT_TEXTURE_ALREADY_EXISTS end
		current.dyn[name] = { w = w, h = h, kind = kind, buf = buf }
		current.n_dyn = (current.n_dyn or 0) + 1
		return true, gui.RESULT_OK
	end
	function gui.delete_texture(name)
		if not current then error("gui: no GUI script is running", 2) end
		if type(name) ~= "string" then error("gui.delete_texture: the name must be a string", 2) end
		current.dyn[name] = nil
	end

	-- transforms and picking -------------------------------------------------------------------------------
	local function world(n)
		if not n.parent then return n.pos.x, n.pos.y, n.scale.x, n.scale.y end
		local px, py, psx, psy = world(n.parent)
		return px + n.pos.x * psx, py + n.pos.y * psy, psx * n.scale.x, psy * n.scale.y
	end
	E.world = world

	-- Window-pixel rectangle of a node: x0, y0, x1, y1 (the node's own size; text nodes without a size
	-- use their measured text).
	local function rect(n)
		local wx, wy, sx, sy = world(n)
		local w, h = n.size.x, n.size.y
		if n.kind == "text" and (w == 0 or not n.line_break) then
			local f = font_for(n.font or "body")
			local width = 0
			for _, cp in ipairs(utf8_codepoints(n.text or "")) do width = width + (f and f.advances[cp] or (f and f.size * 0.55) or 20) end
			w, h = width, (f and f.size or 32)
		end
		local fr = PIVOT_FRACTION[PIVOT_NAME[n.pivot]]
		local x0 = wx + fr[1] * w * sx
		local y0 = wy + fr[2] * h * sy
		return x0, y0, x0 + w * sx, y0 + h * sy
	end
	E.rect = rect

	function gui.pick_node(n, x, y)
		live(n)
		if type(x) ~= "number" or type(y) ~= "number" then error("gui.pick_node: numbers expected", 2) end
		local x0, y0, x1, y1 = rect(n)
		if x0 > x1 then x0, x1 = x1, x0 end
		if y0 > y1 then y0, y1 = y1, y0 end
		return x >= x0 and x <= x1 and y >= y0 and y <= y1
	end

	-- animations ---------------------------------------------------------------------------------------------
	local PROP_FIELD = { position = "pos", scale = "scale", euler = "euler", color = "color", outline = "outline",
		shadow = "shadow", size = "size", slice9 = "slice9", rotation = "rot" }
	local COMPONENTS = { "x", "y", "z", "w" }

	-- components of a property: {{field, comp}...}
	local function components(prop)
		local base_name, comp = prop:match("^([%a_0-9]+)%.?(%a*)$")
		local field = PROP_FIELD[base_name]
		if not field then return nil end
		if comp ~= "" then
			if not (comp == "x" or comp == "y" or comp == "z" or comp == "w") then return nil end
			return { { field, comp } }, base_name, comp
		end
		local n = (field == "color" or field == "outline" or field == "shadow" or field == "slice9" or field == "rot") and 4 or 3
		local out = {}
		for i = 1, n do out[i] = { field, COMPONENTS[i] } end
		return out, base_name, nil
	end

	local function node_value(n, field, comp)
		local t = n[field]
		if t == nil then return 0 end
		return t[comp] or 0
	end

	local function set_value(n, field, comp, v)
		local t = n[field]
		if t == nil then
			t = vmath.vector4(0, 0, 0, 0)
			n[field] = t
		end
		t[comp] = v
	end

	function gui.animate(n, property, to, easing, duration, delay, complete, playback)
		live(n)
		local prop = name_of(property)
		local comps, base_name, comp = nil, nil, nil
		if prop then comps, base_name, comp = components(prop) end
		if not comps then error("gui.animate: unknown property '" .. tostring(prop) .. "'", 2) end
		if comp then
			if type(to) ~= "number" then error("gui.animate: a number was expected for '" .. prop .. "', got " .. tostring(to), 2) end
		elseif not is_vec(to) then
			error("gui.animate: a vector was expected for '" .. prop .. "', got " .. tostring(to), 2)
		end
		local curve = nil
		if type(easing) == "table" and easing.n then
			curve = easing
		elseif type(easing) ~= "number" or not EASING_SET[easing] then
			error("gui.animate: a gui.EASING_* constant (or a vmath.vector curve) was expected, got " .. tostring(easing), 2)
		end
		if type(duration) ~= "number" or duration < 0 then error("gui.animate: duration must be a number >= 0", 2) end
		if delay ~= nil and (type(delay) ~= "number" or delay < 0) then error("gui.animate: delay must be a number >= 0", 2) end
		if complete ~= nil and type(complete) ~= "function" then error("gui.animate: complete_function must be a function", 2) end
		if playback ~= nil and not PLAYBACK_NAME[playback] then error("gui.animate: a gui.PLAYBACK_* constant was expected", 2) end
		local scene = n.scene
		E.count("gui_animate")
		for i, key in ipairs(comps) do
			-- a running animation of the same value is replaced, its callback never runs
			for j = #scene.anims, 1, -1 do
				local a = scene.anims[j]
				if a.node == n and a.field == key[1] and a.comp == key[2] then
					table.remove(scene.anims, j)
					scene.n_anims = scene.n_anims - 1
				end
			end
			if scene.n_anims + 1 > E.limits.animations then
				error("gui.animate: gui.max_animation_count (" .. E.limits.animations .. ") exceeded in " .. scene.path, 2)
			end
			local target = comp and to or to[key[2]]
			if target == nil then target = node_value(n, key[1], key[2]) end
			scene.anims[#scene.anims + 1] = {
				node = n, field = key[1], comp = key[2], to = target, dur = duration, delay = delay or 0, t = 0, easing = easing,
				curve = curve, cb = (i == 1) and complete or nil, playback = playback and PLAYBACK_NAME[playback] or "ONCE_FORWARD",
				started = false, prop = prop,
			}
			scene.n_anims = scene.n_anims + 1
		end
		if scene.n_anims > scene.peak_anims then scene.peak_anims = scene.n_anims end
	end

	function gui.cancel_animations(n, property)
		live(n)
		local comps
		if property ~= nil then
			local prop = name_of(property)
			comps = prop and components(prop)
			if not comps then error("gui.cancel_animations: unknown property '" .. tostring(prop) .. "'", 2) end
		end
		local scene = n.scene
		for j = #scene.anims, 1, -1 do
			local a = scene.anims[j]
			if a.node == n then
				local hit = comps == nil
				for _, key in ipairs(comps or {}) do
					if a.field == key[1] and a.comp == key[2] then hit = true end
				end
				if hit then
					table.remove(scene.anims, j)
					scene.n_anims = scene.n_anims - 1
				end
			end
		end
	end

	local function curve_value(curve, k)
		local n = curve.n
		if n <= 1 then return curve[1] or 1 end
		local pos = k * (n - 1) + 1
		local i = math.floor(pos)
		if i >= n then return curve[n] end
		local f = pos - i
		return curve[i] + (curve[i + 1] - curve[i]) * f
	end

	-- Steps the animations of a scene by dt seconds (the engine does this before the script's update);
	-- finished ones call back (outside the loop) as complete(self, node).
	function E.advance_scene(scene, dt, self)
		local done = {}
		local list = scene.anims
		local keep = {}
		for _, a in ipairs(list) do
			if not a.node.dead then
				local rem = dt
				if a.delay > 0 then
					local used = math.min(a.delay, rem)
					a.delay = a.delay - used
					rem = rem - used
				end
				if a.delay > 0 then
					keep[#keep + 1] = a
				else
					if not a.started then
						a.started = true
						a.from = node_value(a.node, a.field, a.comp)
					end
					a.t = a.t + rem
					local pb = a.playback
					local k
					local finished = false
					if pb == "LOOP_FORWARD" then
						k = a.dur > 0 and ((a.t % a.dur) / a.dur) or 1
					elseif pb == "LOOP_BACKWARD" then
						k = a.dur > 0 and (1 - (a.t % a.dur) / a.dur) or 0
					elseif pb == "LOOP_PINGPONG" then
						local ph = a.dur > 0 and ((a.t % (2 * a.dur)) / a.dur) or 0
						k = ph <= 1 and ph or 2 - ph
					elseif pb == "ONCE_PINGPONG" then
						local ph = a.dur > 0 and (a.t / a.dur) or 2
						if ph >= 2 then k, finished = 0, true else k = ph <= 1 and ph or 2 - ph end
					elseif pb == "ONCE_BACKWARD" then
						k = a.dur > 0 and (1 - a.t / a.dur) or 0
						if a.t >= a.dur then k, finished = 0, true end
					else
						k = a.dur > 0 and (a.t / a.dur) or 1
						if k >= 1 then k, finished = 1, true end
					end
					local e
					if a.curve then e = curve_value(a.curve, k) else e = ease(a.easing, k) end
					set_value(a.node, a.field, a.comp, a.from + (a.to - a.from) * e)
					if finished then
						done[#done + 1] = a
						scene.n_anims = scene.n_anims - 1
					else
						keep[#keep + 1] = a
					end
				end
			end
		end
		-- animations added by callbacks of this very step come after
		scene.anims = keep
		for _, a in ipairs(done) do
			if a.cb and not a.node.dead then a.cb(self, a.node) end
		end
	end

	-- queries for tests ---------------------------------------------------------------------------------------
	local function alive_nodes(scene)
		local out = {}
		for _, n in ipairs(scene.nodes) do
			if not n.dead then out[#out + 1] = n end
		end
		scene.nodes = out
		return out
	end
	E.alive_nodes = alive_nodes

	local function visible(n)
		local p = n
		while p do
			if not p.enabled then return false end
			p = p.parent
		end
		return true
	end
	E.visible = visible

	function E.text_width(n)
		local f = font_for(n.font or "body")
		local width = 0
		for _, cp in ipairs(utf8_codepoints(n.text or "")) do width = width + (f and f.advances[cp] or (f and f.size * 0.55) or 20) end
		return width
	end

	-- the engine side of resource.get_text_metrics: a font resource handle and a string
	local resource = rawget(_G, "resource")
	resource.get_text_metrics = function(font_res, text, options)
		local name = type(font_res) == "table" and font_res.font or nil
		local f = name and font_for(name)
		if not f then error("resource.get_text_metrics: a font resource was expected, got " .. tostring(font_res), 2) end
		local width = 0
		local longest = 0
		for _, cp in ipairs(utf8_codepoints(tostring(text or ""))) do
			if cp == 10 then
				longest, width = math.max(longest, width), 0
			else
				width = width + (f.advances[cp] or f.size * 0.55)
			end
		end
		return { width = math.max(longest, width), height = f.size * 1.25, max_ascent = f.size * 0.95, max_descent = f.size * 0.3 }
	end

	-- scripts ------------------------------------------------------------------------------------------------------
	local Script = {}
	Script.__index = Script

	-- The engine's script instance: userdata, no metatable of its own.
	local function new_self()
		local u = newproxy(true)
		local store = {}
		local mt = getmetatable(u)
		mt.__index = function(_, k) return store[k] end
		mt.__newindex = function(_, k, v) store[k] = v end
		return u
	end

	local function run_in(script, fn, ...)
		local before, before_script = current, E.current_script
		current, E.current_script = script.scene, script
		local res = { pcall(fn, ...) }
		current, E.current_script = before, before_script
		if not res[1] then error(res[2], 0) end
		return unpack(res, 2)
	end

	-- path: the .gui_script; gui_path: its .gui file; opts: {url = "main:/overlay#overlay", input = true}
	function E.script(path, gui_path, opts)
		opts = opts or {}
		local s = setmetatable({ E = E, path = path, gui_path = gui_path, scene = E.scene(gui_path), self = new_self() }, Script)
		s.env = base.load_script(path)
		s.frames = 0
		s.url = opts.url
		if opts.url then E.receivers[opts.url] = s end
		E.scripts[#E.scripts + 1] = s
		return s
	end

	function Script:call(name, ...)
		local fn = self.env[name]
		if not fn then return nil end
		return run_in(self, fn, self.self, ...)
	end

	function Script:init()
		self:call("init")
		return self
	end

	function Script:final()
		if self.finalized then return end
		self.finalized = true
		self:call("final")
		for i = #E.input_stack, 1, -1 do
			if E.input_stack[i] == self then table.remove(E.input_stack, i) end
		end
		if self.url and E.receivers[self.url] == self then E.receivers[self.url] = nil end
	end

	-- one frame: animations first, then the script's update (keep_clock: the caller moved E.clock)
	function Script:frame(dt, keep_clock)
		dt = dt or 1 / 60
		if not keep_clock then E.clock = E.clock + dt end
		run_in(self, E.advance_scene, self.scene, dt, self.self)
		self.frames = self.frames + 1
		self:call("update", dt)
	end

	-- n frames of every script given (default: this one); fs = list of scripts for a shared clock
	function Script:step(n, dt)
		for _ = 1, n or 1 do
			E.pump()
			self:frame(dt)
		end
		E.pump()
	end

	-- seconds of frames (60 per second)
	function Script:run(seconds)
		self:step(math.ceil(seconds * 60))
	end

	function Script:message(id, message, sender)
		local fn = self.env.on_message
		if not fn then return end
		return run_in(self, fn, self.self, hash(id), message or {}, sender)
	end

	-- focus requests move the script in the input stack; everything else is queued by the board
	-- harness' msg.post and delivered by E.pump
	local board_post = rawget(_G, "msg").post
	rawget(_G, "msg").post = function(receiver, id, message)
		local who = E.current_script
		if (receiver == "." or receiver == "#") and who then
			if id == "acquire_input_focus" then
				for i = #E.input_stack, 1, -1 do
					if E.input_stack[i] == who then table.remove(E.input_stack, i) end
				end
				E.input_stack[#E.input_stack + 1] = who
				return
			elseif id == "release_input_focus" then
				for i = #E.input_stack, 1, -1 do
					if E.input_stack[i] == who then table.remove(E.input_stack, i) end
				end
				return
			end
		end
		return board_post(receiver, id, message)
	end

	-- messages posted to a script's url are delivered here (called every step)
	local function route()
		local pending = E.msgs
		E.msgs = {}
		for _, m in ipairs(pending) do
			local target = E.receivers[m.to]
			if target and not target.finalized then
				target:message(m.id, m.message, E.sender_url)
			elseif m.to == "." then
				-- input focus requests and the like: nothing to do
			else
				E.unrouted[#E.unrouted + 1] = m
			end
		end
	end
	function E.pump()
		-- a delivered message may post more: bounded loop
		for _ = 1, 8 do
			if #E.msgs == 0 then return end
			route()
		end
	end

	-- the unrouted messages with this id (and optional receiver), oldest first
	function E.posted(id, to)
		local out = {}
		for _, m in ipairs(E.unrouted) do
			if m.id == id and (to == nil or m.to == to) then out[#out + 1] = m end
		end
		return out
	end

	-- input -----------------------------------------------------------------------------------------------------------
	local layout = require("client.layout")
	function E.to_window(lx, ly)
		local f = layout.fit(E.window.w, E.window.h)
		return f.ox + lx * f.scale, f.oy + ly * f.scale
	end
	function E.to_logical(wx, wy)
		local f = layout.fit(E.window.w, E.window.h)
		return (wx - f.ox) / f.scale, (wy - f.oy) / f.scale
	end

	-- Sends an input action to the scripts in focus order (the last one that took focus first)
	-- until one consumes it. Returns the consuming script or nil.
	function E.input(action_id, action)
		for i = #E.input_stack, 1, -1 do
			local s = E.input_stack[i]
			local used = s:call("on_input", action_id, action)
			if used then return s end
		end
		return nil
	end

	local TOUCH = hash("touch")
	function E.touch_action(lx, ly, pressed, released)
		local wx, wy = E.to_window(lx, ly)
		return { x = wx, y = wy, screen_x = wx, screen_y = wy, pressed = pressed or false, released = released or false }
	end

	-- A tap at logical coordinates: press, two frames, release, a frame. frames = scripts to step.
	function E.tap(lx, ly, frames)
		frames = frames or E.scripts
		local function step(n)
			for _ = 1, n do
				E.clock = E.clock + 1 / 60
				E.pump()
				for _, s in ipairs(frames) do
					if not s.finalized then s:frame(1 / 60, true) end
				end
			end
		end
		local a = E.input(TOUCH, E.touch_action(lx, ly, true, false))
		step(2)
		local b = E.input(TOUCH, E.touch_action(lx, ly, false, true))
		step(1)
		E.pump()
		return a, b
	end

	function E.step(n, dt)
		dt = dt or 1 / 60
		for _ = 1, n or 1 do
			E.clock = E.clock + dt
			E.pump()
			for _, s in ipairs(E.scripts) do
				if not s.finalized then s:frame(dt, true) end
			end
		end
		E.pump()
	end

	function E.run(seconds)
		E.step(math.ceil(seconds * 60))
	end

	function Script:tap(lx, ly)
		return E.tap(lx, ly, { self })
	end

	-- the live texts of the scene; opts.visible = only nodes that can be seen
	function Script:texts(only_visible)
		local out = {}
		for _, n in ipairs(alive_nodes(self.scene)) do
			if n.kind == "text" and (not only_visible or visible(n)) then out[#out + 1] = n.text end
		end
		return out
	end

	function Script:has_text(text, only_visible)
		for _, t in ipairs(self:texts(only_visible)) do
			if t == text then return true end
		end
		return false
	end

	-- the first visible text node (plain match of the whole text, or a Lua pattern with opts.pattern)
	function Script:find(text, pattern)
		for _, n in ipairs(alive_nodes(self.scene)) do
			if n.kind == "text" and visible(n) and n.text ~= nil then
				if pattern then
					if string.find(n.text, text) then return n end
				elseif n.text == text then
					return n
				end
			end
		end
		return nil
	end

	-- logical centre of a node
	function E.centre(n)
		local x0, y0, x1, y1 = rect(n)
		return E.to_logical((x0 + x1) / 2, (y0 + y1) / 2)
	end

	function Script:tap_text(text, pattern)
		local n = self:find(text, pattern)
		if not n then error("tap_text: no visible text '" .. tostring(text) .. "'; texts: " .. table.concat(self:texts(true), " | "), 2) end
		local lx, ly = E.centre(n)
		return self:tap(lx, ly), lx, ly
	end

	function Script:stats()
		local s = self.scene
		return { nodes = s.n, peak = s.peak, anims = s.n_anims, peak_anims = s.peak_anims, textures = s.n_dyn or 0 }
	end


	-- A picture of a scene for tests/client/gui_snapshot.py: its nodes in draw order (parents first,
	-- siblings in order) with world positions (window pixels), scales, rotation, colours, textures,
	-- texts. dyn textures carry their pixels (hex), loose images the file they come from.
	local function hex_of(buf)
		return (string.gsub(buf, ".", function(c) return string.format("%02x", string.byte(c)) end))
	end

	function E.dump_scene(scene)
		if type(scene) == "string" then scene = E.scenes[scene] end
		local out = { path = scene.path, order = scene.order, nodes = {}, textures = {}, atlases = {} }
		for name, t in pairs(scene.textures) do -- order-free: a map
			out.atlases[name] = t.path
		end
		local assets = require("client.assets")
		local function walk(n, rot, vis)
			if n.dead then return end
			local wx, wy, sx, sy = world(n)
			local z = rot + (n.euler.z or 0)
			vis = vis and n.enabled
			local item = {
				k = n.kind, x = wx, y = wy, sx = sx, sy = sy, w = n.size.x, h = n.size.y, pv = PIVOT_NAME[n.pivot],
				c = { n.color.x, n.color.y, n.color.z, n.color.w }, z = z, en = vis, id = n.id,
				add = (n.blend == gui.BLEND_ADD) or nil, mat = n.material,
			}
			if n.slice9 then item.s9 = { n.slice9.x, n.slice9.y, n.slice9.z, n.slice9.w } end
			if n.texture then
				item.tex = n.texture
				local dyn = n.scene.dyn[n.texture]
				if dyn and not out.textures[n.texture] then
					if string.sub(n.texture, 1, 4) == "img:" then
						local e = assets.image(string.sub(n.texture, 5))
						out.textures[n.texture] = { file = e and e.file or nil, w = dyn.w, h = dyn.h }
					else
						out.textures[n.texture] = { w = dyn.w, h = dyn.h, hex = hex_of(dyn.buf) }
					end
				end
				if n.anim then item.anim = n.anim end
			end
			if n.kind == "text" then
				item.text, item.font, item.lb = n.text, n.font, n.line_break or nil
				item.oc = { n.outline.x, n.outline.y, n.outline.z, n.outline.w }
				item.sc = { n.shadow.x, n.shadow.y, n.shadow.z, n.shadow.w }
			end
			out.nodes[#out.nodes + 1] = item
			for _, c in ipairs(n.children) do walk(c, z, vis) end
		end
		for _, n in ipairs(scene.nodes) do
			if not n.dead and not n.parent then walk(n, 0, true) end
		end
		return out
	end

	-- audit ---------------------------------------------------------------------------------------------------------------
	-- A list of problems in every live scene: glyphs the font lacks, characters over the budget, ...
	function E.audit()
		local problems = {}
		local chars = 0
		for path, scene in pairs(E.scenes) do -- order-free: a list of problems
			for _, n in ipairs(alive_nodes(scene)) do
				if n.kind == "text" and n.text then
					local f = font_for(n.font or "body")
					chars = chars + #n.text
					for _, cp in ipairs(utf8_codepoints(n.text)) do
						if cp ~= 10 and f and not f.chars[cp] then
							problems[#problems + 1] = string.format("%s: U+%04X is not in the font '%s' (text '%s')", path, cp, n.font, n.text)
						end
					end
				end
			end
		end
		if chars > E.limits.characters then
			problems[#problems + 1] = "live text characters " .. chars .. " exceed graphics.max_characters " .. E.limits.characters
		end
		table.sort(problems)
		return problems
	end

	-- effective size of a text in logical pixels: font size x node scale x the scales above it (the
	-- scene root's fit scale is taken out)
	function E.text_px(n)
		local f = font_for(n.font or "body")
		local _, _, sx = world(n)
		local fit = layout.fit(E.window.w, E.window.h)
		return (f and f.size or 32) * sx / fit.scale
	end

	-- the smallest visible texts of a scene: {{text, px}} sorted by px
	function Script:smallest_texts(limit)
		local list = {}
		for _, n in ipairs(alive_nodes(self.scene)) do
			if n.kind == "text" and visible(n) and n.text and n.text ~= "" then
				local c = n.color
				if c.w > 0.05 then list[#list + 1] = { text = n.text, px = E.text_px(n) } end
			end
		end
		table.sort(list, function(a, b) if a.px ~= b.px then return a.px < b.px end return a.text < b.text end)
		local out = {}
		for i = 1, math.min(limit or 5, #list) do out[i] = list[i] end
		return out
	end

	-- install the globals ------------------------------------------------------------------------------------------------
	extra_saved = {}
	for _, name in ipairs(EXTRA_GLOBALS) do extra_saved[name] = rawget(_G, name) end
	rawset(_G, "sound", sound)
	rawset(_G, "gui", gui)
	rawset(_G, "socket", rawget(_G, "socket"))

	E.gui = gui
	E.shutdown = function() M.restore() end
	current_env = E
	M.env = E
	return E
end

function M.restore()
	local E = current_env
	if E then
		for i = #E.scripts, 1, -1 do pcall(E.scripts[i].final, E.scripts[i]) end
	end
	current_env = nil
	M.env = nil
	if extra_saved then
		for _, name in ipairs(EXTRA_GLOBALS) do rawset(_G, name, extra_saved[name]) end
		extra_saved = nil
	end
	base.restore()
end

-- Installs the stub and boots the app on the real content (content/districts.json): the
-- meta, the save store (in memory), the language. opts: {window, safe, language = "en",
-- seed = 42, backend = save_io backend, debug = true}.
function M.boot(opts)
	opts = opts or {}
	local E = M.install(opts)
	local ok, err = pcall(function()
		local app = require("client.app")
		local json = require("tools.lib.json")
		local i18n = require("client.i18n")
		local save_io = require("client.save_io")
		local analytics = require("client.services.analytics")
		local rewards = require("client.rewards")
		local bus = require("client.bus")
		local f = assert(io.open("content/districts.json", "r"))
		local districts = json.decode(f:read("*a"))
		f:close()
		analytics.init({ strict = true })
		rewards.clear()
		E.backend = opts.backend or save_io.memory_backend()
		app.init({
			districts = districts, store = save_io.new(E.backend), seed = opts.seed or 42, now = E.clock,
			clock = E.now, sys_language = opts.language or "en", debug = opts.debug ~= false,
		})
		i18n.set_language(opts.language or "en")
		E.bus = bus
	end)
	if not ok then
		M.restore()
		error(err, 0)
	end
	return E
end

function M.shutdown()
	M.restore()
end

return M
