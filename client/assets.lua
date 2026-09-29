-- Lookups into the generated registry client/assets_index.lua (pure Lua).
-- Scripts ask here whether an image or a sound exists instead of naming
-- files directly, so art and audio can be regenerated or be missing.
--
--   assets.image("pieces/red")        --> {atlas = "game", anim = "pieces_red", w, h, slice9?} | nil
--   assets.image("districts/cafe/bg") --> {file = "/assets/images/...png", w, h} (loose
--                                        image: custom resource, loaded by client/ui.lua)
--   assets.note_id("red", 3)          --> "note_red_3" | nil
--   assets.sfx_id("tap")              --> "sfx_tap" | nil
--   assets.sfx_key("win")             --> "C" (tonal effect written in C) | nil (atonal)
--   assets.music_stems("cafe")        --> {"bass", "beat", ...} sorted | {}
--   assets.music_id("cafe", "beat")   --> "music_cafe_beat" | nil
--   assets.music_loop("cafe")         --> 21.333333 (seconds, from the Ogg headers) | nil
--   assets.mixer()                    --> mixer contract of the audio manifest | {}
--   assets.district_bg_key("cafe", "concert") --> "districts/cafe/bg_concert",
--                                        falling back to the day bg | nil
--   assets.district_bg("cafe", "concert") --> image entry of that key | nil
--   assets.gui_has_texture("/screens/level/level.gui", "game") --> bool
--   assets.gui_has_material("/screens/town/town.gui", "grey")  --> bool

local M = {}

M.index = require("client.assets_index")

function M.image(key)
	return M.index.images[key]
end

function M.has_image(key)
	return M.index.images[key] ~= nil
end

function M.note_id(color, n)
	local c = M.index.sounds.notes[color]
	return c and c[n] or nil
end

function M.sfx_id(name)
	return M.index.sounds.sfx[name]
end

function M.sfx_key(name)
	local keys = M.index.sounds.sfx_keys
	return keys and keys[name] or nil
end

function M.music_loop(district)
	local loops = M.index.sounds.loops
	return loops and loops[district] or nil
end

function M.mixer()
	return M.index.sounds.mixer or {}
end

function M.music_stems(district)
	local stems = M.index.sounds.music[district]
	local out = {}
	if not stems then return out end
	for name in pairs(stems) do out[#out + 1] = name end
	table.sort(out)
	return out
end

function M.music_id(district, stem)
	local stems = M.index.sounds.music[district]
	return stems and stems[stem] or nil
end

function M.district_bg_key(district, view)
	if view and view ~= "day" then
		local key = "districts/" .. district .. "/bg_" .. view
		if M.image(key) then return key end
	end
	local key = "districts/" .. district .. "/bg"
	if M.image(key) then return key end
	return nil
end

function M.district_bg(district, view)
	local key = M.district_bg_key(district, view)
	return key and M.image(key) or nil
end

local function listed(list, value)
	for _, v in ipairs(list or {}) do
		if v == value then return true end
	end
	return false
end

function M.gui_has_texture(gui_path, texture)
	local g = M.index.guis[gui_path]
	return g ~= nil and listed(g.textures, texture)
end

function M.gui_has_material(gui_path, material)
	local g = M.index.guis[gui_path]
	return g ~= nil and listed(g.materials, material)
end

function M.font_size(name)
	local f = M.index.fonts[name]
	return f and f.size or 32
end

return M
