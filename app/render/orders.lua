-- orders.lua - the order you are composing, and the ones in flight.
--
-- THE MOST IMPORTANT LAYER FOR FEEL. The whole gesture is "drag
-- out of a planet and a green arrow shows how many are going" -- the
-- player is looking at their own intent before they commit to it. Without
-- that the send is invisible until ants start moving, which is exactly
-- what made the previous build feel like nothing was under your control.

local WW = require("sim.world")

local M = {}

-- TEXT NEVER GOES IN THE SCENE PASS. It is rasterised into the HDR target
-- and comes out MIRRORED (see NOTES) -- which is exactly what shipped:
-- the refusal message, the send count and the "N ready" gauge were all
-- drawn here and all three read backwards on screen. mounds.lua already
-- solved this by collecting its badges and painting them after the
-- composite; orders.lua is now split the same way. Geometry here, type in
-- drawLabels().
local labels = {}
local function label(kind, x, y, text, size, r, gg, b, a, boxR, boxG, boxB, boxA)
  labels[#labels + 1] = { kind = kind, x = x, y = y, text = text,
                          size = size, r = r, g = gg, b = b, a = a,
                          boxR = boxR, boxG = boxG, boxB = boxB, boxA = boxA }
end

function M.draw(snap, vp, intents)
  for i = #labels, 1, -1 do labels[i] = nil end
  local g = love.graphics
  local world = snap.world
  local s = vp.worldScale()
  local t = snap.time
  local A = require("sim.agents")

  -- ── A REFUSAL, briefly, on the mound you pressed ──
  --
  -- Pressing A on a mound that is not yours did nothing and showed
  -- nothing, which is indistinguishable from a broken button. Two
  -- seconds of plain text at the mound is enough.
  if intents.refused and intents.refusedFrames and intents.refusedFrames > 0 then
    local id = intents.cursor and intents.cursor.node
    local n = id and WW.site(world, id)
    if n then
      local sx, sy = vp.worldToScreen(n.x, n.y)
      local a = math.min(1, intents.refusedFrames / 30)
      label("refuse", sx, sy - n.radius * s - vp.u(42), intents.refused, 26,
            0.98, 0.62, 0.45, a, 0.05, 0.04, 0.04, 0.7 * a)
    end
  end

  -- ── the pending order ──
  local from, to, frac, count, legal = intents.pendingOrder(snap.agents)
  if from and WW.site(world, from) then
    local a = WW.site(world, from)
    local ax, ay = vp.worldToScreen(a.x, a.y)

    -- A ring round the source that pulses: this is where the ants come
    -- from, and it is picked up.
    local pulse = 0.5 + 0.5 * math.sin(t * 5)
    g.setColor(0.55, 0.98, 0.62, 0.55 + pulse * 0.4)
    g.setLineWidth(math.max(3, vp.u(6)))
    local px, py
    for k = 0, 40 do
      local th = k / 40 * 6.28318
      local qx, qy = ax + math.cos(th) * a.radius * s * 1.22,
                     ay + math.sin(th) * a.radius * s * 1.22
      if px then g.line(px, py, qx, qy) end
      px, py = qx, qy
    end
    g.setLineWidth(1)

    if to and to ~= from and WW.site(world, to) then
      local b = WW.site(world, to)
      local bx, by = vp.worldToScreen(b.x, b.y)
      -- THE ARROW. Its THICKNESS is the quantity, so how much you are
      -- committing is visible in the gesture rather than in a number.
      local dx, dy = bx - ax, by - ay
      local d = math.sqrt(dx * dx + dy * dy)
      if d > 1 then
        local nx, ny = -dy / d, dx / d
        local w = math.max(2, vp.u(4) + vp.u(16) * (frac or 0.5))
        -- AN ILLEGAL ORDER IS DRAWN AS A REFUSAL, not as a promise. The
        -- network rule is that every mound you RELAY through must be one
        -- you hold; only the destination may be unclaimed. The arrow used
        -- to be drawn green regardless, so it reached straight past the
        -- edge of the range ring to a mound with no path to it -- an
        -- order the sim would then silently drop. Red, and no head.
        if legal then
          g.setColor(0.55, 0.98, 0.62, 0.34 + pulse * 0.18)
        else
          g.setColor(0.95, 0.30, 0.24, 0.30 + pulse * 0.16)
        end
        g.polygon("fill",
          ax + nx * w, ay + ny * w,
          bx + nx * w * 0.45, by + ny * w * 0.45,
          bx - nx * w * 0.45, by - ny * w * 0.45,
          ax - nx * w, ay - ny * w)
        -- Head at the target end.
        local hx, hy = dx / d, dy / d
        local tipx, tipy = bx - hx * b.radius * s * 0.9,
                           by - hy * b.radius * s * 0.9
        if legal then
          g.setColor(0.65, 1.0, 0.70, 0.85)
          g.polygon("fill",
            tipx + hx * w * 2.2, tipy + hy * w * 2.2,
            tipx + nx * w * 1.7, tipy + ny * w * 1.7,
            tipx - nx * w * 1.7, tipy - ny * w * 1.7)
        end
      end

      -- HOW MANY, in words, at the midpoint: the number is the decision.
      local mx, my = (ax + bx) * 0.5, (ay + by) * 0.5
      if legal then
        label("count", mx, my - vp.u(18), tostring(count or 0), 30,
              0.75, 1.0, 0.78, 1, 0.04, 0.07, 0.05, 0.75)
      else
        -- Say WHY, in the same place the count would have been.
        label("count", mx, my - vp.u(18), "no route", 26,
              1.0, 0.62, 0.55, 1, 0.09, 0.03, 0.03, 0.78)
      end
    else
      -- No target yet: say what the gauge is set to, at the source.
      label("ready", ax, ay - a.radius * s - vp.u(38),
            (count or 0) .. " ready", 26, 0.75, 1.0, 0.78, 0.9)
    end
  end
end

-- Painted AFTER the composite, in screen space, where type is the right
-- way round. Positions were resolved during the scene pass, so the text
-- still sits exactly where its geometry is.
function M.drawLabels(vp)
  local g = love.graphics
  local fonts = require("ui.fonts")
  for i = 1, #labels do
    local L = labels[i]
    local f = fonts.get(vp, L.size)
    g.setFont(f)
    local tw = f:getWidth(L.text)
    -- Positions were captured inside the flipped scene pass; mirror the
    -- y back so the text sits where its geometry actually is.
    local ly = vp.unflip(L.y) - f:getHeight()
    if L.boxA then
      g.setColor(L.boxR, L.boxG, L.boxB, L.boxA)
      g.rectangle("fill", L.x - tw * 0.5 - vp.u(12), ly - vp.u(4),
                  tw + vp.u(24), f:getHeight() + vp.u(8))
    end
    g.setColor(L.r, L.g, L.b, L.a)
    g.print(L.text, L.x - tw * 0.5, ly)
  end
end

return M
