local assets = require("client.assets")
local audio = require("client.audio")

-- The index is generated from assets that other tools regenerate, so these
-- tests check its structure and the lookups, not a fixed list of files.
describe("client.assets and the generated index", function()
	local index = assets.index

	it("has the expected sections", function()
		for _, k in ipairs({ "atlases", "images", "fonts", "sounds", "guis" }) do
			assert_eq(type(index[k]), "table", k)
		end
		for _, k in ipairs({ "notes", "sfx", "music" }) do
			assert_eq(type(index.sounds[k]), "table", k)
		end
	end)

	it("lists every image in its atlas", function()
		for key, e in pairs(index.images) do
			local atlas = index.atlases[e.atlas]
			assert_true(atlas ~= nil, key .. " -> missing atlas " .. tostring(e.atlas))
			local found = false
			for _, a in ipairs(atlas.anims) do
				if a == e.anim then found = true end
			end
			assert_true(found, key .. " not in atlas " .. e.atlas)
			assert_eq(e.anim, (string.gsub(key, "/", "_")))
			if e.slice9 then assert_eq(#e.slice9, 4, key .. " slice9") end
		end
		for name, a in pairs(index.atlases) do
			assert_eq(a.anims[1], "white", name .. " has the placeholder")
			assert_eq(a.path, "/assets/gen/" .. name .. ".atlas")
		end
	end)

	it("references only generated atlases from GUI scenes", function()
		for path, g in pairs(index.guis) do
			for _, t in ipairs(g.textures) do
				assert_true(index.atlases[t] ~= nil, path .. " uses unknown texture " .. t)
			end
		end
		assert_true(assets.gui_has_texture("/screens/town/town.gui", "ui"))
		assert_false(assets.gui_has_texture("/screens/town/town.gui", "nope"))
		assert_false(assets.gui_has_texture("/nope.gui", "ui"))
	end)

	it("names sounds the way the audio module expects", function()
		for color, notes in pairs(index.sounds.notes) do
			for n, id in pairs(notes) do
				assert_eq(id, "note_" .. color .. "_" .. n)
				assert_eq(assets.note_id(color, n), id)
			end
		end
		local some_color = next(index.sounds.notes)
		if some_color and index.sounds.notes[some_color][1] then
			assert_eq((audio.note_id(some_color, 1)), index.sounds.notes[some_color][1])
		end
		for name, id in pairs(index.sounds.sfx) do
			assert_eq(id, "sfx_" .. name)
		end
		for did, stems in pairs(index.sounds.music) do
			for stem, id in pairs(stems) do
				assert_eq(assets.music_id(did, stem), id)
			end
			local list = assets.music_stems(did)
			for i = 2, #list do assert_true(list[i - 1] < list[i]) end
		end
		assert_eq(assets.note_id("nope", 1), nil)
		assert_eq(assets.sfx_id("nope"), nil)
		assert_same(assets.music_stems("nope"), {})
	end)

	it("falls back from a missing background view to the day background", function()
		for key in pairs(index.images) do
			local did = string.match(key, "^districts/([^/]+)/bg$")
			if did then
				assert_eq(assets.district_bg(did, "no_such_view"), index.images[key])
				assert_eq(assets.district_bg(did), index.images[key])
			end
		end
		assert_eq(assets.district_bg("nope"), nil)
	end)
end)
