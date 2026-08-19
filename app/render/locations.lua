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


-- ── aphids ─────────────────────────────────────────────────────────────
-- Plump, pale-green and unmistakably edible. They visibly deplete: the
-- patch thins out as they are carried off, which is the feedback that
-- says "this place is nearly spent" without a number.
local function drawAphids(g, sx, sy, r, l, t, shown)
  for k = 1, shown do
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

-- ── grain: the FIELD ───────────────────────────────────────────────────
--
-- A cultivated plot, tilted away from the viewer, with furrows running
-- across it. This is the part of a grain patch that is TERRAIN: it is
-- there whether or not there is a crop standing in it, and it stays on
-- screen once you have found the place -- so a field you have picked
-- clean still reads as a field you own rather than as a faint circle that
-- could be anything.
--
-- WHY A TILTED RECTANGLE AND NOT A CIRCLE. Everything else on this board
-- is round: mounds, the unknown discs, aphid clusters, the spider. A
-- circle for grain said "generic location" in the same visual language as
-- everything else, which is exactly the wrong thing to say about the one
-- site type that is worked ground. Straight edges and parallel furrows
-- are what farmland looks like from above at an angle, and they read as
-- deliberate -- somebody laid this out -- from across the map.
--
-- MOSTLY TOP-DOWN, ONLY SLIGHTLY ANGLED, because the rest of the board
-- is. The mounds, the ants, the unknown discs and the aphids are all
-- drawn straight down; a strongly foreshortened field next to them reads
-- as a graphic from a different game, and the eye reads the mismatch
-- before it reads the field. A first pass at 0.62 did exactly that -- the
-- plot looked like a wall leaning away rather than ground seen from
-- above.
--
-- The tilt is a plain vertical squash rather than a proper isometric
-- rotation, for the same reason: rotation would fight the top-down
-- geometry around it. A gentle squash plus a slight lean is enough to say
-- "a worked rectangle lying on the ground, seen at a bit of an angle"
-- while keeping the footprint honest about where the patch actually is,
-- which matters because the hit area is the drawn shape.
local FIELD_TILT = 0.86      -- vertical squash: 1.0 is flat-on, 0 is edge-on
local FIELD_SKEW = 0.10      -- lean, so it is not a plain axis-aligned box

-- The plot's four corners, in screen space. Kept in one place because the
-- furrows, the crop rows and the border all have to agree on them.
local function fieldQuad(sx, sy, r)
  local w, h = r * 1.02, r * 1.02 * FIELD_TILT
  -- A PARALLELOGRAM, NOT A TRAPEZOID. Pushing the top edge one way and
  -- the bottom edge the other narrows one end, and a quad with a narrow
  -- end reads as a bucket or a crate seen in perspective -- which is what
  -- the first version looked like. Sliding BOTH edges the same direction
  -- keeps every side parallel to its opposite: a rectangle lying on the
  -- ground, turned slightly, seen from almost overhead.
  -- Both TOP corners slide +sk and both BOTTOM corners slide -sk, so the
  -- top and bottom edges stay the same LENGTH and simply offset -- a lean.
  -- (Sliding left corners one way and right corners the other is what
  -- narrows an end, and that is the trapezoid this is not.)
  local sk = w * FIELD_SKEW
  return {
    sx - w + sk, sy - h,      -- top-left
    sx + w + sk, sy - h,      -- top-right
    sx + w - sk, sy + h,      -- bottom-right
    sx - w - sk, sy + h,      -- bottom-left
  }
end

-- Interpolate inside the quad in (u, v), u across the furrows and v down
-- them, so crop rows sit ON the tilted plane instead of floating over it.
local function fieldPoint(q, u, v)
  local topx = q[1] + (q[3] - q[1]) * u
  local topy = q[2] + (q[4] - q[2]) * u
  local botx = q[7] + (q[5] - q[7]) * u
  local boty = q[8] + (q[6] - q[8]) * u
  return topx + (botx - topx) * v, topy + (boty - topy) * v
end

