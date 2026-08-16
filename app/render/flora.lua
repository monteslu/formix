-- flora.lua - the nodes, as generated plants.
--
-- Fractal plants are the thing players remember, and the trick
-- transfers: every node's geometry derives from its own seed, so no two
-- flowers match and the look is reproducible from a save. The geometry is
-- built ONCE per node into a point list and then only transformed per
-- frame, so growing a garden costs a draw call per plant, not a
-- tessellation pass.
--
-- Vector-abstract on purpose: petals are polygon fans, stems are tapered
-- strips, the mound is layered rings. No bitmap anywhere in the game.

local M = {}

local built = {}      -- nodeId -> geometry
local scratch = {}

-- A tiny deterministic PRNG from a node seed, so the same flower comes back
-- every session and after a save/load.
local function seeded(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function()
    s = (s * 16807) % 2147483647
    return (s - 1) / 2147483646
  end
end

local function buildFlower(n)
  local rng = seeded(n.seed)
  local petals = 5 + math.floor(rng() * 4)
  local geo = { kind = "flower", petals = {}, coreR = n.radius * 0.22 }
  local baseAngle = rng() * 6.28318
  local len = n.radius * (0.72 + rng() * 0.3)
  local wide = 0.34 + rng() * 0.22
  for i = 1, petals do
    local a = baseAngle + (i - 1) / petals * 6.28318 + (rng() - 0.5) * 0.12
    geo.petals[i] = {
      angle = a,
      len = len * (0.85 + rng() * 0.3),
      wide = wide,
      -- Per-petal phase so the bloom breathes unevenly, like a real plant.
      phase = rng() * 6.28318,
    }
  end
  geo.hue = rng()
  return geo
end

local function buildFruit(n)
  local rng = seeded(n.seed)
  local lobes = 3 + math.floor(rng() * 3)
  local geo = { kind = "fruit", lobes = {}, hue = rng() }
  for i = 1, lobes do
    local a = rng() * 6.28318
    local d = n.radius * 0.3 * rng()
    geo.lobes[i] = { x = math.cos(a) * d, y = math.sin(a) * d,
                     r = n.radius * (0.42 + rng() * 0.26), phase = rng() * 6.3 }
  end
  return geo
end

local function buildAphid(n)
  local rng = seeded(n.seed)
  local geo = { kind = "aphid", blades = {}, bugs = {} }
  for i = 1, 7 + math.floor(rng() * 5) do
    geo.blades[i] = { angle = -1.5708 + (rng() - 0.5) * 1.5,
                      len = n.radius * (0.9 + rng() * 0.8),
                      bend = (rng() - 0.5) * 0.9, phase = rng() * 6.3,
                      x = (rng() - 0.5) * n.radius * 1.3 }
  end
  for i = 1, 5 + math.floor(rng() * 4) do
    geo.bugs[i] = { x = (rng() - 0.5) * n.radius * 1.1,
                    y = (rng() - 0.5) * n.radius * 0.7,
                    r = n.radius * 0.09, phase = rng() * 6.3 }
  end
  return geo
end

local function buildSeed(n)
  local rng = seeded(n.seed)
  return { kind = "seed", tilt = (rng() - 0.5) * 0.8,
           w = n.radius * 0.5, h = n.radius * 0.78, hue = rng() }
end

local function buildNest(n)
  local rng = seeded(n.seed)
  local geo = { kind = "nest", rings = {}, holes = {} }
  for i = 1, 4 do
    geo.rings[i] = { r = n.radius * (0.45 + i * 0.19),
                     wobble = 0.06 + rng() * 0.08, phase = rng() * 6.3 }
  end
  for i = 1, 3 do
    local a = rng() * 6.28318
    geo.holes[i] = { x = math.cos(a) * n.radius * 0.28,
                     y = math.sin(a) * n.radius * 0.28,
                     r = n.radius * (0.10 + rng() * 0.06) }
  end
  return geo
end

local BUILDERS = {
  flower = buildFlower, fruit = buildFruit, aphid = buildAphid,
  seed = buildSeed, nest = buildNest, rival = buildNest,
}

-- How far over 1.0 an emissive element is drawn. On the HDR path this is
-- what the bloom's bright pass picks up; with no float canvas it must stay
-- at 1.0, because there over-bright colour is simply clipped and the only
-- effect would be losing the hue.
M.emissive = 1.0

function M.init(vp)
  built = {}
  M.emissive = require("render.fx").available and 1.9 or 1.0
end

local function geoFor(n)
  local g = built[n.id]
  if not g then
    g = (BUILDERS[n.kind] or buildSeed)(n)
    built[n.id] = g
  end
  return g
end

-- A filled disc as a POLYGON FAN, never circle("fill"). The engine
-- evaluates a filled circle per fragment from gl_FragCoord, which is
-- viewport-relative -- after a render-target pass it silently vanishes.
-- A fan is ordinary geometry and always draws. (Learned on eightball; the
-- bug showed up only on Android.)
local FAN_N = 20
local function disc(x, y, r)
  local n = 0
  for i = 1, FAN_N do
    local a = (i - 1) / FAN_N * 6.28318
    n = n + 1; scratch[n] = x + math.cos(a) * r
    n = n + 1; scratch[n] = y + math.sin(a) * r
  end
  for i = #scratch, n + 1, -1 do scratch[i] = nil end
  love.graphics.polygon("fill", scratch)
end
M.disc = disc

local function petalShape(cx, cy, angle, len, wide, s)
  -- A petal is a four-point lens: base, two shoulders, tip. Cheap and it
  -- reads as a petal rather than a triangle.
  local ca, sa = math.cos(angle), math.sin(angle)
  local px, py = -sa, ca
  local n = 0
  local function put(dx, dy)
    n = n + 1; scratch[n] = cx + (ca * dx + px * dy) * s
    n = n + 1; scratch[n] = cy + (sa * dx + py * dy) * s
  end
  put(0, 0)
  put(len * 0.45, wide * len * 0.5)
  put(len, 0)
  put(len * 0.45, -wide * len * 0.5)
  for i = #scratch, n + 1, -1 do scratch[i] = nil end
  love.graphics.polygon("fill", scratch)
end

-- The nest's delivery glow. Driven by agents.deliverPulse, which the sim
-- increments and this drains -- so the sim never has to know a renderer
-- exists. It is a LOOK, not a rule: nothing in the world reads it, and the
-- sim is identical with the glow at any value. Held across frames, hence a
-- module field; decayed on world time so it looks the same at any frame
-- rate.
M.deliverGlow = 0
M.lastGlowTime = nil

function M.draw(snap, vp)
  local world = snap.world
  local s = vp.worldScale()
  local g = love.graphics
  local t = snap.time
  local x0, y0, x1, y1 = vp.worldBounds()

  -- Drain whatever arrived since the last frame, then decay. The scale
  -- (0.06) turns a typical delivery into a visible-but-not-blinding lift;
  -- the clamp stops a huge simultaneous arrival from whiting out the nest.
  local a = snap.agents
  if a and a.deliverPulse and a.deliverPulse > 0 then
    M.deliverGlow = math.min(1.4, M.deliverGlow + a.deliverPulse * 0.06)
    a.deliverPulse = 0
  end
  -- Decay on WORLD TIME, not on frames. A per-frame factor makes the glow
  -- last half as long on a 60fps machine as on a 30fps one, which is the
  -- same class of bug as tying a physics step to the frame rate -- and
  -- every other animated thing in this renderer already keys off
  -- snap.time, so this was the one effect that would have looked different
  -- on a phone than in the window.
  local prev = M.lastGlowTime or t
  local dt = math.max(0, math.min(0.25, t - prev))
  M.lastGlowTime = t
  M.deliverGlow = M.deliverGlow * math.exp(-6.0 * dt)

  for i = 1, #world.nodes do
    local n = world.nodes[i]
    -- Cull: off-screen plants cost nothing.
    if n.x + n.radius * 2 >= x0 and n.x - n.radius * 2 <= x1 and
       n.y + n.radius * 2 >= y0 and n.y - n.radius * 2 <= y1 then
      local sx, sy = vp.worldToScreen(n.x, n.y)
      local geo = geoFor(n)

      -- An undiscovered node is a RUMOUR, not a smudge. It has to be
      -- legible enough to want -- the whole of this game's onboarding is
      -- "there is something over there, send someone" -- so it is drawn
      -- dim but SHAPED, with a slow breath so it reads as alive rather
      -- than as a rendering artefact. At 0.16 flat they looked like dirt.
      local known = n.discovered
      local alpha = 1
      local breath = 0
      if not known then
        breath = 0.5 + 0.5 * math.sin(t * 0.8 + (n.seed % 100) * 0.1)
        alpha = 0.30 + 0.10 * breath

        -- A HALO UNDER THE RUMOUR. Alpha alone was not enough: fading a
        -- coloured shape toward a dark ground desaturates it, so an
        -- unvisited flower came out grey and read as DEAD -- the exact
        -- opposite of the "there is something over there, send someone"
        -- that is this game's entire onboarding. A soft cool glow beneath
        -- it restores the sense of something worth walking to, and it
        -- breathes so it can never be mistaken for a static artefact.
        -- Additive, and under the plant, so it lifts the silhouette
        -- without repainting it.
        -- SMALL AND TIGHT. The first attempt used a 2.1x radius at 0.05
        -- alpha per ring and the map filled with pale discs that read as
        -- fog banks -- they drew the eye to a SMEAR rather than to a
        -- point, which is worse than the grey it replaced. A rumour needs
        -- to say "here", so the glow barely exceeds the plant itself and
        -- leans on the breath rather than on size.
        g.setBlendMode("add")
        local hr = n.radius * s * (0.95 + breath * 0.14)
        for k = 2, 1, -1 do
          local f = k / 2
          g.setColor(0.10 * f, 0.20 * f, 0.30 * f,
                     (0.10 + breath * 0.10) * f)
          disc(sx, sy, hr * f)
        end
        g.setBlendMode("alpha")
      end
      local left = 1
      if n.foodMax > 0 then left = math.max(0, math.min(1, n.food / n.foodMax)) end

      if geo.kind == "nest" then
        for k = #geo.rings, 1, -1 do
          local r = geo.rings[k]
          local w = 1 + math.sin(t * 0.6 + r.phase) * r.wobble
          g.setColor(0.20 + k * 0.03, 0.15 + k * 0.02, 0.10, alpha)
          disc(sx, sy, r.r * w * s)
        end
        for _, h in ipairs(geo.holes) do
          g.setColor(0.05, 0.04, 0.03, alpha)
          disc(sx + h.x * s, sy + h.y * s, h.r * s)
        end

        -- FOOD ARRIVING HOME, made visible. Every road in this game exists
        -- to produce this moment, and until now it was a number ticking up
        -- in a corner -- the reward loop had no reward. The sim counts
        -- delivered food into agents.deliverPulse and this is where it is
        -- spent: a warm additive bloom over the nest that decays, so a busy
        -- colony visibly THROBS with returning foragers and a starving one
        -- goes dark. Read-and-decay here rather than in the sim keeps the
        -- renderer read-only with respect to the world state that matters.
        local pulse = M.deliverGlow or 0
        if pulse > 0.004 then
          g.setBlendMode("add")
          -- SUBLINEAR in the arrival rate. Linear looked right on a young
          -- colony and then, at ~80 ants all delivering, sat the nest under
          -- a solid amber disc that hid the very ants the glow is meant to
          -- celebrate. A square root keeps a first delivery clearly
          -- visible while a boom only ever warms the mound.
          local amt = math.sqrt(math.min(1, pulse)) * 0.62
          for k = 3, 1, -1 do
            local f = k / 3
            g.setColor(0.42 * f * amt, 0.30 * f * amt, 0.10 * f * amt, 0.26 * f)
            -- Kept close to the mound. At 1.05+0.55f it spilled a soft
            -- disc well past the nest and read as a light source sitting
            -- on the grass; the glow should look like the nest itself
            -- warming up, so it barely clears the rim.
            disc(sx, sy, n.radius * s * (0.92 + f * 0.30 + amt * 0.14))
          end
          g.setBlendMode("alpha")
        end

      elseif geo.kind == "flower" then
        -- Stem first, so petals overlap it.
        g.setColor(0.16, 0.34, 0.16, alpha)
        g.setLineWidth(math.max(1, 3 * s))
        g.line(sx, sy + n.radius * 0.2 * s, sx, sy + n.radius * 1.4 * s)
        g.setLineWidth(1)
        for _, p in ipairs(geo.petals) do
          -- Bloom shrinks AND dims as the flower is harvested: the plant
          -- reports its own stock, so the HUD never has to. Petals keep
          -- their hue while fading toward a dry brown rather than washing
          -- out to white -- a white flower reads as "highlighted", the
          -- opposite of the "spent" it is meant to mean.
          local open = 0.35 + 0.65 * left
          local breathe = 1 + math.sin(t * 0.9 + p.phase) * 0.04
          local hue = geo.hue
          local pr = 0.85 - hue * 0.25
          local pg = 0.45 + hue * 0.35
          local pb = 0.62 + hue * 0.25
          -- Spent petals: darker and browner, never brighter.
          local dry = 0.35 + 0.65 * left
          local cr = pr * dry + 0.10 * (1 - dry)
          local cg = pg * dry + 0.08 * (1 - dry)
          local cb = pb * dry + 0.05 * (1 - dry)
          if not known then
            -- SATURATE, do not brighten. These petals are pale by design
            -- (at the top of the hue range they are almost white), so
            -- multiplying them up just clipped every channel and produced
            -- the white flowers this was meant to fix. Pushing each channel
            -- AWAY from its own mean keeps the same colour and makes it
            -- read through the low alpha, which is what was actually lost.
            local mean = (cr + cg + cb) / 3
            local sat = 1.85
            cr = math.max(0, mean + (cr - mean) * sat)
            cg = math.max(0, mean + (cg - mean) * sat)
            cb = math.max(0, mean + (cb - mean) * sat)
            -- and darken slightly, so a rumour never out-shouts a real one.
            cr, cg, cb = cr * 0.80, cg * 0.80, cb * 0.80
          end
          g.setColor(cr, cg, cb, alpha)
          petalShape(sx, sy, p.angle, p.len * open * breathe, p.wide, s)
        end
        -- The pollen core is the flower's one emissive element: it goes
        -- over 1.0 so it blooms, which reads as a bead of light at the
        -- centre of the bloom and gives the night scene something warm to
        -- look at. Scaled by how much food is left, so a spent flower
        -- stops glowing before it stops existing.
        -- The core does NOT bloom on an undiscovered plant. Emissive over
        -- 1.0 is what the bright pass looks for, so a rumour with a full
        -- core threw a white bead that swamped the petals behind it and
        -- turned every unvisited flower into a smudge of light. A rumour
        -- glows only once someone has actually been there.
        local glow = M.emissive * (0.35 + 0.65 * left)
        if not known then glow = math.min(glow, 0.55) end
        g.setColor(0.98 * glow, 0.88 * glow, 0.45 * glow, alpha)
        disc(sx, sy, geo.coreR * s * (0.6 + 0.4 * left))

      elseif geo.kind == "fruit" then
        for _, l in ipairs(geo.lobes) do
          local breathe = 1 + math.sin(t * 0.7 + l.phase) * 0.03
          g.setColor(0.72 - geo.hue * 0.2, 0.18 + geo.hue * 0.14, 0.22, alpha)
          disc(sx + l.x * s, sy + l.y * s,
               l.r * s * breathe * (0.45 + 0.55 * left))
        end

      elseif geo.kind == "aphid" then
        for _, b in ipairs(geo.blades) do
          local sway = math.sin(t * 1.3 + b.phase) * 0.12
          local bx = sx + b.x * s
          local by = sy + n.radius * 0.5 * s
          local tipx = bx + math.cos(b.angle + b.bend + sway) * b.len * s
          local tipy = by + math.sin(b.angle + b.bend + sway) * b.len * s
          g.setColor(0.18, 0.38, 0.18, alpha)
          g.setLineWidth(math.max(1, 2.5 * s))
          g.line(bx, by, tipx, tipy)
          g.setLineWidth(1)
        end
        for _, b in ipairs(geo.bugs) do
          local bob = math.sin(t * 2 + b.phase) * 2 * s
          g.setColor(0.55, 0.72, 0.35, alpha)
          disc(sx + b.x * s, sy + b.y * s + bob, b.r * s)
        end

      else -- seed
        g.setColor(0.55 - geo.hue * 0.15, 0.42, 0.24, alpha)
        love.graphics.push()
        love.graphics.translate(sx, sy)
        love.graphics.rotate(geo.tilt)
        disc(0, 0, geo.w * s * (0.5 + 0.5 * left))
        love.graphics.pop()
      end

      -- ── OWNERSHIP, ON THE MAP ITSELF ──────────────────────────────
      --
      -- The panel in the corner tells you about ONE node. The map has to
      -- answer "what is mine" for all of them at once, or every decision
      -- means moving the cursor around to interview each place in turn.
      -- Three states, three readings, no text:
      --
      --   yours    a solid green collar plus a dot per ant, so a strong
      --            base looks strong from across the room
      --   taking   an arc filling clockwise: progress toward owning it
      --   theirs   a hard red collar
      --
      -- Drawn as line segments rather than circle()/arc() -- see NOTES.md;
      -- the stroked primitives are viewport-relative and land elsewhere
      -- after a render-target pass.
      local orole = nil
      if n.owner == "you" then orole = "you"
      elseif n.owner then orole = "them"
      elseif known and n.colonisable then orole = "open" end

      if orole then
        local cr = n.radius * s * 1.16
        local col = (orole == "you") and { 0.45, 0.95, 0.55 }
                 or (orole == "them") and { 0.95, 0.35, 0.30 }
                 or { 0.92, 0.86, 0.55 }
        local a0 = (orole == "open") and 0.30 or 0.75
        -- An unclaimed node's collar is dashed, so "could be yours" never
        -- reads the same as "is yours" at a glance.
        local segs = (orole == "open") and 14 or 44
        g.setColor(col[1], col[2], col[3], a0)
        g.setLineWidth(math.max(2, vp.u(orole == "open" and 3 or 5)))
        local px, py
        for k = 0, segs do
          local th = k / segs * 6.28318
          local qx, qy = sx + math.cos(th) * cr, sy + math.sin(th) * cr
          if px and (orole ~= "open" or k % 2 == 1) then g.line(px, py, qx, qy) end
          px, py = qx, qy
        end
        g.setLineWidth(1)

        -- Siege progress: how much of the collar is already paid for.
        if (n.siege or 0) > 0 and (n.takeCost or 0) > 0 then
          local frac = math.min(1, n.siege / n.takeCost)
          g.setColor(0.60, 0.98, 0.68, 0.95)
          g.setLineWidth(math.max(3, vp.u(7)))
          local steps = math.max(2, math.floor(44 * frac))
          px, py = nil, nil
          for k = 0, steps do
            local th = -1.5708 + (k / 44) * 6.28318
            local qx, qy = sx + math.cos(th) * cr, sy + math.sin(th) * cr
            if px then g.line(px, py, qx, qy) end
            px, py = qx, qy
          end
          g.setLineWidth(1)
        end

        -- Garrison pips: one dot per ant living here, capped so a big base
        -- reads as "many" rather than turning into a solid ring.
        if orole ~= "open" and (n.garrison or 0) > 0 then
          local count = math.min(24, n.garrison)
          local pr = cr + vp.u(13)
          for k = 1, count do
            local th = -1.5708 + (k - 1) / 24 * 6.28318
            g.setColor(col[1], col[2], col[3], 0.9)
            disc(sx + math.cos(th) * pr, sy + math.sin(th) * pr,
                 math.max(1.5, vp.u(4)))
          end
        end
      end

      -- Danger mark: the player's aversion, drawn as a pulsing ring so it
      -- is legible without text at any zoom.
      if n.danger > 0.02 then
        local pulse = 0.5 + 0.5 * math.sin(t * 5)
        g.setColor(0.95, 0.25, 0.2, n.danger * (0.35 + pulse * 0.4))
        g.setLineWidth(math.max(2, 4 * s))
        g.circle("line", sx, sy, n.radius * 1.25 * s)
        g.setLineWidth(1)
      end

      -- A rival claim: someone else's colony is working this source, so its
      -- yield is theirs for a while. Drawn as a ring of THEIR scent plus a
      -- scatter of their foragers, because "a faint purple circle" is a UI
      -- annotation and what the player should see is another colony.
      -- Displacement has to look like something happening, not like a
      -- status effect.
      if n.claimed then
        local pulse = 0.5 + 0.5 * math.sin(t * 1.6)
        -- Two rings, rotating opposite ways: reads as a boundary being
        -- held rather than as a highlight.
        g.setColor(0.62, 0.30, 0.78, 0.30 + pulse * 0.25)
        g.setLineWidth(math.max(2, 4 * s))
        g.circle("line", sx, sy, n.radius * (1.35 + pulse * 0.06) * s)
        g.setColor(0.52, 0.24, 0.68, 0.20)
        g.setLineWidth(math.max(1, 2 * s))
        g.circle("line", sx, sy, n.radius * (1.62 - pulse * 0.06) * s)
        g.setLineWidth(1)

        -- The rival's own foragers, circling. Deterministic from the node
        -- seed so they do not reshuffle every frame.
        local rr = seeded(n.seed + 7)
        for i = 1, 7 do
          local a = rr() * 6.28318 + t * (0.35 + rr() * 0.25)
          local d = n.radius * (0.95 + rr() * 0.45)
          local rx = sx + math.cos(a) * d * s
          local ry = sy + math.sin(a) * d * s
          g.setColor(0.55, 0.26, 0.70, 0.9)
          disc(rx, ry, math.max(1.2, 2.6 * s))
        end
      end
    end
  end
end

return M
