-- Shared flags of the QA layout sweep (the debug bridge command gui_bounds, main/app.script) and the GUI scenes
-- (client/ui.lua): plain data, so that a script in a go context can ask without touching the gui module.
--   track: scenes record the text nodes they make (set before a window is built)
--   want:  a counter; a scene that has not answered it yet computes its bounds on its next update
--   out:   gui path -> list of rows {t, x0, y0, w, h, px, bx0, by0, bw, bh} in window pixels, filled by the scenes
-- Nothing sets `track` in a release build, so nothing is recorded there.
local M = {}
M.track = false
M.want = 0
M.out = {}
return M
