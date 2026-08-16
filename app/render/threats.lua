-- threats.lua - the things that push back.
--
-- A hazard must be legible as a CREATURE, not as an abstract state. The
-- trail layer already pulses a red halo along an occupied road, which tells
-- you WHERE, but a player watching a terrarium wants to see the spider --
-- and a spider you can see is a spider you can route around on purpose
-- rather than by reading a colour.
--
-- Rain is drawn here too, because it is the other thing that happens TO the
-- colony rather than because of it.

local flora = require("render.flora")

local M = {}

local scratch = {}

function M.init(vp) end

-- A spider: a body and eight legs, all generated. The legs bend from a
-- phase so it twitches in place; a perfectly still predator reads as a
-- decal.
-- A tapered limb segment as a convex quad: thick at (ax,ay), thinner at
-- (bx,by). Four points, so the engine's triangle-fan fill always accepts it
-- (see NOTES.md -- a concave polygon kills the GPU 2D path for the run).
local segQuad = {}
local function seg(ax, ay, bx, by, wa, wb)
  local dx, dy = bx - ax, by - ay
  local L = math.sqrt(dx * dx + dy * dy)
  if L < 1e-4 then return end
  local nx, ny = -dy / L, dx / L
  segQuad[1], segQuad[2] = ax + nx * wa, ay + ny * wa
  segQuad[3], segQuad[4] = bx + nx * wb, by + ny * wb
  segQuad[5], segQuad[6] = bx - nx * wb, by - ny * wb
  segQuad[7], segQuad[8] = ax - nx * wa, ay - ny * wa
  love.graphics.polygon("fill", segQuad)
end

local function spider(sx, sy, r, t, phase)
  local g = love.graphics

  -- Legs first, so the body overlaps their joints.
  --
  -- PROPORTIONS ARE THE WHOLE READ. The first pass had a near-round
  -- abdomen at 0.95r and legs at 0.13r, and it came out a fat blob with
  -- hairline whiskers -- a tick, not a spider. What says "spider" is
  -- thick, obviously jointed legs carrying a body that is SMALL relative
  -- to their span. Femur and tibia are drawn as separate segments with the
  -- femur heavier, so the limb tapers toward the foot the way a real one
  -- does, and the whole animal is legs first, body second.
  g.setColor(0.06, 0.05, 0.07, 0.98)
  for i = 1, 8 do
    local side = (i <= 4) and 1 or -1
    local k = ((i - 1) % 4) - 1.5
    -- LEGS COME OFF THE SIDES, and the body runs between them. The fans
    -- were centred on +X and -X -- exactly where the head and abdomen sit
    -- -- so the body lay ALONG the leg axis and the whole animal read as
    -- rotated 90 degrees from itself. Adding a quarter turn puts the four
    -- left legs at 90 degrees and the four right at 270, with the body
    -- pointing down the clear axis between them, which is how a spider is
    -- actually built.
    --
    -- Wider fan (0.42 -> 0.52) so eight legs read as eight legs. Packed
    -- tightly they overlap into a single silhouette however thin they are.
    local base = k * 0.52 + (side > 0 and 1.5708 or -1.5708)
    local twitch = math.sin(t * 2.4 + phase + i * 0.7) * 0.16
    local a1 = base + twitch
    local kneeR = r * 1.62
    -- The 0.85 squash used to be on Y, which flattened the fan when the
    -- legs pointed along X. Now that they point along Y it belongs on X,
    -- or it would shorten every leg in the direction it actually extends.
    local kx, ky = sx + math.cos(a1) * kneeR * 0.85, sy + math.sin(a1) * kneeR
    -- The knee is above the foot, which is what makes a spider look like a
    -- spider rather than a starfish.
    local a2 = a1 + side * 0.55 + twitch * 0.5
    local fx, fy = kx + math.cos(a2) * r * 1.35, ky + math.sin(a2) * r * 1.35
    -- SEGMENTS ARE QUADS, NOT LINES. setLineWidth is not reliable on the
    -- GPU 2D path -- GL caps glLineWidth at 1 on most drivers -- so asking
    -- for a 8px leg still drew a 2px thread, and the spider kept its
    -- hairline legs no matter what the ratio said. Real geometry is the
    -- only way to get a thick limb. Each segment is a four-point quad
    -- (always convex, so the fan path accepts it) and the joints are
    -- capped with discs so the elbow does not show a notch.
    -- Width is a BALANCE, and it was overshot once in each direction: at
    -- 0.13r (a line) the legs were threads, at 0.34r (a quad) all eight
    -- merged into one black mass because the gaps between them closed. The
    -- hip cap is the worst offender there -- eight of them stack on the
    -- same point -- so it is gone entirely and the femur starts inside the
    -- body instead.
    seg(sx, sy, kx, ky, r * 0.17, r * 0.13)     -- femur, heavy
    seg(kx, ky, fx, fy, r * 0.13, r * 0.07)     -- tibia, tapering
    flora.disc(kx, ky, r * 0.12)                -- knee, just enough to
                                                -- round the elbow
    flora.disc(fx, fy, r * 0.07)                -- foot
  end

  -- Abdomen, thorax and head. THESE MUST BE LIGHTER THAN THE LEGS. Once
  -- the legs became solid geometry they read as one dark mass, and a body
  -- painted at 0.10 against legs at 0.06 simply disappeared into it -- the
  -- spider looked like a starburst with no animal in the middle. The body
  -- now steps up in value from abdomen to head, which both separates it
  -- from the limbs and gives the creature a facing.
  --
  -- The abdomen is an oval built from two overlapping discs, never one
  -- outline: convex-only is what the GPU 2D path will accept.
  g.setColor(0.20, 0.17, 0.22, 1)
  flora.disc(sx - r * 0.50, sy, r * 0.70)
  flora.disc(sx - r * 0.14, sy, r * 0.60)
  -- A narrow waist, so abdomen and head are two masses rather than a blob.
  g.setColor(0.26, 0.22, 0.28, 1)
  flora.disc(sx + r * 0.22, sy, r * 0.30)
  -- Head/cephalothorax, the lightest part.
  g.setColor(0.32, 0.27, 0.34, 1)
  flora.disc(sx + r * 0.52, sy, r * 0.42)
  -- Two eye glints: the only bright pixels, so the eye finds it instantly.
  g.setColor(0.92, 0.82, 0.40, 0.95)
  flora.disc(sx + r * 0.66, sy - r * 0.17, r * 0.11)
  flora.disc(sx + r * 0.66, sy + r * 0.17, r * 0.11)
