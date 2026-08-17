-- trails.lua - the roads, which are also the UI.
--
-- The trail map IS the picture of what the colony is thinking, so this is
-- the most important layer in the game. A trail is drawn as a tapered
-- ribbon: width and emissive intensity both read from strength/traffic, so
-- a busy highway is unmistakable at a glance and a fading one visibly
-- forgets.
--
-- Two passes: a dark bed (the worn earth) and an additive core (the scent
-- itself). The additive pass is what makes the map glow at night.

local menu = require("ui.menu")

local WW = require("sim.world")

local M = {}

local SEGMENTS = 14        -- per edge; enough to curve without wasting fill

-- A ribbon is built as a triangle strip in a scratch table and drawn with
-- polygon(). Rebuilt per frame because strength changes every frame; at ~120
-- edges this is nothing, and it avoids a mesh-update path entirely.
local scratch = {}

-- The road bows slightly. A perfectly straight line between two nodes reads
-- as a diagram; a bow reads as a path worn by feet. Deterministic per edge.
local function bow(e)
  local h = 0
  for i = 1, #e.id do h = (h * 31 + e.id:byte(i)) % 997 end
  return ((h / 997) - 0.5) * 0.14
end

-- How far over 1.0 the emissive scent pass is drawn. See flora.M.emissive:
-- the HDR path blooms it, an LDR host would merely clip it.
M.emissive = 1.0

function M.init(vp)
  M.emissive = require("render.fx").available and 1.5 or 1.0
end

-- Sample a point along the bowed curve at parameter u.
local function curvePoint(ax, ay, bx, by, k, u)
  local dx, dy = bx - ax, by - ay
  local nx, ny = -dy, dx
  -- A parabola peaking at the middle: 4u(1-u) is 0 at both ends, 1 at u=0.5
  local off = 4 * u * (1 - u) * k
  return ax + dx * u + nx * off, ay + dy * u + ny * off
end
M.curvePoint = curvePoint

-- Exposed so agents can be drawn ON the same curve rather than on a straight
-- line between nodes -- if the ants walked straight while the road bowed,
-- the whole layer would read as broken.
function M.edgePoint(world, e, t)
  local a, b = world.node[e.a], world.node[e.b]
  return curvePoint(a.x, a.y, b.x, b.y, bow(e), t)
end

-- A ribbon is drawn as a run of QUADS, one per segment -- never as a single
-- long outline polygon.
--
-- WHY (this cost a whole debugging round): the engine sends a filled polygon
-- to GL as a triangle fan, which only works for a CONVEX shape. A tapered,
-- bowed ribbon traced up one side and back down the other is emphatically
-- not convex, so wcl_r2d_poly rejects it, and the engine then DISABLES THE
-- GPU 2D PATH FOR THE REST OF THE RUN -- deliberately, as a loud failure
-- rather than a silent slow fallback. The visible symptom was the next
-- setShader() call erroring with "this run is on the software rasterizer".
-- Four-point quads are always convex, so every segment fans cleanly and the
-- GPU path stays up.
local quad = {}
local function ribbon(vp, world, e, widthScale, colour, alphaMul)
  local a, b = world.node[e.a], world.node[e.b]
  if not (a.discovered or b.discovered) then return end
  local k = bow(e)

  love.graphics.setColor(colour[1], colour[2], colour[3],
                         (colour[4] or 1) * alphaMul)

  -- Walk the curve once, keeping the previous rim points so each step emits
  -- one quad. Screen-space throughout: the width is a screen measure so a
  -- road stays legible at any zoom.
  local px, py = curvePoint(a.x, a.y, b.x, b.y, k, 0)
  local sx0, sy0 = vp.worldToScreen(px, py)
  local prevLx, prevLy, prevRx, prevRy

  for i = 0, SEGMENTS do
    local u = i / SEGMENTS
    local cx, cy = curvePoint(a.x, a.y, b.x, b.y, k, u)
    local scx, scy = vp.worldToScreen(cx, cy)
    -- Tangent from the neighbouring sample, in SCREEN space so the normal
    -- is a true screen normal (mixing spaces makes the ribbon pinch).
    local u2 = math.min(1, u + 1 / SEGMENTS)
    local nx2, ny2 = curvePoint(a.x, a.y, b.x, b.y, k, u2)
    local snx, sny = vp.worldToScreen(nx2, ny2)
    local dx, dy = snx - scx, sny - scy
    if u >= 1 then dx, dy = scx - sx0, scy - sy0 end
    local L = math.sqrt(dx * dx + dy * dy)
    if L < 1e-4 then dx, dy, L = 1, 0, 1 end
    -- Taper: thin where the road meets a node, fat in the middle.
    local taper = 0.35 + 0.65 * math.sin(u * 3.14159)
    local w = widthScale * taper
    local ox, oy = -dy / L * w, dx / L * w
    local lx, ly = scx + ox, scy + oy
    local rx, ry = scx - ox, scy - oy

    if prevLx then
      quad[1], quad[2] = prevLx, prevLy
      quad[3], quad[4] = lx, ly
      quad[5], quad[6] = rx, ry
      quad[7], quad[8] = prevRx, prevRy
      love.graphics.polygon("fill", quad)
    end
    prevLx, prevLy, prevRx, prevRy = lx, ly, rx, ry
    sx0, sy0 = scx, scy
  end
end

