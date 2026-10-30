-- The music of the town and of the levels, and the jukebox pick (client-architecture.md, section 5).
--
-- A player may pick a song in the jukebox (meta:song(), saved with the prefs). While a valid pick is set,
-- every place that starts music plays IT instead of the track of the district: entering the town, paging
-- the districts, coming back from a level, starting a level, the next district after a concert. The pick
-- is cleared only by an explicit action (songs.clear(): the "Return the town music" button, or a tap on the
-- playing row). Closing the jukebox keeps it.
--
--   local songs = require("client.songs")
--   songs.play("town", district)    -- starts the music of the town for the district on display
--   songs.play("level", focus)      -- starts the music of a level
--   songs.pick(id) / songs.clear()  -- the jukebox: set the pick and play it / follow the town again
--   songs.resolve(meta, district, ctx) -- what would play (pure; the tests and the QA status read it)
--
-- What plays (resolve):
--   no pick                 the layered theme of `district`: its built layers, the same in town and level
--   a song of a genre       that single mix (no layers: tension / party do nothing for it)
--   the theme of district X X's layered track: the built layers, and for a FINISHED district the full song
--                           (every stem + the party layer) in the town; a level plays the same stems
--                           without the party layer, which belongs to its final concert
-- The key of the notes and effects follows the track that plays (main/audio.script), so a picked song
-- of another genre is played with its own key.

local app = require("client.app")
local audio = require("client.audio")

local M = {}

M.TOWN = "town"
M.LEVEL = "level"

-- {id = the track to start, all, party (client/audio.lua music()), chosen = a pick is playing, kind = "theme" |
-- "song", district = the genre the track belongs to}. ctx = "town" (default) | "level".
function M.resolve(meta, district, ctx)
	local picked = meta and meta:song() or nil
	local info = picked and meta:song_info(picked) or nil
	if info then
		if info.theme then
			local complete = meta:district(info.district).complete and true or false
			-- party = nil follows `all` (the town plays the full song); false keeps it out of a level
			local party = nil
			if ctx == M.LEVEL and complete then party = false end
			return {
				id = picked, all = complete, party = party,
				chosen = true, kind = "theme", district = info.district,
			}
		end
		return { id = picked, all = false, chosen = true, kind = "song", district = info.district }
	end
	return { id = district, all = false, chosen = false, kind = "theme", district = district }
end

-- Starts the music of the town / a level (a repeated request for the track that already plays changes nothing).
-- Returns what resolve() decided.
function M.play(ctx, district)
	local r = M.resolve(app.meta, district, ctx)
	if r.id then audio.music(r.id, { all = r.all, party = r.party }) end
	return r
end

-- The district on display (the town may be paging through the districts), else the one being built.
function M.shown_district()
	return app.ui.district or app.focus_district()
end

-- The jukebox picks `id` (a song of the catalogue, a district id for its theme): saved, logged, played now.
-- true, or false and the meta's reason.
function M.pick(id)
	local ok, why = app.set_song(id)
	if not ok then return false, why end
	M.play(M.TOWN, M.shown_district())
	return true
end

-- Follow the town again: the pick is forgotten and the track of the district on display comes back.
function M.clear()
	local ok, why = app.set_song(nil)
	if not ok then return false, why end
	M.play(M.TOWN, M.shown_district())
	return true
end

return M
