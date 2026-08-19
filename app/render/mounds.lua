-- mounds.lua - the places. Ant hills, not flowers.
--
-- Replaces the old flora layer wholesale. The map is no longer a garden of
-- food sources to harvest; it is a field of MOUNDS you take and hold, so
-- each one has to say four things at a glance:
--
--   whose it is        colour of the rim
--   how strong it is   the garrison walking on it (drawn by render/ants)
--   what it can reach  its orbit ring, which IS the rule about where you
--                      may send -- drawn, so the rule is visible
--   what it is worth   size, and how many queens it can hold
--
-- Everything is generated from the node's seed, so no two mounds look the
-- same and the look is reproducible from a save.

local M = {}

local FAN = 22
local scratch = {}

-- A filled disc as a polygon fan, never circle("fill"): the engine
-- evaluates a filled circle per fragment from gl_FragCoord, which is
-- viewport-relative and lands elsewhere after a render-target pass.
-- SEGMENT COUNT IS OPT-IN, AND THE DEFAULT STAYS 22 ON PURPOSE. The mounds
-- are concentric rings that deliberately wobble (`rg.wob` below) so a hill
-- is never a perfect circle, and 22 samples is what turns that wobble into
-- a subtle irregular pile. Scaling the count with radius resolved every
-- lobe crisply and the mounds came out reading as CLOUD BLOBS rather than
-- earth. The coarse fan is load-bearing art direction, not an oversight --
-- pass a higher count only for a disc that genuinely wants to read as a
-- smooth circle.
local function disc(x, y, r, segs)
  local n = 0
  local FANn = segs or FAN
  for i = 1, FANn do
    local a = (i - 1) / FANn * 6.28318
    n = n + 1; scratch[n] = x + math.cos(a) * r
    n = n + 1; scratch[n] = y + math.sin(a) * r
  end
  for i = #scratch, n + 1, -1 do scratch[i] = nil end
  love.graphics.polygon("fill", scratch)
end
M.disc = disc

-- A ring from line segments. Same reasoning as disc: the stroked
-- primitives are unreliable after a target pass.
local function ring(x, y, r, segs)
  local g = love.graphics
  local px, py
  for i = 0, segs do
    local a = i / segs * 6.28318
    local qx, qy = x + math.cos(a) * r, y + math.sin(a) * r
    if px then g.line(px, py, qx, qy) end
    px, py = qx, qy
  end
end
M.ring = ring

local built = {}

