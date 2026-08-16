-- fonts.lua - one place that owns type.
--
-- THE RULE: nothing in this game draws text with the engine's built-in
-- bitfont. That font is a blocky 8x8 debug face; it is fine for an engine
-- assertion and wrong for anything a person looks at, including the debug
-- overlay (which a human reads over someone's shoulder during a playtest).
-- Every love.graphics.print in this project must have a real font set
-- first, and it comes from here.
--
-- The face is Atkinson Hyperlegible Bold (SIL OFL), the same one the rest
-- of the family uses: it was designed for low-vision readability, which is
-- exactly the couch-across-the-room problem.

local M = {}

local cache = {}
local PATH = "fonts/AtkinsonBold.ttf"

-- Sizes are requested in DESIGN UNITS (1/1080th of the reference height),
-- so type scales with the window instead of being pinned to 1080p pixels.
function M.get(vp, designSize)
  local px = math.max(8, math.floor(designSize * vp.unit + 0.5))
  local f = cache[px]
  if not f then
    f = love.graphics.newFont(PATH, px)
    cache[px] = f
  end
  return f
end

-- PRE-WARM every size the game uses, at init, before any frame is drawn.
--
-- newFont() mid-frame allocates a texture while the HDR pass is bound,
-- and on this engine that broke the composite's declared-format blit mesh
-- ("Mesh:setVertices: the update failed... cannot grow past 6 vertices"),
-- raising a Lua error EVERY frame and dropping the whole run to the
-- software rasterizer. The symptom that surfaced was a gate reporting a
-- menu that would not open -- the erroring frame never processed input --
-- which is three layers away from a font cache.
--
-- Keep this list in step with the sizes the UI asks for; a missed one is
-- not a crash, just the same first-use hazard again.
local SIZES = { 17, 21, 22, 23, 24, 26, 30, 32, 34, 40, 46 }
function M.warm(vp)
  for i = 1, #SIZES do M.get(vp, SIZES[i]) end
end

-- Convenience: set and return, for the common one-liner.
function M.set(vp, designSize)
  local f = M.get(vp, designSize)
  love.graphics.setFont(f)
  return f
end

function M.reset() cache = {} end

return M
