-- sim/init.lua - the whole simulation behind one door.
--
--   sim.new(seed)        build a world
--   sim.update(s, dt)    advance one fixed tick
--   sim.apply(s, intent) apply ONE player intent (the only mutation door)
--   sim.snapshot(s)      read-only view for the renderer
--   sim.dump(s)          a diffable string, for gates and save/load
--
-- Nothing under sim/ calls love.graphics or any wall clock. The only
-- entropy is the injected RNG, which makes determinism structural.

local W = require("sim.world")
local A = require("sim.agents")
local campaign = require("sim.campaign")
local rival = require("sim.rival")

local M = {}

M.world  = W
M.agents = A

-- What things cost, in ants. Ants are the currency, so every price here is
-- a number of bodies the player gives up -- which is what makes spending
-- feel like spending.
M.cost = {
  queen   = 10,   -- Ten ants raise a new queen, and a mound holds several.
  -- TWENTY, AND TWICE. Priced at 8 it was cheaper than the queen it
  -- exists to improve, so gathering toward a queen crossed the upgrade
  -- threshold first and one press spent the ants you were saving. At 20 it
  -- is a deliberate investment in a mound you have already committed to,
  -- and the cap stops a single super-mound from being the whole strategy.
  upgrade = 20,   -- one point of one stat
  upgradeMax = 2, -- how many times a single mound may be improved
}

-- FOOD: THE FUEL, NOT A SECOND CURRENCY.
--
-- The player never spends food on anything. A queen eats one to lay one
-- larva, and that is the whole of it -- so ants remain the only thing you
-- CHOOSE to spend, and food is the line that keeps them coming.
--
-- It is GLOBAL, one pool per side, like money in any other strategy game.
-- Per-mound stores were considered and rejected: thematically neater,
-- but it turns every send into bookkeeping about which hill is hungry.
M.food = {
  perAnt   = 1,    -- what one larva costs her
  -- SATURATION. A mound stops laying once it is crowded, so production
  -- cannot be concentrated into one super-hill: growing past this means
  -- another queen (which needs ten ants) or another mound. Without it
  -- the right play is to pour everything into home forever, which is
  -- neither interesting nor what "a colony" means.
  perQueen = 10,   -- workers per queen a mound may hold before she rests
}

-- ── the pool ───────────────────────────────────────────────────────────
-- Sides are discovered, never enumerated: a hardcoded list breaks the
-- day a map fields a fourth colour, and it would break silently.
function M.foodOf(s, side)
  return (s.food and s.food[side]) or 0
end

function M.addFood(s, side, v)
  if not side or not v or v == 0 then return end
  s.food = s.food or {}
  s.food[side] = (s.food[side] or 0) + v
end

-- Spend if it is there. Returns true if the pool paid.
--
-- What is eaten is COUNTED, because otherwise the food ledger cannot be
-- closed: a gate can see what is in the ground, what is on an ant's back
-- and what is in the pool, but the fourth place food goes -- into a
-- larva -- is invisible, and a sum with an invisible term proves nothing
-- about whether food is being lost or quietly duplicated.
function M.takeFood(s, side, v)
  local have = M.foodOf(s, side)
  if have < v then return false end
  s.food[side] = have - v
  s.eaten = s.eaten or {}
  s.eaten[side] = (s.eaten[side] or 0) + v
  return true
end

function M.eatenBy(s, side)
  return (s.eaten and s.eaten[side]) or 0
end

local function makeRng(seed)
  local s = (seed or 1) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function()
    s = (s * 16807) % 2147483647
    return (s - 1) / 2147483646
  end, function() return s end, function(v) s = v end
end

