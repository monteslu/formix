-- ants.lua - two thousand individuals.
--
-- M0/M1 draw ants as immediate-mode polygons, which is honest and slow. M3
-- replaces the body of draw() with an instanced mesh (one draw call for the
-- whole colony) without changing this module's interface. The split is
-- deliberate: the game has to be PROVEN fun before it is made fast, and the
-- swap is contained to one function.
--
-- Ants are drawn ON the bowed trail curve, not on the straight line between
-- nodes. If the trail bows and the ants walk straight, the whole layer
-- reads as broken -- which is exactly what happened the first time.

local trails = require("render.trails")

local WW = require("sim.world")

local M = {}

-- Body colours by role. Foragers are the default amber, nurses are paler
-- (they are almost always in the nest, so they read as a warm cluster),
-- soldiers are darker and bigger.
-- YOURS ARE AMBER, THEIRS ARE RED. A rival colony has to be readable as
-- an enemy at a glance from across the map, so each side has its own body
-- colour and the two never share a palette.
local YOUR_COL  = { 0.90, 0.64, 0.26 }
local ENEMY_COL = { 0.92, 0.24, 0.18 }
-- ONE COLOUR PER ENEMY SIDE, matching the mound rims. Two rival colonies
-- drawn in the same red make a three-way war unreadable: you cannot tell
-- whose column is crossing your ground, or see them fighting each other.
--
-- GOLD USED TO BE 0.135 AWAY FROM YOUR_COL IN RGB SPACE (red sits 0.41
-- away, three times the separation) -- an amber gold next to an amber
-- "yours" on the same warm earth fill is not a second colour, it is the
-- same colour with the brightness nudged. Measured off a live war-map
-- screenshot: a gold raider standing on a green-rimmed mound you hold was
-- reported as impossible to tell from your own ants at a glance, which is
-- exactly what the distance predicts.
--
-- Pulled toward yellow rather than orange, which is what pushes it away
-- from amber without turning it red-adjacent or reusing green (already
-- spoken for by "you" on the rim). Distance to YOUR_COL nearly triples.
local SIDE_COL = {
  red  = { 0.92, 0.24, 0.18 },
  gold = { 0.95, 0.90, 0.15 },
}
local ROLE_SIZE = { 1.0, 0.86, 1.28 }

-- Ants carrying food get a bright dot: at a glance, the ratio of laden to
-- empty ants on a road tells you whether it is productive. That is the
-- single most informative pixel in the game and it costs one extra disc.
local CARRY_COL = { 0.96, 0.88, 0.35 }
-- The colour of an ant carrying out an order. Deliberately cool and pale
-- against the warm browns of the foraging castes, so a marching column
-- separates from ordinary traffic at a glance.
local MISSION_COL = { 0.72, 0.94, 0.98 }

local scratch = {}

-- See flora.M.emissive: over-bright only pays off on the HDR path.
M.emissive = 1.0

function M.init(vp)
  M.emissive = require("render.fx").available and 2.2 or 1.0
end

-- An ant, drawn as a real insect: gaster, thorax, head, six walking legs and
-- two antennae. THREE SEPARATE convex blobs rather than one outline, which
-- is what buys the pinched waist -- the silhouette that says "ant" instead
-- of "grain of rice".
--
-- EACH PIECE MUST STAY CONVEX. The engine fans a filled polygon on the GPU
-- and REFUSES a concave one, disabling the GPU 2D path for the whole run (a
-- deliberate loud failure, not a fallback). A single outline traced round a
-- waisted body is exactly the concave case; three overlapping convex ovals
-- are not, and they read better anyway because each segment carries its own
-- shade. Legs are lines, which are never a fill at all.

-- Unit circle, tabulated once: every body segment is this scaled and placed,
-- so the whole colony costs no trigonometry per ant.
local OVAL_N = 9
local OVAL_C, OVAL_S = {}, {}
for i = 1, OVAL_N do
  local a = (i - 1) / OVAL_N * 6.28318
  OVAL_C[i] = math.cos(a)
  OVAL_S[i] = math.sin(a)
end

