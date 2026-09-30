-- The town's animated steps (screens/town/show.lua runs them):
--   M.task(town, task, res)        stars fly from the top bar to the card, a light
--                                  flies to the item, the item lights up, the new
--                                  stem fades in, Bit cheers (2-3 s, tap to skip)
--   M.concert(town, res)           the District Concert (gui/concert.lua)
--   M.chest(town, params)          a chest reveal (gui/chest.lua), then its coins,
--                                  boosters and unlimited lives fly to the HUD
--   M.next_district(town, id)      the next district slides in with its music
--   M.rewards(town, result)        the steps of one level result (rewards.steps)
-- Amounts already paid by the meta but not landed yet are held back from the
-- counters: town.hold (coins, stars) grows when a step takes them over and
-- shrinks as every icon lands (town:sync_disp()).

local app = require("client.app")
local i18n = require("client.i18n")
local audio = require("client.audio")
local rewards = require("client.rewards")
local analytics = require("client.services.analytics")
local fx = require("client.fx")

local M = {}

M.COIN_TRAIL = "#FFE066"
M.STAR_TRAIL = "#FFF3A6"

-- Flies `amount` of coins or stars from (x, y) (or fn) into the top bar.
-- The counter grows as each icon lands; on_done() after the last.
-- Returns a table {left} with what has not landed yet (for a skip).
local function fly_to_bar(town, kind, amount, from, on_done, opts)
	opts = opts or {}
	local hud = town.hud
	local n = rewards.flyers(kind, amount)
	local track = { left = amount, acct = opts.acct }
	if n == 0 then
		if on_done then on_done() end
		return track
	end
	local chunks = rewards.chunks(amount, n)
	local landed = 0
	for i = 1, n do
		town.fx:fly({
			image = kind == "stars" and "ui/icons/star" or "ui/icons/coin",
			size = kind == "stars" and 70 or 58,
			from = from,
			to = function()
				if kind == "stars" then return hud:stars_pos() end
				return hud:coins_pos()
			end,
			delay = (opts.delay or 0) + (i - 1) * (kind == "stars" and 0.12 or 0.07),
			dur = 0.6 + (i % 3) * 0.05,
			arc = (i % 2 == 0 and 1 or -1) * (110 + i * 9),
			spin = kind == "stars" and 360 or 0,
			trail = kind == "stars" and M.STAR_TRAIL or M.COIN_TRAIL,
			on_land = function()
				local c = chunks[i]
				track.left = track.left - c
				town.hold[kind] = town.hold[kind] - c
				if opts.acct then opts.acct[kind] = opts.acct[kind] - c end
				town:sync_disp()
				local node = kind == "stars" and hud.star_icon or hud.coin_icon
				if node then town.fx:pop(node, 0.35, 0.25) end
				town.fx:sfx(kind == "stars" and "star" or "coin", nil, 0.06)
				landed = landed + 1
				if landed == n and on_done then on_done() end
			end,
		})
	end
	return track
end
M.fly_to_bar = fly_to_bar

-- Lands everything of a track at once (a skip).
local function land_all(town, kind, track)
	if track and track.left > 0 then
		town.hold[kind] = town.hold[kind] - track.left
		if track.acct then track.acct[kind] = track.acct[kind] - track.left end
		track.left = 0
		town:sync_disp()
	end
end

-- Lands whatever of a result is still held (acct = {coins, stars} left).
local function settle(town, acct)
	if not acct then return end
	town.hold.coins = town.hold.coins - acct.coins
	town.hold.stars = town.hold.stars - acct.stars
	acct.coins, acct.stars = 0, 0
	town:sync_disp()
end
M.settle = settle
M.land_all = land_all

-- a task ---------------------------------------------------------------------------------------