-- THE MAP IS A FIELD, not a ring and not a star.
--
-- The map is twenty-odd mounds scattered across open ground, most of them
-- neutral, with your one home somewhere in it. That is what makes
-- the game about expansion: there is visibly somewhere to go, and the
-- orbit rule decides the order you can go there in. The previous build had
-- three nodes on screen and nothing to expand into, which is why it read
-- as "one ant hill" rather than as a map.
local function buildMap(w, rng, opts)
  opts = opts or {}
  local count = opts.count or 22
  local spread = opts.spread or 6200

  -- Poisson-ish scatter: keep trying points until one is far enough from
  -- every node already placed. A pure random scatter clumps, and a clump
  -- is a place where the orbit rule stops meaning anything.
  -- SPACING IS THE NETWORK. Two constraints, and the second is the one
  -- that matters: a gap has to clear the biggest mound's worker ring (or
  -- two crowds merge into one blob), AND it has to be large enough
  -- relative to a mound's radius that a mound typically has two or three
  -- neighbours rather than the whole map. A complete graph makes the
  -- orbit rule meaningless -- nothing is ever "two hops away", so there
  -- is no frontier and no reason to care which mound you take first.
  local minGap = opts.minGap or 900
  local placed = {}
  local function far(x, y)
    for i = 1, #placed do
      local p = placed[i]
      local dx, dy = p.x - x, p.y - y
      if dx * dx + dy * dy < minGap * minGap then return false end
    end
    return true
  end

  -- Home first, at the origin.
  local home = W.addNode(w, "home", 0, 0,
                         { owner = "you", queens = { A.newQueen() }, seen = true })
  w.homeId = home.id
  placed[#placed + 1] = home

  local kinds = { "small", "plain", "plain", "rich", "plain", "small" }
  local tries = 0
  while #placed < count and tries < count * 400 do
    tries = tries + 1
    local a = rng() * 6.28318
    -- sqrt keeps the scatter even by AREA rather than piling up near home.
    local r = 320 + math.sqrt(rng()) * spread
    local x, y = math.cos(a) * r, math.sin(a) * r
    if far(x, y) then
      local kind = kinds[math.floor(rng() * #kinds) + 1]
      -- The far field is richer: a reason to push outward rather than
      -- sitting in the safe middle.
      if r > spread * 0.62 and rng() < 0.45 then kind = "rich" end
      placed[#placed + 1] = W.addNode(w, kind, x, y)
    end
  end

  -- GUARANTEE A FIRST MOVE. If nothing at all sits inside home's orbit the
  -- player is stuck staring at a map they cannot touch, which no amount of
  -- good tuning recovers. Pull the nearest node into range.
  local best, bestD = nil, math.huge
  for i = 2, #w.nodes do
    local d = W.dist(home, w.nodes[i])
    if d < bestD then best, bestD = w.nodes[i], d end
  end
  if best and bestD > W.reach(home) then
    local k = (W.reach(home) * 0.82) / bestD
    best.x, best.y = home.x + (best.x - home.x) * k,
                     home.y + (best.y - home.y) * k
  end

  -- ── FOOD IN THE FIELD ────────────────────────────────────────────────
  --
  -- Roughly one location per two and a half mounds, scattered by the same
  -- rule and kept out of the mounds' laps. Aphids are the common windfall,
  -- grain the slow faucet, and a spider now and then for the ground that
  -- looks too good to be free.
  local lkinds = { "grain", "aphids", "aphids", "grain", "spider", "aphids" }
  local want = math.max(3, math.floor(#w.nodes / 2.5))
  local tries2 = 0
  while #w.locs < want and tries2 < want * 400 do
    tries2 = tries2 + 1
    local ang = rng() * 6.28318
    local r = 420 + math.sqrt(rng()) * spread
    local x, y = math.cos(ang) * r, math.sin(ang) * r
    -- Clear of every mound and of every other location: a patch inside a
    -- mound's worker ring is unreadable and unclickable.
    local ok = true
    for i = 1, #w.nodes do
      if W.dist(w.nodes[i], { x = x, y = y }) < w.nodes[i].radius * 3.2 then
        ok = false; break
      end
    end
    if ok then
      for i = 1, #w.locs do
        if W.dist(w.locs[i], { x = x, y = y }) < 520 then ok = false; break end
      end
    end
    if ok then
      W.addLoc(w, lkinds[math.floor(rng() * #lkinds) + 1], x, y)
    end
  end

  -- ONE GRAIN PATCH INSIDE HOME'S REACH, ALWAYS.
  --
  -- This is the whole of the anti-starvation guarantee on a generated
  -- map. Queens eat, the colony starts with nothing, and a board whose
  -- nearest food is two hops beyond the opening position is a board that
  -- was lost before the player touched it. Grain rather than aphids
  -- because grain comes back: the guarantee has to survive the player
  -- spending it badly the first time.
  local nearest, nd = nil, math.huge
  for i = 1, #w.locs do
    local d = W.dist(home, w.locs[i])
    if w.locs[i].kind == "grain" and d < nd then nearest, nd = w.locs[i], d end
  end
  if not nearest then
    nearest = W.addLoc(w, "grain", W.reach(home) * 0.7, 0)
    nd = W.dist(home, nearest)
  end
  if nd > W.reach(home) * 0.9 then
    local k = (W.reach(home) * 0.7) / nd
    nearest.x = home.x + (nearest.x - home.x) * k
    nearest.y = home.y + (nearest.y - home.y) * k
  end
end

-- `levelId` selects a hand-built opening (sim/campaign.lua); omit it for
-- the generated field. The campaign is how the game teaches itself: each
-- level arranges the ground so its lesson is the obvious thing to try,
-- which a generated map cannot guarantee.
function M.new(seed, levelId, opts)
  local rng, getState, setState = makeRng(seed or 12345)
  local level = levelId and campaign.byId(levelId) or nil
  local s = {
    seed = seed or 12345,
    level = level,
    levelId = level and level.id or nil,
    rng = rng, _rngState = getState, _setRng = setState,
    time = 0, ticks = 0,
    paused = false,
    events = {},
    -- EVERYONE STARTS HUNGRY. Nobody has a grain to their name; the
    -- first larva anywhere is paid for by something a worker carried
    -- home. (A level may seed a side by hand -- see campaign.build.)
    food = {},
    eaten = {},
    dead = {},
  }
  s.world = W.new(rng)
  s.agents = A.new(s.world, rng)

  if level and not level.generated then
    campaign.build(level, s.world, W, s.agents, A)
    local sides = campaign.sides(level)
    for i = 1, #sides do
      M.addFood(s, sides[i], campaign.startFood(level, sides[i]))
    end
  else
    buildMap(s.world, rng, opts)
    -- Your opening hand on the open field.
    for _ = 1, (opts and opts.startAnts) or 20 do
      A.spawn(s.agents, s.world.homeId, A.YOU)
    end
  end

  -- ONE BRAIN PER SIDE THAT HOLDS GROUND. The late campaign fields two
  -- rival colonies at once, and they have to think independently -- a
  -- single brain driving both would coordinate them into one opponent
  -- with two bodies. Separate brains also means they fight EACH OTHER,
  -- since each simply attacks the weakest thing in its reach.
  s.rivals = {}
  local seenSide = {}
  for i = 1, #s.world.nodes do
    local n = s.world.nodes[i]
    if n.owner and n.owner ~= A.YOU and not seenSide[n.owner] then
      seenSide[n.owner] = true
      s.rivals[#s.rivals + 1] = rival.new(rng, n.owner)
    end
  end
  -- SLEEPING UNTIL FOUND. A level can ask that its enemies stay dormant
  -- until the player can actually see them, so exploring slowly is never
  -- punished by an attack from a colony they had no way to know about.
  s.rivalsAsleep = (s.level and s.level.wakeOnContact) or false
  -- Kept for save compatibility and for anything reading a single rival.
  s.rival = s.rivals[1]

  M.updateVision(s)
  return s
end

-- YOU CAN SEE THE WHOLE FIELD. Every mound is drawn from the start; what
-- you do not know is who holds them and how strong they are. Hiding the mounds themselves was a
-- mistake carried over from the previous game: it left 20 of 22 mounds in
-- the dark, so the map looked like two hills and there was visibly
-- nowhere to expand to, which is the exact opposite of what a 4X map is
-- for. Reach still limits where you can SEND; it no longer limits what
-- you can see.
-- FOG OF WAR, at the right grain.
--
-- You can always SEE the mounds -- the field is not a black screen you
-- feel your way across, and hiding it made the map read as three hills
-- with nowhere to go. What the fog hides is the INHABITANTS: how many
-- ants are on a mound, how many queens it has, how much energy it would
-- cost to take. That is the information worth scouting for, and it comes
-- with reach -- anything inside the radius of a mound you hold is
-- observed, everything else is a shape whose contents you can only guess.
function M.updateVision(s)
  for i = 1, #s.world.nodes do
    local n = s.world.nodes[i]
    n.seen = true          -- the shape of the field is never hidden
    n.observed = false     -- can you see who is on this mound
    n.lit = false          -- is this mound's radius out of the fog
    -- ARE YOU ATTACKING IT THIS INSTANT? Recomputed every tick, unlike
    -- `found`, because a fight is a moment and not a fact you learn: the
    -- reveal has to end when the assault does.
    n.contested = false
  end
  -- LOCATIONS FOG THE SAME WAY, and what theirs hides is the KIND. An
  -- unvisited location is an anonymous grey clump: you cannot tell
  -- grain from aphids from a spider until somebody stands on it, which
  -- is what makes walking up to one a real decision instead of a
  -- formality.
  for i = 1, #s.world.locs do
    local l = s.world.locs[i]
    l.seen = true
    l.observed = false
    l.held = false
  end

  -- TWO DIFFERENT QUESTIONS, and conflating them was the bug.
  --
  -- `lit` is about GROUND: a mound's radius is pulled out of the fog when
  -- the mound is an established COLONY -- a queen living there. Ants
  -- passing through do not light the ground; a squad standing on captured
  -- dirt has taken a position, not settled it, and the country around it
  -- is still dark. That is what makes raising the queen the moment the
  -- map opens up, rather than the moment the ants arrive.
  --
  -- `observed` is about BODIES: you can see who is on a mound whenever
  -- your own ants are standing on it, fog or not -- and during a war that
  -- cuts both ways, because a contested uncolonised mound shows you the
  -- enemy standing on it too. Your ants are in the same chamber; of
  -- course they can see.
  local lit = {}
  for i = 1, #s.world.nodes do
    local n = s.world.nodes[i]
    if n.owner == A.YOU and #(n.queens or {}) > 0 then
      lit[#lit + 1] = n
    end
  end
  for i = 1, #lit do
    local n = lit[i]
    n.lit = true
    n.observed = true
    -- THE GROUND IS LIT, THE NEIGHBOURS ARE NOT WATCHED.
    --
    -- `lit` still spreads: an established colony's radius comes out of
    -- the fog, which is what makes raising a queen the moment the map
    -- opens up. But `observed` no longer travels with it, and that
    -- deletion is the point of plan 04.
    --
    -- What it used to do: set `observed` on EVERY neighbour of EVERY
    -- queened colony, every tick. So on any settled board the kinds of
    -- neighbouring food, their live item counts, their owners and the
    -- enemy bodies standing on them were all free, permanently, from
    -- across the map -- for the price of a queen you were raising
    -- anyway. Discovery was very nearly gone: there was almost nothing
    -- left to find out by walking somewhere, which is the complaint that
    -- started this plan.
    --
    -- `observed` now means exactly one thing: PRESENCE. Your ants are
    -- standing here, or your assault is inbound (contested, below).
    local ns = W.neighbours(s.world, n)
    for k = 1, #ns do ns[k].lit = true end
  end

  -- Bodies on the ground see that ground.
  --
  -- `held` is the narrower question: is one of YOUR ants physically on
  -- this mound right now. `observed` is not a substitute -- it is also set
  -- for every neighbour of an established colony, so a mound nobody has
  -- ever walked on reads as observed. The renderer greys a mound until an
  -- ant of yours actually stands on it, and that needs the strict fact.
  -- A GARRISON SCOUTS ITS OWN HORIZON. Ants standing on a mound can see
  -- WHO is on the mounds next door, even though the ground there stays
  -- dark until a queen lights it. Without this, finding a neighbour meant
  -- settling the bridge first (queen and all), so a squad could stand on
  -- ground adjacent to an enemy colony and not notice it -- which reads as
  -- the discovery being broken rather than as a rule about queens.
  for i = 1, #s.world.nodes do s.world.nodes[i].held = false end
  -- WHERE YOUR ANTS ARE HEADED IS SOMEWHERE YOU CAN SEE.
  --
  -- An ant walking at a defended mound dies the instant it arrives, so it
  -- never stands there: `held` stays false, `found` never latches, and the
  -- garrison killing it was drawn by nothing. This marks the DESTINATION of
  -- every column in flight, which is exactly the ground a player is
  -- currently paying attention to and paying ants for.
  for i = 1, s.agents.n do
    local ant = s.agents.pool[i]
    if ant.side == A.YOU and not ant.at and ant.to then
      local d = W.site(s.world, ant.to)
      if d then
        d.contested = true
        -- A FIGHT IS NEVER A SECRET, BUT AN UNOPENED BOX STAYS SHUT.
        --
        -- Marking the destination `observed` is what draws the garrison
        -- defending against your assault (plan 03: an attacker dies on
        -- arrival, so `held` never becomes true and the ants killing your
        -- army were drawn by nothing).
        --
        -- It must NOT reveal what an unvisited LOCATION is, though.
        -- Sending a column at an anonymous grey clump is the moment the
        -- whole discovery loop pays off -- you find out what you walked
        -- into when you get there, and sometimes it is a spider. Letting
        -- the send itself open it means you never have to arrive, and the
        -- clump might as well have been labelled from the start.
        --
        -- A site you have already visited has nothing left to hide, so
        -- the reveal is free there.
        if not (d.isLoc and not d.visited) then
          d.observed = true
        end
      end
    end
  end
  for i = 1, s.agents.n do
    local ant = s.agents.pool[i]
    if ant.side == A.YOU and ant.at then
      -- A LOCATION COUNTS AS GROUND UNDERFOOT. Looking this up in
      -- `world.node` alone left a squad standing on a grain patch
      -- invisible to the fog: the patch stayed an anonymous clump with
      -- ants drawn on top of it, and the mounds it could see next door
      -- stayed dark.
      local n = W.site(s.world, ant.at)
      if n then
        n.observed = true
        n.held = true
        -- YOU HAVE BEEN HERE, AND YOU WILL REMEMBER IT. Set once, never
        -- cleared -- not by leaving, not by losing the ground.
        --
        -- This is NOT the "found" latch that was tried and reverted (see
        -- render/mounds.lua): that one kept ground WARM forever -- colour,
        -- owner, the lot -- which test-grey rightly killed, because in
        -- this game the coloured ground IS the ground you hold. `visited`
        -- remembers only IDENTITY: what kind of place this is and how big
        -- it really is. The ground still goes back to grey stone the
        -- moment your ants leave.
        --
        -- Set on ARRIVAL only (`at`), never on approach: a column inbound
        -- to an unknown clump has not learned what is in it yet, which is
        -- the whole point of walking over to find out.
        n.visited = true
        -- WHAT IT LOOKED LIKE WHEN YOU LEFT.
        --
        -- NOTHING DRAWS FROM THIS ANY MORE. A discovered patch shows its
        -- LIVE count now (food is terrain: a field you have walked to is
        -- one whose crop you can see standing in it, and watching grain
        -- come back is information scouting earned). The latch is kept
        -- because it is serialized and reported in the probe dumps, and
        -- because "what it looked like when you left" is the natural shape
        -- for any future memory rule -- but if you are looking for what
        -- decides the number on screen, it is `l.items`, not this.
        if n.isLoc then n.lastSeenItems = n.items or 0 end
        -- A GARRISON NO LONGER SCOUTS ITS HORIZON, and that deletion is
        -- the other half of plan 04.
        --
        -- This used to set `observed` on every neighbour of any mound
        -- your ants stood on -- so the opening position alone, before the
        -- player had done anything at all, revealed the kind and live
        -- item count of every patch of food beside home. That is why the
        -- generated field's guaranteed grain was legible at boot: not
        -- because anyone had walked to it, but because somebody was
        -- standing next door.
        --
        -- You now learn a place by GOING to it. Standing on one mound
        -- tells you about that mound, and nothing about the anonymous
        -- clumps around it.
      end
    end
  end
end

-- THE ONLY MUTATION DOOR for player action. Returns true if it did
-- something, which the UI uses for its refusal feedback.
function M.apply(s, intent)
  local k = intent.kind
  local world = s.world

  if k == "send" then
    if not (intent.from and intent.to) then return false end
    local n = A.send(s.agents, intent.from, intent.to,
                     intent.count or 1, A.YOU)
    if n > 0 then
      s.events[#s.events + 1] = { kind = "sent", n = n, t = s.time }
      return true
    end
    return false

  elseif k == "withdraw" then
    -- PLAN 05, section 6c: pulling the player's engaged ants off a
    -- spider fight, with a parting-kill cost. A distinct intent from
    -- "send" because M.withdrawFromSpider's rules (a live spider is
    -- never "owned", so M.send's ownership gate would refuse this) are
    -- specific to that one fight -- see the function's own note.
    if not (intent.from and intent.to) then return false end
    local n = A.withdrawFromSpider(s.agents, intent.from, intent.to, A.YOU)
    if n > 0 then
      s.events[#s.events + 1] = { kind = "withdrawn", n = n, t = s.time }
      return true
    end
    return false

  elseif k == "queen" then
    -- TEN ANTS RAISE A QUEEN. The price is fixed, and the moment ants
    -- stop being only an army: you spend bodies to buy production. A
    -- mound holds several queens, so this is a repeatable investment
    -- rather than a one-off unlock -- the same shape as planting more
    -- than one Dyson tree on an asteroid.
    local n = world.node[intent.node]
    if not n or n.owner ~= A.YOU then return false end
    n.queens = n.queens or {}
    if #n.queens >= (n.maxQueens or 3) then return false end
    if A.garrison(s.agents, n.id, A.YOU) < M.cost.queen then return false end
    -- LADEN ANTS BANK WHAT THEY CARRY, in the same act that spends them.
    -- Ten workers who walked home with food do not take it to the grave:
    -- the new queen is born fed, which is what makes the opening
    -- (eleven ants: ten for her, one to harvest) a puzzle worth solving.
    local spent, banked = A.spend(s.agents, n.id, A.YOU, M.cost.queen)
    M.addFood(s, A.YOU, banked)
    n.queens[#n.queens + 1] = A.newQueen()
    print(string.format(
      "@queen node=%s spent=%d banked=%d queens=%d garrison=%d food=%d",
      tostring(n.id), spent, banked, #n.queens,
      A.garrison(s.agents, n.id, A.YOU), M.foodOf(s, A.YOU)))
    s.events[#s.events + 1] = { kind = "queen", node = n.id, t = s.time }
    return true

  elseif k == "upgrade" then
    -- Feed ants into a node to raise one stat. The reason to keep holding
    -- somewhere you have already secured.
    local n = world.node[intent.node]
    if not n or n.owner ~= A.YOU then return false end
    local stat = intent.stat
    if stat ~= "growStat" and stat ~= "rangeStat" and stat ~= "speedStat" then
      return false
    end
    -- NO QUEEN, NO UPGRADE. Refusing this in the panel alone would leave
    -- the button live: X still spent the ants, it just did it invisibly.
    -- An upgrade only modifies what a queen produces, so buying one with
    -- no queen is pure loss -- and it was priced BELOW her, so it ate the
    -- ants a player was gathering for her.
    if #(n.queens or {}) == 0 then return false end
    -- CAPPED PER MOUND. Without a limit the right play is to pour every
    -- ant into one hill forever, which is neither interesting nor what
    -- "a colony" means.
    n.upgrades = n.upgrades or 0
    if n.upgrades >= (M.cost.upgradeMax or 2) then return false end
    if A.garrison(s.agents, n.id, A.YOU) < M.cost.upgrade then return false end
    local _, banked = A.spend(s.agents, n.id, A.YOU, M.cost.upgrade)
    M.addFood(s, A.YOU, banked)
    n[stat] = (n[stat] or 1) + 0.35
    n.upgrades = n.upgrades + 1
    s.events[#s.events + 1] = { kind = "upgraded", node = n.id,
                                stat = stat, t = s.time }
    return true
  end
  return false
end

-- ── death ──────────────────────────────────────────────────────────────
-- NO WORKERS AND NO FOOD IS THE END. This replaces the old relief valve,
-- which trickled an ant every six seconds into a queenless colony so the
-- run could never become unwinnable. Food makes starvation a real state
-- worth fearing, and a game you cannot lose has nothing at stake in it.
--
-- A side is ALIVE while any of these is true, because each is a path back
-- to a worker:
--   * it has an ant anywhere (even one, even laden, even in transit)
--   * it has brood in the ground -- larvae were paid for when they were
--     laid, so they hatch regardless of the pantry
--   * it holds a queened mound AND has a food to feed her
--
-- Note that food alone saves nobody: with no ants and no queen there is
-- nothing that can spend it. That is the shape of the loss.
-- AN ORDERED LIST, not a set. `pairs` order is not part of Lua's
-- contract, and two sides dying on the same tick would then print their
-- @gameover lines in an order that could differ between runs of the same
-- seed -- which is exactly the kind of drift the determinism gates exist
-- to catch, arriving via the one table nobody thought was gameplay.
local function sidesInPlay(s)
  local out, seen = {}, {}
  local function add(side)
    if side and not seen[side] then seen[side] = true; out[#out + 1] = side end
  end
  add(A.YOU)
  for i = 1, #s.world.nodes do add(s.world.nodes[i].owner) end
  for i = 1, #s.world.locs do add(s.world.locs[i].owner) end
  for i = 1, s.agents.n do add(s.agents.pool[i].side) end
  return out
end

function M.alive(s, side)
  for i = 1, s.agents.n do
    if s.agents.pool[i].side == side then return true end
  end
  local fed = M.foodOf(s, side) >= M.food.perAnt
  for i = 1, #s.world.nodes do
    local n = s.world.nodes[i]
    if n.owner == side then
      if #(n.brood or {}) > 0 then return true end
      if fed and #(n.queens or {}) > 0 then return true end
    end
  end
  return false
end

function M.checkDeath(s)
  s.dead = s.dead or {}
  local sides = sidesInPlay(s)
  for k = 1, #sides do
    local side = sides[k]
    -- LATCHED, AND ANNOUNCED ONCE. Gates read @-lines out of the cart
    -- log and the UI keys off the flag; a per-tick reprint would drown
    -- both. Death is final -- nothing in the rules can undo it.
    if not s.dead[side] and not M.alive(s, side) then
      s.dead[side] = true
      if side == A.YOU then s.gameOver = true end
      print(string.format("@gameover side=%s t=%.1f", tostring(side), s.time))
      s.events[#s.events + 1] = { kind = "dead", side = side, t = s.time }
    end
  end
end

function M.update(s, dt)
  if s.paused then return end
  s.time = s.time + dt
  s.ticks = s.ticks + 1
  s.world.time = s.time

  M.checkDeath(s)

  -- PRODUCTION. Only a mound with a nursery raises ants, and it does so
  -- at its own rate. This is the entire economy.
  for i = 1, #s.world.nodes do
    local n = s.world.nodes[i]
    -- A SLEEPING ENEMY GROWS SLOWLY -- not at full speed, and not frozen.
    --
    -- Both extremes were tried and both are wrong. At FULL speed an
    -- undiscovered colony went 8 -> 22 ants in forty idle seconds, so
    -- exploring carefully was punished with an unwinnable wall. FROZEN, it
    -- sat at exactly 8 while the player grew 22 -> 81 over five minutes,
    -- so by the time contact happened there was no contest at all: you
    -- annihilated it on arrival and never saw a battle. That is the state
    -- this shipped in, and it is the worse of the two -- an enemy that
    -- cannot fight is scenery.
    --
    -- A quarter rate keeps the discovery meaningful: they are behind you,
    -- but they are still a colony worth taking seriously.
    local dormant = s.rivalsAsleep and n.owner and n.owner ~= A.YOU
    local rate = dormant and 0.25 or 1.0
    if n.owner and n.queens and #n.queens > 0 then
      -- EVERY QUEEN LAYS. Each one runs her own timer into the mound's
      -- shared brood chamber, so a mound with three queens fills three
      -- times as fast -- which is what makes raising another one a real
      -- purchase rather than a flavour unlock.
      local period = W.growPeriod(n)
      n.brood = n.brood or {}
      local room = 4 + #n.queens * 3
      -- SATURATION: a crowded mound rests. Counting the brood already in
      -- the chamber as well as the standing garrison stops a nursery
      -- overshooting the cap by everything it has in the ground. Ants
      -- merely PASSING THROUGH are not counted (they are counted where
      -- they came from and where they are going), so massing an army at
      -- a front mound never sterilises it.
      local crowd = A.garrison(s.agents, n.id, n.owner) + #n.brood
      local full = crowd >= M.food.perQueen * #n.queens
      -- TAKE TURNS WHEN THERE IS NOT ENOUGH TO GO ROUND.
      --
      -- This loop used to run 1..#queens in fixed order, and every queen
      -- shares one pantry -- so on a trickle income the FIRST queen reached
      -- her timer, took the only food, and the others never laid at all. A
      -- mound with three queens produced exactly as fast as a mound with
      -- one, which quietly makes the second and third queen (ten ants each)
      -- a purchase that buys nothing until the colony is already rich.
      --
      -- `layStart` walks one place per tick, so whoever went hungry last is
      -- first in line next time. It is stored on the MOUND (not the queen)
      -- and advances deterministically, so a replay is unaffected: no clock
      -- and no rng, which is the sim's standing promise.
      n.layStart = ((n.layStart or 0) + 1) % #n.queens
      for k = 1, #n.queens do
        local qi = ((n.layStart + k - 1) % #n.queens) + 1
        local q = n.queens[qi]
        q.layTimer = (q.layTimer or 0) + dt * rate
        if q.layTimer >= period then
          -- SHE LAYS ONLY IF THERE IS ROOM AND A MEAL.
          --
          -- Every reason not to lay is checked BEFORE the food is taken,
          -- or the pantry pays for larvae that were never laid -- a leak
          -- that only shows up on a crowded mound and looks like famine
          -- arriving from nowhere.
          --
          -- Hunger DELAYS production, it never destroys progress: the
          -- timer holds at full rather than resetting, so a queen who has
          -- been waiting lays on the first tick after food arrives.
          if full or #n.brood >= room then
            q.layTimer = period
          elseif not M.takeFood(s, n.owner, M.food.perAnt) then
            q.layTimer = period
          else
            q.layTimer = q.layTimer - period
            -- A LARVA IS LAID BY A PARTICULAR QUEEN and starts at her
            -- gaster, then crawls a little way off as it ripens. The
            -- renderer reads `queen` to find where she is, so an egg
            -- visibly comes OUT OF HER rather than appearing somewhere in
            -- the mound -- which is the difference between production you
            -- watch and a counter going up.
            n.brood[#n.brood + 1] = {
              ripe = 0, queen = qi,
              -- Where it ends up crawling to, relative to her.
              a = s.rng() * 6.28318,
              r = 0.18 + s.rng() * 0.30,
              seed = s.rng(),
            }
          end
        elseif q.layTimer > period * 2 then
          q.layTimer = period * 2
        end
      end

      -- LARVAE RIPEN AND HATCH. Production you can WATCH happening in the
      -- chamber, rather than a counter going up somewhere.
      local k = 1
      while k <= #n.brood do
        local b = n.brood[k]
        b.ripe = b.ripe + dt / period
        if b.ripe >= 1 then
          if A.spawn(s.agents, n.id, n.owner) then
            table.remove(n.brood, k)
            s.events[#s.events + 1] = { kind = "hatch", node = n.id, t = s.time }
          else
            b.ripe = 1
            k = k + 1
          end
        else
          k = k + 1
        end
      end
    end

    -- A node you hold slowly recovers the energy an assault cost it.
    if n.owner and (n.energy or 0) < (n.maxEnergy or 0) then
      n.energy = math.min(n.maxEnergy, (n.energy or 0) + dt * 0.25)
    end
  end

  -- The ground's own clock: grain comes back, aphids and legs do not.
  W.updateLocs(s.world, dt)

  A.update(s.agents, dt)
  -- BATTLES RESOLVE OVER TIME, after everyone has moved. Ants standing on
  -- the same mound in different colours trade blows until one side is gone;
  -- see A.fight. Ordering matters only in that arrivals should join the
  -- fight on the tick they land, which is what running it after update does.
  A.fight(s.agents, dt)
  -- THE SPIDER (plan 05): a separate subdual fight, same reason it runs
  -- after A.update -- an ant that just arrived should be able to grab a
  -- free leg on the tick it lands.
  A.fightSpider(s, dt)
  -- AGE THE DEAD. Corpses from either fight above land in a.corpses this
  -- same tick; ticking after both means a body killed this frame still
  -- gets its full corpseLife rather than one already spent.
  A.tickCorpses(s.agents, dt)

  -- SWEEP THE DELIVERIES. Ants bank what they carried into an
  -- accumulator on the agent pool rather than reaching up into the sim
  -- (which would be a require cycle); this is the one place it lands in
  -- the pool. Ordered side list, because iteration order of a plain
  -- table is not part of the determinism contract.
  do
    local sides = sidesInPlay(s)
    for k = 1, #sides do
      local got = A.takeBanked(s.agents, sides[k])
      if got > 0 then
        M.addFood(s, sides[k], got)
        if sides[k] == A.YOU then
          print(string.format("@forage delivered=%d food=%d t=%.1f",
            got, M.foodOf(s, A.YOU), s.time))
        end
      end
    end
  end
  -- WAKE ON CONTACT. The enemy is asleep until the player can see it --
  -- `observed` is set for a mound inside the reach of ground you hold, so
  -- this fires exactly when the frontier touches them. Once awake it
  -- stays awake; a colony that had a fright and went back to sleep would
  -- read as a bug.
  if s.rivalsAsleep then
    for i = 1, #s.world.nodes do
      local n = s.world.nodes[i]
      if n.owner and n.owner ~= A.YOU and n.observed then
        s.rivalsAsleep = false
        print("@rival woke side=" .. tostring(n.owner))
        break
      end
    end
  end
  if not s.rivalsAsleep and s.rivals then
    for i = 1, #s.rivals do
      rival.update(s.rivals[i], s.world, s.agents, dt, s)
    end
  end
  M.updateVision(s)

  -- CAMPAIGN PROGRESS. A level ends by OPENING the next one, never by
  -- failing, and the world is not swapped mid-play -- that would strand
  -- every ant in flight.
  if s.level and not s.levelDone then
    if campaign.complete(s.level, s.world, s.agents) then
      s.levelDone = true
      local nxt = campaign.next(s.levelId)
      s.nextLevelId = nxt and nxt.id or nil
      -- PLAN 06: record it on the rising edge, in its own file. This is
      -- the ONLY thing that has to survive for the level select to work,
      -- and it is written the moment it becomes true rather than at the
      -- next autosave -- a player who wins and immediately closes the
      -- game has still beaten the level.
      require("sim.progress").markBeaten(s.levelId)
      -- The celebration reads this edge (ui/celebrate.lua): it must fire
      -- once, on the transition, not every frame the level stays done.
      s.levelJustDone = true
      print("@level complete " .. tostring(s.levelId) ..
            " next=" .. tostring(s.nextLevelId))
    end
  end

  -- Keep the event list short; it is a per-frame channel, not a log.
  while #s.events > 16 do table.remove(s.events, 1) end
end

function M.snapshot(s)
  return {
    world = s.world, agents = s.agents,
    time = s.time, events = s.events,
    cost = M.cost,
    level = s.level, levelId = s.levelId, levelDone = s.levelDone,
    food = M.foodOf(s, A.YOU), foodCfg = M.food,
    gameOver = s.gameOver,
    carried = A.carried(s.agents, A.YOU),
    -- Running total of landed blows. The audio layer diffs it per frame and
    -- turns the RATE into clanks; the sim never plays a sound itself.
    hits = s.agents.hits or 0,
  }
end

function M.dump(s)
  return table.concat({
    string.format("t=%.3f ticks=%d seed=%d", s.time, s.ticks, s.seed),
    "world " .. W.digest(s.world),
    "agents " .. A.digest(s.agents),
    string.format("food you=%d carried=%d", M.foodOf(s, A.YOU),
                  A.carried(s.agents, A.YOU)),
  }, "\n")
end

return M