-- The bare plot: soil, furrows, and a border. Drawn whenever the place is
-- discovered, crop or no crop.
local function drawField(g, sx, sy, r, l, here)
  local q = fieldQuad(sx, sy, r)
  -- Turned soil. LIGHTER THAN THE GRASS, not darker: a first pass at
  -- 0.24/0.20/0.14 was darker than the field it sits in, so the plot read
  -- as a hole rather than as ground somebody had worked, and at a glance
  -- it looked like a shadow. Tilled earth catches light; the grass around
  -- here is dark and desaturated, so the plot has to come UP off it.
  --
  -- Dimmed rather than greyed when you are away, which is the same
  -- language the rest of state 2 uses -- the place is still legible, it
  -- is just not lit by your presence.
  local a = here and 1.0 or 0.78
  g.setColor(0.34 * a, 0.28 * a, 0.19 * a, 1)
  g.polygon("fill", q[1], q[2], q[3], q[4], q[5], q[6])
  g.polygon("fill", q[1], q[2], q[5], q[6], q[7], q[8])
  -- Furrows RUN ALONG THE ROWS THE CROP IS PLANTED IN, which means across
  -- the plot (constant v), not down it. The first pass drew them at
  -- constant u -- perpendicular to the planting -- so the stalks appeared
  -- to be standing across the furrows instead of growing out of them, and
  -- the two halves of the drawing disagreed about which way the field was
  -- ploughed.
  g.setLineWidth(math.max(1, r * 0.018))
  for k = 1, 5 do
    local v = k / 6
    local x0, y0 = fieldPoint(q, 0, v)
    local x1, y1 = fieldPoint(q, 1, v)
    g.setColor(0.26 * a, 0.21 * a, 0.14 * a, 1)
    g.line(x0, y0, x1, y1)
  end
  -- The edge of the plot, so it ends somewhere definite.
  g.setColor(0.46 * a, 0.40 * a, 0.26 * a, 1)
  g.polygon("line", q[1], q[2], q[3], q[4], q[5], q[6], q[7], q[8])
  g.setLineWidth(1)
  return q
end

-- Stalks, drawn as quads (a ribbon traced up one side and back down the
-- other is concave and kills the GPU path). They pop back as they regrow,
-- so a patch left alone visibly refills.
local function drawGrain(g, sx, sy, r, l, t, shown, here, q)
  -- PLANTED IN THE FURROWS, not scattered in a circle. Each item takes a
  -- slot down a furrow, so a filling patch fills row by row the way a
  -- crop does, and the stalks sit on the tilted plane rather than
  -- floating over it.
  --
  -- Slots are assigned in a fixed order (furrow by furrow, near rows
  -- first) so regrowth is legible: the same item index always lands in
  -- the same place, and the patch visibly refills toward the back.
  -- SPREAD ACROSS THE PLOT, AND FILL FROM THE FRONT.
  --
  -- Two earlier tries and what each got wrong, because both look fine as
  -- code and only fail on screen:
  --
  --   Plain index order put a small crop entirely in the BACK row --
  --   three stalks in a line along the far edge of an otherwise bare
  --   field, which reads as "empty" rather than "a few left".
  --
  --   Stepping across the row by a fixed stride fixed that but left the
  --   last, partly-filled row bunched to one side (six items landed as
  --   four across the front and two crowded left behind them), so the
  --   field looked lopsided rather than half-planted.
  --
  -- What works is laying each row out for the number ACTUALLY IN IT: a
  -- row with two stalks spaces those two across the whole plot, a row
  -- with four spaces four. Rows fill near-edge first, because the front
  -- of a field is where the eye lands.
  local COLS, ROWS = 4, 3
  local INSET = 0.16
  local rows = {}
  for k = 1, shown do
    local row = math.floor(((k - 1) % (COLS * ROWS)) / COLS)
    rows[row] = (rows[row] or 0) + 1
  end
  local placed = {}
  for k = 1, shown do
    local idx = (k - 1) % (COLS * ROWS)
    local row = math.floor(idx / COLS)
    placed[row] = (placed[row] or 0) + 1
    local n = rows[row]
    -- Centres of n equal slices across the plot, so any count is centred.
    local cu = INSET + ((placed[row] - 0.5) / n) * (1 - INSET * 2)
    -- Near row (v = 1) first, back row last.
    local cv = 1 - (INSET + (row + 0.5) / ROWS * (1 - INSET * 2))
    local x, y = fieldPoint(q, cu, cv)
    -- Stalks further up the plot are further away, so they are shorter.
    -- That depth cue is what stops the field reading as a flat sticker.
    -- Gentler than it was, to match the shallower tilt above: at nearly
    -- top-down there is very little distance between the near and far
    -- edge of a plot this size, so a strong near/far size ramp would be
    -- claiming a depth the angle does not support.
    local depth = 0.88 + cv * 0.18
    -- MUCH SMALLER THAN THEY WERE. At 0.44 the stalks stood almost half
    -- the height of the whole plot, so two of them read as a pair of
    -- lollipops planted in a crate rather than as a crop -- the field
    -- became the background to the items instead of the items being
    -- something growing in the field. A stalk is a detail on a plot, not
    -- a landmark beside one.
    local h = r * 0.20 * depth
    local sway = math.sin(t * 0.9 + k * 2.3) * r * 0.02
    local w = math.max(1, r * 0.022 * depth)
    local a = here and 1.0 or 0.80
    g.setColor(0.52 * a, 0.46 * a, 0.22 * a, 1)
    g.polygon("fill", x - w, y, x + w, y,
                      x + w + sway, y - h, x - w + sway, y - h)
    -- The ear: a fat little convex head at the top.
    g.setColor(0.80 * a, 0.72 * a, 0.34 * a, 1)
    disc(x + sway, y - h, r * 0.045 * depth)
  end