end

-- Rain: short streaks, drawn over everything, with a wind slant. Density is
-- constant rather than sim-driven -- rain is weather, not a resource, and
-- tying it to a count would make it flicker as the sim changed.
local RAIN_N = 260
local function rain(vp, t, intensity)
  local g = love.graphics
  g.setColor(0.62, 0.74, 0.92, 0.30 * intensity)
  g.setLineWidth(math.max(1, vp.u(2)))
  for i = 1, RAIN_N do
    -- Deterministic pseudo-scatter from the index: no RNG, so the rain does
    -- not reshuffle every frame (which reads as static, not rain).
    local sx = ((i * 7919) % 1000) / 1000 * vp.w
    local sy0 = ((i * 104729) % 1000) / 1000
    local speed = 0.55 + ((i * 31) % 100) / 100 * 0.5
    local y = ((sy0 + t * speed) % 1) * vp.h
    local len = vp.u(26) * speed
    g.line(sx, y, sx - len * 0.35, y + len)
  end
  g.setLineWidth(1)
end

function M.draw(snap, vp)
  local g = love.graphics
  local world = snap.world
  local t = snap.time
  local s = vp.worldScale()

  -- Spiders sit at the MIDPOINT of the road they occupy, which is exactly
  -- where the ants have to walk past them.
  for i = 1, #snap.threats.spiders do
    local sp = snap.threats.spiders[i]
    local e = world.edge[sp.edge]
    if e then
      local a, b = world.node[e.a], world.node[e.b]
      if a.discovered or b.discovered then
        local trails = require("render.trails")
        local wx, wy = trails.edgePoint(world, e, 0.5)
        local sx, sy = vp.worldToScreen(wx, wy)
        -- A phase per spider so two never twitch in lockstep.
        local phase = 0
        for k = 1, #sp.edge do phase = phase + sp.edge:byte(k) end
        spider(sx, sy, math.max(4, 26 * s), t, phase)
      end
    end
  end

  -- Beetles: the roamer. Drawn as a rounded, hard-shelled body with short
  -- legs -- deliberately NOT a spider silhouette, because the two are
  -- different problems and a player has to tell them apart at a glance.
  for i = 1, #(snap.threats.beetles or {}) do
    local bt = snap.threats.beetles[i]
    local e = world.edge[bt.edge]
    if e then
      local a, b = world.node[e.a], world.node[e.b]
      if a.discovered or b.discovered then
        local trails = require("render.trails")
        -- It WALKS its road rather than squatting mid-span, so it reads as
        -- something passing through.
        local u = 0.5 + 0.42 * math.sin(t * 0.5 + i)
        local wx, wy = trails.edgePoint(world, e, u)
        local sx, sy = vp.worldToScreen(wx, wy)
        local r = math.max(3, 19 * s)
        local ang = math.sin(t * 0.5 + i) >= 0 and 0 or 3.14159

        -- Six short legs, thick and stubby.
        g.setColor(0.10, 0.09, 0.06, 0.98)
        for k = 1, 6 do
          local side = (k <= 3) and 1 or -1
          local kk = ((k - 1) % 3) - 1
          local base = kk * 0.5 + (side > 0 and 1.5708 or -1.5708)
          local tw = math.sin(t * 3 + k) * 0.2
          local fx = sx + math.cos(base + tw + ang) * r * 0.95
          local fy = sy + math.sin(base + tw + ang) * r * 0.95
          seg(sx, sy, fx, fy, r * 0.16, r * 0.10)
        end
        -- Carapace: two overlapping ovals with a bright seam, which is the
        -- read that says "beetle" rather than "blob".
        g.setColor(0.30, 0.22, 0.10, 1)
        flora.disc(sx - math.cos(ang) * r * 0.18, sy - math.sin(ang) * r * 0.18, r * 0.72)
        g.setColor(0.38, 0.29, 0.13, 1)
        flora.disc(sx + math.cos(ang) * r * 0.30, sy + math.sin(ang) * r * 0.30, r * 0.46)
        g.setColor(0.16, 0.12, 0.06, 0.9)
        seg(sx - math.cos(ang) * r * 0.8, sy - math.sin(ang) * r * 0.8,
            sx + math.cos(ang) * r * 0.1, sy + math.sin(ang) * r * 0.1,
            r * 0.05, r * 0.05)
      end
    end
  end

  if snap.threats.rain > 0 then
    -- Fade in and out rather than snapping: weather that appears instantly
    -- reads as a bug.
    local dur = require("sim.threats").cfg.rainDur
    local left = snap.threats.rain
    local intensity = math.min(1, math.min(left, dur - left) / 2.5)
    rain(vp, t, math.max(0.15, intensity))
  end
end

return M