function M.task(town, task, res)
	local step = { name = "task", skippable = true }
	local spent = { left = task.cost } -- stars still shown in the top bar
	local lit = false
	local function light_up()
		if lit then return end
		lit = true
		audio.unlock_stem(res.district, res.stem)
	end
	step.run = function(done)
		local hud, fxi = town.hud, town.fx
		fxi:sfx("button")
		if hud.card then fxi:pop(hud.card, 0.08, 0.25) end
		town.bit:mood_for(3, "happy")
		local n = rewards.flyers("stars", task.cost)
		local chunks = rewards.chunks(task.cost, n)
		local landed = 0
		local function stage3(x, y)
			-- the item lights up, its stem joins the track
			light_up()
			town.scene:light_up(task.id)
			local e = town.scene.items[task.id]
			local h = e and e.h or 120
			fxi:flash(x, y, { size = 460, dur = 0.5 })
			fxi:ring(x, y, { size = 160, scale = 3.2 })
			fxi:burst(x, y, { count = 20, radius = 220, size = 38 })
			fxi:sfx("unlock")
			fx.buzz(40)
			fxi:float_text(i18n.t("town.layer_added", { stem = i18n.t("stem." .. task.stem) }), x, y + h / 2 + 30, {
				size = 46, outline = "#8B45FF", shadow = "#5220A6", dur = 1.6,
			})
			town.bit:cheer(2.2, 3)
			analytics.log("task_complete", { district = res.district, task = task.id, cost = task.cost, stem = task.stem })
			fxi:after(0.3, function()
				hud:build()
				hud:card_in()
				town:publish()
			end)
			fxi:after(1.5, done)
		end
		local function stage2()
			-- a ball of light flies from the card to the item
			hud:card_out()
			local tx, ty = town.scene:item_pos(task.id)
			local cx, cy = hud:chip_pos()
			fxi:fly({ image = "fx/star_particle", size = 110, color = "#FFF3A6", from = { cx, cy }, to = { tx, ty },
				dur = 0.6, arc = 220, spin = 540, scale_to = 1.6, trail = "#FFE066", on_land = stage3 })
			fxi:sfx("special_create")
		end
		for i = 1, n do
			fxi:fly({
				image = "ui/icons/star", size = 70, from = function() return hud:stars_pos() end,
				to = function() return hud:chip_pos() end,
				delay = (i - 1) * 0.12, dur = 0.5, arc = -140 - i * 10, spin = -360, trail = M.STAR_TRAIL,
				on_start = function()
					spent.left = spent.left - chunks[i]
					town.hold.stars = town.hold.stars + chunks[i]
					town:sync_disp()
					if hud.star_icon then fxi:pop(hud.star_icon, 0.25, 0.2) end
				end,
				on_land = function()
					if hud.chip then fxi:pop(hud.chip, 0.25, 0.2) end
					local x, y = hud:chip_pos()
					fxi:burst(x, y, { count = 6, radius = 70, size = 24 })
					fxi:sfx("star", { speed = 1 + landed * 0.06 }, 0.04)
					landed = landed + 1
					if landed == n then fxi:after(0.1, stage2) end
				end,
			})
		end
	end
	step.finish = function()
		if spent.left > 0 then
			town.hold.stars = town.hold.stars + spent.left
			spent.left = 0
		end
		town:sync_disp()
		light_up()
		if not lit then analytics.log("task_complete", { district = res.district, task = task.id, cost = task.cost, stem = task.stem }) end
		town.scene:refresh()
		town.hud:build()
		town.bit:cheer(1.5, 1)
	end
	step.after = function()
		town:sync_disp()
		town:publish()
	end
	return step
end

-- the district concert, its chest and the next district ------------------------------------------

function M.concert(town, res)
	return {
		name = "concert",
		run = function(done)
			analytics.log("district_complete", { district = res.district })
			town:open_popup("concert", { district = res.district, on_close = function() done() end })
		end,
	}
end

