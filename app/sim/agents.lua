-- agents.lua - the ants. They are UNITS, and they are the currency.
--
-- THE ONE-UNIT RULE, which the first two builds both missed: an ant is
-- simultaneously your army, your money and your builder. There is no
-- resource to gather, nothing to shuttle, and no autonomous behaviour at
-- all. Every unit on screen is either sitting at a node you hold or
-- travelling somewhere you ordered it to go.
--
-- What that deletes, deliberately:
--   * foraging. The previous build ran a permanent errand loop -- ants
--     running to food and back forever -- which was most of the motion on
--     screen and none of it the player's. The complaint that landed it was
--     exact: "all i see is a shit ton of ants going quickly back and
--     forth. what the fuck are they even doing?"
--   * food as a separate resource, and the economy that moved it.
--   * scent trails as a mechanic. A send draws a visible path because the
--     player wants to SEE the order, not because ants follow a gradient.
--
-- What remains is small: an ant is at a node, or it is walking to one.

local W = require("sim.world")

local M = {}

M.cfg = {
  maxAgents = 2600,
  speed     = 96,        -- world units/sec, before the node's speed stat
  -- Spread of ants idling around their node, as a fraction of its radius.
  -- They ORBIT rather than stack, so a garrison of forty reads as forty.
  orbitMin  = 1.25,
  orbitMax  = 1.95,
  orbitRate = 0.20,      -- radians/sec (legacy; wander replaced it)
  -- WORKERS MILL AROUND THE OUTSIDE OF THE MOUND, never on top of it.
  -- The inside is the queens' and the brood's; a worker standing over the
  -- chamber hides the thing the mound is FOR. These are the inner and
  -- outer limits of the ring they amble in, in mound radii -- so a mound
  -- always reads as a hill with a crowd around its base.
  -- A TIGHT BAND ON THE PERIMETER -- workers ringing the hill, not a
  -- loose crowd in the neighbourhood. Just
  -- outside the hill's edge, and only a little depth so the ring reads as
  -- a ring.
  -- With a VISIBLE GAP between the hill's edge and the ring: ants sitting
  -- flush against the rim merge into it and the mound loses its outline.
  -- 1.14 leaves daylight; the band is thin so the ring stays a ring.
  -- FURTHER OUT, so the queens and their brood have the middle of the
  -- mound to themselves. At 1.14 the ring sat on top of the chamber and
  -- the queen -- the thing the mound is FOR -- was buried under workers.
  wanderInner  = 1.34,
  wanderOuter  = 1.52,
  wanderSpeed  = 46,     -- world units/sec: an amble, not a march
  circulate    = 0.30,   -- radians/sec around the perimeter
  -- Leaving: they walk the rim to the point facing the target, then
  -- cross. One shared gate per direction means the open ground carries a
  -- single column instead of a fan.
  gateRing     = 1.44,   -- mound radii: just outside the worker ring
  rimSpeed     = 1.7,    -- radians/sec while walking round to the gate

  -- HOW FAST A BODY CAN SWING ROUND. An ant pivots quickly but not
  -- instantly, and this is the only thing standing between the renderer
  -- and a sprite that teleports through 180 degrees in one frame.
  --
  -- 9 rad/sec is about half a turn in 0.35s: fast enough that a departing
  -- column still looks decisive, slow enough that every snap this file
  -- used to produce becomes a visible pivot instead. See M.face.
  turnRate     = 9.0,    -- radians/sec the facing may change

  -- ── COMBAT ───────────────────────────────────────────────────────────
  --
  -- A FIGHT TAKES TIME, and it is not a coin flip.
  --
  -- Attacks used to resolve instantly and 1-for-1: an arriving ant killed
  -- one defender and died doing it. That made a battle a subtraction rather
  -- than an event -- there was nothing to watch, nothing to reinforce
  -- mid-fight, and no reason to care whether you sent thirty ants or
  -- thirty-one.
  --
  -- Now every ant has hit points and swings once a second for 2 or 3
  -- damage, half the time missing entirely. The randomness is per-swing, so
  -- an individual duel is genuinely uncertain -- but the LAW OF LARGE
  -- NUMBERS does the rest: across a real engagement the bigger army wins
  -- comfortably, because both sides draw from the same distribution and one
  -- of them has more dice.
  --
  -- Everything here is read through the ant's own `atk`/`def`, so an
  -- offensive or defensive upgrade later is a multiplier on a body rather
  -- than a change to this rule.
  maxHp        = 10,     -- what a fresh worker can absorb
  -- A QUEEN IS THE OBJECTIVE, and she is hard to kill: five workers' worth
  -- of body. A mound belongs to whoever's queen is alive in it, so taking
  -- an established colony means fighting through the garrison AND then
  -- through her -- which is why a settled mound is worth more than the
  -- ground it sits on.
  queenHp      = 50,
  -- ...and she is worth eating. Eight food is more than any single item in
  -- the ground (an aphid is 6, a spider's leg 3), so a colony you storm
  -- pays for part of the army it cost -- which is what stops a won siege
  -- from leaving you too poor to hold the ground you just took.
  queenFood    = 8,
  -- BUT ONLY FOR THE PLAYER'S SIDE OF THE TABLE, and this is a balance
  -- rule rather than a fiction one.
  --
  -- Paid to everybody, the bounty is a runaway loop between AIs: killing a
  -- queen buys eight ants, eight ants take the next colony faster, and
  -- whoever wins the first exchange eats the map. Measured on the war map
  -- the moment it went in -- side-to-side captures jumped 2 -> 7 and gold
  -- was ANNIHILATED (`{you:1, red:10}`), which test-war caught because it
  -- asserts all three sides survive to fight. A three-way war where one
  -- rival is dead by minute five is not the map's design.
  --
  -- A rival still gets the ground, the kill and the denial -- everything
  -- except the compounding. The player gets the spoils because the player
  -- is the one who needs a reason to commit to an expensive siege.
  queenFoodRivals = 0,
  swingPeriod  = 1.0,    -- seconds between an ant's attacks
  hitChance    = 0.5,    -- ...and how often one lands at all
  hitMin       = 2,      -- damage when it does land
  hitMax       = 3,
  -- How close two ants have to be to trade blows, in mound radii. A fight
  -- happens AT the mound, so this only has to cover the ring the defenders
  -- mill in plus the arrivals pushing into it.
  fightRange   = 1.9,
}

M.YOU = "you"

-- A NEW QUEEN. One constructor because there are four places that raise
-- one (the player's apply, the rival's brain, a hand-built campaign level
-- and a save restore), and her hit points have to be the same number in all
-- of them -- a queen who loads back from a save with no `hp` is a queen who
-- cannot be killed, and nothing would have caught it.
function M.newQueen()
  return { layTimer = 0, hp = M.cfg.queenHp }
end

-- FACE WHERE YOU ARE ACTUALLY GOING, and get there by turning.
--
-- Every stage of an ant's life used to compute `dir` from whatever number
-- was convenient to that stage, and the stages disagreed:
--
--   * MILLING  faced `phase + 90*spin` -- the lane's tangent, not the
--     ant's. The ant chases its lane target rather than sitting on it, so
--     the two drift apart, and re-rolling the target (`wt` expiring)
--     snapped the body up to 164 degrees with no movement to justify it.
--   * RIM      faced `cur + 90*sign(diff)` -- tangential, sign taken from
--     which way round it still has to go.
--   * CROSSING faced `atan2(dy, dx)` -- along the travel vector.
--
-- Two of those are tangents and one is a heading, so leaving the mound
-- turned the body 90 degrees in a single frame; and when the rim's turn
-- direction opposed the mound's spin, the mill->rim handoff was a clean
-- 180. Measured on the Gather board, one send produced jumps of 163, 106,
-- 127, 164, 180, 90 and 89 degrees. That is the "shaking" -- the body
-- flipping back and forth as an ant leaves a mound.
--
-- The fix is to stop deriving facing from bookkeeping at all. An ant faces
-- the way it MOVED, whatever stage it is in, and it can only turn so fast.
-- One rule, so there is no handoff left to disagree about.
--
-- Called with the ant's position BEFORE it moved. A frame that produced no
-- real displacement leaves the facing alone rather than snapping it to a
-- direction computed from rounding noise.
function M.face(ant, px, py, dt)
  local dx, dy = ant.x - px, ant.y - py
  -- Below this the "direction" is numerical noise, not a heading. An ant
  -- easing the last hair into its lane must not spin to face the jitter.
  if dx * dx + dy * dy < 1e-6 then return end
  local want = math.atan(dy, dx)
  local cur = ant.dir or want
  -- Shortest way round, so a turn across the +/-pi seam is a small pivot
  -- rather than the long way about.
  local diff = (want - cur + math.pi) % 6.28318 - math.pi
  local step = M.cfg.turnRate * dt
  if math.abs(diff) <= step then
    ant.dir = want
  else
    ant.dir = cur + (diff > 0 and step or -step)
  end
end

function M.new(world, rng)
  local a = {
    world = world,
    rng = rng or math.random,
    pool = {},
    n = 0,
    born = 0, died = 0, sent = 0, arrived = 0, picked = 0,
    -- PER SIDE, because the totals lie. `picked` counts every pickup on
    -- the board by anybody, and reporting it as the player's made a war
    -- map where the player never moved read as "the player picked 59
    -- items" -- which is exactly the assertion a gate wants to make
    -- about the RIVALS foraging unaided.
    pickedBy = {}, deliveredBy = {},
    -- FOOD DELIVERED THIS TICK, waiting to be swept into the pool.
    --
    -- The pool lives in sim/init.lua, which requires THIS module -- so
    -- reaching up to it from here would be a cycle. An accumulator keeps
    -- the dependency pointing one way: ants put deliveries in, and the
    -- sim takes them out once per tick.
    banked = {},
  }
  for i = 1, M.cfg.maxAgents do
    a.pool[i] = {
      side = M.YOU,
      -- Exactly one of these is set: `at` (idling in orbit) or
      -- from/to/t (walking a straight line between two nodes).
      at = nil,
      from = nil, to = nil, t = 0,
      -- "rim" = walking round its mound to the gate; "cross" = out in
      -- the open on the single line between the two mounds.
      stage = nil,
      -- Where it is ULTIMATELY headed. `to` is only the next mound on the
      -- way; a long order is a chain of legs through the network.
      goal = nil,
      -- Where it actually left from, so a squad leaving a ring spreads
      -- into a column rather than a blob.
      sx = 0, sy = 0,
      -- WHAT IT IS CARRYING HOME, in food. nil = empty-handed. A laden
      -- ant walks to the nearest queened mound and banks it there.
      carry = nil,
      -- WANDER STATE, for an ant idling at a mound. It walks a slow
      -- random path over the mound rather than orbiting a fixed ring: a
      -- perfect circle of bodies reads as a UI element, and an ant farm
      -- reads as ants MILLING.
      phase = 0, orbit = 1.5,
      wx = 0, wy = 0,        -- current wander target, in mound-radius units
      wt = 0,                -- seconds until it picks a new one
      x = 0, y = 0, dir = 0,
      speed = 1,
      -- COMBAT. An ant is not a one-shot token any more: it has hit points
      -- and it trades blows once a second until one side falls over.
      --
      -- `atk` and `def` are per-ant MULTIPLIERS, and they exist so the
      -- offensive/defensive upgrades this game will want later are a number
      -- on the ant rather than a rewrite of the fight: an upgrade raises
      -- atk (harder hits) or def (hits land softer), and everything below
      -- reads them without knowing where they came from.
      hp = M.cfg.maxHp,
      atk = 1, def = 1,
      fightT = 0,            -- seconds until this ant's next swing
    }
  end
  return a
end

function M.spawn(a, nodeId, side)
  if a.n >= M.cfg.maxAgents then return nil end
  a.n = a.n + 1
  local ant = a.pool[a.n]
  ant.side = side or M.YOU
  ant.at, ant.from, ant.to, ant.t = nodeId, nil, nil, 0
  ant.stage, ant.goal = nil, nil
  -- THE POOL RECYCLES BODIES. A dead ant's fields survive in the slot
  -- until it is reused, so a stale `carry` here would be free food
  -- appearing out of a corpse -- and stale HP would hatch a larva that is
  -- already half dead, which is the same bug wearing armour.
  ant.carry = nil
  ant.hp = M.cfg.maxHp
  ant.atk, ant.def = 1, 1
  ant.fightT = a.rng() * M.cfg.swingPeriod   -- swings desynchronised
  ant.phase = a.rng() * 6.28318
  ant.orbit = M.cfg.orbitMin + a.rng() * (M.cfg.orbitMax - M.cfg.orbitMin)
  ant.speed = 0.85 + a.rng() * 0.3
  local wa = a.rng() * 6.28318
  local wr = M.cfg.wanderInner
             + a.rng() * (M.cfg.wanderOuter - M.cfg.wanderInner)
  ant.wx, ant.wy = math.cos(wa) * wr, math.sin(wa) * wr
  ant.wt = a.rng() * 2.0
  local n = a.world.node[nodeId]
  -- A NEW WORKER COMES UP OUT OF THE CHAMBER, not out of a point.
  --
  -- Spawning on the mound's exact centre made every hatchling FLOAT
  -- OUTWARD IN A SPIRAL: the milling code walks an ant toward the lane
  -- target its `phase` picks out on the perimeter, and `phase` keeps
  -- advancing round the circle while the ant is still crossing the radius.
  -- A point travelling outward while its target rotates traces a spiral --
  -- so a hatch read as something drifting up out of the middle rather than
  -- an ant climbing out of a nest and joining the traffic.
  --
  -- Born ON its lane instead, at a small inner radius: it starts where the
  -- milling rule already wants it to be, so the very first step it takes is
  -- an ordinary walk round the ring. `phase` is already random per ant
  -- (above), so hatchlings still come up all over the mound rather than
  -- from one door.
  --
  -- Inside the wander band rather than on it, because a worker that has
  -- just climbed out should still drift outward into the procession -- a
  -- short honest walk, not a spiral.
  local br = n.radius * (M.cfg.orbitMin * 0.75)
  ant.x = n.x + math.cos(ant.phase) * br
  ant.y = n.y + math.sin(ant.phase) * br
  -- FACING THE WAY IT WILL WALK, so its first frame is not a pivot. The
  -- lane is a circle, so that is the tangent at its own phase, turned the
  -- way this mound circulates.
  ant.dir = ant.phase + 1.5708 * (n.spin or 1)
  a.born = a.born + 1
  return ant
end

local function kill(a, i)
  local ant = a.pool[i]
  a.died = a.died + 1
  a.pool[i] = a.pool[a.n]
  a.pool[a.n] = ant
  a.n = a.n - 1
end
M.kill = kill

-- How many of a side's ants are sitting at a node. This is the number the
-- player spends; ants in transit belong to nobody yet.
function M.garrison(a, nodeId, side)
  side = side or M.YOU
  local c = 0
  for i = 1, a.n do
    local ant = a.pool[i]
    if ant.at == nodeId and ant.side == side then c = c + 1 end
  end
  return c
end

-- ── spending bodies ────────────────────────────────────────────────────
-- EAT `count` ANTS OFF A MOUND, and hand back what they were carrying.
--
-- ONE COPY, because there were three: the player's queen, the player's
-- upgrade and the rival's queen each had their own backwards loop over
-- the pool. Three copies of a rule is three places for it to drift, and
-- the food-banking rule below has to hold in all of them -- ten laden
-- ants spent on a queen must not take their food to the grave.
--
-- Returns spent, banked. Iterates BACKWARD because `kill` is a
-- swap-remove: going forward skips an ant every time one dies.
function M.spend(a, nodeId, side, count)
  local spent, banked = 0, 0
  for i = a.n, 1, -1 do
    if spent >= count then break end
    local ant = a.pool[i]
    if ant.at == nodeId and ant.side == side then
      if ant.carry then banked = banked + ant.carry end
      kill(a, i)
      spent = spent + 1
    end
  end
  return spent, banked
end

-- Standing here PLUS on the way here. What the player is watching arrive
-- is theirs already, and a badge that ignores the column in flight reads
-- as ants vanishing -- which is exactly how "12 ants became 4" looked.
function M.garrisonIncoming(a, nodeId, side)
  side = side or M.YOU
  local c = 0
  for i = 1, a.n do
    local ant = a.pool[i]
    if ant.side == side and (ant.at == nodeId or ant.to == nodeId) then
      c = c + 1
    end
  end
  return c
end

-- ── the one order ──────────────────────────────────────────────────────
-- Send `count` ants from a node to another in its RANGE. The gesture is
-- drag-from-centre with a quantity, so the count is explicit: how much to
-- commit is the whole decision in the game.
function M.send(a, fromId, toId, count, side)
  side = side or M.YOU
  local world = a.world
  -- EITHER END MAY BE A LOCATION. Looking these up in `world.node` alone
  -- made every send to a patch of food return "no such place" -- the
  -- intent was emitted, the path existed, and the order was dropped on
  -- the floor with ok=false. Food you can see, aim at, and not walk to.
  local from, to = W.site(world, fromId), W.site(world, toId)
  if not from or not to or fromId == toId then return 0 end
  if from.owner ~= side then return 0 end
  -- ANYWHERE THE NETWORK CONNECTS, not just one hop.
  --
  -- A mound's radius says where its ants can go IN ONE LEG; travelling
  -- further means a chain of mounds, each leg inside the radius of the
  -- mound it starts from. Refusing anything out of the source's own
  -- radius made the player hand-relay every long move, one send per hop,
  -- which is bookkeeping rather than a decision. The order is now "go
  -- there" and the ants walk the path.
  if not W.path(world, fromId, toId, side) then return 0 end

  local sent = 0
  for i = 1, a.n do
    if sent >= count then break end
    local ant = a.pool[i]
    if ant.at == fromId and ant.side == side then
      -- THEY WALK ROUND THE MOUND TO THE GATE, THEN CROSS.
      --
      -- Every ant leaving a mound uses the same departure point: the spot
      -- on the perimeter nearest the target. So an ant on the far side
      -- has to walk round the rim first, which strings the column out
      -- naturally, and the open ground between two mounds carries ONE
      -- line of traffic rather than a fan of private trajectories. (A
      -- straight line from each ant's own position looked like a shotgun
      -- blast and made two mounds read as connected by a smear.)
      -- `goal` is where it is ultimately headed; `to` is only the next
      -- mound on the way. On arrival it re-asks the network for the next
      -- leg, so a squad re-routes if the map changes under it.
      ant.goal = toId
      ant.from, ant.to = fromId, W.nextHop(world, fromId, toId, side) or toId
      ant.stage = "rim"           -- walking round to the gate
      ant.t = 0
      ant.at = nil
      sent = sent + 1
    end
  end
  a.sent = a.sent + sent
  return sent
end

function M.bank(a, side, v)
  if not v or v == 0 then return end
  a.banked[side] = (a.banked[side] or 0) + v
end

-- The sim sweeps this once a tick and adds it to the pool.
function M.takeBanked(a, side)
  local v = a.banked[side] or 0
  a.banked[side] = 0
  return v
end

-- ── carrying food home ─────────────────────────────────────────────────
-- THE NEAREST QUEEN, by hops and then by distance. A larva is laid where
-- a queen is, so food has to reach one; anywhere else it is just a
-- crumb in a corridor.
local function nearestQueenedMound(a, fromId, side)
  local world = a.world
  local best, bestHops, bestD = nil, math.huge, math.huge
  local origin = W.site(world, fromId)
  for i = 1, #world.nodes do
    local n = world.nodes[i]
    if n.owner == side and #(n.queens or {}) > 0 then
      if n.id == fromId then return n.id end
      local p = W.path(world, fromId, n.id, side)
      if p then
        local hops = #p - 1
        local d = origin and W.dist(origin, n) or 0
        if hops < bestHops or (hops == bestHops and d < bestD) then
          best, bestHops, bestD = n.id, hops, d
        end
      end
    end
  end
  return best
end

-- Point a laden ant at the nearest queen and start it walking. Returns
-- true if it found somewhere to go.
local function dispatchCarrier(a, ant)
  local world = a.world
  local hereId = ant.at
  if not hereId then return false end
  local dest = nearestQueenedMound(a, hereId, ant.side)
  if not dest then return false end
  if dest == hereId then
    -- Already standing on a queen: bank it where it stands.
    return "here"
  end
  local nxt = W.nextHop(world, hereId, dest, ant.side)
  if not nxt then return false end
  ant.goal = dest
  ant.from, ant.to = hereId, nxt
  ant.at, ant.stage, ant.t = nil, "rim", 0
  return true
end
M.dispatchCarrier = dispatchCarrier

function M.update(a, dt)
  local world = a.world
  local i = 1
  while i <= a.n do
    local ant = a.pool[i]
    local dead = false

    if ant.at then
      -- IDLING: WALK AROUND THE MOUND. Each ant picks a spot on the mound
      -- and ambles toward it, then picks another -- so a garrison looks
      -- like an ant farm rather than a ring of dots on a circle. (An
      -- orbit was the first attempt and it read as a UI element: forty
      -- ants evenly spaced on a perfect circle is a progress meter, not a
      -- colony.) The count is still legible because they spread out.
      local n = W.site(world, ant.at)

      -- IT PICKS UP WHATEVER IS UNDER ITS FEET, the instant it is there.
      -- No work cycle, no timer: an ant that shows up where there is
      -- grain takes a grain. One ant, one item, and the item leaves the
      -- ground at pickup so two ants never carry the same aphid home.
      if n and n.isLoc and not ant.carry and n.owner == ant.side
         and (n.items or 0) > 0 then
        n.items = n.items - 1
        ant.carry = n.value or 1
        a.picked = (a.picked or 0) + 1
        a.pickedBy[ant.side] = (a.pickedBy[ant.side] or 0) + 1
      end

      -- LADEN: take it to the nearest queen. This is the ONE piece of
      -- movement the player did not order, and it is the shortest one
      -- possible -- there and back, then it stays. It does NOT return for
      -- more. A colony that re-forages on its own is the errand loop this
      -- game deleted: "a shit ton of ants going back and forth", most of
      -- the motion on screen and none of it yours. Collecting again is a
      -- send, like everything else.
      if ant.carry then
        ant.think = (ant.think or 0) - dt
        if ant.think <= 0 then
          ant.think = 1.0
          local r = dispatchCarrier(a, ant)
          if r == "here" then
            M.bank(a, ant.side, ant.carry)
            ant.carry = nil
          end
          -- NOWHERE TO TAKE IT: keep hold of it and ask again in a
          -- second. A colony with no queen anywhere still has its food,
          -- on the legs of the ant that found it, ready for the moment
          -- one is raised.
        end
      end

      if n then
        -- THEY CIRCULATE THE PERIMETER, in the mound's own direction.
        -- Each ant walks its own lane at its own pace, so the ring is a
        -- procession of individuals rather than a rigid wheel -- and a
        -- clockwise mound beside an anticlockwise one reads as two
        -- colonies rather than one pattern repeated.
        --
        -- (Wandering to random spots was the previous attempt: it looked
        -- like milling but never resolved into a ring around the hill.)
        ant.phase = ant.phase + dt * M.cfg.circulate * ant.speed * (n.spin or 1)
        -- A slow breathe in and out of the lane, so the band is alive
        -- rather than a drawn circle.
        ant.wt = ant.wt - dt
        if ant.wt <= 0 then
          ant.orbit = M.cfg.wanderInner
                      + a.rng() * (M.cfg.wanderOuter - M.cfg.wanderInner)
          ant.wt = 2.5 + a.rng() * 4.0
        end
        local r = n.radius * ant.orbit
        local tx = n.x + math.cos(ant.phase) * r
        local ty = n.y + math.sin(ant.phase) * r
        local dx, dy = tx - ant.x, ty - ant.y
        local d = math.sqrt(dx * dx + dy * dy)
        local px, py = ant.x, ant.y
        if d > 0.4 then
          local v = M.cfg.wanderSpeed * ant.speed * dt
          if v > d then v = d end
          ant.x = ant.x + dx / d * v
          ant.y = ant.y + dy / d * v
        end
        -- Face along the walk, so the procession looks like it is going
        -- somewhere. Derived from the step actually taken rather than from
        -- `phase`: the ant chases its lane target instead of sitting on it,
        -- so the tangent of the lane is not the heading of the ant, and
        -- re-rolling the target used to snap the body without moving it.
        M.face(ant, px, py, dt)
      end
    else
      local from, to = W.site(world, ant.from), W.site(world, ant.to)
      if not from or not to then
        dead = true
      elseif ant.stage == "rim" then
        -- ROUND THE RIM to the gate: the point on this mound's perimeter
        -- that faces the target. Short way round, so nobody doubles back.
        local ga = math.atan(to.y - from.y, to.x - from.x)
        local gr = from.radius * M.cfg.gateRing
        local gx = from.x + math.cos(ga) * gr
        local gy = from.y + math.sin(ga) * gr
        local dx, dy = gx - ant.x, gy - ant.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d < 2 then
          ant.stage = "cross"
          ant.sx, ant.sy = ant.x, ant.y
          ant.t = 0
        else
          -- Walk along the rim rather than across the mound: step the
          -- angle toward the gate and keep the radius.
          local cur = math.atan(ant.y - from.y, ant.x - from.x)
          local diff = (ga - cur + math.pi) % 6.28318 - math.pi
          local stepA = M.cfg.rimSpeed * dt * ant.speed
          if math.abs(diff) <= stepA then
            cur = ga
          else
            cur = cur + (diff > 0 and stepA or -stepA)
          end
          -- Ease outward to the gate ring as it goes.
          local curR = math.sqrt((ant.x - from.x) ^ 2 + (ant.y - from.y) ^ 2)
          local nr = curR + (gr - curR) * math.min(1, dt * 2.2)
          local px, py = ant.x, ant.y
          ant.x = from.x + math.cos(cur) * nr
          ant.y = from.y + math.sin(cur) * nr
          -- Along the arc it just walked. The old tangent took its sign
          -- from which way round the gate still was, so an ant rounding a
          -- mound whose spin opposed that turn flipped a full 180.
          M.face(ant, px, py, dt)
        end
      else
        -- CROSSING the open ground, from the gate to the target.
        local ox = ant.sx or from.x
        local oy = ant.sy or from.y
        local dx, dy = to.x - ox, to.y - oy
        local dist = math.sqrt(dx * dx + dy * dy)
        local v = M.cfg.speed * ant.speed * (from.speedStat or 1)
        ant.t = ant.t + (v * dt) / math.max(1, dist)
        if ant.t >= 1 then
          local dest = to
          a.arrived = a.arrived + 1
          if dest.owner == ant.side then
            ant.at, ant.from, ant.to = ant.to, nil, nil
            ant.stage = nil
            ant.phase = (ant.phase + 1.1) % 6.28318
            -- HOME WITH THE SHOPPING. Any queen will do -- if the road
            -- home passes one, the food goes in there rather than being
            -- walked further for no reason.
            --
            -- Only a delivery clears the goal. An intermediate mound with
            -- no queen must leave the journey alone: clearing it here
            -- stranded every carrier on the first stepping stone it
            -- crossed, one hop into a two-hop walk.
            if ant.carry and not dest.isLoc
               and #(dest.queens or {}) > 0 then
              M.bank(a, ant.side, ant.carry)
              ant.carry = nil
              ant.goal = nil
              ant.think = 0
              a.delivered = (a.delivered or 0) + 1
              a.deliveredBy[ant.side] = (a.deliveredBy[ant.side] or 0) + 1
            end
            -- STILL TRAVELLING? Take the next leg. This is what makes a
            -- long order one order: the ant hops mound to mound until it
            -- is actually where it was sent.
            if ant.goal and ant.goal ~= ant.at then
              local nxt = W.nextHop(world, ant.at, ant.goal, ant.side)
              if nxt then
                -- PASSING THROUGH IS NOT ARRIVING.
                --
                -- A leg ends at `t >= 1`, which puts the ant on the
                -- mound's exact CENTRE. For an ant that stops here that is
                -- fine -- the milling rule walks it out to the ring. But an
                -- ant only changing trains got sent straight back into the
                -- "rim" stage from that centre point, so it walked a full
                -- arc from the middle of the hill out to the next gate:
                -- a visible detour into the centre and back out, on a
                -- journey that should read as one continuous march.
                --
                -- Measured: transiting ants arrived at x=0,y=0 (the hub's
                -- centre) on every hop of a two-leg order.
                --
                -- A traveller crosses the mound instead. It keeps the
                -- position it actually has and goes straight for the next
                -- gate, so a long order looks like a column walking THROUGH
                -- a waypoint rather than stopping to tour it.
                -- It walks on from WHERE IT IS. The arrival put it on
                -- the mound's centre (a leg ends at t>=1, which is the
                -- destination point exactly), and the next leg is a
                -- straight crossing from that position to the next gate.
                -- Starting the crossing here means the ant continues in
                -- one motion -- in at one side, out at the other -- with
                -- no arc around a hill it is not stopping at.
                --
                -- BUT ONLY IF IT HAS NO BUSINESS HERE. Skipping the "at"
                -- frame entirely is what the pickup rule reads to decide
                -- whether an ant is standing on food (see `n.isLoc` above),
                -- so a route that happened to run over a grain patch used
                -- to harvest it in passing and now walked straight over the
                -- top: test-war caught it as rivals whose food never left
                -- the ground (items 24 -> 25, i.e. regrowth only).
                --
                -- So a waypoint it could take something from is a stop, not
                -- a pass -- it gets its frame, picks up, and leaves next
                -- tick like any other arrival.
                ant.from, ant.to = ant.at, nxt
                ant.at, ant.stage, ant.t = nil, "rim", 0
              else
                ant.goal = nil     -- unreachable now; stand down here
              end
            else
              ant.goal = nil
            end
          elseif dest.isLoc and (dest.guard or 0) > 0 then
            -- SHE IS GUARDED. The spider is checked before anything else
            -- about the place, so "claimed but still guarded" is a state
            -- that cannot exist rather than one that has to be handled.
            --
            -- Six defenders wearing one body: every ant that reaches her
            -- trades itself for one hit, which is the same bargain as
            -- attacking a defended mound. When she falls, the legs are
            -- lying there to be carried off.
            dest.guard = dest.guard - 1
            if dest.guard <= 0 then
              dest.guard = 0
              dest.owner = ant.side
              dest.items = math.max(dest.items or 0, dest.spoils or 0)
              ant.at, ant.from, ant.to = ant.to, nil, nil
              ant.stage, ant.goal = nil, nil
            else
              dead = true
            end
          elseif dest.owner == nil then
            -- Taking a mound en route is fine, and it ends the journey:
            -- an ant that has just claimed ground stays to hold it.
            dest.owner = ant.side
            ant.at, ant.from, ant.to = ant.to, nil, nil
            ant.stage, ant.goal = nil, nil
          else
            -- HOSTILE GROUND: LAND AND FIGHT.
            --
            -- This used to resolve on the spot -- the arriving ant killed
            -- one defender and died with it, or chipped one point off the
            -- mound's energy and died. A battle was therefore instantaneous
            -- subtraction: nothing to watch, nothing to reinforce, and no
            -- difference between sending thirty ants and thirty-one.
            --
            -- Now the attacker simply ARRIVES, and the fighting is done in
            -- M.fight() over the following seconds. It stands on ground it
            -- does not own, which is exactly the state combat resolves.
            ant.at, ant.from, ant.to = ant.to, nil, nil
            ant.stage, ant.goal = nil, nil
            ant.phase = ant.phase + 1.1
          end
        else
          local px, py = ant.x, ant.y
          ant.x = ox + dx * ant.t
          ant.y = oy + dy * ant.t
          -- Same rule as everywhere else. The heading is constant across
          -- the whole crossing, so this only ever has work to do on the
          -- first frame -- easing the 90-degree turn out of the rim's
          -- tangent into the line of march instead of snapping it.
          M.face(ant, px, py, dt)
        end
      end
    end

    if dead then kill(a, i) else i = i + 1 end
  end
