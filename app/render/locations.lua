-- locations.lua - food in the ground, drawn.
--
-- The fog rule these obey is the whole reason they are interesting: an
-- unvisited location is an anonymous grey CLUMP. Not a hidden thing --
-- you can see something is there, and that it is worth walking to -- but
-- you cannot tell grain from aphids from a spider until one of your ants
-- is standing on it. Walking up to one is a real decision, and sometimes
-- the answer is a spider.
--
-- Everything here is generated from the location's seed, so a patch looks
-- the same every time the map is rebuilt from a save, and no two look
-- alike. No bitmaps, and CONVEX polygons only: the engine fans a filled
-- polygon on the GPU and refuses a concave one, which kills the 2D path
-- for the whole run.

local flora = require("render.flora")

local M = {}

local disc = flora.disc

-- A small deterministic generator per location, so item positions are
-- stable across frames without storing them in the sim.
local function seeded(seed)
  local s = (seed or 1) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function()
    s = (s * 16807) % 2147483647
    return (s - 1) / 2147483646
  end
end

-- Where item `k` of `n` sits, in location-radius units. Stable per seed.
local function itemSpot(seed, k)
  local rng = seeded(seed + k * 7919)
  local a = rng() * 6.28318
  local r = 0.30 + rng() * 0.62
  return math.cos(a) * r, math.sin(a) * r
end

-- ── the unknown ────────────────────────────────────────────────────────
--
-- A GREY CIRCLE, exactly the language an unvisited MOUND speaks. That is
-- the point: the player already knows what grey stone means -- somewhere
-- worth walking to that will not tell you anything until you are
-- standing on it -- so a location borrows the same sentence rather than
-- inventing a second one.
--
-- A cluster of little lumps was tried first and it read as scenery: too
-- small and too scattered to look like a destination, so the eye skipped
-- over the food entirely. One disc with rings, sized like the place it
-- is, reads as A PLACE.
local function drawUnknown(g, sx, sy, r, seed)
  local rng = seeded(seed)
  -- Concentric rings darkening inward, still (nothing breathes out here
  -- -- only an established colony does that) and slightly irregular per
  -- seed, so no two unknown patches are the same circle.
  for k = 4, 1, -1 do
    local f = k / 4
    local wob = 1 + (rng() - 0.5) * 0.10
    local v = 0.17 + (5 - k) * 0.030
    g.setColor(v * 0.96, v * 1.0, v * 1.10, 1)
    disc(sx, sy, r * f * wob)
  end
end

-- ── aphids ─────────────────────────────────────────────────────────────
-- Plump, pale-green and unmistakably edible. They visibly deplete: the
-- patch thins out as they are carried off, which is the feedback that
-- says "this place is nearly spent" without a number.
local function drawAphids(g, sx, sy, r, l, t)
  for k = 1, (l.items or 0) do
    local ox, oy = itemSpot(l.seed, k)
    local x, y = sx + ox * r, sy + oy * r
    local bob = math.sin(t * 1.4 + k * 1.7) * r * 0.03
    local br = r * 0.30
    -- Body: two overlapping convex ovals, never one waisted outline.
    g.setColor(0.58, 0.76, 0.42, 1)
    disc(x, y + bob, br)
    g.setColor(0.66, 0.84, 0.48, 1)
    disc(x - br * 0.34, y + bob - br * 0.22, br * 0.72)
    -- A wet highlight, because they are meant to look delicious.
    g.setColor(0.86, 0.95, 0.70, 0.55)
    disc(x - br * 0.42, y + bob - br * 0.40, br * 0.26)
  end
end

-- ── grain ──────────────────────────────────────────────────────────────
-- Stalks, drawn as quads (a ribbon traced up one side and back down the
-- other is concave and kills the GPU path). They pop back as they regrow,
-- so a patch left alone visibly refills.
local function drawGrain(g, sx, sy, r, l, t)
  for k = 1, (l.items or 0) do
    local ox, oy = itemSpot(l.seed, k)
    local x, y = sx + ox * r, sy + oy * r
    local h = r * 0.62
    local sway = math.sin(t * 0.9 + k * 2.3) * r * 0.06
    local w = math.max(1, r * 0.05)
    g.setColor(0.52, 0.46, 0.22, 1)
    g.polygon("fill", x - w, y, x + w, y,
                      x + w + sway, y - h, x - w + sway, y - h)
    -- The ear: a fat little convex head at the top.
    g.setColor(0.80, 0.72, 0.34, 1)
    disc(x + sway, y - h, r * 0.11)
  end
end