end

-- ── the spider ─────────────────────────────────────────────────────────
-- Big, legged, and unmistakable the moment you can see her. Built from
-- overlapping convex ovals like the ants, for the same reason. Her legs
-- go as she is beaten down, so a wounded spider reads as wounded.
-- `here` is whether one of your ants is standing in the patch. SHE is
-- only drawn when it is true: a spider is a GUARD, and a guard is the
-- half of a location that hides. Her legs, once she is beaten, are food
-- and follow the food rule instead (always visible once discovered).
local function drawSpider(g, sx, sy, r, l, t, shown, here)
  local alive = (l.guard or 0) > 0
  if alive and not here then
    -- DISCOVERED, SHE IS IN THERE, AND YOU CANNOT SEE HER.
    --
    -- You know the place and you know what kind of place it is -- the
    -- panel will say "Spider" -- but whether she is still alive, and how
    -- badly you hurt her last time, is a live fact about a body, and
    -- bodies need presence. Drawing her from memory would make a scouted
    -- spider a permanent health bar readable from across the map.
    --
    -- Nothing is drawn here on purpose: the empty-patch stubble above
    -- has already marked the ground as a known place, which is exactly
    -- the right amount to say.
    return
  end
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
    for k = 1, shown do
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

  local unknownsite = require("render.unknownsite")

  for i = 1, #world.locs do
    local l = world.locs[i]
    local sx, sy = vp.worldToScreen(l.x, l.y)

    -- THREE STATES, AND THE RADIUS IS PART OF WHAT IS HIDDEN.
    --
    -- An unvisited location draws at the SHARED unknown radius, never at
    -- its own kind's. Drawing it at `l.radius` told the player the kind
    -- from across the map without anyone walking anywhere: a spider is 96
    -- units, grain 80, aphids 74, and the mounds are 56/78/104 -- so
    -- every circle on the board was labelled by its size, and the spider
    -- (the one thing the fog most needs to hide) was the biggest thing
    -- out there.
    local known = l.visited
    local r = (known and l.radius or unknownsite.RADIUS) * s
    -- FOOD STAYS VISIBLE ONCE FOUND. WHO IS STANDING ON IT DOES NOT.
    --
    -- These are two different kinds of fact and they get two different
    -- rules, which is the correction to the first cut of this plan.
    --
    -- The FOOD is terrain. A grain patch you have walked to is a field
    -- you know the location of, and a field does not sneak about: you can
    -- see from a distance roughly how much is standing in it, and you can
    -- see it grow back. Latching the count to what you last saw (the
    -- earlier rule here) made a discovered patch quietly stop being
    -- information -- you had to keep walking back to a place you already
    -- knew just to re-read a number that was never hidden from you in the
    -- first place. That is busywork, not fog.
    --
    -- WHO IS THERE is the part that hides. A rival column parked on a
    -- patch, or a spider sitting in it, is an army -- and an army in the
    -- dark is exactly what state 2 refuses to report. That gating lives
    -- below (the guard art and the owner ring), and it still keys on
    -- `observed`, which is presence.
    local shown = known and (l.items or 0) or 0

    -- Cull offscreen: a location is small and there can be a dozen.
    if sx > -r * 4 and sx < vp.w + r * 4
       and sy > -r * 4 and sy < vp.h + r * 4 then
      -- A soft patch of darker ground under everything, so a location
      -- reads as a PLACE rather than as objects lying on the grass.
      -- Sized off `r`, so it says nothing an unknown circle does not.
      g.setColor(0.10, 0.11, 0.08, 0.35)
      disc(sx, sy, r * 1.15)

      if not known then
        -- STATE 3: the same circle every unvisited site wears, mound and
        -- food alike.
        unknownsite.draw(g, sx, sy, r)
      else
      -- STATE 2 STILL LOOKS LIKE A PLACE YOU KNOW.
      --
      -- The item art IS the whole drawing of a location, so a discovered
      -- patch you had picked clean rendered as bare ground -- nothing at
      -- all. That loses the identity the visit was supposed to buy: you
      -- walked over, found grain, and the map went back to showing you
      -- nothing, which is indistinguishable from never having gone.
      --
      -- A faint grey ring and a scatter of dead stubble at the item spots
      -- marks it as a known, spent place. Grey, always: what changes hands
      -- or grows back here is state you do not have any more (state 2
      -- shows no live counts), and this says only "you have been here and
      -- it was this kind of place".
      -- SHOWN WHENEVER THE PLACE IS EMPTY, not only when you are away.
      --
      -- Gating this on absence alone was wrong in the one case a player
      -- actually looks at: a patch you are STANDING ON that you have just
      -- picked clean drew as a bare green outline with nothing inside it.
      -- Your ants are working an empty ring. The identity you walked over
      -- to earn is gone from the screen at the exact moment you earned
      -- it, which is the same complaint that put the stubble here in the
      -- first place -- it was just fixed for the remembered case and not
      -- the present one.
      --
      -- Stubble is what a picked-over patch LOOKS like, so it is drawn
      -- whenever there is nothing live to draw: under your feet (brighter
      -- -- you are here, you can see the ground) and from memory (fainter
      -- -- you are recalling it). A patch with items in it draws the items
      -- and needs none of this.
      -- A LIVE GUARD IS NOT AN EMPTY PATCH. A spider you are standing on
      -- has `items = 0` (her legs are not a meal until she is beaten), so
      -- the "nothing live to draw" test above counted her patch as spent
      -- and drew dead stubble UNDER her. She is very much something to
      -- draw. Suppressed only where she is actually drawn -- away from
      -- the patch she is hidden (see drawSpider), and there the stubble
      -- is the one mark saying "you have been here", which is the whole
      -- point of it.
      local guardShown = (l.guard or 0) > 0 and l.observed
      local ringA = (shown > 0 or guardShown) and 0.0
                    or (l.observed and 0.42 or 0.32)
      if ringA > 0 then
        g.setColor(0.42, 0.44, 0.40, ringA)
        g.setLineWidth(math.max(1, vp.u(2)))
        local n, pts = 26, {}
        for k = 0, n - 1 do
          local a = (k / n) * 6.28318
          pts[#pts + 1] = sx + math.cos(a) * r * 0.92
          pts[#pts + 1] = sy + math.sin(a) * r * 0.92
        end
        g.polygon("line", pts)
        g.setLineWidth(1)
        -- Stubble where the crop was, at the same seeded spots the live
        -- art uses, so the memory lines up with what you actually saw.
        local marks = math.max(3, math.min(6, (l.cap or 4)))
        for k = 1, marks do
          local ox, oy = itemSpot(l.seed, k)
          g.setColor(0.34, 0.35, 0.31, l.observed and 0.7 or 0.55)
          disc(sx + ox * r, sy + oy * r, r * 0.055)
        end
      end
      if l.kind == "aphids" then
        drawAphids(g, sx, sy, r, l, t, shown)
      elseif l.kind == "grain" then
        -- THE FIELD IS TERRAIN AND GOES DOWN FIRST, crop or no crop: it
        -- is the thing that says "this is a grain patch you have found"
        -- even when there is nothing standing in it. Then the crop on
        -- top, planted in its furrows.
        local q = drawField(g, sx, sy, r, l, l.observed)
        drawGrain(g, sx, sy, r, l, t, shown, l.observed, q)
      elseif l.kind == "spider" then
        drawSpider(g, sx, sy, r, l, t, shown, l.observed)
      end
      end

      -- CLAIMED GROUND WEARS ITS COLOUR, the same as a mound's rim does.
      -- PRESENCE ONLY: a discovered patch you are not standing on says
      -- nothing about who holds it now (state 2).
      --
      -- THE RING FOLLOWS THE SHAPE IT IS MARKING. A single 28-sided circle
      -- was drawn around every location whatever was under it, which was
      -- fine while every location WAS a circle -- and looked wrong the
      -- moment grain became a rectangular field: a green hoop floating
      -- around a square plot, touching it at four points and drifting away
      -- everywhere else. The eye reads the mismatch as a bug in the art
      -- before it reads it as ownership.
      --
      -- A field gets a border parallel to its own edges; everything round
      -- keeps the circle.
      if l.owner and l.observed then
        local mounds = require("render.mounds")
        local c = mounds.sideColour(l.owner)
        g.setColor(c[1], c[2], c[3], 0.55)
        g.setLineWidth(math.max(1, vp.u(2)))
        if l.kind == "grain" then
          -- The plot's own quad, pushed out a little so the border sits
          -- just outside the soil rather than on it. Scaled about the
          -- centre, which keeps every edge parallel to the edge it is
          -- marking.
          local q = fieldQuad(sx, sy, r)
          local pts = {}
          for k = 1, 8, 2 do
            pts[#pts + 1] = sx + (q[k] - sx) * 1.10
            pts[#pts + 1] = sy + (q[k + 1] - sy) * 1.10
          end
          g.polygon("line", pts)
        else
          local n, pts = 28, {}
          for k = 0, n - 1 do
            local a = (k / n) * 6.28318
            pts[#pts + 1] = sx + math.cos(a) * r * 1.2
            pts[#pts + 1] = sy + math.sin(a) * r * 1.2
          end
          g.polygon("line", pts)
        end
        g.setLineWidth(1)
      end
    end
  end
end

return M