local function seeded(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function()
    s = (s * 16807) % 2147483647
    return (s - 1) / 2147483646
  end
end

-- A mound is concentric rings of earth with a wobble, plus a dark entrance
-- and a scatter of excavated grit -- read from above, which is how this
-- game looks at the world.
local function geoFor(n)
  local g = built[n.id]
  if g then return g end
  local rng = seeded(n.seed)
  g = { rings = {}, grit = {}, holes = {} }
  for i = 1, 4 do
    g.rings[i] = { r = 0.30 + i * 0.19,
                   wob = 0.05 + rng() * 0.07,
                   phase = rng() * 6.3 }
  end
  local holes = 1 + math.floor(rng() * 2)
  for i = 1, holes do
    local a = rng() * 6.28318
    local d = rng() * 0.16
    g.holes[i] = { x = math.cos(a) * d, y = math.sin(a) * d,
                   r = 0.09 + rng() * 0.05 }
  end
  for i = 1, 14 do
    local a = rng() * 6.28318
    local d = 0.75 + rng() * 0.45
    g.grit[i] = { x = math.cos(a) * d, y = math.sin(a) * d,
                  r = 0.02 + rng() * 0.03 }
  end
  built[n.id] = g
  return g
end

function M.init(vp) built = {} end

-- Colours by owner. The rim is the only place ownership is stated on the
-- mound itself, so it has to be unambiguous.
-- ONE COLOUR PER SIDE. The late campaign fields TWO enemy colonies at
-- once, and drawing both in the same red makes a three-way war read as
-- one big opponent -- you cannot tell whose border you are on, or notice
-- when they start eating each other, which is the most interesting thing
-- happening on that map.
local RIM = {
  you  = { 0.45, 0.95, 0.55 },
  red  = { 0.98, 0.26, 0.20 },   -- unmistakably hostile
  -- Matches SIDE_COL.gold in render/ants.lua, and for the same reason: the
  -- old 0.74,0.16 sat only 0.135 from YOUR_COL in RGB space, so a gold
  -- ant on a gold rim read as "amber", not as "the second enemy". Pulled
  -- toward yellow so it separates from both your colour and red's.
  gold = { 0.98, 0.92, 0.16 },
  them = { 0.98, 0.26, 0.20 },   -- any other side falls back to red
  none = { 0.72, 0.66, 0.48 },
}
-- The rim colour for an owner string, whatever it is.
function M.sideColour(owner)
  if not owner then return RIM.none end
  return RIM[owner] or RIM.them
end

-- FOG OF WAR LIVES IN THE MOUNDS NOW, not in a layer over them. A mound
-- reads as grey stone until one of your ants is standing on it and warms
-- to earth when one arrives, so the coloured ground IS the ground you
-- hold -- see the colour note in M.draw.
--
-- The previous implementation drew a dark sheet and punched holes in it
-- with a stack of concentric polygon discs. It is gone rather than parked:
-- the stack could not produce a clean edge (a 16-step alpha ramp is a
-- staircase, and the eye adds its own bands at every step boundary), and
-- a shader replacement could not be composited either, because on this
-- engine `alpha` discards a shader's alpha channel and `multiply`
-- overwrites the destination instead of modulating it. Anyone reviving
-- fog as a separate pass should measure those two facts first.

function M.draw(snap, vp, intents)

  local g = love.graphics
  local world = snap.world
  local s = vp.worldScale()
  local t = snap.time
  local W = require("sim.world")

  local cursorId = intents and intents.cursor and intents.cursor.node
  local selectedId = intents and intents.selected

  -- ── RANGE RING, for ONE mound only ──
  --
  -- The orbit rule is the map puzzle, so it is drawn rather than implied.
  -- But it is drawn for the mound in question ONLY: a ring around every
  -- mound you own turns the screen into overlapping circles and -- worse
  -- -- makes "owned" and "pointed at" look the same, which is exactly the
  -- confusion this had ("it also just looks like i have 2 things
  -- selected"). Ownership is said by the mound itself; the ring answers
  -- "how far can THIS one throw".


  -- MOUNDS ONLY. A location has no reach of its own -- its link to a
  -- mound is judged by the MOUND's radius -- so drawing a ring around a
  -- patch of grain states a rule that does not exist, and states it in
  -- the one visual language this game promises is literal: the ring you
  -- see IS the rule (see world.lua). It drew a 900-unit circle around
  -- every aphid cluster the cursor touched, announcing a throw the
  -- player cannot make.
  local ringFor = selectedId or cursorId
  local ringNode = ringFor and world.node[ringFor]
  if ringNode then
    local n = ringNode
    if n.seen then
      local sx, sy = vp.worldToScreen(n.x, n.y)
      g.setColor(0.60, 0.90, 0.65, 0.28)
      g.setLineWidth(math.max(1, vp.u(2)))
      ring(sx, sy, W.reach(n) * s, 72)
      g.setLineWidth(1)
    end
  end

  -- ── the mounds ──
  local unknownsite = require("render.unknownsite")
  for i = 1, #world.nodes do
    local n = world.nodes[i]
    if n.seen then
      local sx, sy = vp.worldToScreen(n.x, n.y)

      -- ── STATE 3: NEVER VISITED ──
      --
      -- One grey circle, identical to the one an unvisited LOCATION
      -- wears, at the same shared radius. Everything below this branch --
      -- the kind's real radius, its ring geometry, its grit spill, its
      -- entrance holes, its rim -- is a tell, and together they told the
      -- player the whole board for free: a `rich` mound is a 104-unit
      -- circle with four entrances, a `small` one is 56 with one, and a
      -- spider out in the fog was the biggest circle on the map. You now
      -- learn a place by going to it.
      --
      -- `visited` (never cleared) rather than `held`/`observed`: what
      -- this branch hides is IDENTITY, and identity once learned stays
      -- learned even after your ants walk away.
      -- Expressed as an if/ELSE rather than a `goto continue`: a goto
      -- aiming at a label on the enclosing loop from inside a branch is
      -- not visible to it, and this engine only says so at LOAD time --
      -- every gate goes red at once with `fetch failed` and nothing
      -- renders. (See the same note in input/intents.lua.)
      if not n.visited then
        local ur = unknownsite.RADIUS * s
        if sx > -ur * 4 and sx < vp.w + ur * 4
           and sy > -ur * 4 and sy < vp.h + ur * 4 then
          g.setColor(0.10, 0.11, 0.08, 0.35)
          disc(sx, sy, ur * 1.15)
          unknownsite.draw(g, sx, sy, ur)
        end
      else

      local r = n.radius * s
      local geo = geoFor(n)

      -- ── IS THIS MOUND ALIVE? ──
      --
      -- Colour says "somebody lives here", and a QUEEN is the strongest
      -- possible form of that: a colony with a queen laying in it is
      -- inhabited whether or not a worker happens to be standing on the
      -- surface at this instant. Greying it the moment the last forager
      -- walked out made your own established colonies flicker to stone
      -- while the queen was still in the chamber.
      --
      -- `held` (one of your ants present) still counts, so a squad that
      -- has just walked onto neutral dirt warms it immediately -- that is
      -- what reveals a mound you are exploring.
      -- `n.contested` is the third way in, and it is about a FIGHT rather
      -- than about knowledge: a mound you are assaulting right now. An
      -- attacker dies on arrival against a defended hill, so it never
      -- stands there and `held` never becomes true however many ants you
      -- spend -- which is why an assault used to look like your army
      -- dissolving into featureless grey stone. It clears the moment the
      -- assault does, so this stays a rule about presence.
      --
      -- (A permanent "once seen, always known" latch was tried here and
      -- REVERTED: it kept every mound you had ever touched warm forever,
      -- which is a different game. `test-grey` caught it -- a mound whose
      -- ants all left must go back to stone, because in this game the
      -- coloured ground IS the ground you hold.)
      local inhabited = n.held or n.contested
                     or (#(n.queens or {}) > 0 and n.owner == "you")
      -- WHOSE, if it is knowable at all -- computed here, once, because
      -- both the earth fill below and the rim further down read the same
      -- answer to "known and coloured how". Duplicating this test at the
      -- rim used to leave the fill with no owner colour to draw from at
      -- all, which is the whole reason every held mound rendered identical
      -- brown regardless of whose it was.
      local known = inhabited
      local c = known and M.sideColour(n.owner) or RIM.none

      -- Excavated grit around the base: an ant hill is a pile of stuff
      -- brought UP, and the spill is what makes it read as earth rather
      -- than as a brown circle.
      -- The spill follows the mound: a greyed hill ringed with brown grit
      -- reads as a rendering fault rather than as stone.
      if inhabited then
        g.setColor(0.30, 0.25, 0.17, 0.5)
      else
        -- Same cool cast as the stone rings, or the spill reads as a
        -- separate object sitting under the mound.
        g.setColor(0.17, 0.18, 0.21, 0.5)
      end
      for k = 1, #geo.grit do
        local q = geo.grit[k]
        disc(sx + q.x * r, sy + q.y * r, math.max(0.6, q.r * r))
      end

      -- The mound: concentric rings, darkening inward, wobbling slowly so
      -- the hill is never a perfect circle -- when it is alive.
      --
      -- TWO SIGNALS, TWO QUESTIONS.
      --
      --   COLOUR answers "am I here". A mound is grey stone until one of
      --   your ants is standing on it and warms to earth the moment one
      --   arrives, so the coloured ground IS the ground you hold. Gated on
      --   `held` -- not `observed`, which is also true for every neighbour
      --   of a colony and would warm mounds nobody has walked on.
      --
      --   MOVEMENT answers "does this place live". Only an established
      --   COLONY breathes. Gated on `lit` (a queen), so a squad standing
      --   on captured dirt is warm but still.
      --
      -- Together they replace the fog layer: the map says where you are
      -- and where you have actually settled, without covering anything up.
      for k = #geo.rings, 1, -1 do
        local rg = geo.rings[k]
        -- BREATHING MEANS A QUEEN IS IN THERE. The wobble is the mound
        -- being alive, and a mound is only alive once it is an established
        -- COLONY -- a queen laying, not merely a squad standing on it. So
        -- it gates on `lit` (queen present) rather than `held` (any ant of
        -- yours), which are different questions: colour answers "am I
        -- here", movement answers "does this place live".
        --
        -- Everything else on the map is still, so the breathing reads as
        -- the one thing it means instead of as general ambience.
        local alive = n.lit and n.owner == "you"
        local w = alive and (1 + math.sin(t * 0.4 + rg.phase) * rg.wob) or 1
        local shade = 0.16 + k * 0.045
        if inhabited then
          -- Earth: warm, the colour of a worked hill -- WASHED TOWARD ITS
          -- OWNER, not plain brown regardless of whose it is.
          --
          -- Every held mound used to fill with the identical brown, so
          -- ownership lived ONLY in the 4px rim -- and on a busy war
          -- screen, with ants, food and a minimap all competing for the
          -- eye, that ring is easy to miss entirely. Reported directly
          -- from play: a gold raider standing on your own mound (green
          -- rim, correct) was mistaken for one of yours because nothing
          -- about the ground itself said "not your colour".
          --
          -- The wash is a BLEND toward the owner's rim colour, not a
          -- replacement -- at 0.30 the hill still reads as worked earth,
          -- shaded and ringed the same as before, but a red or gold mound
          -- now differs from a green one at the largest, stillest part of
          -- the shape, not only at its edge. `known` gates it so a mound
          -- you have never stood on (still fogged, `n.owner` invisible to
          -- you) never leaks its owner through the fill.
          local ec, ey, eb = shade + 0.06, shade * 0.82 + 0.04, shade * 0.55
          if known and c then
            local wash = 0.30
            ec = ec + (c[1] - ec) * wash
            ey = ey + (c[2] - ey) * wash
            eb = eb + (c[3] - eb) * wash
          end
          g.setColor(ec, ey, eb, 1)
        else
          -- STONE, mixed as its own colour rather than as a desaturated
          -- earth. Averaging the earth channels gave a dead putty grey; a
          -- real stone reads slightly COOL and holds its ring contrast, so
          -- the hill keeps its form instead of flattening into a disc.
          --
          -- DARKER THAN THE EARTH, NOT LIGHTER. The first version sat at
          -- 1.18x and the unheld mounds became the brightest things on
          -- screen -- the eye went straight to the ground you do NOT hold,
          -- which is exactly backwards. Stone should recede and let the
          -- worked mounds lead.
          local v = shade * 0.82 + 0.03
          g.setColor(v * 0.94, v * 0.98, v * 1.14, 1)
        end
        disc(sx, sy, rg.r * r * w * 2.0)
      end

      -- Entrances.
      for k = 1, #geo.holes do
        local h = geo.holes[k]
        g.setColor(0.06, 0.05, 0.04, 1)
        disc(sx + h.x * r, sy + h.y * r, h.r * r)
      end

      -- THE RIM says whose it is -- ONCE YOU HAVE BEEN THERE. A mound you
      -- have never stood on gets the neutral dashed rim whatever is really
      -- on it, so the map shows you the SHAPE of the field and nothing
      -- else. A coloured rim visible from across the board answered "whose
      -- is that, and should I worry" for free, which is the question
      -- scouting exists to ask. `held` is the same flag that warms the
      -- mound from stone to earth and reveals its garrison.
      -- THE RIM FOLLOWS PRESENCE, exactly like the mound's colour. Keeping
      -- `or n.owner == "you"` here put a thick green ownership rim around
      -- a mound rendered as bare grey stone -- the two signals saying
      -- opposite things about the same hill. A mound with nobody on it
      -- reads as unheld, whoever nominally owns it, which is also the
      -- truth: an empty mound is territory, not a colony.
      -- The rim uses the SAME "alive" test as the colour, so a queened
      -- mound is never brown with a neutral rim. `known` and `c` are
      -- computed once, above the fill, and reused here.
      local key = known and ((n.owner == "you") and "you"
                          or n.owner and "them" or "none")
               or "none"
      g.setColor(c[1], c[2], c[3], key == "none" and 0.34 or 0.85)
      g.setLineWidth(math.max(2, vp.u(key == "none" and 2 or 4)))
      if key == "none" then
        local px, py
        for k = 0, 40 do
          local a = k / 40 * 6.28318
          local qx, qy = sx + math.cos(a) * r * 1.06, sy + math.sin(a) * r * 1.06
          if px and k % 2 == 1 then g.line(px, py, qx, qy) end
          px, py = qx, qy
        end
      else
        ring(sx, sy, r * 1.06, 48)
      end
      g.setLineWidth(1)

      -- ── WHAT IS POINTED AT, AND WHAT IS PICKED UP ──
      --
      -- These have to be unmistakable and DIFFERENT from each other and
      -- from ownership. Ownership is the rim; the cursor is a bracket of
      -- four corners outside the mound; a picked-up mound gets a thick
      -- pulsing halo as well. Nothing else on screen uses either shape.
      if n.id == cursorId then
        -- OUTSIDE the worker ring (which runs to 1.75r), or the
        -- bracket lands among the ants and reads as decoration.
        local br = r * 1.78
        local L = br * 0.42
        g.setColor(0.98, 0.98, 0.90, 0.95)
        g.setLineWidth(math.max(2, vp.u(4)))
        for q = 0, 3 do
          local a0 = q * 1.5708 + 0.7854
          local cx, cy = sx + math.cos(a0) * br, sy + math.sin(a0) * br
          -- Two short strokes meeting at the corner.
          g.line(cx, cy, cx - math.cos(a0 - 0.5) * L, cy - math.sin(a0 - 0.5) * L)
          g.line(cx, cy, cx - math.cos(a0 + 0.5) * L, cy - math.sin(a0 + 0.5) * L)
        end
        g.setLineWidth(1)
      end
      if n.id == selectedId then
        -- PICKED UP HAS TO BE UNMISSABLE, because the cost of confusing it
        -- with "the cursor is here" is losing a garrison: pressing A on a
        -- mound you thought was merely hovered SENDS its ants away, which
        -- is exactly how ten gathered ants disappeared with no queen.
        --
        -- This was a setLineWidth(7) ring, and GL caps glLineWidth at 1 on
        -- most drivers (the same trap that kept the spider's legs as
        -- threads -- see render/threats.lua). It drew a hairline, so the
        -- two states looked identical. Real geometry is the only way to
        -- get a thick ring: an annulus of quads, pulsing.
        local pulse = 0.5 + 0.5 * math.sin(t * 5)
        local rr = r * 1.64
        local w = math.max(2, r * 0.10) * (0.85 + pulse * 0.35)
        g.setColor(0.60, 1.0, 0.68, 0.55 + pulse * 0.4)
        local SEG = 48
        for q = 0, SEG - 1 do
          local a0 = q / SEG * 6.28318
          local a1 = (q + 1) / SEG * 6.28318
          local c0, s0 = math.cos(a0), math.sin(a0)
          local c1, s1 = math.cos(a1), math.sin(a1)
          g.polygon("fill",
            sx + c0 * (rr - w), sy + s0 * (rr - w),
            sx + c0 * (rr + w), sy + s0 * (rr + w),
            sx + c1 * (rr + w), sy + s1 * (rr + w),
            sx + c1 * (rr - w), sy + s1 * (rr - w))
        end
      end

      -- NO ANT-COUNT BADGE. There was a number floating over every
      -- mound and it earned nothing: the ants are drawn walking the
      -- perimeter, so the size of a garrison is already visible, and the
      -- exact figure is in the panel the moment you select the mound.
      -- What the badges actually did was scatter green digits across
      -- open ground with no visible connection to any hill.

      -- ENERGY, for a defended mound you are chewing through. Only shown
      -- when it has actually been damaged, so an untouched map is quiet.
      --
      -- AND ONLY WHERE YOU CAN SEE IT. This arc used to be gated on
      -- `n.owner` alone, which made it the last thing leaking live enemy
      -- state across the whole board after plan 04 closed everything
      -- else: a red-orange ring around every damaged mound anybody owned,
      -- readable from across the map, saying both "somebody holds this"
      -- and "here is how close it is to falling". `test-fog3` caught it
      -- as 165 enemy-coloured pixels sitting on grey stone the player was
      -- nowhere near.
      --
      -- How damaged a mound is is a state-1 fact, so it needs the same
      -- presence test everything else does: your ants standing there, or
      -- your assault inbound (an assault you are paying for is never a
      -- secret), or it is your own ground.
      local liveEnergy = n.held or n.contested or n.owner == "you"
      if liveEnergy
         and n.owner and n.maxEnergy and n.energy and n.energy < n.maxEnergy then
        local frac = math.max(0, n.energy / n.maxEnergy)
        g.setColor(0.95, 0.45, 0.30, 0.9)
        g.setLineWidth(math.max(2, vp.u(4)))
        local px, py
        local steps = math.max(1, math.floor(48 * frac))
        for k = 0, steps do
          local a = -1.5708 + (k / 48) * 6.28318
          local qx, qy = sx + math.cos(a) * r * 1.18, sy + math.sin(a) * r * 1.18
          if px then g.line(px, py, qx, qy) end
          px, py = qx, qy
        end
        g.setLineWidth(1)
      end
      end   -- close the visited/unvisited branch
    end
  end
end

return M
