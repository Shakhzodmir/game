-- A headless stand-in for the part of Defold 1.13 that the level board
-- uses, so the Defold glue (screens/level/board.script, client/level_view.lua,
-- client/level_vfx.lua) can run in the pure-Lua test suite. There is no
-- Defold build tool in the dev container; this is the guard against typos,
-- wrong factory / component names, unknown atlas animations, unknown
-- particle emitters and blown engine limits.
--
-- The stub is STRICT: it reads the real project files (game.project, the
-- .collection / .go / .particlefx / .material / .atlas text protos) and
-- raises an error where the engine would refuse or silently misbehave:
--   * factory.create of an unknown factory, or past the limits of game.project
--     (collection.max_instances, sprite.max_count, particle_fx.max_count,
--     particle_fx.max_emitter_count, factory.max_count);
--   * sprite.play_flipbook with an animation the atlas does not have;
--   * go.set of a property the component does not have (sprite vertex
--     attributes come from the material);
--   * particlefx.set_constant on an emitter the particle effect does not have, or on an effect that is
--     not playing (never played, or its instance already pruned: the engine drops the constant);
--   * go.* on an instance that was deleted.
--
--   local stub = require("tests.client.level_defold_stub")
--   local E = stub.install({window = {720, 1280}})   -- sets the globals
--   ... run scripts ...
--   stub.restore()
--
-- E.objects / E.counts / E.msgs / E.live_particles() describe what happened.
-- Not a renderer: nothing is drawn, only state is kept.

local M = {}

-- text proto -----------------------------------------------------------------------