-- params = {kind, chest, level_id?, district_name?}; the chest's coins are
-- held (town.hold.coins, and acct.coins) by whoever queued the step.
function M.chest(town, params, acct)
	local step = { name = "chest" }
	local tracks = {}
	step.run = function(done)
		local p = {}
		for k, v in pairs(params) do p[k] = v end -- order-free: a shallow copy
		analytics.log("chest_open", {
			kind = params.kind, level = params.level_id, district = params.district,
			coins = params.chest and params.chest.coins or 0,
		})
		p.district_name = params.district and app.district(params.district) and app.district(params.district).name or nil
		p.on_close = function(result)
			local items = type(result) == "table" and result.items or {}
			local pending = 0
			local function one_done()
				pending = pending - 1
				if pending <= 0 then
					town.hud:build()
					town:publish()
					done()
				end
			end
			for _, it in ipairs(items) do
				if it.kind == "coins" then
					pending = pending + 1
					tracks[#tracks + 1] = fly_to_bar(town, "coins", it.amount, { it.x, it.y }, one_done, { acct = acct })
				elseif it.kind == "booster" then
					pending = pending + 1
					town.fx:fly({ image = require("client.views").booster_icon(it.id), size = 90, from = { it.x, it.y },
						to = function() return town.hud:level_pos() end, dur = 0.7, arc = 160, trail = "#E3D0FF",
						on_land = function()
							if town.hud.level_btn then town.fx:pop(town.hud.level_btn, 0.06, 0.25) end
							town.fx:sfx("booster", nil, 0.08)
							one_done()
						end })
				elseif it.kind == "infinite" then
					pending = pending + 1
					town.fx:fly({ image = "ui/icons/heart_infinite", size = 100, from = { it.x, it.y },
						to = function() return town.hud:lives_pos() end, dur = 0.7, arc = -160, trail = "#FFB3E1",
						on_land = function()
							town.hud:build()
							if town.hud.heart then town.fx:pop(town.hud.heart, 0.4, 0.3) end
							town.fx:sfx("unlock", nil, 0.1)
							one_done()
						end })
				end
			end
			-- a chest closed without "collect" (screen change): land it all
			if pending == 0 then
				settle(town, acct)
				done()
			end
		end
		town:open_popup("chest", p)
	end
	step.finish = function()
		for _, t in ipairs(tracks) do land_all(town, "coins", t) end
	end
	step.skippable = false
	return step
end

function M.next_district(town, next_id)
	return {
		name = "next_district",
		run = function(done)
			if not next_id then
				audio.music(town.district)
				app.toast_key("town.town_done", nil, { color = "gold", duration = 3 })
				town.bit:cheer(2, 3)
				town.hud:build()
				done()
				return
			end
			local d = app.district(next_id)
			town.district = next_id
			audio.music(next_id)
			town.fx:sfx("win")
			town.scene:slide_to(next_id, function()
				town.hud:build()
				town.hud:card_in()
				town.bit:cheer(2, 2)
				town:publish()
				done()
			end)
			town.hud:build()
			app.toast_key("town.new_district", { name = d and d.name or next_id }, { color = "gold", duration = 3 })
		end,
	}
end

-- rewards of a level ---------------------------------------------------------------------------------

-- Steps for one popped result r (normalized, client/rewards.lua). Its coins
-- and stars are held from now until they land.
function M.rewards(town, r)
	local out = {}
	local a = rewards.amounts(r)
	local acct = { coins = a.coins, stars = a.stars }
	town.hold.coins = town.hold.coins + a.coins
	town.hold.stars = town.hold.stars + a.stars
	for _, s in ipairs(rewards.steps(r)) do
		if s.kind == "win" then
			local tracks = {}
			out[#out + 1] = {
				name = "reward_win", skippable = true,
				run = function(done)
					local hud, fxi = town.hud, town.fx
					local x, y = hud:level_pos()
					fxi:burst(x, y + 40, { count = 16, radius = 200, size = 36 })
					fxi:sfx("win")
					town.bit:cheer(2, 2)
					local ty = y + 120
					if s.stars > 0 then
						fxi:float_text(i18n.t("reward.stars", { n = s.stars }), x - (s.coins > 0 and 130 or 0), ty, {
							size = 44, outline = "#E07F00", shadow = "#B35F00", dur = 1.6,
						})
					end
					if s.coins > 0 then
						fxi:float_text(i18n.t("reward.coins", { n = s.coins }), x + (s.stars > 0 and 130 or 0), ty, {
							size = 44, outline = "#E07F00", shadow = "#B35F00", dur = 1.6,
						})
					end
					local pending = 2
					local function one() pending = pending - 1; if pending == 0 then fxi:after(0.25, done) end end
					tracks.stars = fly_to_bar(town, "stars", s.stars, { x - 80, y + 40 }, one, { delay = 0.25, acct = acct })
					tracks.coins = fly_to_bar(town, "coins", s.coins, { x + 80, y + 40 }, one, { delay = 0.4, acct = acct })
				end,
				finish = function()
					land_all(town, "stars", tracks.stars or { left = s.stars, acct = acct })
					land_all(town, "coins", tracks.coins or { left = s.coins, acct = acct })
				end,
			}
		elseif s.kind == "streak" then
			out[#out + 1] = {
				name = "reward_streak", skippable = true,
				run = function(done)
					local hud, fxi = town.hud, town.fx
					local lit = math.min(3, s.count)
					for i = 1, lit do
						fxi:after(0.1 + (i - 1) * 0.28, function()
							hud:streak_pop(i)
							fxi:sfx("star", { speed = 1 + i * 0.12 })
						end)
					end
					local x, y = hud:level_pos()
					fxi:after(0.2, function()
						fxi:float_text(i18n.t("reward.streak", { n = s.count }), x + 150, y + 96, {
							size = 36, outline = "#FF4D8D", dur = 1.4,
						})
					end)
					fxi:after(0.3 + lit * 0.28 + 0.4, done)
				end,
			}
		elseif s.kind == "chest" then
			out[#out + 1] = M.chest(town, { kind = "level", chest = s.chest, level_id = r.level_id }, acct)
		elseif s.kind == "unlock" then
			for _, id in ipairs(s.ids) do
				out[#out + 1] = {
					name = "reward_gift",
					run = function(done)
						town:open_popup("gift", { id = id, on_close = function(result)
							if type(result) == "table" and result.action == "collect" then
								town.fx:fly({ image = require("client.views").booster_icon(id), size = 110,
									from = { result.x, result.y }, to = function() return town.hud:level_pos() end,
									dur = 0.7, arc = 180, trail = "#E3D0FF",
									on_land = function()
										if town.hud.level_btn then town.fx:pop(town.hud.level_btn, 0.06, 0.25) end
										town.fx:sfx("booster")
										done()
									end })
							else
								done()
							end
						end })
					end,
				}
			end
		elseif s.kind == "loss" then
			out[#out + 1] = {
				name = "reward_loss", skippable = true,
				run = function(done)
					local hud, fxi = town.hud, town.fx
					town.bit:worry(1.6)
					if s.life_lost then
						local x, y = hud:lives_pos()
						fxi:sfx("lose")
						if hud.heart then fxi:shake(hud.heart, 10, 0.45) end
						fxi:fly({ image = "ui/icons/heart", size = 70, from = { x, y }, to = { x + 30, y - 260 },
							dur = 0.9, arc = 60, spin = 90, scale_to = 0.3 })
						fxi:float_text(i18n.t("reward.life_lost"), x + 40, y - 90, { size = 38, outline = "#D12F6B", dur = 1.4 })
					end
					if s.streak_lost > 0 then
						local x, y = hud:level_pos()
						if hud.level_btn then fxi:shake(hud.level_btn, 12, 0.45) end
						fxi:after(0.3, function()
							fxi:float_text(i18n.t("reward.streak_lost"), x + 120, y + 96, { size = 32, outline = "#6B5E8F", dur = 1.4 })
						end)
					end
					fxi:after(1.2, done)
				end,
			}
		end
	end
	-- a result without steps (nothing to show) still releases what it held
	out[#out + 1] = {
		name = "reward_end",
		run = function(done)
			settle(town, acct)
			done()
		end,
	}
	return out
end

return M
