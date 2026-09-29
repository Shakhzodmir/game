-- Lookups into the generated registry client/assets_index.lua (pure Lua).
-- Scripts ask here whether an image or a sound exists instead of naming
-- files directly, so art and audio can be regenerated or be missing.
--
--   assets.image("pieces/red")        --> {atlas = "game", anim = "pieces_red", w, h, slice9?} | nil
--   assets.note_id("red", 3)          --> "note_red_3" | nil
--   assets.sfx_id("tap")              --> "sfx_tap" | nil
--   assets.music_stems("cafe")        --> {"bass", "beat", ...} sorted | {}
--   assets.music_id("cafe", "beat")   --> "music_cafe_beat" | nil
--   assets.district_bg("cafe", "concert") --> image entry of the concert bg,
--                                        falling back to the day bg | nil
--   assets.gui_has_texture("/screens/town/town.gui", "bg_cafe") --> bool

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

function M.district_bg(district, view)
	if view and view ~= "day" then
		local e = M.image("districts/" .. district .. "/bg_" .. view)
		if e then return e end
	end
	return M.image("districts/" .. district .. "/bg")
end

function M.gui_has_texture(gui_path, texture)
	local g = M.index.guis[gui_path]
	if not g then return false end
	for _, t in ipairs(g.textures) do
		if t == texture then return true end
	end
	return false
end

function M.font_size(name)
	local f = M.index.fonts[name]
	return f and f.size or 32
end

return M
