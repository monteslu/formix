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
local SIDE_COL = {
  red  = { 0.92, 0.24, 0.18 },
  gold = { 0.95, 0.70, 0.15 },
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
local function limbs(x, y, c, s, size, col, gait, antennae)
  local g = love.graphics
  g.setColor(col[1] * 0.5, col[2] * 0.5, col[3] * 0.5, 1)
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

  if antennae then
    -- Elbowed and sweeping: the most recognisable thing on an ant after the
    -- waist, and worth two lines at close zoom.
    g.setLineWidth(math.max(1, size * 0.15))
    local sweep = math.sin(gait * 0.7) * 0.22
    limb(1.95,  0.26,  0.5 + sweep, 1.35, -0.7)
    limb(1.95, -0.26, -0.5 + sweep, 1.35, 0.7)
  end
  g.setLineWidth(1)
end

local function body(x, y, dir, size, col, gait, detail)
  local c, s = math.cos(dir), math.sin(dir)
  local g = love.graphics

  -- Limbs first so the segments overlap the joints.
  if detail then limbs(x, y, c, s, size, col, gait, detail == 2) end

  -- Gaster, thorax, head. Each is shaded a little apart from its neighbour
  -- so the three segments separate at a glance.
  g.setColor(col[1] * 0.80, col[2] * 0.80, col[3] * 0.80, 1)
  segment(x, y, c, s, size, -1.70, 0, 1.15, 0.90)
  g.setColor(col[1], col[2], col[3], 1)
  segment(x, y, c, s, size, 0.42, 0, 0.80, 0.58)
  g.setColor(col[1] * 1.12, col[2] * 1.06, col[3] * 1.00, 1)
  segment(x, y, c, s, size, 1.80, 0, 0.68, 0.58)

  if detail == 2 then
    -- Two eyes. Two pixels in the right place is the whole difference
    -- between a bug and a blob.
    g.setColor(0.05, 0.04, 0.04, 0.9)
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
  local detail = 0
  if antSize >= 2.6 then detail = 1 end
  if antSize >= 4.0 then detail = 2 end

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
    local vis = ant.side == "you"
    if not vis then
      local at = ant.at and WW.site(world, ant.at)
      vis = at and at.held or false
    end
    if vis and ant.x >= x0 and ant.x <= x1 and ant.y >= y0 and ant.y <= y1 then
      local sx, sy = vp.worldToScreen(ant.x, ant.y)
      local col = (ant.side == "you") and YOUR_COL
                or SIDE_COL[ant.side] or ENEMY_COL
      -- AN ANT UNDER ORDERS is pale and bright: a send is the player's
      -- move and its column must separate from the milling garrison.
      if not ant.at then col = MISSION_COL end
      local gait = (ant.x + ant.y) * 0.05
      body(sx, sy, ant.dir, antSize, col, gait, detail)

      -- WHAT IT IS CARRYING, held up over its head.
      --
      -- This is the picture the whole food system is for: a line of ants
      -- walking home with something. Only at the closer detail tiers --
      -- from across the room a column reads as a column, and a crumb per
      -- ant at that zoom is a pixel of noise.
      if ant.carry and detail >= 2 then
        local lift = antSize * 1.05
        local hx = sx + math.cos(ant.dir) * lift
        local hy = sy + math.sin(ant.dir) * lift
        local cr = antSize * 0.42
        -- Colour by what it is worth, which is a decent proxy for what it
        -- is: a pale grain, a fat green aphid, a dark spider leg.
        if ant.carry >= 4 then
          love.graphics.setColor(0.62, 0.80, 0.44, 1)      -- aphid
        elseif ant.carry >= 3 then
          love.graphics.setColor(0.26, 0.20, 0.22, 1)      -- leg
        else
          love.graphics.setColor(0.84, 0.76, 0.38, 1)      -- grain
        end
        require("render.flora").disc(hx, hy, cr)
      end
    end
  end
end

-- Exposed for the gates.
function M.hdrActive() return true end

return M