-- One segment: an oval at (fx,fy) in body space, rx by ry, rotated into place.
local function segment(x, y, c, s, size, fx, fy, rx, ry)
  local n = 0
  for i = 1, OVAL_N do
    local ox, oy = fx + OVAL_C[i] * rx, fy + OVAL_S[i] * ry
    n = n + 1; scratch[n] = x + (c * ox - s * oy) * size
    n = n + 1; scratch[n] = y + (s * ox + c * oy) * size
  end
  for i = #scratch, n + 1, -1 do scratch[i] = nil end
  love.graphics.polygon("fill", scratch)
end

-- Legs and antennae as bent lines. `gait` walks them: a real ant moves in an
-- alternating tripod, so the two sides run half a cycle apart and the column
-- reads as walking rather than sliding.
local function limbs(x, y, c, s, size, col, gait, antennae, legFade, antFade)
  local g = love.graphics
  -- The fades bring each tier up as it is entered rather than snapping it
  -- on: at a tier boundary the new parts are transparent, a little further
  -- in they are solid. Nothing about the geometry changes, only its alpha.
  legFade = legFade or 1
  antFade = antFade or 1
  g.setColor(col[1] * 0.5, col[2] * 0.5, col[3] * 0.5, legFade)
  g.setLineWidth(math.max(1, size * 0.20))

  local function limb(bx, by, ang, len, spread)
    local kx, ky = bx + math.cos(ang) * len * 0.55, by + math.sin(ang) * len * 0.55
    local ex, ey = kx + math.cos(ang + spread) * len * 0.6,
                   ky + math.sin(ang + spread) * len * 0.6
    local x1 = x + (c * bx - s * by) * size
    local y1 = y + (s * bx + c * by) * size
    local x2 = x + (c * kx - s * ky) * size
    local y2 = y + (s * kx + c * ky) * size
    local x3 = x + (c * ex - s * ey) * size
    local y3 = y + (s * ex + c * ey) * size
    g.line(x1, y1, x2, y2)
    g.line(x2, y2, x3, y3)
  end

  -- Six legs off the thorax, three a side, in an alternating tripod.
  for i = -1, 1 do
    local bx = 0.5 + i * 0.55
    local swing = math.sin(gait + i * 1.1) * 0.28
    limb(bx,  0.36,  0.95 + i * 0.40 + swing, 1.55, 0.55)
    limb(bx, -0.36, -0.95 - i * 0.40 -
         math.sin(gait + i * 1.1 + 3.14159) * 0.28, 1.55, -0.55)
  end

  if antennae and antFade > 0 then
    -- Elbowed and sweeping: the most recognisable thing on an ant after the
    -- waist, and worth two lines at close zoom. Faded on its OWN tier's
    -- curve, so it arrives after the legs are already solid.
    g.setColor(col[1] * 0.5, col[2] * 0.5, col[3] * 0.5, antFade)
    g.setLineWidth(math.max(1, size * 0.15))
    local sweep = math.sin(gait * 0.7) * 0.22
    limb(1.95,  0.26,  0.5 + sweep, 1.35, -0.7)
    limb(1.95, -0.26, -0.5 + sweep, 1.35, 0.7)
  end
  g.setLineWidth(1)
end

local function body(x, y, dir, size, col, gait, detail, fade)
  local c, s = math.cos(dir), math.sin(dir)
  local g = love.graphics
  fade = fade or 1

  -- Limbs first so the segments overlap the joints. Each tier fades in only
  -- while it is the NEWEST one: legs (tier 1) are solid by the time eyes and
  -- antennae (tier 2) start arriving, so nothing already established dims
  -- again as you keep zooming.
  local legFade  = (detail == 1) and fade or 1
  local tier2Fade = (detail == 2) and fade or 0
  if detail > 0 then
    limbs(x, y, c, s, size, col, gait, detail == 2, legFade, tier2Fade)
  end

  -- Gaster, thorax, head. Each is shaded a little apart from its neighbour
  -- so the three segments separate at a glance.
  g.setColor(col[1] * 0.80, col[2] * 0.80, col[3] * 0.80, 1)
  segment(x, y, c, s, size, -1.70, 0, 1.15, 0.90)
  g.setColor(col[1], col[2], col[3], 1)
  segment(x, y, c, s, size, 0.42, 0, 0.80, 0.58)
  g.setColor(col[1] * 1.12, col[2] * 1.06, col[3] * 1.00, 1)
  segment(x, y, c, s, size, 1.80, 0, 0.68, 0.58)

  if detail == 2 and tier2Fade > 0 then
    -- Two eyes. Two pixels in the right place is the whole difference
    -- between a bug and a blob. Faded with the rest of their tier so they
    -- do not blink into existence at one particular zoom value.
    g.setColor(0.05, 0.04, 0.04, 0.9 * tier2Fade)
    segment(x, y, c, s, size, 2.00, 0.30, 0.19, 0.19)
    segment(x, y, c, s, size, 2.00, -0.30, 0.19, 0.19)
  end