end

-- ── COMBAT ─────────────────────────────────────────────────────────────
--
-- Ants standing on the same mound with different colours fight, once a
-- second each, until one colour is gone. Then whoever is left standing on
-- ground they do not own takes it.
--
-- WHY DICE RATHER THAN ARITHMETIC. A deterministic trade (one attacker
-- kills one defender) makes every battle a subtraction you can do in your
-- head before you order it, which is the same as having no battle. A swing
-- that lands half the time for 2 or 3 makes a single duel genuinely
-- uncertain -- and because both sides draw from the SAME distribution, the
-- larger army still wins on average by the law of large numbers. Ten ants
-- against five is not a coin flip; ten against nine is a real question.
--
-- DETERMINISM IS PRESERVED. Every roll comes from the injected RNG
-- (`a.rng`), never math.random and never a clock, so the same seed and the
-- same orders still replay identically -- which the longrun/determinism
-- gates check.
--
-- `atk` and `def` are read off the ANT, so a future offensive or defensive
-- upgrade is a multiplier on a body and needs no change here.
function M.fight(a, dt)
  local cfg = M.cfg
  -- Group the combatants by the mound they are standing on. Only ants that
  -- are AT a site fight: a column in transit is not in the battle yet, which
  -- is what makes arriving reinforcements feel like arriving reinforcements.
  local byNode = {}
  for i = 1, a.n do
    local ant = a.pool[i]
    if ant.at then
      local g = byNode[ant.at]
      if not g then g = {}; byNode[ant.at] = g end
      g[#g + 1] = i
    end
  end

  -- ORDERED, not `pairs`. Iteration order of a plain table is not part of
  -- Lua's contract, and rolling dice in a different order for the same seed
  -- would break replay -- the one way randomness can leak determinism.
  local ids = {}
  for id in pairs(byNode) do ids[#ids + 1] = id end
  table.sort(ids)

  for k = 1, #ids do
    local group = byNode[ids[k]]
    -- Is there more than one side here at all? The overwhelming majority of
    -- mounds are peaceful, so this cheap check keeps the whole system free
    -- when nothing is happening.
    local firstSide, mixed = nil, false
    for gi = 1, #group do
      local s = a.pool[group[gi]].side
      if not firstSide then firstSide = s
      elseif s ~= firstSide then mixed = true; break end
    end
    if mixed then
      for gi = 1, #group do
        local ant = a.pool[group[gi]]
        if ant.hp and ant.hp > 0 then
          ant.fightT = (ant.fightT or 0) - dt
          if ant.fightT <= 0 then
            ant.fightT = (ant.fightT or 0) + cfg.swingPeriod
            -- STRIKE THE NEAREST ENEMY, not the first one in the list.
            --
            -- Picking by pool order made the fight non-spatial: an ant on
            -- the far rim could be hitting a body on the opposite side of
            -- the mound while an enemy stood on its head. Nearest means the
            -- battle happens WHERE THE ANTS ARE -- a column arriving on one
            -- side engages that side, the fighting visibly concentrates at
            -- the point of contact, and a flanking send is a real move
            -- rather than a relabelled reinforcement.
            --
            -- Ties resolve by pool index (the `<` keeps the first found),
            -- so this stays deterministic for a given seed.
            local target, bestD = nil, math.huge
            for tj = 1, #group do
              local t = a.pool[group[tj]]
              if t.side ~= ant.side and t.hp and t.hp > 0 then
                local ddx, ddy = t.x - ant.x, t.y - ant.y
                local d2 = ddx * ddx + ddy * ddy
                if d2 < bestD then target, bestD = t, d2 end
              end
            end
            if target then
              -- HALF THE SWINGS MISS. The other half land for 2 or 3,
              -- scaled by the attacker's atk and the target's def.
              if a.rng() < cfg.hitChance then
                local roll = cfg.hitMin
                          + math.floor(a.rng() * (cfg.hitMax - cfg.hitMin + 1))
                local dmg = roll * (ant.atk or 1) / (target.def or 1)
                target.hp = target.hp - dmg
                -- A LANDED HIT IS AN EVENT THE MIX WANTS. Counted rather
                -- than played here, because sim/ must never touch audio --
                -- the audio layer reads the delta each frame and rate-limits
                -- it into clanks. (A per-hit callback would put a
                -- love.audio call inside the simulation, which is the wall
                -- this whole codebase is built around.)
                a.hits = (a.hits or 0) + 1
              end
            end
          end
        end
      end
    end
  end

  -- Clear the dead. BACKWARD, because kill() is a swap-remove: forward
  -- iteration skips an ant every time one dies (the discipline this file
  -- documents at M.spend).
  for i = a.n, 1, -1 do
    local ant = a.pool[i]
    if ant.hp and ant.hp <= 0 then
      a.killedInFight = (a.killedInFight or 0) + 1
      kill(a, i)
    end
  end

  -- WHO HOLDS THE GROUND NOW. A mound flips when the last defender falls
  -- and somebody else is still standing on it. Energy is spent as the
  -- attackers dig in, so a fortified mound still costs more than an empty
  -- one -- it is just no longer the whole fight.
  local W = a.world
  for k = 1, #ids do
    local id = ids[k]
    local site = W.node and W.node[id]
    if site and site.owner then
      local defenders, attacker = 0, nil
      for i = 1, a.n do
        local ant = a.pool[i]
        if ant.at == id then
          if ant.side == site.owner then defenders = defenders + 1
          elseif not attacker then attacker = ant.side end
        end
      end
      if defenders == 0 and attacker then
        -- THE QUEEN IS THE MOUND. While she lives it is still theirs, however
        -- many enemy ants are standing on the surface -- so an established
        -- colony cannot be taken by walking in, only by digging her out.
        -- That is what makes a settled mound worth more than the dirt, and
        -- what gives a defender something to reinforce toward.
        local queens = site.queens
        if queens and #queens > 0 then
          -- Every attacker present chews on the nearest queen. She has five
          -- workers' worth of body (cfg.queenHp), so this is a real siege
          -- rather than a formality -- and the more ants you brought, the
          -- faster she falls, which is the pressure the whole assault is for.
          local swings = 0
          for i = 1, a.n do
            local ant = a.pool[i]
            if ant.at == id and ant.side ~= site.owner then
              ant.fightT = (ant.fightT or 0) - dt
              if ant.fightT <= 0 then
                ant.fightT = (ant.fightT or 0) + cfg.swingPeriod
                swings = swings + 1
                if a.rng() < cfg.hitChance then
                  local roll = cfg.hitMin
                            + math.floor(a.rng() * (cfg.hitMax - cfg.hitMin + 1))
                  local q = queens[1]
                  q.hp = (q.hp or cfg.queenHp) - roll * (ant.atk or 1)
                  a.hits = (a.hits or 0) + 1
                end
              end
            end
          end
          -- She falls, and her chamber with her. Removing her from the FRONT
          -- keeps the remaining queens' brood attribution stable (a larva
          -- records the index of the queen that laid it).
          if (queens[1].hp or 0) <= 0 then
            table.remove(queens, 1)
            a.queensKilled = (a.queensKilled or 0) + 1
            -- SHE IS A MEAL. A dead queen is the biggest single piece of
            -- food on the board -- more than an aphid, more than a spider's
            -- leg -- which is what makes storming a colony pay for the ants
            -- it cost rather than just denying them to somebody else.
            --
            -- Banked to the ATTACKER through the same accumulator a carried
            -- item uses, so it lands in their pool on the next sweep and the
            -- food ledger still closes.
            M.bank(a, attacker,
                   (attacker == M.YOU) and cfg.queenFood or cfg.queenFoodRivals)
            -- Her brood dies with her: there is nobody left to tend it.
            if #queens == 0 then site.brood = {} end
          end
        else
          -- NO QUEEN LEFT: now the ground itself changes hands. Energy is
          -- what an uncolonised position costs to dig into.
          site.energy = (site.energy or 0) - dt * 4
          if site.energy <= 0 then
            site.owner, site.energy = attacker, 0
          end
        end
      end
    end
  end
end

-- Food currently on legs. The ledger a forage gate balances against:
-- pool + carried + items still in the ground == everything ever grown.
function M.carried(a, side)
  local c = 0
  for i = 1, a.n do
    local ant = a.pool[i]
    if ant.carry and (not side or ant.side == side) then c = c + ant.carry end
  end
  return c
end

function M.stats(a)
  local mine, theirs, moving = 0, 0, 0
  for i = 1, a.n do
    local ant = a.pool[i]
    if ant.side == M.YOU then mine = mine + 1 else theirs = theirs + 1 end
    if not ant.at then moving = moving + 1 end
  end
  return a.n, mine, theirs, moving
end

function M.digest(a)
  local n, mine, theirs, moving = M.stats(a)
  return string.format("n=%d mine=%d theirs=%d moving=%d sent=%d born=%d died=%d",
    n, mine, theirs, moving, a.sent, a.born, a.died)
end

function M.positionHash(a)
  local h = 2166136261
  for i = 1, a.n do
    local ant = a.pool[i]
    h = (h + math.floor(ant.x) * 31 + math.floor(ant.y) * 17) % 4294967296
  end
  return h
end

return M