-- Parses a Defold text-format file into {field = {value, ...}} (every field
-- is a list, repeated fields have several entries). Values are strings,
-- numbers, booleans (true / false), enum names (strings) or nested messages
-- (tables of the same shape). Adjacent string literals concatenate.
function M.parse_proto(text)
	local pos, len = 1, #text
	local function skip()
		while pos <= len do
			local c = text:sub(pos, pos)
			if c == " " or c == "\t" or c == "\r" or c == "\n" then
				pos = pos + 1
			elseif c == "#" then
				local nl = text:find("\n", pos, true)
				pos = nl and nl + 1 or len + 1
			else
				break
			end
		end
	end
	local function read_string()
		local q = text:sub(pos, pos)
		pos = pos + 1
		local buf = {}
		while pos <= len do
			local c = text:sub(pos, pos)
			if c == "\\" then
				local n = text:sub(pos + 1, pos + 1)
				if n == "n" then buf[#buf + 1] = "\n"
				elseif n == "t" then buf[#buf + 1] = "\t"
				elseif n == "r" then buf[#buf + 1] = "\r"
				else buf[#buf + 1] = n end
				pos = pos + 2
			elseif c == q then
				pos = pos + 1
				return table.concat(buf)
			else
				buf[#buf + 1] = c
				pos = pos + 1
			end
		end
		error("proto: unterminated string")
	end
	local parse_message
	local function read_value()
		skip()
		local c = text:sub(pos, pos)
		if c == "{" then
			pos = pos + 1
			local m = parse_message("}")
			return m
		elseif c == '"' or c == "'" then
			local s = read_string()
			while true do
				skip()
				local d = text:sub(pos, pos)
				if d == '"' or d == "'" then s = s .. read_string() else break end
			end
			return s
		end
		local word = text:match("^[%w_%.%-%+]+", pos)
		if not word then error("proto: unexpected '" .. c .. "' at " .. pos) end
		pos = pos + #word
		if word == "true" then return true end
		if word == "false" then return false end
		local num = tonumber(word)
		if num then return num end
		return word
	end
	parse_message = function(close)
		local msg = {}
		while true do
			skip()
			if pos > len then
				if close then error("proto: missing }") end
				return msg
			end
			local c = text:sub(pos, pos)
			if c == close then
				pos = pos + 1
				return msg
			end
			local name = text:match("^[%a_][%w_]*", pos)
			if not name then error("proto: expected a field name at " .. pos .. ": '" .. text:sub(pos, pos + 20) .. "'") end
			pos = pos + #name
			skip()
			if text:sub(pos, pos) == ":" then pos = pos + 1 end
			local v = read_value()
			local list = msg[name]
			if not list then
				list = {}
				msg[name] = list
			end
			list[#list + 1] = v
		end
	end
	return parse_message(nil)
end

local function one(msg, key)
	return msg and msg[key] and msg[key][1] or nil
end
M.one = one

local function read_file(root, path)
	local f = io.open(root .. path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- game.project ----------------------------------------------------------------------

local function parse_project(text)
	local cfg, section = {}, nil
	for line in (text or ""):gmatch("[^\r\n]+") do
		local sec = line:match("^%[([%w_%.]+)%]")
		if sec then
			section = sec
		else
			local k, v = line:match("^([%w_%.]+)%s*=%s*(.-)%s*$")
			if k and section then cfg[section .. "." .. k] = v end
		end
	end
	return cfg
end

-- vectors ------------------------------------------------------------------------------

local V3, V4, QT = {}, {}, {}
V3.__index, V4.__index, QT.__index = V3, V4, QT

local function num_or(v, d)
	if type(v) == "number" then return v end
	return d
end

local function vector3(x, y, z)
	if type(x) == "table" then return setmetatable({ x = x.x, y = x.y, z = x.z }, V3) end
	if y == nil and z == nil and type(x) == "number" then return setmetatable({ x = x, y = x, z = x }, V3) end
	return setmetatable({ x = num_or(x, 0), y = num_or(y, 0), z = num_or(z, 0) }, V3)
end
local function vector4(x, y, z, w)
	if type(x) == "table" then return setmetatable({ x = x.x, y = x.y, z = x.z, w = x.w }, V4) end
	if y == nil and z == nil and w == nil and type(x) == "number" then
		return setmetatable({ x = x, y = x, z = x, w = x }, V4)
	end
	return setmetatable({ x = num_or(x, 0), y = num_or(y, 0), z = num_or(z, 0), w = num_or(w, 0) }, V4)
end

V3.__mul = function(a, b)
	if type(a) == "number" then a, b = b, a end
	if type(b) == "number" then return vector3(a.x * b, a.y * b, a.z * b) end
	return vector3(a.x * b.x, a.y * b.y, a.z * b.z)
end
V3.__add = function(a, b) return vector3(a.x + b.x, a.y + b.y, a.z + b.z) end
V3.__sub = function(a, b) return vector3(a.x - b.x, a.y - b.y, a.z - b.z) end
V3.__unm = function(a) return vector3(-a.x, -a.y, -a.z) end
V3.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
V3.__tostring = function(a) return string.format("vmath.vector3(%g, %g, %g)", a.x, a.y, a.z) end
V4.__mul = function(a, b)
	if type(a) == "number" then a, b = b, a end
	if type(b) == "number" then return vector4(a.x * b, a.y * b, a.z * b, a.w * b) end
	return vector4(a.x * b.x, a.y * b.y, a.z * b.z, a.w * b.w)
end
V4.__add = function(a, b) return vector4(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w) end
V4.__sub = function(a, b) return vector4(a.x - b.x, a.y - b.y, a.z - b.z, a.w - b.w) end
V4.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z and a.w == b.w end
V4.__tostring = function(a) return string.format("vmath.vector4(%g, %g, %g, %g)", a.x, a.y, a.z, a.w) end

local function is_v3(v) return getmetatable(v) == V3 end
local function is_v4(v) return getmetatable(v) == V4 end
local function is_quat(v) return getmetatable(v) == QT end

local function quat_rotation_z(angle)
	return setmetatable({ x = 0, y = 0, z = math.sin(angle / 2), w = math.cos(angle / 2) }, QT)
end

local function make_vmath()
	return {
		vector3 = vector3, vector4 = vector4,
		quat_rotation_z = quat_rotation_z,
		quat = function() return setmetatable({ x = 0, y = 0, z = 0, w = 1 }, QT) end,
		vector = function(t) return setmetatable({ n = #t, unpack(t) }, { __index = function() return 0 end }) end,
		length = function(v)
			return math.sqrt((v.x or 0) ^ 2 + (v.y or 0) ^ 2 + (v.z or 0) ^ 2 + (v.w or 0) ^ 2)
		end,
		lerp = function(t, a, b) return a + (b - a) * t end,
	}
end

-- hashes and urls ------------------------------------------------------------------------

local HASH = {}
HASH.__tostring = function(h) return "hash: [" .. h.s .. "]" end

-- One interning table for the whole process: like the engine's, hash("x") is the same value in every
-- install, so a module that keeps hash("touch") in a constant (client/ui.lua, gui/kit.lua) still
-- compares equal after the stub is installed again.
local INTERNED = {}

local function make_hash_table()
	local interned = INTERNED
	local function hash(s)
		if type(s) ~= "string" then error("hash: string expected, got " .. type(s), 2) end
		local h = interned[s]
		if not h then
			h = setmetatable({ s = s }, HASH)
			interned[s] = h
		end
		return h
	end
	return hash
end

local function name_of(v)
	if type(v) == "string" then return v end
	if getmetatable(v) == HASH then return v.s end
	return nil
end

local URL = {}
URL.__tostring = function(u) return "url: [" .. tostring(u.socket) .. ":" .. tostring(u.path) .. "#" .. tostring(u.fragment) .. "]" end

-- install --------------------------------------------------------------------------------

local GLOBALS = { "hash", "vmath", "msg", "go", "factory", "sprite", "particlefx", "window", "sys", "json", "gui",
	"image", "resource", "html5", "socket", "label", "timer", "collectionfactory", "render", "graphics" }
local saved = nil

function M.install(opts)
	opts = opts or {}
	if saved then M.restore() end
	local root = opts.root or "."
	local E = {
		root = root,
		time = 0,
		window = { w = (opts.window and opts.window[1]) or 720, h = (opts.window and opts.window[2]) or 1280 },
		msgs = {},
		objects = {},          -- id name -> instance record
		n_objects = 0, n_sprites = 0, n_particlefx = 0, n_emitters = 0,
		next_id = 0,
		counts = {},
		batches = {},          -- live particle batches {n, untilt, emitter, url}
		peak_particles = 0,
		resources = {},        -- path -> text of the files read
	}
	function E.count(name) E.counts[name] = (E.counts[name] or 0) + 1 end
	function E.reset_counts() E.counts = {} end

	local hash = make_hash_table()
	E.hash = hash

	-- project, atlas, collection ---------------------------------------------------------
	E.project = parse_project(read_file(root, "/game.project"))
	local function limit(key, default)
		return tonumber(E.project[key]) or default
	end
	E.limits = {
		max_instances = limit("collection.max_instances", 1024),
		sprites = limit("sprite.max_count", 128),
		particlefx = limit("particle_fx.max_count", 64),
		emitters = limit("particle_fx.max_emitter_count", 64),
		particles = limit("particle_fx.max_particle_count", 1024),
		factories = limit("factory.max_count", 128),
	}

	local atlas_cache, proto_cache, fx_cache, material_cache = {}, {}, {}, {}
	local function atlas(path)
		local a = atlas_cache[path]
		if not a then
			local text = read_file(root, path)
			if not text then error("atlas not found: " .. tostring(path)) end
			local doc = M.parse_proto(text)
			a = { ids = {} }
			for _, an in ipairs(doc.animations or {}) do a.ids[one(an, "id")] = true end
			atlas_cache[path] = a
		end
		return a
	end
	local function material(path)
		local m = material_cache[path]
		if not m then
			local text = read_file(root, path)
			if not text then error("material not found: " .. tostring(path)) end
			local doc = M.parse_proto(text)
			m = { attributes = {}, constants = {} }
			for _, a in ipairs(doc.attributes or {}) do m.attributes[one(a, "name")] = true end
			for _, c in ipairs(doc.fragment_constants or {}) do m.constants[one(c, "name")] = true end
			for _, c in ipairs(doc.vertex_constants or {}) do m.constants[one(c, "name")] = true end
			material_cache[path] = m
		end
		return m
	end
	local function particlefx_def(path)
		local d = fx_cache[path]
		if not d then
			local text = read_file(root, path)
			if not text then error("particlefx not found: " .. tostring(path)) end
			local doc = M.parse_proto(text)
			d = { emitters = {}, list = {} }
			for _, em in ipairs(doc.emitters or {}) do
				local id = one(em, "id")
				local life = 1
				for _, p in ipairs(em.properties or {}) do
					if one(p, "key") == "EMITTER_KEY_PARTICLE_LIFE_TIME" then
						local pt = one(p, "points")
						life = (pt and one(pt, "y") or 1) + (one(p, "spread") or 0)
					end
				end
				-- span: how long the engine keeps the instance of this emitter: its start delay, the
				-- emission (duration) and the longest particle life
				local e = { id = id, count = one(em, "max_particle_count") or 0, life = life,
					span = (one(em, "start_delay") or 0) + (one(em, "duration") or 0) + life,
					animation = one(em, "animation"), tile_source = one(em, "tile_source") }
				d.emitters[id] = e
				d.list[#d.list + 1] = e
			end
			fx_cache[path] = d
		end
		return d
	end
	local function prototype(path)
		local p = proto_cache[path]
		if p then return p end
		local text = read_file(root, path)
		if not text then error("prototype not found: " .. tostring(path)) end
		local doc = M.parse_proto(text)
		p = { path = path, comps = {}, order = {} }
		for _, c in ipairs(doc.components or {}) do
			local id, file = one(c, "id"), one(c, "component")
			local kind = file:match("%.(%w+)$")
			p.comps[id] = { id = id, type = kind, file = file }
			p.order[#p.order + 1] = id
		end
		for _, c in ipairs(doc.embedded_components or {}) do
			local id, kind = one(c, "id"), one(c, "type")
			local data = M.parse_proto(one(c, "data") or "")
			p.comps[id] = { id = id, type = kind, data = data }
			p.order[#p.order + 1] = id
		end
		for _, id in ipairs(p.order) do
			local c = p.comps[id]
			if c.type == "sprite" then
				local tex = one(c.data, "textures")
				c.atlas = tex and one(tex, "texture")
				c.material = one(c.data, "material")
				c.anims = c.atlas and atlas(c.atlas).ids or {}
				c.attrs = c.material and material(c.material).attributes or {}
				c.constants = c.material and material(c.material).constants or {}
			elseif c.type == "particlefx" then
				c.fx = particlefx_def(c.file)
			end
		end
		proto_cache[path] = p
		return p
	end
	E.prototype = prototype

	-- the collection of the screen: its factories ---------------------------------------
	E.factories = {}
	local function load_collection(path)
		local text = read_file(root, path)
		if not text then return end
		local doc = M.parse_proto(text)
		for _, inst in ipairs(doc.embedded_instances or {}) do
			local data = M.parse_proto(one(inst, "data") or "")
			for _, c in ipairs(data.embedded_components or {}) do
				if one(c, "type") == "factory" then
					local fd = M.parse_proto(one(c, "data") or "")
					E.factories[one(c, "id")] = one(fd, "prototype")
				end
			end
		end
	end
	for _, path in ipairs(opts.collections or { "/screens/level/level.collection" }) do load_collection(path) end
	local n_factories = 0
	for _ in pairs(E.factories) do n_factories = n_factories + 1 end -- order-independent
	if n_factories > E.limits.factories then error("stub: factory.max_count exceeded by the collection") end

	-- msg ----------------------------------------------------------------------------------
	local msg = {}
	function msg.url(socket, path, fragment)
		if socket ~= nil and path == nil and fragment == nil and type(socket) == "string" then
			local sock, p, frag = socket:match("^([^:]*):?([^#]*)#?(.*)$")
			return setmetatable({ socket = sock ~= "" and sock or nil, path = p ~= "" and p or nil,
				fragment = frag ~= "" and frag or nil }, URL)
		end
		return setmetatable({ socket = socket, path = path, fragment = fragment }, URL)
	end
	function msg.post(receiver, id, message)
		E.count("msg_post")
		local rname = type(receiver) == "string" and receiver or tostring(receiver)
		E.msgs[#E.msgs + 1] = { to = rname, id = name_of(id) or tostring(id), message = message }
	end

	-- go / factory / sprite / particlefx ------------------------------------------------------
	local go, factory, sprite, particlefx = {}, {}, {}, {}

	local function instance(id, level)
		local key = name_of(id)
		if type(id) == "table" and getmetatable(id) == URL then key = name_of(id.path) end
		local o = key and E.objects[key]
		if not o then error("go: the instance " .. tostring(key or id) .. " does not exist (deleted or never created)", (level or 1) + 1) end
		return o
	end

	local function component(url, level)
		level = (level or 1) + 1
		local path, frag
		if getmetatable(url) == URL then
			path, frag = name_of(url.path), name_of(url.fragment)
		elseif type(url) == "string" then
			frag = url:match("#(.*)$")
		else
			error("go: a url is required, got " .. tostring(url), level)
		end
		if not path then error("go: url without an instance path: " .. tostring(url), level) end
		local o = E.objects[path]
		if not o then error("go: the instance " .. path .. " does not exist", level) end
		local c = o.proto.comps[frag or ""]
		if not c then error("go: no component '" .. tostring(frag) .. "' in " .. o.proto.path, level) end
		return o, c
	end

	function go.set_position(pos, id)
		E.count("go_set_position")
		if not is_v3(pos) then error("go.set_position: vector3 expected", 2) end
		local o = instance(id, 2)
		o.pos.x, o.pos.y, o.pos.z = pos.x, pos.y, pos.z
	end
	function go.set_scale(scale, id)
		E.count("go_set_scale")
		local o = instance(id, 2)
		-- the engine refuses (logs an error, keeps the old scale) a scale with a component <= 0; this
		-- showed up only in the first live browser run, so the stub is strict about it too
		if type(scale) == "number" then
			if not (scale > 0) then error("go.set_scale: Vector passed to go.set_scale contains components that are below or equal to zero", 2) end
			o.scale = vector3(scale, scale, scale)
		elseif is_v3(scale) then
			if not (scale.x > 0 and scale.y > 0 and scale.z > 0) then
				error("go.set_scale: Vector passed to go.set_scale contains components that are below or equal to zero", 2)
			end
			o.scale = vector3(scale)
		else
			error("go.set_scale: number or vector3 expected", 2)
		end
	end
	function go.set_rotation(rot, id)
		E.count("go_set_rotation")
		if not is_quat(rot) then error("go.set_rotation: quaternion expected", 2) end
		local o = instance(id, 2)
		o.rot = rot
	end
	function go.get_position(id)
		return vector3(instance(id, 2).pos)
	end
	function go.get_scale(id)
		return vector3(instance(id, 2).scale)
	end
	function go.set(url, property, value)
		E.count("go_set")
		local o, c = component(url, 2)
		local prop = name_of(property)
		if not prop then error("go.set: property must be a string or hash", 2) end
		if c.type == "sprite" then
			local ok = c.attrs[prop] or prop == "tint" or prop == "cursor" or prop == "playback_rate"
				or prop == "scale" or prop == "size" or prop == "slice" or c.constants[prop]
			if not ok then error("go.set: the sprite has no property '" .. prop .. "' (material attributes: vcolor, vfx...)", 2) end
			if c.attrs[prop] and not is_v4(value) then error("go.set: vector4 expected for attribute " .. prop, 2) end
			c.props = c.props or {}
			c.props[prop] = is_v4(value) and vector4(value) or value
		else
			error("go.set: unsupported component type " .. tostring(c.type), 2)
		end
		o.touched = true
	end
	function go.delete(id)
		E.count("go_delete")
		local list = id
		if type(id) ~= "table" or getmetatable(id) == HASH or getmetatable(id) == URL then list = { id } end
		for _, one_id in ipairs(list) do
			local o = instance(one_id, 2)
			E.objects[o.key] = nil
			E.n_objects = E.n_objects - 1
			for _, cid in ipairs(o.proto.order) do
				local c = o.proto.comps[cid]
				if c.type == "sprite" then E.n_sprites = E.n_sprites - 1 end
				if c.type == "particlefx" then
					E.n_particlefx = E.n_particlefx - 1
					E.n_emitters = E.n_emitters - #c.fx.list
				end
			end
			-- its particles go with it
			local keep = {}
			for _, b in ipairs(E.batches) do
				if b.key ~= o.key then keep[#keep + 1] = b end
			end
			E.batches = keep
		end
	end

	function factory.create(url, position, rotation, properties, scale)
		E.count("factory_create")
		local name
		if getmetatable(url) == URL then name = name_of(url.fragment) else name = type(url) == "string" and url:match("#(.*)$") end
		local ppath = name and E.factories[name]
		if not ppath then error("factory.create: no factory component '" .. tostring(name) .. "' in the collection", 2) end
		if position ~= nil and not is_v3(position) then error("factory.create: position must be a vector3", 2) end
		if rotation ~= nil and not is_quat(rotation) then error("factory.create: rotation must be a quaternion", 2) end
		local proto = prototype(ppath)
		if E.n_objects + 1 > E.limits.max_instances then
			error("factory.create: collection.max_instances (" .. E.limits.max_instances .. ") exceeded", 2)
		end
		local add_sprites, add_fx, add_emitters = 0, 0, 0
		for _, cid in ipairs(proto.order) do
			local c = proto.comps[cid]
			if c.type == "sprite" then add_sprites = add_sprites + 1 end
			if c.type == "particlefx" then
				add_fx = add_fx + 1
				add_emitters = add_emitters + #c.fx.list
				for _, em in ipairs(c.fx.list) do
					if not atlas(em.tile_source).ids[em.animation] then
						error("factory.create: the emitter '" .. em.id .. "' of " .. c.file .. " uses the animation '" ..
							tostring(em.animation) .. "' that " .. tostring(em.tile_source) .. " does not have", 2)
					end
				end
			end
		end
		if E.n_sprites + add_sprites > E.limits.sprites then
			error("factory.create: sprite.max_count (" .. E.limits.sprites .. ") exceeded", 2)
		end
		if E.n_particlefx + add_fx > E.limits.particlefx then
			error("factory.create: particle_fx.max_count (" .. E.limits.particlefx .. ") exceeded", 2)
		end
		if E.n_emitters + add_emitters > E.limits.emitters then
			error("factory.create: particle_fx.max_emitter_count (" .. E.limits.emitters .. ") exceeded", 2)
		end
		E.next_id = E.next_id + 1
		local key = "/instance" .. E.next_id
		local o = {
			key = key, id = hash(key), proto = proto, factory = name,
			pos = position and vector3(position) or vector3(0, 0, 0),
			rot = rotation or setmetatable({ x = 0, y = 0, z = 0, w = 1 }, QT),
			scale = vector3(1, 1, 1),
		}
		if type(scale) == "number" then o.scale = vector3(scale, scale, scale)
		elseif is_v3(scale) then o.scale = vector3(scale) end
		-- per-instance component state (the prototype tables are shared)
		o.proto = setmetatable({ comps = {}, order = proto.order, path = proto.path }, { __index = proto })
		for _, cid in ipairs(proto.order) do
			local c = {}
			for k, v in pairs(proto.comps[cid]) do c[k] = v end -- order-independent
			c.props = {}
			c.instances = {}   -- particlefx: the playing particle instances (see particlefx.play)
			c.tints = {}       -- particlefx: the constants of the newest instance
			o.proto.comps[cid] = c
		end
		E.objects[key] = o
		E.n_objects = E.n_objects + 1
		E.n_sprites = E.n_sprites + add_sprites
		E.n_particlefx = E.n_particlefx + add_fx
		E.n_emitters = E.n_emitters + add_emitters
		E.peak = E.peak or {}
		E.peak.objects = math.max(E.peak.objects or 0, E.n_objects)
		E.peak.sprites = math.max(E.peak.sprites or 0, E.n_sprites)
		E.peak.particlefx = math.max(E.peak.particlefx or 0, E.n_particlefx)
		return o.id
	end

	function sprite.play_flipbook(url, id, complete, props)
		E.count("sprite_play_flipbook")
		local _, c = component(url, 2)
		if c.type ~= "sprite" then error("sprite.play_flipbook: not a sprite component", 2) end
		local anim = name_of(id)
		if getmetatable(id) ~= HASH then error("sprite.play_flipbook: the animation id must be a hash", 2) end
		if not c.anims[anim] then
			error("sprite.play_flipbook: the atlas " .. tostring(c.atlas) .. " has no animation '" .. anim .. "'", 2)
		end
		c.anim = anim
	end
	function sprite.set_hflip(url, flip)
		E.count("sprite_set_hflip")
		local _, c = component(url, 2)
		if c.type ~= "sprite" then error("sprite.set_hflip: not a sprite component", 2) end
		if type(flip) ~= "boolean" then error("sprite.set_hflip: boolean expected", 2) end
		c.hflip = flip
	end

	-- Like the engine, an effect has particle INSTANCES: play creates one (it starts with the constants
	-- of the material) and the engine prunes it once its emitters are done and its particles are dead
	-- (`span` below). A constant lives on an instance, so set_constant before play, or after the
	-- instance is pruned, finds nothing (the engine logs "Particle FX to set constant for could not be
	-- found. You need to start playing it before setting constants." and drops it): an error here.
	function particlefx.play(url, callback)
		E.count("particlefx_play")
		local o, c = component(url, 2)
		if c.type ~= "particlefx" then error("particlefx.play: not a particlefx component", 2) end
		local span, live = 0, {}
		for _, em in ipairs(c.fx.list) do
			if em.span > span then span = em.span end
		end
		for _, inst in ipairs(c.instances) do
			if inst.alive_until > E.time then live[#live + 1] = inst end
		end
		if #live > 0 then E.count("particlefx_play_overlap") end -- a second instance on the object: set_constant hits both
		local inst = { tints = {}, alive_until = E.time + span }
		live[#live + 1] = inst
		c.instances, c.tints = live, inst.tints
		for _, em in ipairs(c.fx.list) do
			E.batches[#E.batches + 1] = { key = o.key, comp = c.id, emitter = em.id, n = em.count,
				untilt = E.time + em.life, from = E.time, tints = inst.tints }
		end
		E.count("particles_emitted")
		E.counts.particles_total = (E.counts.particles_total or 0) + (function()
			local n = 0
			for _, em in ipairs(c.fx.list) do n = n + em.count end
			return n
		end)()
		local live = E.live_particles()
		if live > E.peak_particles then E.peak_particles = live end
		c.playing = true
	end
	function particlefx.stop(url, options)
		E.count("particlefx_stop")
		local o, c = component(url, 2)
		if c.type ~= "particlefx" then error("particlefx.stop: not a particlefx component", 2) end
		if options ~= nil and type(options) ~= "table" then error("particlefx.stop: options must be a table", 2) end
		if options and options.clear then
			local keep = {}
			for _, b in ipairs(E.batches) do
				if not (b.key == o.key and b.comp == c.id) then keep[#keep + 1] = b end
			end
			E.batches = keep
			c.instances, c.tints = {}, {} -- the particles are gone, so is the instance
		end
		c.playing = false
	end
	function particlefx.set_constant(url, emitter, constant, value)
		E.count("particlefx_set_constant")
		local _, c = component(url, 2)
		if c.type ~= "particlefx" then error("particlefx.set_constant: not a particlefx component", 2) end
		local em = name_of(emitter)
		if not c.fx.emitters[em] then
			error("particlefx.set_constant: the effect " .. tostring(c.file) .. " has no emitter '" .. tostring(em) .. "'", 2)
		end
		if name_of(constant) ~= "tint" then error("particlefx.set_constant: unknown constant '" .. tostring(name_of(constant)) .. "'", 2) end
		if not is_v4(value) then error("particlefx.set_constant: vector4 expected", 2) end
		local found = false
		for _, inst in ipairs(c.instances) do
			if inst.alive_until > E.time then
				inst.tints[em] = vector4(value)
				found = true
			end
		end
		if not found then
			E.count("particlefx_set_constant_lost")
			error("particlefx.set_constant: " .. tostring(c.file) .. " has no playing instance (never played, or already " ..
				"pruned): the engine drops the constant with the warning 'Particle FX to set constant for could not be " ..
				"found. You need to start playing it before setting constants.' Call particlefx.play first", 2)
		end
	end

	-- window / sys / json ----------------------------------------------------------------------
	local window = {
		get_size = function() return E.window.w, E.window.h end,
		get_safe_area = function()
			return { x = 0, y = 0, width = E.window.w, height = E.window.h,
				inset_left = 0, inset_top = 0, inset_right = 0, inset_bottom = 0 }
		end,
		set_listener = function() end,
		WINDOW_EVENT_FOCUS_LOST = 0, WINDOW_EVENT_FOCUS_GAINED = 1, WINDOW_EVENT_RESIZED = 2,
		WINDOW_EVENT_ICONIFIED = 3, WINDOW_EVENT_DEICONIFIED = 4,
	}
	local sys = {
		load_resource = function(path)
			local text = read_file(root, path)
			if not text then return nil, "resource not found: " .. tostring(path) end
			E.resources[path] = true
			return text
		end,
		get_sys_info = function() return { system_name = "Linux", language = "en", device_language = "en" } end,
		get_engine_info = function() return { version = "1.13.1", is_debug = true } end,
		get_config_number = function(_, default) return default end,
		get_config_string = function(_, default) return default end,
		set_error_handler = function() end,
	}

	-- gui ----------------------------------------------------------------------------------------
	-- One scene at a time (E.use_gui(path)): its nodes, its max_nodes from the .gui file, its
	-- animations; E.advance(dt) runs the animations (linear, no easing) and calls their callbacks.
	local gui = {}
	local GUI_CONSTS = {
		EASING_LINEAR = 1, EASING_INQUAD = 2, EASING_OUTQUAD = 3, EASING_INOUTQUAD = 4, EASING_OUTBACK = 5,
		EASING_INBACK = 6, EASING_INOUTSINE = 7, EASING_INSINE = 8, EASING_OUTSINE = 9, EASING_OUTELASTIC = 10,
		EASING_INOUTBACK = 11, EASING_OUTBOUNCE = 12, EASING_INCUBIC = 13, EASING_OUTCUBIC = 14,
		BLEND_ALPHA = 1, BLEND_ADD = 2, BLEND_MULT = 3, BLEND_ADD_ALPHA = 4, BLEND_SCREEN = 5,
		PIVOT_CENTER = 1, PIVOT_N = 2, PIVOT_NE = 3, PIVOT_E = 4, PIVOT_SE = 5, PIVOT_S = 6, PIVOT_SW = 7,
		PIVOT_W = 8, PIVOT_NW = 9,
		PLAYBACK_ONCE_FORWARD = 1, PLAYBACK_LOOP_FORWARD = 2, PLAYBACK_LOOP_PINGPONG = 3, PLAYBACK_ONCE_BACKWARD = 4,
		PLAYBACK_LOOP_BACKWARD = 5, PLAYBACK_ONCE_PINGPONG = 6,
		SIZE_MODE_MANUAL = 1, SIZE_MODE_AUTO = 2,
	}
	for k, v in pairs(GUI_CONSTS) do gui[k] = v end -- order-independent
	local scene = nil
	local NODE = {}
	local function live(n)
		if type(n) ~= "table" or getmetatable(n) ~= NODE then error("gui: a node was expected, got " .. tostring(n), 3) end
		if n.dead then error("gui: the node " .. tostring(n.id or "?") .. " was deleted", 3) end
		return n
	end
	function E.use_gui(path)
		local text = read_file(root, path)
		local max_nodes = 256
		if text then
			local doc = M.parse_proto(text)
			max_nodes = one(doc, "max_nodes") or max_nodes
		end
		scene = { path = path, max_nodes = max_nodes, nodes = {}, n = 0, anims = {}, textures = {}, peak = 0, order = nil }
		E.gui = scene
		return scene
	end
	local function new_node(kind, pos, size)
		if not scene then error("stub: E.use_gui(path) first", 3) end
		if scene.n + 1 > scene.max_nodes then
			error("gui: the node buffer is full (max_nodes " .. scene.max_nodes .. " of " .. scene.path .. ")", 3)
		end
		local n = setmetatable({
			kind = kind, pos = vector3(pos and pos.x or 0, pos and pos.y or 0, pos and pos.z or 0),
			size = size and vector3(size) or vector3(0, 0, 0), scale = vector3(1, 1, 1), euler = vector3(0, 0, 0),
			color = vector4(1, 1, 1, 1), enabled = true, children = {}, parent = nil, text = nil, pivot = GUI_CONSTS.PIVOT_CENTER,
		}, NODE)
		scene.nodes[#scene.nodes + 1] = n
		scene.n = scene.n + 1
		if scene.n > scene.peak then scene.peak = scene.n end
		return n
	end
	function gui.new_box_node(pos, size) return new_node("box", pos, size) end
	function gui.new_text_node(pos, text)
		local n = new_node("text", pos)
		n.text = text
		return n
	end
	local function remove_tree(n)
		for _, c in ipairs(n.children) do if not c.dead then remove_tree(c) end end
		n.dead = true
		scene.n = scene.n - 1
		for i = #scene.anims, 1, -1 do
			if scene.anims[i].node == n then table.remove(scene.anims, i) end
		end
	end
	function gui.delete_node(n)
		live(n)
		if n.parent then
			local sib = n.parent.children
			for i = #sib, 1, -1 do if sib[i] == n then table.remove(sib, i) end end
		end
		remove_tree(n)
	end
	function gui.set_parent(n, parent)
		live(n)
		if n.parent then
			local sib = n.parent.children
			for i = #sib, 1, -1 do if sib[i] == n then table.remove(sib, i) end end
		end
		n.parent = parent and live(parent) or nil
		if parent then parent.children[#parent.children + 1] = n end
	end
	function gui.get_parent(n) return live(n).parent end
	function gui.set_position(n, v) live(n).pos = vector3(v.x, v.y, v.z) end
	function gui.get_position(n) return vector3(live(n).pos) end
	function gui.set_scale(n, v) live(n).scale = vector3(v.x, v.y, v.z) end
	function gui.get_scale(n) return vector3(live(n).scale) end
	function gui.set_euler(n, v) live(n).euler = vector3(v.x, v.y, v.z) end
	function gui.set_size(n, v) live(n).size = vector3(v.x, v.y, v.z) end
	function gui.set_color(n, v) live(n).color = vector4(v.x, v.y, v.z, v.w) end
	function gui.get_color(n) return vector4(live(n).color) end
	function gui.set_enabled(n, on) live(n).enabled = on and true or false end
	function gui.is_enabled(n) return live(n).enabled end
	function gui.set_inherit_alpha(n, on) live(n).inherit_alpha = on and true or false end -- off by default, like the engine's
	function gui.get_inherit_alpha(n) return live(n).inherit_alpha == true end
	function gui.set_pivot(n, p) live(n).pivot = p end
	function gui.set_id(n, id) live(n).id = name_of(id) or id end
	function gui.set_text(n, t) live(n).text = t end
	function gui.get_text(n) return live(n).text end
	function gui.set_font(n, f) live(n).font = f end
	function gui.get_font(n) return live(n).font or hash("body") end
	function gui.get_font_resource(f) return f end
	function gui.set_outline(n, v) live(n).outline = v end
	function gui.set_shadow(n, v) live(n).shadow = v end
	function gui.set_line_break(n, on) live(n).line_break = on end
	function gui.set_blend_mode(n, m) live(n).blend = m end
	function gui.set_slice9(n, v) live(n).slice9 = v end
	function gui.set_texture(n, name) live(n).texture = name end
	function gui.play_flipbook(n, anim) live(n).anim = name_of(anim) or anim end
	function gui.set_render_order(o) scene.order = o end
	function gui.move_below(n, ref)
		live(n)
		live(ref)
	end
	function gui.pick_node(n, x, y)
		live(n)
		return false
	end
	function gui.new_texture(name, w, h, kind, buf, flip)
		scene.textures[name] = { w = w, h = h }
		return true
	end
	function gui.delete_texture(name) scene.textures[name] = nil end
	local ANIM_PROPS = { position = true, scale = true, euler = true, color = true, size = true, outline = true,
		shadow = true, rotation = true, slice = true, fill_angle = true }
	function gui.animate(n, property, to, easing, duration, delay, complete, playback)
		live(n)
		local prop = name_of(property)
		local base = prop and prop:match("^([%a_]+)")
		if not (prop and ANIM_PROPS[base]) then error("gui.animate: unknown property '" .. tostring(prop) .. "'", 2) end
		if type(easing) ~= "number" and type(easing) ~= "table" and getmetatable(easing) == nil then
			error("gui.animate: an easing constant (or a vector curve) was expected", 2)
		end
		if type(duration) ~= "number" or duration < 0 then error("gui.animate: duration must be a number >= 0", 2) end
		if complete ~= nil and type(complete) ~= "function" then error("gui.animate: complete_function must be a function", 2) end
		E.count("gui_animate")
		scene.anims[#scene.anims + 1] = { node = n, prop = prop, to = to, dur = duration, delay = delay or 0, cb = complete,
			t = 0, playback = playback }
	end
	function gui.cancel_animations(n, property)
		live(n)
		local prop = property and name_of(property)
		for i = #scene.anims, 1, -1 do
			local a = scene.anims[i]
			if a.node == n and (not prop or a.prop == prop or a.prop:match("^" .. prop)) then table.remove(scene.anims, i) end
		end
	end
	local function apply_anim(a)
		local n = a.node
		local base, comp = a.prop:match("^([%a_]+)%.?(%a*)$")
		local cur = n[base == "position" and "pos" or base]
		if type(cur) == "table" and comp ~= "" then
			cur[comp] = a.to
		elseif type(cur) == "table" and type(a.to) == "table" then
			for _, k in ipairs({ "x", "y", "z", "w" }) do if a.to[k] then cur[k] = a.to[k] end end
		elseif base == "color" and type(a.to) == "table" then
			n.color = vector4(a.to)
		end
	end
	-- steps the animations of the current scene (linear); finished ones call back (outside the loop)
	function E.gui_advance(dt)
		if not scene then return end
		local done, keep = {}, {}
		for _, a in ipairs(scene.anims) do
			local rem = dt
			if a.delay > 0 then
				local used = math.min(a.delay, rem)
				a.delay = a.delay - used
				rem = rem - used
			end
			if a.delay > 0 then
				keep[#keep + 1] = a
			else
				a.t = a.t + rem
				if a.playback and a.playback ~= GUI_CONSTS.PLAYBACK_ONCE_FORWARD then
					keep[#keep + 1] = a -- a looping animation never ends
				elseif a.t >= a.dur then
					apply_anim(a)
					done[#done + 1] = a
				else
					keep[#keep + 1] = a
				end
			end
		end
		scene.anims = keep
		for _, a in ipairs(done) do
			if a.cb and not a.node.dead then a.cb(nil, a.node) end
		end
	end
	function E.gui_stats()
		return { nodes = scene and scene.n or 0, peak = scene and scene.peak or 0, anims = scene and #scene.anims or 0 }
	end
	-- plain data about the live nodes (tests): the texts and the node count
	function E.gui_texts()
		local out = {}
		if scene then
			for _, n in ipairs(scene.nodes) do
				if not n.dead and n.kind == "text" then out[#out + 1] = n.text end
			end
		end
		return out
	end
	local image = {
		TYPE_RGB = 1, TYPE_RGBA = 2, TYPE_LUMINANCE = 3,
		load = function(data, options)
			return { width = 8, height = 8, type = 2, buffer = string.rep("\255", 8 * 8 * 4) }
		end,
	}
	local resource = {
		get_text_metrics = function(font, text)
			text = tostring(text or "")
			return { width = #text * 20, height = 32, max_ascent = 26, max_descent = 6 }
		end,
	}

	-- install the globals ---------------------------------------------------------------------
	saved = {}
	for _, name in ipairs(GLOBALS) do saved[name] = rawget(_G, name) end
	rawset(_G, "hash", hash)
	rawset(_G, "vmath", make_vmath())
	rawset(_G, "msg", msg)
	rawset(_G, "go", go)
	rawset(_G, "factory", factory)
	rawset(_G, "sprite", sprite)
	rawset(_G, "particlefx", particlefx)
	rawset(_G, "window", window)
	rawset(_G, "sys", sys)
	rawset(_G, "json", require("tools.lib.json"))
	rawset(_G, "gui", gui)
	rawset(_G, "image", image)
	rawset(_G, "resource", resource)
	rawset(_G, "socket", nil)
	rawset(_G, "html5", nil)
	E.go, E.sprite, E.particlefx = go, sprite, particlefx

	-- particles --------------------------------------------------------------------------------
	function E.live_particles()
		local n = 0
		for _, b in ipairs(E.batches) do
			if b.untilt > E.time then n = n + b.n end
		end
		return n
	end

	-- advances the engine clock: particle batches expire, gui animations run
	function E.advance(dt)
		E.time = E.time + dt
		local keep = {}
		for _, b in ipairs(E.batches) do
			if b.untilt > E.time then keep[#keep + 1] = b end
		end
		E.batches = keep
		if E.gui_advance then E.gui_advance(dt) end
	end

	-- helpers for tests -------------------------------------------------------------------------
	-- A plain-data picture of the world sprites and live particle batches (tools that
	-- render a frame of the board offline, tests): [{factory, x, y, z, sx, sy, rot (degrees),
	-- image, r, g, b, a, flash, clip}] and [{x, y, emitter, r, g, b, n, age, life}].
	function E.snapshot()
		local sprites, parts = {}, {}
		local keys = {}
		for key in pairs(E.objects) do keys[#keys + 1] = key end -- order-independent
		table.sort(keys)
		for _, key in ipairs(keys) do
			local o = E.objects[key]
			local c = o.proto.comps.sprite
			if c and c.anim and E.visible(o) then
				local vc = c.props.vcolor or { x = 1, y = 1, z = 1, w = 1 }
				local vf = c.props.vfx or { x = 100000, y = 0 }
				sprites[#sprites + 1] = {
					factory = o.factory, x = o.pos.x, y = o.pos.y, z = o.pos.z, sx = o.scale.x, sy = o.scale.y,
					rot = math.deg(2 * math.atan2(o.rot.z, o.rot.w)), image = c.anim, r = vc.x, g = vc.y, b = vc.z,
					a = vc.w, flash = vf.y, clip = vf.x, hflip = c.hflip and true or false,
				}
			end
		end
		for _, b in ipairs(E.batches) do
			local o = E.objects[b.key]
			if o then
				local comp = o.proto.comps[b.comp]
				local t = b.tints and b.tints[b.emitter]
				parts[#parts + 1] = { x = o.pos.x, y = o.pos.y, scale = o.scale.x, emitter = b.emitter,
					r = t and t.x or 1, g = t and t.y or 1, b = t and t.z or 1, n = b.n, age = E.time - b.from,
					life = b.untilt - b.from, kind = comp and comp.file }
			end
		end
		return { sprites = sprites, particles = parts, time = E.time }
	end

	function E.by_factory(name)
		local list = {}
		for _, o in pairs(E.objects) do -- order-independent
			if o.factory == name then list[#list + 1] = o end
		end
		table.sort(list, function(a, b) return a.key < b.key end)
		return list
	end
	function E.sprite_of(o)
		return o.proto.comps.sprite
	end
	function E.visible(o)
		return o.pos.x > -5000 and o.pos.y > -5000
	end

	M.env = E
	return E
end

function M.restore()
	if not saved then return end
	for _, name in ipairs(GLOBALS) do rawset(_G, name, saved[name]) end
	saved = nil
	M.env = nil
end

-- Loads a Defold script file as a table of its global callbacks (init, update,
-- on_input, final, on_message), the way the engine runs it: a private
-- environment that falls back to the globals.
function M.load_script(path)
	local chunk, err = loadfile(path)
	if not chunk then error(err, 0) end
	local env = setmetatable({}, { __index = _G })
	setfenv(chunk, env)
	chunk()
	return env
end

return M