end

-- THE QUEEN. Twice a worker's size, with a crown and wings -- she is the
-- production unit, so she has to be unmistakable at a glance. Drawn from
-- the same three-segment body, then given the two things that say queen.
local function queenBody(x, y, dir, size, col, gait)
  local g = love.graphics
  local c, sn = math.cos(dir), math.sin(dir)

  -- WINGS FIRST, so the body overlaps their roots. Long translucent
  -- ovals swept back off the thorax, with a slow idle flutter -- a queen
  -- who never moves reads as a decal.
  local flutter = math.sin(gait * 0.6) * 0.10
  for side = -1, 1, 2 do
    g.setColor(0.86, 0.90, 0.95, 0.34)
    local n = 0
    local wingScratch = {}
    for i = 1, 12 do
      local t = (i - 1) / 12 * 6.28318
      -- An oval in body space: long along the body, thin across it,
      -- rooted at the thorax and swept toward the gaster.
      local ox = -0.55 + math.cos(t) * 2.30
      local oy = side * (0.55 + math.sin(t) * 0.62)
      -- Sweep and flutter, applied in body space before the rotation.
      local sw = ox * 0.18 * side
      oy = oy + sw + side * flutter
      n = n + 1; wingScratch[n] = x + (c * ox - sn * oy) * size
      n = n + 1; wingScratch[n] = y + (sn * ox + c * oy) * size
    end
    g.polygon("fill", wingScratch)
  end

  body(x, y, dir, size, col, gait, 2)

  -- THE CROWN: three points sitting on the head, in gold so it is the
  -- brightest thing on her.
  g.setColor(0.98, 0.85, 0.30, 1)
  for i = -1, 1 do
    local bx, by = 2.35, i * 0.42
    local tipx, tipy = 3.15, i * 0.60
    local w = 0.16
    local q = {}
    q[1] = x + (c * bx - sn * (by - w)) * size
    q[2] = y + (sn * bx + c * (by - w)) * size
    q[3] = x + (c * tipx - sn * tipy) * size
    q[4] = y + (sn * tipx + c * tipy) * size
    q[5] = x + (c * bx - sn * (by + w)) * size
    q[6] = y + (sn * bx + c * (by + w)) * size
    g.polygon("fill", q)
  end
end

-- A LARVA: a fat pale grub that visibly grows as it ripens, so a nursery
-- is production you WATCH rather than a counter going up.
local function larva(x, y, r, ripe, seed)
  local g = love.graphics
  local wob = math.sin(seed * 6.28 + ripe * 9) * 0.12
  -- Pale and translucent at first, opaque and yellowed when ready.
  g.setColor(0.94, 0.90 - ripe * 0.10, 0.72 - ripe * 0.14,
             0.45 + ripe * 0.5)
  local n = 0
  local q = {}
  for i = 1, 10 do
    local t = (i - 1) / 10 * 6.28318
    local ox = math.cos(t) * r * (1.25 + wob)
    local oy = math.sin(t) * r * 0.78
    n = n + 1; q[n] = x + ox
    n = n + 1; q[n] = y + oy
  end
  g.polygon("fill", q)
end

M.queenBody = queenBody
M.larva = larva

