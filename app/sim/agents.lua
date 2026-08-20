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
  -- SLOWED FROM 1.0 (plan 05): a battle you can watch, not a blur of
  -- invisible dice. At the old any-target 1s cadence nothing on screen
  -- explained who was winning; at 3s + the facing cone below, an ant
  -- spends most of a fight unable to strike, which is what makes the
  -- moment it CAN strike an event.
  swingPeriod  = 3.0,    -- seconds between an ant's attacks
  hitChance    = 0.5,    -- ...and how often one lands at all
  hitMin       = 2,      -- damage when it does land
  hitMax       = 4,      -- plan 05: was 3
  -- How close two ants have to be to trade blows, in mound radii. A fight
  -- happens AT the mound, so this only has to cover the ring the defenders
  -- mill in plus the arrivals pushing into it.
  fightRange   = 1.9,
  -- THE FACING CONE (plan 05). A target must be within this cosine of the
  -- attacker's current facing to be struck at all -- cos(45 deg), so a
  -- cone of 90 degrees TOTAL, +/-45 either side of `ant.dir`. No target in
  -- cone on a swing means the swing is FORFEIT (the timer still resets):
  -- that is the rule working, not a bug. You strike when the march brings
  -- someone across your face. See M.battleSpin for why this cannot
  -- deadlock: the two sides are marched in OPPOSING directions, which
  -- guarantees every pair closes and passes.
  hitArcDot    = 0.7071067811865476,   -- cos(45 deg)
  -- A DEAD ANT LEAVES A BODY (plan 05). Head and abdomen come apart
  -- within a blast radius of 2x the ant's drawn size, and fade over this
  -- many seconds before they are swept from `a.corpses`. Sim owns the
  -- lifetime (a.corpses is state, serialized in save v6); the renderer
  -- owns turning a seed into a scatter -- see render/ants.lua.
  -- Raised from 10 to 20 (Luis, 2026-08-19): bodies were fading before a
  -- player looking at the fight had time to register them.
  corpseLife   = 20.0,
  -- Hard cap on how many corpses `a.corpses` holds at once, oldest first.
  -- A long war must not grow the save file without bound. If this ever
  -- trips it is logged (a.corpsesDropped), never silently swallowed.
  corpseCap    = 96,
  -- ── THE SPIDER (plan 05) ────────────────────────────────────────────
  -- She is not a toll booth: a subdual fight. Eight ants pin her eight
  -- legs by their pincers; only while ALL eight are held can anyone else
  -- land a hit. She kills one engaged ant every spiderKillPeriod seconds,
  -- guaranteed -- no dice -- and (Luis, 2026-08-18) she goes for whoever
  -- is STABBING her first: only when no strikers remain does she start
  -- tearing leg-holders off, which frees the leg and un-subdues her.
  -- See M.fightSpider.
  --
  -- THREE SECONDS, NOT SIX (Luis, 2026-08-20: "the spider can attack a
  -- little faster than 6 seconds, lets say 3 seconds"). At six she was
  -- subdued and whittled down on a clock the player never felt any
  -- pressure from; doubling her rate makes a swarm that arrives piecemeal
  -- actually cost something, without touching her 20 hp or the eight-leg
  -- pin that makes the fight a fight.
  -- MUST EQUAL world.lua's LKINDS.spider.killPeriod, which seeds her
  -- first countdown while this drives every kill after it. test-spider
  -- asserts the two agree, because a mismatch is invisible in play: only
  -- the first kill is early or late.
  spiderKillPeriod = 3.0,
  spiderHp     = 20,
  spiderLegs   = 8,
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
    -- DEAD BODIES (plan 05). Each entry is
    -- { x, y, side, t, seed, at } -- position and side captured at the
    -- moment of death (BEFORE the swap-remove in `kill`), a seed rolled
    -- once here so the renderer never re-rolls the scatter, and `t`
    -- ticking up to cfg.corpseLife before the entry is dropped.
    corpses = {},
    corpsesDropped = 0,
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
  -- SAME TRAP, FOUND LIVE 2026-08-19: `carryQueen` is a per-ant render
  -- flag added for the queen-carry-home feature, and it has the exact
  -- shape this comment already warns about -- a hatchling spawned into a
  -- recycled slot inherited a stale `carryQueen = true` from whichever
  -- corpse used to occupy it, so a brand-new worker that had never
  -- touched a queen's body rode the dead-queen carry art forever
  -- (measured: `carryingQueen` stuck at 1 in the `@m` line long after
  -- the real delivery finished and the actual carrier had `carry = nil`
  -- -- a DIFFERENT ant, a fresh hatch, had picked up the stale flag).
  ant.carryQueen = nil
  ant.carryQueenSide = nil
  ant.siegeClose = nil
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

-- A BODY, LEFT WHERE IT FELL (plan 05). Called with values already read
-- off the ant -- see the call site in M.fight, which reads them before
-- `kill` swap-removes the slot; calling this AFTER kill() would capture
-- whatever ant got swapped into that index instead of the one that died.
--
-- The seed is rolled HERE, once, from the injected RNG -- never at draw
-- time. render/ants.lua turns it into a head/abdomen scatter; nothing
-- about the scatter may vary frame to frame, or two players watching the
-- same replay would see different corpses.
function M.pushCorpse(a, x, y, side, at)
  local list = a.corpses
  if #list >= M.cfg.corpseCap then
    -- OLDEST FIRST, and COUNTED rather than silently dropped -- a long
    -- war must not grow the save without bound, but a cap that trims
    -- invisibly is exactly the kind of silent truncation the gates exist
    -- to catch. A gate asserts on a.corpsesDropped if this ever trips.
    table.remove(list, 1)
    a.corpsesDropped = (a.corpsesDropped or 0) + 1
  end
  list[#list + 1] = { x = x, y = y, side = side, at = at, t = 0,
                       seed = math.floor(a.rng() * 1e9) }
end

-- AGE AND SWEEP CORPSES. Called once a tick from M.update, same as any
-- other timer in this file -- never from render, which must stay a pure
-- function of state.
function M.tickCorpses(a, dt)
  local list = a.corpses
  local w = 1
  for r = 1, #list do
    local c = list[r]
    c.t = c.t + dt
    if c.t < M.cfg.corpseLife then
      list[w] = c
      w = w + 1
    end
  end
  for r = #list, w, -1 do list[r] = nil end
end

-- THE SPIDER (plan 05, section 6). Not a toll booth any more: eight ants
-- pin her eight legs by their pincers, and only while every leg is held
-- can anyone else land a hit on her 20 hp. She kills one engaged ant
-- every killPeriod seconds, guaranteed -- no dice -- and goes for
-- whoever is STABBING her first (ruling 1): only once no strikers
-- remain does she start tearing leg-holders off, which frees the leg
-- and un-subdues her.
--
-- Same split as M.fight(): this function decides what happens to bodies
-- ALREADY standing at her location (placed there by the arrival branch
-- in M.update, which simply lands an ant on her and does not resolve
-- anything). Determinism discipline matches M.fight throughout: sorted
-- ids, `a.rng` never `math.random`, corpses captured before `kill`.
function M.fightSpider(s, dt)
  local a, world = s.agents, s.world
  local cfg = M.cfg
  for li = 1, #world.locs do
    local l = world.locs[li]
    if l.kind == "spider" and not l.owner and l.hp then
      -- WHO IS HERE. Sorted by pool index for determinism, same as the
      -- mound fight's `ids`.
      local engaged = {}
      for i = 1, a.n do
        if a.pool[i].at == l.id then engaged[#engaged + 1] = i end
      end
      if #engaged > 0 then
        table.sort(engaged)

        -- 1. FILL LEGS. A holder that died last tick already had its
        -- slot cleared below; free legs claim the nearest engaged
        -- ant that is not ALREADY holding a different leg.
        local held = {}
        for leg = 1, cfg.spiderLegs do
          local holder = l.spiderLegs[leg]
          if holder and not (a.pool[holder] and a.pool[holder].at == l.id) then
            -- The holder left or died without going through the kill
            -- path below (should not happen, but a stale reference
            -- must not wedge a leg forever).
            l.spiderLegs[leg] = nil
          end
          if l.spiderLegs[leg] then held[l.spiderLegs[leg]] = true end
        end
        for leg = 1, cfg.spiderLegs do
          if not l.spiderLegs[leg] then
            for ei = 1, #engaged do
              local pid = engaged[ei]
              if not held[pid] then
                l.spiderLegs[leg] = pid
                held[pid] = true
                break
              end
            end
          end
        end

        -- 2. HER KILL. Guaranteed, on a clock -- no roll on whether it
        -- happens, only on WHO it takes.
        l.killT = (l.killT or cfg.spiderKillPeriod) - dt
        if l.killT <= 0 then
          l.killT = l.killT + cfg.spiderKillPeriod
          -- Strikers first (ruling 1): engaged ants NOT holding a leg.
          local strikers = {}
          for ei = 1, #engaged do
            if not held[engaged[ei]] then strikers[#strikers + 1] = engaged[ei] end
          end
          local pool = (#strikers > 0) and strikers or engaged
          if #pool > 0 then
            local victim = pool[1 + math.floor(a.rng() * #pool)]
            local ant = a.pool[victim]
            if ant then
              -- Free the leg she was holding, if any, so the subdued
              -- check below reads the post-kill state.
              for leg = 1, cfg.spiderLegs do
                if l.spiderLegs[leg] == victim then l.spiderLegs[leg] = nil end
              end
              M.pushCorpse(a, ant.x, ant.y, ant.side, ant.at)
              kill(a, victim)
              a.killedInFight = (a.killedInFight or 0) + 1
              -- The pool index `victim` may now hold a swapped-in ant
              -- (kill() is a swap-remove); `engaged`'s remaining
              -- entries were captured before this and are stale for
              -- indices >= victim, but this tick's striking pass below
              -- re-reads `a.pool` by id by index, so a stale id pointing
              -- at the swapped body is corrected the same way M.fight's
              -- forward references already tolerate -- see the note on
              -- `held` being rebuilt next tick regardless.
            end
          end
        end

        -- 3. SUBDUED = every leg held THIS tick, after both the fill and
        -- the kill above. Only then do non-holders strike her.
        local subdued = true
        for leg = 1, cfg.spiderLegs do
          if not l.spiderLegs[leg] then subdued = false; break end
        end
        if subdued then
          for ei = 1, #engaged do
            local pid = engaged[ei]
            local ant = a.pool[pid]
            if ant and ant.at == l.id and not held[pid] then
              ant.fightT = (ant.fightT or 0) - dt
              if ant.fightT <= 0 then
                ant.fightT = ant.fightT + cfg.swingPeriod
                a.swings = (a.swings or 0) + 1
                if a.rng() < cfg.hitChance then
                  local roll = cfg.hitMin
                            + math.floor(a.rng() * (cfg.hitMax - cfg.hitMin + 1))
                  local dmg = roll * (ant.atk or 1)
                  l.hp = l.hp - dmg
                  a.hits = (a.hits or 0) + 1
                  if not a.dmgMin or roll < a.dmgMin then a.dmgMin = roll end
                  if not a.dmgMax or roll > a.dmgMax then a.dmgMax = roll end
                end
              end
            end
          end
        end

        -- 4. SHE DIES. Every leg-holder and striker present stands down
        -- onto the now-claimed ground, same as a mound's ground-flip.
        if l.hp <= 0 then
          l.hp = 0
          l.owner = a.pool[engaged[1]] and a.pool[engaged[1]].side or nil
          l.items = math.max(l.items or 0, l.spoils or 0)
          l.spiderLegs = {}
          for ei = 1, #engaged do
            local ant = a.pool[engaged[ei]]
            if ant and ant.at == l.id then
              ant.at, ant.from, ant.to = l.id, nil, nil
              ant.stage, ant.goal = nil, nil
            end
          end
        end

        -- A FIGHT IS NEVER A SECRET (plan 04): the location reveals like
        -- a contested mound while ants are engaged with her.
        l.contested = true
      end
    end
  end
end

-- WITHDRAWAL, WITH PARTING SHOTS (plan 05, section 6c). Pulling a side's
-- engaged ants off the spider and walking them to a reachable site.
-- A separate function from M.send, not a special case inside it: M.send
-- refuses any `from` the side does not OWN (`from.owner ~= side`), and a
-- spider location is never owned while she lives -- that gate is exactly
-- right for ordinary sends and exactly wrong here, which is why plan 04
-- flagged a fighting column as unselectable in the first place. This is
-- the selectability fix, scoped to spider locations only, the plan asks
-- for -- mound battles get no such path (still Open).
--
-- Returns the count that survives to walk out (0 if nothing was engaged
-- or no route exists), matching M.send's contract so the caller can
-- refuse the same way a failed send does.
function M.withdrawFromSpider(a, spiderId, toId, side)
  local world = a.world
  local l = W.site(world, spiderId)
  local to = W.site(world, toId)
  if not l or l.kind ~= "spider" or not to or spiderId == toId then return 0 end
  if not W.path(world, spiderId, toId, side) then return 0 end

  -- Everyone of this side currently engaged, sorted for determinism --
  -- same discipline as M.fight and M.fightSpider throughout this plan.
  local engaged, holders = {}, {}
  for i = 1, a.n do
    local ant = a.pool[i]
    if ant.at == spiderId and ant.side == side then engaged[#engaged + 1] = i end
  end
  if #engaged == 0 then return 0 end
  table.sort(engaged)
  if l.spiderLegs then
    for leg = 1, M.cfg.spiderLegs do
      if l.spiderLegs[leg] then holders[l.spiderLegs[leg]] = true end
    end
  end

  -- THE PRICE: the moment withdrawal is ordered she gets ONE guaranteed
  -- parting kill, plus a second at 50% -- "a loss or two", exactly as
  -- asked (Luis, 2026-08-18) -- taken from the withdrawing ants, HOLDERS
  -- PREFERRED (ruling in section 6c: "they are the ones letting go in
  -- her face"). Rolled from `a.rng`, at the tick the order lands, so a
  -- replay withdraws the same bodies every time.
  local function partingVictimPool()
    local pool = {}
    for i = 1, #engaged do
      if holders[engaged[i]] then pool[#pool + 1] = engaged[i] end
    end
    if #pool == 0 then pool = engaged end
    return pool
  end
  local toKill = {}
  local kills = 1 + ((a.rng() < 0.5) and 1 or 0)
  for _ = 1, kills do
    -- Re-pool each kill so a second parting shot still prefers a
    -- REMAINING holder over a striker, not the first roll's snapshot.
    local pool = {}
    for i = 1, #engaged do
      local already = false
      for j = 1, #toKill do if toKill[j] == engaged[i] then already = true break end end
      if not already and holders[engaged[i]] then pool[#pool + 1] = engaged[i] end
    end
    if #pool == 0 then
      for i = 1, #engaged do
        local already = false
        for j = 1, #toKill do if toKill[j] == engaged[i] then already = true break end end
        if not already then pool[#pool + 1] = engaged[i] end
      end
    end
    if #pool > 0 then
      toKill[#toKill + 1] = pool[1 + math.floor(a.rng() * #pool)]
    end
  end

  -- Free every leg this side held (a striker never held one, so this is
  -- a no-op for them): the fight goes cold, exactly as the plan asks --
  -- survivors that re-engage later retake legs one by one, no discount.
  if l.spiderLegs then
    for leg = 1, M.cfg.spiderLegs do
      local holder = l.spiderLegs[leg]
      if holder then
        for i = 1, #engaged do
          if engaged[i] == holder then l.spiderLegs[leg] = nil; break end
        end
      end
    end
  end

  -- KILL THE MARKED FEW FIRST, by pool index descending, so an earlier
  -- swap-remove never invalidates a later index still to be processed
  -- (the same forward-reference discipline M.fightSpider's own kill
  -- call documents). Corpse captured before kill(), same as every other
  -- death in this file.
  table.sort(toKill, function(x, y) return x > y end)
  local killedSet = {}
  for i = 1, #toKill do
    local pid = toKill[i]
    local ant = a.pool[pid]
    if ant then
      M.pushCorpse(a, ant.x, ant.y, ant.side, ant.at)
      killedSet[pid] = true
      kill(a, pid)
    end
  end

  -- WALK THE SURVIVORS OUT. Re-scan rather than trust `engaged`: kill()
  -- is a swap-remove, so any index at or above the lowest killed index
  -- may now hold a different ant than when `engaged` was built.
  local sent = 0
  for i = 1, a.n do
    local ant = a.pool[i]
    if ant.at == spiderId and ant.side == side then
      ant.goal = toId
      ant.from, ant.to = spiderId, W.nextHop(world, spiderId, toId, side) or toId
      ant.stage = "rim"
      ant.t = 0
      ant.at = nil
      sent = sent + 1
    end
  end
  -- A FIGHT NEVER SECRET, one tick more: the withdrawal itself, and the
  -- parting kills that came with it, happen on ground that was already
  -- contested -- nothing to clear here, M.fightSpider's own scan drops
  -- `contested` on the next tick once nobody of either side remains.
  a.sent = a.sent + sent
  -- REPORTED ATOMICALLY, in the same call that ordered the withdrawal:
  -- hp is a fact of the fight up to and including this tick, engaged
  -- and kills describe what THIS order did to it -- test-spider #9
  -- reads this line rather than a before/after pair of separately-timed
  -- inspects, which the fight's own ongoing damage clock would
  -- contaminate (same reasoning as probe.lua's killholder/roundtrip
  -- snapshots).
  print(string.format(
    "@withdraw spider=%s engaged=%d kills=%d survivors=%d hp=%d",
    spiderId, #engaged, #toKill, sent, l.hp or 0))
  return sent
end

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

      -- A FALLEN QUEEN, THE SAME RULE (Luis, 2026-08-19: "you didn't
      -- carry queen's body back to hive"). `M.fight`'s siege loop sets
      -- `site.corpses`/`site.corpseValue` on a mound when a queen falls
      -- but nothing ever consumed them -- the body sat there forever,
      -- and the plan-05 note beside that code ("she leaves a BODY...
      -- carried home like anything else") was aspirational, not built.
      -- Picked up by the WINNING side, not `n.owner` -- a queen's death
      -- does not flip the mound (only the LAST queen falling, and then
      -- only after the energy grind in M.fight's queenless branch, does
      -- that), so `n.owner == ant.side` would never be true for the
      -- attacker who is actually standing over the body. One ant, one
      -- corpse, same as an item -- and the same `ant.carry` field feeds
      -- the ordinary dispatchCarrier/bank path below, so a queen's body
      -- makes the same walk-home trip any other prize does.
      --
      -- WORTH ZERO TO A RIVAL, ON PURPOSE (`cfg.queenFoodRivals = 0` --
      -- see formix-combat-hp-dice-and-queen-bounty.md: unbounded queen
      -- bounty to AI rivals snowballs). A rival killing the player's
      -- queen leaves a body nobody bothers to carry -- `n.corpseValue`
      -- is the gate, not `n.owner ~= ant.side` alone, so the corpse
      -- stays on the ground (a visible, honest "she fell here" marker)
      -- rather than being picked up and walked home for nothing.
      -- GUARDED ON HER SIDE, NOT ON WHO HOLDS THE GROUND (plan 06). This
      -- read `n.owner ~= ant.side`, which means "not the defender" only
      -- for as long as the mound has not changed hands -- and a mound
      -- whose queen just died is a mound about to change hands. The
      -- instant the attacker captures it, `n.owner` IS the attacker, and
      -- the guard starts refusing the very side that earned the body:
      -- the corpse then sits on your own new mound forever, uneaten.
      --
      -- Measured on gatesiege/gatesiege2 during plan 06's phase 0, the
      -- pickup happens to win that race (she dies and is lifted inside
      -- the same tick, before the capture lands), which is why the bug
      -- never showed in a gate -- but the ordering was luck, not a rule,
      -- and it inverts on any board where the last defender outlives her.
      -- `corpseSide` is set where she falls and does not move under us.
      if n and not n.isLoc and not ant.carry and n.corpses and n.corpses > 0
         and (n.corpseSide or n.owner) ~= ant.side
         and (n.corpseValue or 0) > 0 then
        n.corpses = n.corpses - 1
        ant.carry = n.corpseValue
        ant.carryQueen = true
        -- Her colony, for the renderer: a carried queen wears her OWN
        -- side's colour, not her carrier's.
        ant.carryQueenSide = n.corpseSide
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
            ant.carryQueen = nil
            ant.carryQueenSide = nil
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
        --
        -- WHILE THE MOUND IS AT WAR (plan 05), a side's OWN battleSpin
        -- overrides the mound's ordinary spin -- see M.fight, which rolls
        -- it once per battle and clears it once the fight ends. This is
        -- what feeds the facing cone: opposing spins guarantee every
        -- enemy pair closes and passes rather than orbiting in lockstep.
        local spin = (n.battleSpin and n.battleSpin[ant.side]) or n.spin or 1
        ant.phase = ant.phase + dt * M.cfg.circulate * ant.speed * spin
        -- A slow breathe in and out of the lane, so the band is alive
        -- rather than a drawn circle.
        --
        -- BUG FOUND LIVE 2026-08-19: `siegeClose` (set once, in
        -- M.fight's siege loop below) only guards against RE-tightening
        -- an already-close attacker -- it did nothing to stop THIS
        -- periodic re-roll from firing again once `ant.wt` next expired
        -- and putting the ant straight back on the wide wanderInner/
        -- wanderOuter band, `siegeClose` still `true` the whole time.
        -- Measured live: a 12-ant siege where 9 ants sat correctly tight
        -- (orbit ~0.13-0.27) and 3 had drifted back out to ~1.40-1.50 --
        -- exactly the ordinary wander range -- because their `wt` timer
        -- had ticked over since the one-time tightening. Re-rolling
        -- WITHIN the siege band while `siegeClose` holds keeps the same
        -- "breathe in and out" liveliness this comment already wanted,
        -- just around the tight ring instead of the wide one.
        ant.wt = ant.wt - dt
        if ant.wt <= 0 then
          if ant.siegeClose then
            ant.orbit = 0.10 + a.rng() * 0.20
          else
            ant.orbit = M.cfg.wanderInner
                        + a.rng() * (M.cfg.wanderOuter - M.cfg.wanderInner)
          end
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
              -- FOUND LIVE 2026-08-19, the SECOND of two bank sites --
              -- this one, not the "already standing here" shortcut
              -- above, is what actually clears a carrying ant's queen
              -- flag in ordinary play: a carrier almost always banks
              -- HERE, mid-arrival after a real walk, not via the
              -- instant "here" path, which only fires when the pickup
              -- and the delivery are the same mound. Missing this line
              -- is why `carryingQueen` stuck at 1 forever in the
              -- `@m` line even though `ant.carry` and `food` were both
              -- correct -- the render flag alone survived every real
              -- delivery.
              ant.carryQueen = nil
              ant.carryQueenSide = nil
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
          elseif dest.isLoc and dest.kind == "spider" and not dest.owner then
            -- SHE IS A FIGHT (plan 05), checked before anything else
            -- about the place, so "claimed but still being fought" is a
            -- state that cannot exist rather than one that has to be
            -- handled -- the same discipline the old guard branch used,
            -- with a different fight underneath it. An arriving ant
            -- simply ENGAGES (stands at her location) and the subdual
            -- resolves over the following seconds in M.fightSpider, the
            -- same split M.fight() uses for a mound: this function
            -- places bodies, that one decides what happens to them.
            --
            -- No `dead = true` branch here any more -- a too-small send
            -- is not an instant loss on arrival, it is a fight that can
            -- run long and grind (ruling 3), and grinding is resolved by
            -- her kill clock in M.fightSpider, not by refusing the ant a
            -- place to stand.
            ant.at, ant.from, ant.to = ant.to, nil, nil
            ant.stage, ant.goal = nil, nil
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

  -- DEBUG FACE LOCK (plan 05, test-battle's cone gate ONLY). Set by
  -- probe.command's faceaway/facetoward/faceoff, never by ordinary play.
  -- Runs AFTER the loop above so it overwrites whatever M.face just
  -- derived from this tick's movement -- a milling ant's `dir` is
  -- re-derived from displacement every frame, so anything that ran
  -- before this point would be clobbered on the very next tick.
  if a.debugFaceLock then
    for i = 1, a.n do
      local ant = a.pool[i]
      if ant.side == M.YOU and ant.at then
        local best, bestD = nil, math.huge
        for j = 1, a.n do
          local t = a.pool[j]
          if t.side ~= M.YOU and t.at == ant.at then
            local dx, dy = t.x - ant.x, t.y - ant.y
            local d2 = dx * dx + dy * dy
            if d2 < bestD then best, bestD = t, d2 end
          end
        end
        if best then
          local toward = math.atan(best.y - ant.y, best.x - ant.x)
          ant.dir = (a.debugFaceLock == "facetoward") and toward
                    or (toward + math.pi)
        end
      end
    end
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
    local site = W.site(a.world, ids[k])
    if mixed then
      -- BATTLE SPIN (plan 05): the two sides march the perimeter in
      -- OPPOSING directions, rolled once when the mound first goes mixed
      -- and cleared the moment it stops being mixed. This is what feeds
      -- the facing cone above -- if both sides circulated the same way
      -- (the ordinary `n.spin`), two ants could orbit in lockstep and
      -- NEVER face each other, and a cone requirement would deadlock the
      -- fight. Opposing spins guarantee every pair closes and passes.
      --
      -- Sides are SORTED before rolling, and the roll comes from `a.rng`,
      -- so the same seed produces the same assignment -- the same
      -- determinism discipline as the sort on `ids` above.
      if site and not site.battleSpin then
        local sides, seen = {}, {}
        for gi = 1, #group do
          local sd = a.pool[group[gi]].side
          if not seen[sd] then seen[sd] = true; sides[#sides + 1] = sd end
        end
        table.sort(sides)
        site.battleSpin = {}
        local s0 = (a.rng() < 0.5) and 1 or -1
        for si = 1, #sides do
          -- First two sides split opposite. A THIRD side arriving mid-
          -- fight (the war map is three-way) is assigned the opposite of
          -- the first side already spinning, so it does not silently
          -- inherit a lockstep match with whichever enemy it shares a
          -- sign with.
          --
          -- DEBUG SABOTAGE ONLY (plan 05, test-battle's no-deadlock
          -- control): a.debugForceSameSpin makes every side spin the
          -- SAME way, which is exactly the bug opposite-marching exists
          -- to prevent -- two ants can then orbit in lockstep and never
          -- close. Never set by ordinary play.
          site.battleSpin[sides[si]] = a.debugForceSameSpin and s0 or (
            (si == 1) and s0
            or (si == 2) and -s0
            or -site.battleSpin[sides[1]])
        end
      end
      for gi = 1, #group do
        local ant = a.pool[group[gi]]
        if ant.hp and ant.hp > 0 then
          ant.fightT = (ant.fightT or 0) - dt
          if ant.fightT <= 0 then
            ant.fightT = (ant.fightT or 0) + cfg.swingPeriod
            -- SWING ATTEMPTS, counted whether or not a target was in
            -- cone -- the cadence gate (test-battle 1) asserts on
            -- ATTEMPTS, not landings, because a landing also depends on
            -- the 50% hit roll and would conflate two different rules.
            a.swings = (a.swings or 0) + 1
            -- STRIKE THE NEAREST ENEMY IN THE FACING CONE (plan 05), not
            -- the first one in the list and not just the nearest.
            --
            -- Picking by pool order made the fight non-spatial: an ant on
            -- the far rim could be hitting a body on the opposite side of
            -- the mound while an enemy stood on its head. Nearest means the
            -- battle happens WHERE THE ANTS ARE -- a column arriving on one
            -- side engages that side, the fighting visibly concentrates at
            -- the point of contact, and a flanking send is a real move
            -- rather than a relabelled reinforcement.
            --
            -- THE CONE: an enemy behind an ant is not a target, whatever
            -- its distance -- this is what makes opposite-direction
            -- marching (M.battleSpin) matter. An ant with nobody in its
            -- +/-45 degree cone this tick simply does not swing; fightT
            -- has already been reset above, so the attempt is spent
            -- either way, exactly as a real miss would be.
            --
            -- Ties resolve by pool index (the `<` keeps the first found),
            -- so this stays deterministic for a given seed.
            local fx, fy = math.cos(ant.dir or 0), math.sin(ant.dir or 0)
            local target, bestD = nil, math.huge
            for tj = 1, #group do
              local t = a.pool[group[tj]]
              if t.side ~= ant.side and t.hp and t.hp > 0 then
                local ddx, ddy = t.x - ant.x, t.y - ant.y
                local d2 = ddx * ddx + ddy * ddy
                if d2 < bestD then
                  local d = math.sqrt(d2)
                  local inCone = d > 0 and (ddx * fx + ddy * fy) / d >= cfg.hitArcDot
                  if inCone then target, bestD = t, d2 end
                end
              end
            end
            if target then
              -- HALF THE SWINGS MISS. The other half land for 2 to 4,
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
                -- THE UNSCALED ROLL, min/max over the run (plan 05's
                -- test-battle damage-bounds gate). Tracked as the raw
                -- roll rather than `dmg` because atk/def multipliers are
                -- 1 for every ant today and would otherwise silently
                -- validate a wrong hitMax if a future upgrade changed
                -- them -- this asserts the DICE, not their scaling.
                if not a.dmgMin or roll < a.dmgMin then a.dmgMin = roll end
                if not a.dmgMax or roll > a.dmgMax then a.dmgMax = roll end
              end
            end
          end
        end
      end
    elseif site and site.battleSpin then
      -- THE MOUND STOPPED BEING MIXED: clear the spin so the NEXT battle
      -- here rolls fresh rather than inheriting a stale assignment from a
      -- fight that already ended.
      site.battleSpin = nil
    end
  end

  -- Clear the dead. BACKWARD, because kill() is a swap-remove: forward
  -- iteration skips an ant every time one dies (the discipline this file
  -- documents at M.spend). Position and side are CAPTURED HERE, before
  -- kill() swaps the slot out from under them -- the resolved value, not
  -- a re-derivation (see M.pushCorpse: capturing after kill() would read
  -- whatever ant got swapped into this index instead).
  for i = a.n, 1, -1 do
    local ant = a.pool[i]
    if ant.hp and ant.hp <= 0 then
      a.killedInFight = (a.killedInFight or 0) + 1
      M.pushCorpse(a, ant.x, ant.y, ant.side, ant.at)
      kill(a, i)
    end
  end

  -- WHO HOLDS THE GROUND NOW. A mound flips when the last defender falls
  -- and somebody else is still standing on it. Energy is spent as the
  -- attackers dig in, so a fortified mound still costs more than an empty
  -- one -- it is just no longer the whole fight.
  --
  -- (Not named `W` here: that shadows the sim.world MODULE this file
  -- requires at the top, and W.site below needs the module, not the
  -- world TABLE. The shadow compiled fine and threw at runtime the first
  -- time anything reached this line: "attempt to call a nil value
  -- (field 'site')", because `a.world.site` is nothing.)
  local world = a.world
  for k = 1, #ids do
    local id = ids[k]
    -- LOCATIONS TOO, NOT JUST MOUNDS. This used to read only W.node[id],
    -- so a location a rival had claimed could never change hands again --
    -- no queen to dig out, no energy to grind down, nothing at all in
    -- this loop even looked at it. The player's ants would arrive (the
    -- generic hostile-ground branch above sets `ant.at` for either kind),
    -- sit there with `held=true`, and never pick up a single item, because
    -- the pickup rule requires `n.owner == ant.side` and nothing was ever
    -- going to make that true again.
    --
    -- Reproduced directly: force a location's owner to a rival, send the
    -- player at it, and watch -- items sat at 4/6 forever while `held`
    -- correctly flipped true. The ants were exactly where they should be
    -- and could do nothing there.
    local site = W.site(world, id)
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
        -- CLEAR THE CLOSE-IN FLAG for anyone who is no longer besieging A
        -- QUEEN at this mound -- an ant that left, or a fresh arrival
        -- reusing a swapped pool slot (kill() is a swap-remove), starts
        -- at the ordinary wander orbit and only tightens once confirmed
        -- attacking below. Also covers the queen's OWN death: once
        -- `queens` empties this scan is the only thing left running for
        -- these ants (the branch below falls to the queenless "dig out
        -- the ground" case, which never touches position), so without
        -- this an ant that sieged her and then just stood there after
        -- she fell would mill unnaturally tight forever.
        for i = 1, a.n do
          local ant = a.pool[i]
          local stillSieging = ant.at == id and ant.side ~= site.owner
                                and queens and #queens > 0
          if ant.siegeClose and not stillSieging then ant.siegeClose = nil end
        end
        if queens and #queens > 0 then
          -- Every attacker present chews on the nearest queen. She has five
          -- workers' worth of body (cfg.queenHp), so this is a real siege
          -- rather than a formality -- and the more ants you brought, the
          -- faster she falls, which is the pressure the whole assault is for.
          local swings = 0
          for i = 1, a.n do
            local ant = a.pool[i]
            if ant.at == id and ant.side ~= site.owner then
              -- SHE IS THE TARGET, SO CLOSE ON HER (Luis, 2026-08-19):
              -- an attacker sieging the queen used to keep its ordinary
              -- wanderInner/wanderOuter milling orbit -- the same ring a
              -- peaceful idling ant sits at -- so a siege looked exactly
              -- like a garrison standing around, nothing on screen ever
              -- pointed at what was actually being attacked. `queenPos`
              -- (render/ants.lua) draws her within 0.34 mound-radii of
              -- centre; pulling an attacker's orbit down to that band
              -- makes the siege visually converge on her instead of
              -- staying parked on the perimeter. Set once (not every
              -- tick) so `ant.wt`'s own re-roll timer (the idling block's
              -- "breathe in and out") still governs the small drift
              -- around that tighter ring, rather than fighting it.
              if not ant.siegeClose then
                ant.orbit = 0.10 + a.rng() * 0.20
                ant.siegeClose = true
              end
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
            -- SHE IS A MEAL, BUT SOMEBODY HAS TO CARRY HER HOME.
            --
            -- A dead queen is the biggest single piece of food on the
            -- board -- more than an aphid, more than a spider's leg --
            -- which is what makes storming a colony pay for the ants it
            -- cost rather than just denying them to somebody else.
            --
            -- She used to bank INSTANTLY on death, which quietly made her
            -- the only food in the game that teleports: every aphid, grain
            -- and spider leg has to be walked back to a queen, and the
            -- biggest prize on the board arrived by magic the moment she
            -- fell. Now she leaves a BODY where she died, and it is
            -- carried home like anything else -- so taking a colony and
            -- profiting from taking it are two different things, and a
            -- storming party that gets wiped out afterwards leaves the
            -- corpse lying there for whoever comes next.
            site.corpses = (site.corpses or 0) + 1
            site.corpseValue = (attacker == M.YOU)
                               and cfg.queenFood or cfg.queenFoodRivals
            -- WHOSE QUEEN SHE WAS (plan 06). Two consumers, and neither
            -- can be served by the mound's `owner`, because the mound
            -- CHANGES HANDS moments after she falls:
            --
            --   1. The pickup rule. "The defender does not eat its own
            --      fallen queen" has to be asked about HER side, not
            --      about who holds the ground now -- once the attacker
            --      captures, `owner` is the attacker and an owner-based
            --      test silently swaps its meaning.
            --   2. The renderer. A carried body is drawn in her own
            --      colony's colour, so a red queen slung over a green
            --      ant's back still reads as a red queen -- which is the
            --      whole trophy.
            site.corpseSide = site.owner
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
