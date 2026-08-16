-- caste_widget.lua - the entire economy screen.
--
-- Three bars in a row: forager, nurse, soldier. That is the whole economy
-- UI, and it is the only place in the game where the player sets a number.
-- It is a PLAN rather than a lever -- the colony converges on the ratio over
-- the following minutes -- so it is drawn as an intention (the requested
-- share) with the actual population overlaid on it. Seeing the actual chase
-- the requested is what teaches the lag without a tutorial.

local castes = require("sim.castes")
local A      = require("sim.agents")

local M = {}

local font
local COL = {
  { 0.86, 0.62, 0.28 },     -- forager
  { 0.92, 0.84, 0.66 },     -- nurse
  { 0.52, 0.34, 0.22 },     -- soldier
}
local LABEL = { "forage", "brood", "guard" }

local geom = {}

function M.init(vp, f)
  font = f
  local w = vp.u(78)
  local gap = vp.u(14)
  geom.barW = w
  geom.barH = vp.u(120)
  geom.gap = gap
  geom.totalW = w * 3 + gap * 2
end

-- Where each bar sits, in screen space. Exposed so the touch handler can
-- hit-test the same rectangles the renderer draws -- one source of truth,
-- so the widget can never be visually offset from its own hitboxes.
function M.barRect(vp, i)
  local x, y = vp.anchor("br")
  local left = x - geom.totalW
  local top = y - geom.barH - vp.u(30)
  return left + (i - 1) * (geom.barW + geom.gap), top, geom.barW, geom.barH
end

function M.draw(snap, vp, intents)
  local g = love.graphics
  local c = snap.castes
  local want = { c.f, c.n, c.s }
  local steps = castes.cfg.steps
  local n, f, nu, sol = A.stats(snap.agents)
  local have = { f, nu, sol }
  local total = math.max(1, n)

  for i = 1, 3 do
    local bx, by, bw, bh = M.barRect(vp, i)

    -- The trough.
    g.setColor(0, 0, 0, 0.32)
    g.rectangle("fill", bx, by, bw, bh, vp.u(6))

    -- The REQUEST: a soft column at the share the player asked for.
    local wantH = bh * (want[i] / steps)
    local col = COL[i]
    g.setColor(col[1], col[2], col[3], 0.38)
    g.rectangle("fill", bx, by + bh - wantH, bw, wantH, vp.u(6))

    -- The ACTUAL: a solid, narrower column at the live population share.
    local haveH = bh * (have[i] / total)
    local inset = bw * 0.22
    g.setColor(col[1], col[2], col[3], 0.95)
    g.rectangle("fill", bx + inset, by + bh - haveH, bw - inset * 2, haveH,
                vp.u(4))

    -- The request line, so the gap between plan and reality is legible even
    -- when the two columns nearly agree.
    g.setColor(1, 1, 1, 0.55)
    g.setLineWidth(math.max(1, vp.u(2)))
    g.line(bx, by + bh - wantH, bx + bw, by + bh - wantH)
    g.setLineWidth(1)

    g.setFont(font)
    g.setColor(0.9, 0.88, 0.82, 0.75)
    local tw = font:getWidth(LABEL[i])
    g.print(LABEL[i], bx + bw * 0.5 - tw * 0.5, by + bh + vp.u(6))
  end
end

-- Hit-test for touch: which bar is under this screen point, and whether the
-- tap was in the upper or lower half (raise or lower). Returns nil if the
-- point is not on the widget, so the world sees the tap instead.
--
-- Guarded on init: the input layer runs BEFORE the first draw, so on frame
-- one the geometry does not exist yet. Without this the first tap of a
-- session throws instead of doing nothing.
function M.hit(vp, sx, sy)
  if not vp or not geom.barW then return nil end
  for i = 1, 3 do
    local bx, by, bw, bh = M.barRect(vp, i)
    if sx >= bx and sx <= bx + bw and sy >= by and sy <= by + bh then
      return i, (sy < by + bh * 0.5) and 1 or -1
    end
  end
  return nil
end

return M