function M.draw(snap, vp, intents)
  local world = snap.world
  local g = love.graphics

  -- Pass 1: the worn bed -- cleared earth, LIGHTER than the soil around it,
  -- because that is what a real ant road looks like from above and because
  -- a dark line reads as a crack in the ground rather than a path. (The
  -- first pass used a near-black brown at 0.85 alpha and the map looked
  -- like it was cracking apart.) Alpha, not colour, carries the strength.
  for i = 1, #world.edges do
    local e = world.edges[i]
    local mass = math.max(e.strength, math.min(0.35, e.traffic * 0.02))
    if mass > 0.01 then
      ribbon(vp, world, e, 5 + mass * 20,
             { 0.34, 0.28, 0.19, 0.20 + mass * 0.45 }, 1)
    end
  end

  -- Pass 2: the scent itself, additive. This is the glow, and it is the
  -- single most informative thing on screen: brightness IS how strongly the
  -- colony is thinking about this road.
  g.setBlendMode("add")
  for i = 1, #world.edges do
    local e = world.edges[i]
    if e.strength > 0.01 then
      -- Colour carries meaning: green is a road the player is feeding,
      -- amber is one the colony is running harder than it is fed, red is
      -- danger. Two soft passes (a wide halo under a narrow core) read as
      -- light rather than as a coloured stripe.
      local traffic = math.min(1, e.traffic * 0.03)
      local r, gg, bl
      if menu.paletteIsHighContrast() then
        -- The natural palette separates "fed" from "busy" on green-vs-amber
        -- and danger on red -- three hues along the one axis a red-green
        -- colour-blind player cannot resolve, which makes the most
        -- informative thing on screen unreadable to them. High contrast
        -- re-keys the same three states to the blue-yellow axis (which
        -- survives every common deficiency) and leans on BRIGHTNESS, so
        -- the reading holds even in greyscale.
        r  = 0.20 + traffic * 0.75 + e.danger * 0.75
        gg = 0.52 + traffic * 0.45 - e.danger * 0.30
        bl = 0.95 - traffic * 0.70 - e.danger * 0.20
      else
        r = 0.18 + traffic * 0.60 + e.danger * 0.8
        gg = 0.62 + traffic * 0.20 - e.danger * 0.45
        bl = 0.30 - e.danger * 0.22
      end

      -- The core is drawn ABOVE 1.0 on purpose. The scene target is
      -- rgba16f, so a colour over one is not clipped -- it is what the
      -- bright pass picks up, and it is the difference between a trail that
      -- is coloured and a trail that GLOWS. Drawn at LDR values the bloom
      -- had nothing to find and the whole map read flat.
      --
      -- BUT the multiplier is modest (1.5, not 2.6) and it is applied to a
      -- NORMALISED colour. At 2.6 the additive core saturated all three
      -- channels on a busy road: the trail bloomed beautifully and came out
      -- white, losing the green/amber/red reading that is the whole point
      -- of colouring it. Glow should raise a hue's brightness, not erase
      -- its identity.
      local hdr = M.emissive
      local peak = math.max(r, gg, bl)
      local nr, ng, nb = r / peak, gg / peak, bl / peak
      local halo = 0.07 + e.strength * 0.15
      local core = 0.18 + e.strength * 0.42
      ribbon(vp, world, e, 9 + e.strength * 30,
             { nr * hdr * 0.55, ng * hdr * 0.55, nb * hdr * 0.55, halo }, 1)
      ribbon(vp, world, e, 2 + e.strength * 7,
             { nr * hdr, ng * hdr, nb * hdr, core }, 1)

      -- A hazard (a spider on the road) pulses hard so it is impossible to
      -- miss without reading any text.
      if e.hazard > 0 then
        local pulse = 0.5 + 0.5 * math.sin(snap.time * 6)
        -- The pulse is the loudest thing on the map and must not rely on
        -- red alone to say "danger": in high contrast it is white-hot, and
        -- in BOTH palettes the flashing itself carries the message.
        local hr, hg, hb = 0.9, 0.15, 0.12
        if menu.paletteIsHighContrast() then hr, hg, hb = 1.0, 0.85, 0.20 end
        -- LOUD ON PURPOSE. A spider on a road is the only thing in this
        -- game that is actually urgent, and at the first values it was a
        -- faint warm tint under a road that still glowed friendly green --
        -- a watcher simply did not notice the attack. Wider than the road
        -- it sits on, and pulsing over 1.0 so the bloom picks it up, which
        -- is what makes it read across a room.
        ribbon(vp, world, e, 10 + e.hazard * 34,
               { hr, hg, hb, 0.16 + pulse * 0.30 }, 1)
        ribbon(vp, world, e, 3 + e.hazard * 10,
               { hr * M.emissive, hg * M.emissive, hb * M.emissive,
                 0.20 + pulse * 0.45 }, 1)
      end
    end
  end
  g.setBlendMode("alpha")

  -- The live drag: a rubber band from the node the finger started on. Drawn
  -- here so it reads as a road being laid rather than a UI line.
  local fromId, px, py = intents.dragLine()
  if fromId and WW.site(world, fromId) then
    local a = WW.site(world, fromId)
    local ax, ay = vp.worldToScreen(a.x, a.y)
    g.setColor(0.5, 0.95, 0.6, 0.55)
    g.setLineWidth(3)
    g.line(ax, ay, px, py)
    g.setLineWidth(1)
  end

  -- The pad's pending selection gets the same treatment toward the cursor.
  if intents.selected and intents.cursor.node and
     intents.selected ~= intents.cursor.node then
    local a = WW.site(world, intents.selected)
    local b = WW.site(world, intents.cursor.node)
    if a and b then
      local ax, ay = vp.worldToScreen(a.x, a.y)
      local bx, by = vp.worldToScreen(b.x, b.y)
      g.setColor(0.5, 0.95, 0.6, 0.45)
      g.setLineWidth(3)
      g.line(ax, ay, bx, by)
      g.setLineWidth(1)
    end
  end
end

return M