-- ── the spider ─────────────────────────────────────────────────────────
-- Big, legged, and unmistakable the moment you can see her. Built from
-- overlapping convex ovals like the ants, for the same reason. Her legs
-- go as she is beaten down, so a wounded spider reads as wounded.
local function drawSpider(g, sx, sy, r, l, t)
  local alive = (l.guard or 0) > 0
  if alive then
    local legs = 8
    local hurt = 1 - (l.guard / math.max(1, l.guardMax or l.guard))
    for k = 1, legs do
      local a = (k / legs) * 6.28318 + math.sin(t * 0.7 + k) * 0.06
      local len = r * (0.95 + math.sin(t * 1.6 + k * 2.1) * 0.05)
      local w = math.max(1, r * 0.055)
      local nx, ny = math.cos(a), math.sin(a)
      local px, py = -ny * w, nx * w
      -- A knee, so the legs read as legs rather than spokes.
      local kx, ky = sx + nx * len * 0.55, sy + ny * len * 0.55 - r * 0.22
      g.setColor(0.14, 0.11, 0.13, 1)
      g.polygon("fill", sx + px, sy + py, sx - px, sy - py,
                        kx - px, ky - py, kx + px, ky + py)
      g.polygon("fill", kx + px, ky + py, kx - px, ky - py,
                        sx + nx * len - px, sy + ny * len - py,
                        sx + nx * len + px, sy + ny * len + py)
    end
    -- Abdomen and head.
    g.setColor(0.20, 0.15, 0.17, 1)
    disc(sx + r * 0.22, sy, r * 0.46)
    g.setColor(0.16, 0.12, 0.14, 1)
    disc(sx - r * 0.26, sy, r * 0.30)
    -- Eyes: the tell that she is looking back at you.
    g.setColor(0.92, 0.86, 0.40, 0.9)
    disc(sx - r * 0.38, sy - r * 0.10, r * 0.06)
    disc(sx - r * 0.38, sy + r * 0.10, r * 0.06)
    -- Damage: she pales as she is worn down.
    if hurt > 0 then
      g.setColor(0.55, 0.20, 0.18, hurt * 0.35)
      disc(sx + r * 0.22, sy, r * 0.46)
    end
  else
    -- Beaten: the legs are lying about, and each one is a meal.
    for k = 1, (l.items or 0) do
      local ox, oy = itemSpot(l.seed, k)
      local x, y = sx + ox * r, sy + oy * r
      local a = (k * 0.9) % 6.28318
      local len = r * 0.42
      local w = math.max(1, r * 0.05)
      local nx, ny = math.cos(a), math.sin(a)
      local px, py = -ny * w, nx * w
      g.setColor(0.18, 0.14, 0.15, 1)
      g.polygon("fill", x + px, y + py, x - px, y - py,
                        x + nx * len - px, y + ny * len - py,
                        x + nx * len + px, y + ny * len + py)
    end
    -- Her husk, so the place still reads as a spider's.
    g.setColor(0.15, 0.12, 0.13, 0.55)
    disc(sx, sy, r * 0.34)
  end
end

function M.draw(snap, vp)
  local g = love.graphics
  local world = snap.world
  if not world.locs then return end
  local s = vp.worldScale()
  local t = snap.time

  for i = 1, #world.locs do
    local l = world.locs[i]
    local sx, sy = vp.worldToScreen(l.x, l.y)
    local r = l.radius * s

    -- Cull offscreen: a location is small and there can be a dozen.
    if sx > -r * 4 and sx < vp.w + r * 4
       and sy > -r * 4 and sy < vp.h + r * 4 then
      -- A soft patch of darker ground under everything, so a location
      -- reads as a PLACE rather than as objects lying on the grass.
      g.setColor(0.10, 0.11, 0.08, 0.35)
      disc(sx, sy, r * 1.15)

      if not l.observed then
        drawUnknown(g, sx, sy, r, l.seed)
      elseif l.kind == "aphids" then
        drawAphids(g, sx, sy, r, l, t)
      elseif l.kind == "grain" then
        drawGrain(g, sx, sy, r, l, t)
      elseif l.kind == "spider" then
        drawSpider(g, sx, sy, r, l, t)
      else
        drawUnknown(g, sx, sy, r, l.seed)
      end

      -- CLAIMED GROUND WEARS ITS COLOUR, the same as a mound's rim does.
      if l.owner and l.observed then
        local mounds = require("render.mounds")
        local c = mounds.sideColour(l.owner)
        g.setColor(c[1], c[2], c[3], 0.55)
        g.setLineWidth(math.max(1, vp.u(2)))
        local n, pts = 28, {}
        for k = 0, n - 1 do
          local a = (k / n) * 6.28318
          pts[#pts + 1] = sx + math.cos(a) * r * 1.2
          pts[#pts + 1] = sy + math.sin(a) * r * 1.2
        end
        g.polygon("line", pts)
        g.setLineWidth(1)
      end
    end
  end
end

return M
