-- The unbounded leak fuzzer (a script, not a test: tools/test/run.lua only runs *_test.lua).
--
--   lua5.1 tests/client/level_leak_fuzz.lua FIRST COUNT [key=value ...]
--   luajit tests/client/level_leak_fuzz.lua 1 2000 dt_mode=3000 source=combo
--
-- Plays COUNT random scenarios (tests/client/level_leak.lua) with the seeds FIRST ... FIRST + COUNT - 1 on the real
-- screens/level/board.script, headless on the strict Defold stub, and asks the visual-leak oracle after each one.
-- A scenario is a pure function of its seed (a board or one of the 100 level files, a frame rhythm, a list of random
-- ops), the same on both VMs, so a line of the output is a reproduction: run it again with FIRST = seed, COUNT = 1.
--
-- Options (all optional):
--   dt_mode=60|30|10|500|3000|spike|mixed   the frame rhythm (1/60 s, 1/30 s, 1/10 s, 0.5 s, 3 s, 1/60 s with spikes of
--                                           0.5 s and 3 s, rhythm changing every 50 frames)
--   source=board|level|combo                a random board with specials / one of the 100 levels / two specials side by side
--   level=N                                 the level of source=level
--   ops=N                                   the number of random ops
--   end_mode=settle|win|give_up|continue    how the scenario ends before the final check
--   rest_checks=0|1                         ask the oracle at rests in the middle of the scenario too (slower)
--   skippy=0|1  blinky=0|1                  taps that skip the concert / the app losing the focus while the level plays on
--   gui=0                                   skip the replay of the overlay script (faster)
--   float32=1                               the vectors of the stub keep float32 like the engine's (a little slower; the
--                                           board is calm for the janitor only if it does not mistake them for a change)
--   shrink=1                                drop ops while the scenario still leaks (prints the small story)
--   story=1                                 print the ops of every leaking scenario
--   verbose=1                               print a line for every scenario
--
-- Exit status 1 when any scenario leaked.

package.path = "./?.lua;./?/init.lua;" .. package.path
local L = require("tests.client.level_leak")

local first = tonumber(arg[1]) or 1
local count = tonumber(arg[2]) or 100
local opts = {}
for i = 3, #arg do
	local k, v = arg[i]:match("^([%w_]+)=(.*)$")
	if k then opts[k] = tonumber(v) or v end
end

local play_opts = { gui = opts.gui ~= 0, board = { float32 = opts.float32 == 1 } }
local started = os.clock()
local bad, kinds, max_tail, passes = 0, {}, 0, 0
for seed = first, first + count - 1 do
	local sc = L.scenario(seed, opts)
	local c0 = os.clock()
	local res = L.play(sc, play_opts)
	if os.clock() - c0 > 8 then
		print(string.format("seed %d: slow, %.1f s (%s frames, %s, %s)", seed, os.clock() - c0, tostring(res.frames), sc.source, sc.dt_mode))
	end
	max_tail = math.max(max_tail, res.tail_max or 0)
	-- (the recount of the effect sprites and the janitor of the board are nets: a sprite they had to put right got through)
	local repaired = res.vfx and ((res.vfx.repaired or 0) + (res.view and res.view.repaired or 0) + (res.janitor and res.janitor.repairs or 0)) or 0
	passes = passes + (res.janitor and res.janitor.passes or 0)
	local leaked = res.error or #res.leaks > 0 or #res.findings > 0 or repaired > 0
	if opts.verbose or leaked then
		print(string.format("seed %d src=%s lvl=%s dt=%s end=%s ops=%d frames=%s state=%s tail=%s repaired=%s janitor=%s%s", seed, sc.source,
			tostring(sc.level), sc.dt_mode, sc.end_mode, #sc.ops, tostring(res.frames), tostring(res.final_state),
			tostring(res.tail_max), tostring(repaired), tostring(res.janitor and res.janitor.passes), res.error and " ERROR" or ""))
	end
	if leaked then
		bad = bad + 1
		if res.error then print("  ERROR " .. tostring(res.error):sub(1, 600):gsub("\n", " | ")) end
		local seen = {}
		for _, l in ipairs(res.leaks) do
			kinds[l.kind] = (kinds[l.kind] or 0) + 1
			if not seen[l.kind] then
				seen[l.kind] = true
				print("  LEAK " .. l.kind .. ": " .. l.text)
			end
		end
		for i, f in ipairs(res.findings) do
			kinds["frame:" .. f.kind] = (kinds["frame:" .. f.kind] or 0) + 1
			if i <= 3 then
				print(string.format("  FRAME %s: %s (frame %d, op %d, dt %.3f)", f.kind, tostring(f.text), f.frame, f.op, f.dt))
			end
		end
		if opts.story or opts.shrink then
			local story = sc.ops
			if opts.shrink then
				local small = L.shrink(sc, function(r) return r.error ~= nil or #r.leaks > 0 or #r.findings > 0 end, play_opts)
				story = small.ops
				print("  shrunk to " .. #story .. " ops")
			end
			for i, op in ipairs(story) do print(string.format("    %2d %s", i, L.op_text(op))) end
		end
	end
end

local ks = {}
for k, v in pairs(kinds) do ks[#ks + 1] = k .. "=" .. v end -- order-independent
table.sort(ks)
print(string.format("seeds %d..%d: %d leaking of %d, longest tail %.2f s, janitor looked %d times, %s (%.1f s)", first, first + count - 1,
	bad, count, max_tail, passes, #ks > 0 and table.concat(ks, " ") or "clean", os.clock() - started))
if bad > 0 then os.exit(1) end