function M.draw(snap, vp)
  local a = snap.agents
  local world = snap.world
  local s = vp.worldScale()
  local g = love.graphics
  local t = snap.time
  local x0, y0, x1, y1 = vp.worldBounds()

  -- ANTS ARE UNITS, so they must be legible at the zoom the game is
  -- actually played at. A worker must be a clearly visible dot
  -- you can count; at 3.0*scale on a zoomed-out map these were a smear.
  -- A floor keeps one readable even when the whole field is on screen.
  local antSize = math.max(2.2, 4.4 * s)
  -- LOD TIERS STAY (six legs and two antennae per ant is real work at 2000
  -- ants, and there is no point drawing an eye that lands inside one pixel)
  -- -- but they must not make the ZOOM itself feel stepped.
  --
  -- Hard cutoffs meant legs popped into existence at zoom 0.60 and eyes at
  -- 0.92, so a smooth scroll through those numbers showed the colony
  -- visibly CHANGE rather than approach. The geometry was always vector and
  -- continuous; the tiers were the only thing quantised.
  --
  -- `detail` is still an integer for the cheap branch, and `fade` is how far
  -- INTO that tier we are (0..1), used to bring the new parts up by alpha so
  -- they arrive instead of appearing.
  local detail = 0
  local fade = 1
  if antSize >= 2.6 then
    detail = 1
    fade = math.min(1, (antSize - 2.6) / 0.7)
  end
  if antSize >= 4.0 then
    detail = 2
    fade = math.min(1, (antSize - 4.0) / 1.1)
  end

  -- Where each queen sits in her mound. Computed once here because both
  -- the queens and their larvae need it -- a larva is laid AT its queen's
  -- gaster and crawls off from there, so the two have to agree.
  local function queenPos(n, qi, count)
    local sx, sy = vp.worldToScreen(n.x, n.y)
    local ang = (qi - 1) / math.max(1, count) * 6.28318 + 0.6
    local rr = n.radius * s * (count > 1 and 0.34 or 0)
    -- Her facing, and the small idle sway.
    local face = ang + 1.5708 + math.sin(t * 0.5 + qi) * 0.12
    return sx + math.cos(ang) * rr, sy + math.sin(ang) * rr, face
  end

  -- ── larvae: laid at a queen's gaster, crawling off as they ripen ──
  for i = 1, #world.nodes do
    local n = world.nodes[i]
    -- LARVAE ARE BODIES TOO, hidden by the same rule as the workers and
    -- the queens: yours always, an enemy's only where one of your ants is
    -- standing. Gating on `observed` left an enemy's brood on screen from
    -- across the map -- which tells the player how fast that colony is
    -- growing, the single most useful thing scouting exists to find out.
    if n.seen and ((n.owner == "you") or n.held)
       and n.brood and #n.brood > 0 then
      local nq = n.queens and #n.queens or 0
      local sx, sy = vp.worldToScreen(n.x, n.y)
      for k = 1, #n.brood do
        local b = n.brood[k]
        local qx, qy, face = sx, sy, 0
        if nq > 0 then
          qx, qy, face = queenPos(n, math.min(b.queen or 1, nq), nq)
        end
        -- Start behind her (the gaster is at -1.7 in body space) and
        -- crawl outward to its own spot as it ripens.
        local qsize = antSize * 2.0
        local bx = qx - math.cos(face) * 1.9 * qsize
        local by = qy - math.sin(face) * 1.9 * qsize
        local rr = n.radius * b.r * s
        local tx = sx + math.cos(b.a) * rr
        local ty = sy + math.sin(b.a) * rr
        -- Ease out: it pops from her, then drifts.
        local u = math.min(1, b.ripe * 1.6)
        u = u * u * (3 - 2 * u)
        larva(bx + (tx - bx) * u, by + (ty - by) * u,
              math.max(1.2, n.radius * s * 0.10 * (0.55 + b.ripe * 0.75)),
              b.ripe, b.seed)
      end
    end
  end

  -- ── queens ──
  for i = 1, #world.nodes do
    local n = world.nodes[i]
    -- A QUEEN IS A BODY TOO, so she hides by the same rule as the workers
    -- below: yours are always visible, an enemy's only where one of your
    -- ants is actually standing. Gating her on `observed` put every enemy
    -- queen on screen from across the board, which told the player exactly
    -- how strong each colony was without them ever going to look.
    local reveal = (n.owner == "you") or n.held
    if n.seen and reveal and n.queens and #n.queens > 0 then
      local sx, sy = vp.worldToScreen(n.x, n.y)
      local col = (n.owner == "you") and { 0.95, 0.78, 0.32 }
                                     or { 0.96, 0.40, 0.30 }
      for qi = 1, #n.queens do
        -- She is MOSTLY STATIC -- a queen who marches reads as a big
        -- worker -- with a small sway and a slow leg cycle so she is
        -- alive rather than a decal.
        local qx, qy, face = queenPos(n, qi, #n.queens)
        queenBody(qx, qy, face, antSize * 2.0, col, t * 0.9 + qi)
      end
    end
  end

  -- ── the ants themselves ──
  for i = 1, a.n do
    local ant = a.pool[i]
    -- FOG OF WAR IS THIS LINE. Your own ants are always visible -- you
    -- know where you sent them -- but an ENEMY is drawn only where one of
    -- your ants is physically standing, which is the same `held` flag that
    -- warms a mound from stone to earth. So a grey mound tells you nothing
    -- about who is on it; walking in is what reveals the garrison, and
    -- that is the whole of the fog.
    --
    -- `observed` is NOT the flag to use here, though it reads like it. It
    -- is true for every neighbour of a colony and for every mound within a
    -- garrison's reach -- deliberately, so the map can show you the SHAPE
    -- of the field -- which would have laid every enemy garrison bare from
    -- across the board.
    -- AN ENEMY YOU ARE FIGHTING IS ALWAYS VISIBLE. This used to be `held`
    -- alone, and `held` means "one of YOUR ants is standing here" -- so a
    -- garrison defending its own mound against your assault was invisible
    -- until the instant you took the ground, and an enemy COLUMN crossing
    -- open country was invisible always, because a walking ant has no `at`
    -- for the flag to be read from. Measured on the war map: 86 enemy ants
    -- alive, 43 of them moving, and TEN red pixels on the whole screen.
    -- Your ants died to nothing, next to a red rim.
    --
    -- Fog is meant to hide what you have not scouted, not to hide the
    -- battle you are in the middle of. Three ways an enemy earns a body:
    local vis = ant.side == "you"
    if not vis then
      local at = ant.at and WW.site(world, ant.at)
      if at and at.contested then
        -- 0. YOU ARE ATTACKING THIS MOUND RIGHT NOW. The decisive case, and
        --    the one every other rule missed: an attacker DIES ON ARRIVAL
        --    against a defended mound, so it never stands there, `held`
        --    never becomes true and `found` never latches. Measured on the
        --    war map -- 16 ants sent at a 5-ant garrison, and across the
        --    whole assault the screen showed 115 -> 103 -> 66 -> 36 -> 23
        --    -> 0 of YOUR pale bodies and exactly ZERO red ones. The army
        --    dissolved into a hill with nothing visibly on it.
        --
        --    `contested` is set by the sim for any mound with your ants
        --    inbound. A fight you are paying for is never a secret.
        vis = true
      elseif at and at.held then
        -- 1. You are standing on the same ground -- the original rule, and
        --    still the right one for a garrison at rest. (A permanent
        --    "once seen" latch was tried alongside it and reverted: it
        --    revealed every mound you had ever touched for the rest of the
        --    game, which `test-grey` correctly failed.)
        vis = true
      elseif at and at.owner == "you" then
        -- 2. It is on YOUR ground: an attacker in your nest is not a
        --    secret, whether or not a defender is still alive to see it.
        vis = true
      elseif not ant.at then
        -- 3. It is in the open, walking to or from somewhere you can SEE
        --    -- ground you own, or ground one of your ants is standing on
        --    this instant.
        --
        --    STRICTER THAN IT WAS, deliberately. This used to accept
        --    `observed` at either end, and `observed` used to be set on
        --    every neighbour of every queened colony, every tick -- so a
        --    settled board watched most of the map for free and enemy
        --    columns were visible almost everywhere. Plan 04 deleted that
        --    adjacency, and this rule follows it down: an army crossing
        --    country you are not standing in is not something you can
        --    see, and the fog is not there to make war convenient.
        --
        --    The plan-03 measurements that motivated this rule ("86 enemy
        --    ants, ten red pixels") described a board whose fog leaked
        --    everywhere ELSE, which is what made the blind spot feel like
        --    a bug rather than the design. With a consistent three-state
        --    fog, an unseen army in the dark is the point. The assault
        --    reveal (case 0) is untouched: a fight you are paying for is
        --    still never a secret.
        local function seeable(site)
          return site and (site.owner == "you" or site.held) or false
        end
        vis = seeable(ant.to and WW.site(world, ant.to))
           or seeable(ant.from and WW.site(world, ant.from))
      end
    end
    if vis and ant.x >= x0 and ant.x <= x1 and ant.y >= y0 and ant.y <= y1 then
      local sx, sy = vp.worldToScreen(ant.x, ant.y)
      local col = (ant.side == "you") and YOUR_COL
                or SIDE_COL[ant.side] or ENEMY_COL
      -- AN ANT UNDER ORDERS is pale and bright: a send is the player's
      -- move and its column must separate from the milling garrison.
      if not ant.at then col = MISSION_COL end
      local gait = (ant.x + ant.y) * 0.05
      body(sx, sy, ant.dir, antSize, col, gait, detail, fade)

      -- WHAT IT IS CARRYING, held up over its head.
      --
      -- This is the picture the whole food system is for: a line of ants
      -- walking home with something.
      --
      -- DRAWN AT EVERY TIER THE ANT ITSELF IS, and that is the whole point.
      -- Gated at `detail >= 2` this needed antSize >= 4.0, i.e. zoom >= 0.91
      -- -- and the zoom rungs are {0.20, 0.42, 0.85, 1.50} with 0.42 the
      -- default, so THREE OF FOUR RUNGS never drew a crumb and the feature
      -- was invisible at the zoom the game is actually played at. One step
      -- in from the default (0.85) did not reach it either. A carried item
      -- is a gameplay signal, not surface detail: if the ant is worth
      -- drawing, what it is carrying is worth drawing.
      --
      -- The same argument as the antSize floor above -- a worker must be a
      -- countable dot -- applied to the thing that makes the worker mean
      -- something.
      -- IT CARRIES THE ACTUAL THING, not a token for it.
      --
      -- The first version drew one coloured disc for everything, colour-
      -- coded by value. That reads as a bead, not as cargo -- an aphid is a
      -- plump body with a wet highlight, a grain is a stalk with a fat ear,
      -- a leg is a straight dark segment, and those silhouettes are what
      -- make a laden column legible at a glance. Each shape below is the
      -- SAME construction render/locations.lua uses to draw the item lying
      -- in the ground, scaled to the mandibles, so what an ant walks off
      -- with is visibly what was taken from the patch.
      if ant.carry then
        local disc = require("render.flora").disc
        local ca, sa = math.cos(ant.dir), math.sin(ant.dir)
        -- BIG ENOUGH TO BE THE THING IT IS.
        --
        -- Sized at 0.52 * antSize with a floor of 2.0 this was mathematically
        -- "drawn" and visually a DOT: at the default zoom antSize is pinned
        -- to its own 2.2 floor, so the aphid's body came out at 1.24px
        -- radius, its second oval at 0.92 and its highlight at 0.40 -- three
        -- sub-pixel discs stacked into one smudge. Building the right
        -- silhouette and then scaling it below the size of a pixel is not
        -- drawing it.
        --
        -- The floor is now 5.0 (a ~10px aphid), which is the size an item
        -- has to be before its shape survives rasterisation.
        --
        -- AND IT IS BIGGER THAN THE ANT, because that is what an ant IS. A
        -- worker hauls many times its own body: the image everybody has of
        -- ants is a line of them under loads that look impossible, and a
        -- crumb tucked under the chin throws that away. Two earlier passes
        -- read as a dot for exactly this reason -- 0.52x the ant with a 2px
        -- floor put an aphid's body at 1.24px radius, and even at 1.05x the
        -- grain's stalk was a 5x1 hairline with a 3.4px ear.
        --
        -- So the load is scaled ~2.4x the ant and floored at a size that
        -- survives 1080p: an aphid rides as a boulder, a grain as a whole
        -- stalk. Clamped at the top so a close zoom does not hand one ant a
        -- tree.
        local isz = math.max(11.0, math.min(antSize * 2.4, 26.0))

        -- HELD IN THE JAWS, forward of the head on the ant's own axis so it
        -- swings with the body as the ant turns. The offset has to account
        -- for the ITEM's size as well as the ant's, or a load big enough to
        -- see is a load big enough to bury the head it is carried in front
        -- of.
        local lift = antSize * 1.15 + isz * 0.55
        local hx = sx + ca * lift
        local hy = sy + sa * lift

        if ant.carry >= 4 then
          -- APHID: two overlapping convex ovals plus the wet highlight,
          -- exactly as the patch draws it. Never one waisted outline -- a
          -- concave fill kills the GPU 2D path for the whole run.
          love.graphics.setColor(0.58, 0.76, 0.42, 1)
          disc(hx, hy, isz * 0.62)
          love.graphics.setColor(0.66, 0.84, 0.48, 1)
          disc(hx - ca * isz * 0.20, hy - sa * isz * 0.20, isz * 0.46)
          love.graphics.setColor(0.86, 0.95, 0.70, 0.55)
          disc(hx - ca * isz * 0.28, hy - sa * isz * 0.28, isz * 0.20)
        elseif ant.carry >= 3 then
          -- SPIDER LEG: a straight segment carried lengthways, as a quad
          -- (setLineWidth is capped at 1 on most drivers -- the shape has
          -- to be real geometry). Lightened from the husk colour it has on
          -- the ground: measured against soil at luminance 39, the original
          -- rgb(66,51,56) sat at 55 for a contrast ratio of 1.37 and simply
          -- vanished at this size. This reads at 3.4x while staying the
          -- darkest of the three.
          local len = isz * 1.10
          local w = math.max(1, isz * 0.20)
          local px, py = -sa * w, ca * w
          love.graphics.setColor(0.72, 0.52, 0.44, 1)
          love.graphics.polygon("fill",
            hx - ca * len * 0.5 + px, hy - sa * len * 0.5 + py,
            hx - ca * len * 0.5 - px, hy - sa * len * 0.5 - py,
            hx + ca * len * 0.5 - px, hy + sa * len * 0.5 - py,
            hx + ca * len * 0.5 + px, hy + sa * len * 0.5 + py)
        else
          -- GRAIN: a whole stalk, carried lengthways across the jaws like a
          -- log -- which is the classic picture of an ant hauling a seed.
          --
          -- The stalk was a 5x1 HAIRLINE before (0.16 * a 5px item, floored
          -- to one pixel wide) with a 3.4px ear on the end, which is the
          -- "tiny yellow dot" exactly. It is now a real quad with the ear as
          -- a proper swollen head: the ear is the part that says GRAIN, so
          -- it carries most of the mass.
          local len = isz * 1.25
          local w = math.max(2, isz * 0.16)
          local px, py = -sa * w, ca * w
          love.graphics.setColor(0.52, 0.46, 0.22, 1)
          love.graphics.polygon("fill",
            hx - ca * len * 0.5 + px, hy - sa * len * 0.5 + py,
            hx - ca * len * 0.5 - px, hy - sa * len * 0.5 - py,
            hx + ca * len * 0.5 - px, hy + sa * len * 0.5 - py,
            hx + ca * len * 0.5 + px, hy + sa * len * 0.5 + py)
          -- The ear: two overlapping ovals so it reads as a swollen head of
          -- seed rather than a ball on a stick, brightest at the tip.
          love.graphics.setColor(0.74, 0.66, 0.30, 1)
          disc(hx + ca * len * 0.30, hy + sa * len * 0.30, isz * 0.30)
          love.graphics.setColor(0.86, 0.78, 0.38, 1)
          disc(hx + ca * len * 0.52, hy + sa * len * 0.52, isz * 0.34)
        end
      end
    end
  end
end

-- Exposed for the gates.
function M.hdrActive() return true end

return M
