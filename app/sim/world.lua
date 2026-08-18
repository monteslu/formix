-- world.lua - the map: a field of nodes you can see across.
--
-- THE ORBIT RULE, which the earlier builds did not have. A mound has a
-- radius it can reach, and you may only send to somewhere inside the reach
-- of a place you already hold. That single rule is what
-- makes a map a puzzle rather than a menu: a rich node just outside your
-- reach is a reason to take the poor one between you and it.
--
-- Reach is computed from positions, not stored as edges. That matters
-- because it can then be DRAWN honestly -- the ring you see is the rule --
-- and because a node whose range stat grows really does reach further.
--
-- RENDERER-BLIND, like everything under sim/.

local M = {}

-- A node's kind sets its look and its starting stats. There is no food and
-- nothing to harvest: a node's value is what it GROWS and how far it can
-- throw, which is the whole economy.
--
--   grow    seconds per new ant once a nursery is dug here
--   range   how far it can send, in world units
--   energy  what an attacker must chew through once its defenders are dead
local KINDS = {
-- SIZE FOLLOWS CAPACITY. A mound that houses four queens, their brood
-- chambers and a crowd of workers has to LOOK like it holds them -- the
-- first pass drew a 46-unit hill for a four-queen home, which read as a
-- pebble and left the queens invisible inside it. Radius roughly tracks
-- maxQueens now, so a big mound is visibly a prize.
-- RANGE MUST COMFORTABLY EXCEED THE MAP'S MINIMUM SPACING, or mounds
-- become islands: widening the field for looks (minGap 620) left a small
-- mound's 520 reach unable to touch ANYTHING, so picking one up and
-- pressing a direction did nothing and the controls read as broken. A
-- small mound now reaches ~1.6 gaps, a home ~2.4, which keeps the orbit
-- rule meaningful (not everything is in range) without stranding anyone.
  home  = { radius = 118, grow = 3.2, range = 1500, energy = 14, maxQueens = 4 },
  rich  = { radius = 104, grow = 2.6, range = 1320, energy = 10, maxQueens = 4 },
  plain = { radius = 78,  grow = 4.4, range = 1150, energy = 7,  maxQueens = 3 },
  small = { radius = 56,  grow = 6.0, range = 1000, energy = 5,  maxQueens = 2 },
}
M.KINDS = KINDS

-- ── LOCATIONS: food in the ground ──────────────────────────────────────
--
-- A location is somewhere worth walking to that is NOT a mound. It sits
-- in the same field and is claimed the same way, but it has none of a
-- mound's organs: no queens, no brood, no stats, no upgrades, and no
-- reach of its own. What it has is ITEMS, and an ant that arrives where
-- there is one picks it up and carries it home.
--
-- THEY ARE A SEPARATE LIST, not mounds wearing a flag, and that is a
-- deliberate structural choice. Nearly every loop in this game walks
-- `world.nodes` meaning "mounds" -- production, vision, the rival's
-- holdings, the save format, the panel, the minimap. A flagged mound
-- would need an exclusion in every one of them, and the first one anybody
-- forgot would be a queen raised on a patch of grain.
--
--   items   how many are pickable right now
--   value   food each one is worth
--   cap     how many it holds when full
--   regrow  seconds per item; nil means never (what is taken is gone)
--   guard   hits an attacker must land before the place can be claimed
--   relay   may ants travel THROUGH it to somewhere further?
--   scouts  does holding it show you who is on the ground next door?
--
-- `relay` and `scouts` are FALSE for everything that currently exists,
-- and they are per-kind rather than a blanket rule about locations
-- because they will not stay that way. A patch of aphids is a meal and a
-- spider is a fight -- neither has any business changing the shape of the
-- map. A FARM, if one is ever built here, is a different proposition: it
-- would be a thing the colony makes, and making it extend the network is
-- exactly what would justify building one. Leaving these as flags means
-- that day is a line in this table rather than surgery on the pathfinder.
-- SIZED LIKE THE MOUNDS THEY SIT AMONG (a small mound is 56, a plain one
-- 78). The first pass drew them at 48-64 and they read as litter on the
-- grass: too small to look like a destination, so the eye slid over the
-- food and the map looked empty between the hills. A location has to say
-- "there is somewhere to go here" from across the field, because
-- deciding to walk over and find out what it is IS the mechanic.
local LKINDS = {
  -- Plump, juicy, and worth the walk. A one-off windfall.
  -- Worth SIX, not four: an aphid cluster is the one-off prize you spend a
  -- send on, and against grain that regrows forever the windfall has to be
  -- worth choosing. Six also means one laden ant is most of a larva-and-a-
  -- half, so a short column visibly moves the counter.
  aphids = { radius = 74, range = 900, items = 6, cap = 6, value = 6 },
  -- The slow faucet, and the reason a colony need never starve outright:
  -- one food per grain, but they come back.
  -- TEN SECONDS, not twenty. The faucet was slow enough that a patch left
  -- alone was barely worth returning to, which pushed every decision back
  -- onto the one-off windfalls; at ten it refills a visited patch inside
  -- the time it takes to do something else, so leaving a scout on grain is
  -- a real option rather than a rounding error.
  grain  = { radius = 80, range = 900, items = 4, cap = 10, value = 1,
             regrow = 10 },
  -- Not a harvest -- a fight. Beat her and the legs are the prize. The
  -- biggest of the three, and deliberately: she should look like trouble
  -- the moment the fog lifts off her.
  spider = { radius = 96, range = 900, items = 0, cap = 8, value = 3,
             guard = 6, spoils = 8 },
}
M.LKINDS = LKINDS

local function newId(w, prefix)
  w._nextId = w._nextId + 1
  return prefix .. w._nextId
end

function M.new(rng)
  return {
    nodes = {}, node = {},
    -- Locations live beside the mounds, never among them.
    locs = {}, loc = {},
    _nextId = 0,
    rng = rng or math.random,
    time = 0,
  }
end

function M.addLoc(w, kind, x, y, opts)
  opts = opts or {}
  local spec = LKINDS[kind] or LKINDS.grain
  local l = {
    id = opts.id or newId(w, "L"),
    kind = kind,
    isLoc = true,
    x = x, y = y,
    radius = opts.radius or spec.radius,
    owner = opts.owner or nil,
    -- What is pickable, and what it is worth.
    items = opts.items or spec.items or 0,
    cap = opts.cap or spec.cap or 0,
    value = opts.value or spec.value or 1,
    regrow = opts.regrow or spec.regrow,   -- nil = never comes back
    regrowT = 0,
    -- A guarded place must be beaten before it can be claimed. The
    -- spider is six defenders wearing one body: each attacker that
    -- reaches her trades itself for one hit, exactly as an ant trades
    -- itself for a defender on a mound.
    guard = opts.guard or spec.guard or 0,
    spoils = opts.spoils or spec.spoils or 0,
    -- See the note on LKINDS: false for everything that exists today.
    relay = opts.relay or spec.relay or false,
    scouts = opts.scouts or spec.scouts or false,
    -- A nominal radius, kept only so the generic helpers have something
    -- to read. It is NOT what decides whether you can get here: a
    -- location's link to a mound is judged by the MOUND's reach, both
    -- ways, so an ant can always walk back the way it was thrown. See
    -- M.inRange.
    baseRange = opts.range or spec.range,
    rangeStat = 1,
    seed = opts.seed or math.floor(w.rng() * 1e9),
    -- The same three flags a mound has. `seen` is always true (the shape
    -- of the field is never hidden); what the fog withholds is the KIND,
    -- so grain and a spider are the same grey clump until somebody
    -- stands on one. That is what makes scouting a location tense.
    -- ALWAYS true, and written as a constant rather than as
    -- `opts.seen or true` -- which reads like an option and is not one,
    -- since `false or true` is true. The shape of the field is never
    -- hidden; what the fog withholds is the KIND.
    seen = true,
    observed = false,
    held = false,
  }
  w.locs[#w.locs + 1] = l
  w.loc[l.id] = l
  return l
end

-- A mound OR a location, by id. Everything that walks the network wants
-- this; everything that is about colonies wants `w.node` alone.
function M.site(w, id)
  return w.node[id] or w.loc[id]
end

-- Is this place claimable ground rather than a colony? Used wherever the
-- rules differ: you cannot raise a queen on a patch of grain.
function M.isLoc(x)
  return x ~= nil and x.isLoc == true
end

function M.addNode(w, kind, x, y, opts)
  opts = opts or {}
  local spec = KINDS[kind] or KINDS.plain
  local n = {
    id = opts.id or newId(w, "n"),
    kind = kind,
    x = x, y = y,
    radius = opts.radius or spec.radius,
    -- OWNERSHIP is the whole game state. nil = neutral.
    owner = opts.owner or nil,
    -- QUEENS ARE THE PRODUCTION. Ten ants raise one (see sim/init.lua),
    -- and a mound can hold SEVERAL: each one adds production, so a developed mound out-produces a bare one
    -- by a lot and is worth defending.
    --
    -- Each queen is { layTimer } -- she lays larvae into the mound's
    -- shared brood chamber.
    queens = opts.queens or {},
    maxQueens = opts.maxQueens or spec.maxQueens or 3,
    -- LARVAE ARE VISIBLE. A nursery holds brood that ripens and then
    -- hatches into an ant, which is the ant-farm equivalent of seedlings
    -- dropping off a Dyson tree -- production you can WATCH rather than a
    -- counter going up. Each entry is a ripeness in 0..1 plus a fixed
    -- position in the chamber, so the renderer can draw them growing.
    brood = {},
    -- STATS. Feeding ants into a node you hold raises one of these, which
    -- is the only upgrade path and the reason to hold a place you have
    -- already secured.
    growStat  = opts.growStat  or 1,   -- production rate multiplier
    rangeStat = opts.rangeStat or 1,   -- reach multiplier
    speedStat = opts.speedStat or 1,   -- how fast ants LAUNCHED here move
    baseGrow  = opts.grow  or spec.grow,
    baseRange = opts.range or spec.range,
    energy    = opts.energy or spec.energy,
    maxEnergy = opts.energy or spec.energy,
    -- Cosmetic seed so every node's generated art is unique and stable.
    seed = opts.seed or math.floor(w.rng() * 1e9),
    -- WHICH WAY ITS WORKERS CIRCULATE. Half the mounds run clockwise and
    -- half anticlockwise, from the seed, so no two neighbours march in
    -- lockstep and each hill reads as its own colony rather than as a
    -- copy of the one beside it.
    spin = opts.spin or 0,   -- set below, once the seed is known
    -- Have you ever seen it? A node outside every reach you hold is a
    -- rumour on the map rather than a target.
    seen = opts.seen or false,
    -- OBSERVED: inside the radius of a mound you hold, so its garrison,
    -- queens and energy are visible. Outside, the mound is drawn but its
    -- contents are not. See sim.updateVision.
    observed = false,
  }
  if n.spin == 0 then n.spin = (n.seed % 2 == 0) and 1 or -1 end
  w.nodes[#w.nodes + 1] = n
  w.node[n.id] = n
  return n
end

-- THE ORBIT: how far this node can throw, with its stat applied.
function M.reach(n)
  return (n.baseRange or 480) * (n.rangeStat or 1)
end

function M.dist(a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  return math.sqrt(dx * dx + dy * dy)
end

-- Can `from` send to `to`? Range only -- there are no edges to consult.
-- CENTRE TO CENTRE, deliberately.
--
-- Counting the target's RADIUS here was tried and reverted. It looked like
-- a fix for "no route" on a mound whose body overlapped the reach ring --
-- but that report turned out to be a mound 268 units beyond reach, which
-- no radius bridges, so it fixed nothing that was actually broken. What it
-- DID do was widen every mound's effective reach by its neighbour's size,
-- which let the war map's rival colonies grab five mounds each and dig in
-- before they ever collided: eight attack orders and zero captures, where
-- the same map produced two captures before.
--
-- If the ring and the rule ever need reconciling, move the RING (draw it
-- at the distance a send actually succeeds) rather than the rule. The rule
-- is load-bearing for balance; the ring is a picture of it.
function M.inRange(w, from, to)
  if not from or not to or from == to then return false end

  -- A LOCATION HAS NO REACH OF ITS OWN. Its connection to a mound is
  -- decided by the MOUND's reach, in both directions -- which makes the
  -- link symmetric, and that is not a nicety:
  --
  -- an ant sent to a patch of food has to be able to WALK BACK. Judging
  -- the return leg by the patch's own radius stranded carriers on any
  -- location that a mound could only just reach: seven grains picked up,
  -- nothing ever delivered, the ants standing on the food for the rest of
  -- the game holding it. The mound threw them there; the mound can take
  -- them back.
  --
  -- Two locations are NEVER connected to each other. That is the rule
  -- that keeps food from becoming a chain of stepping stones across the
  -- map, and it is why this is a reach question rather than a distance
  -- one.
  local fl, tl = from.isLoc, to.isLoc
  if fl and tl then return false end
  if fl then return M.dist(from, to) <= M.reach(to) end
  return M.dist(from, to) <= M.reach(from)
end

-- THE NEIGHBOUR LIST: every mound inside THIS one's radius. That is the
-- network -- one hop, and no further. Recomputed rather than stored
-- because a mound's range stat can grow, and a network that went stale
-- when you upgraded would be a lie the player could not see.
-- LOCATIONS ARE DESTINATIONS, NEVER BRIDGES.
--
-- They appear here, so a patch of food inside your reach can be sent to
-- and walked on. What they must never do is EXTEND anything: holding a
-- grain patch does not let you throw further, does not open a route to
-- the mound behind it, and does not see for you. Only mounds do that.
--
-- Food that widened the network would quietly change the shape of the
-- map -- the orbit rule is the whole puzzle, and a patch of grain is not
-- a colony. Proximity still governs everything: you have to be near
-- enough to reach it, exactly like any other target. See M.path, which
-- refuses to relay THROUGH one.
function M.neighbours(w, n)
  local out = {}
  for i = 1, #w.nodes do
    local o = w.nodes[i]
    if o ~= n and M.inRange(w, n, o) then out[#out + 1] = o end
  end
  for i = 1, #w.locs do
    local o = w.locs[i]
    if o ~= n and M.inRange(w, n, o) then out[#out + 1] = o end
  end
  return out
end

-- THE PATH BETWEEN TWO MOUNDS, hop by hop.
--
-- Ants travel the network: each leg must lie inside the radius of the
-- mound it STARTS from, so reaching something far away means finding a
-- chain of mounds that gets there. This is the rule the map is built
-- around, and it is what makes a badly-placed frontier genuinely
-- awkward -- a rich mound two hops beyond your reach is a reason to take
-- the poor one between you and it.
--
-- Breadth-first over the neighbour lists, so the result is the fewest
-- hops. Returns an array of node ids from `fromId` to `toId` inclusive,
-- or nil if the network does not connect them at all.
-- `side` is who is travelling. EVERY MOUND ON THE WAY MUST BE THEIRS.
--
-- The BFS used to expand through every mound on the map regardless of
-- who held it, which quietly broke the central rule: you could send far
-- beyond your own radius by relaying through neutral (or enemy!) ground
-- you had never taken. On screen that is an order arrow reaching right
-- past the edge of the range ring to an unclaimed mound, with the panel
-- cheerfully offering "send ants to take it".
--
-- A relay is a mound your colony HOLDS. The destination is exempt --
-- taking it is the whole point of the order -- so only the INTERIOR of
-- the path is restricted. That is what makes a far mound a reason to
-- take the poor one between you and it, rather than a free move.
function M.path(w, fromId, toId, side)
  if fromId == toId then return nil end
  local from, to = M.site(w, fromId), M.site(w, toId)
  if not from or not to then return nil end
  side = side or from.owner

  local prev, seen = {}, { [fromId] = true }
  local queue, head = { from }, 1
  while head <= #queue do
    local cur = queue[head]; head = head + 1
    local ns = M.neighbours(w, cur)
    for i = 1, #ns do
      local nb = ns[i]
      if not seen[nb.id] then
        seen[nb.id] = true
        prev[nb.id] = cur.id
        if nb.id == toId then
          -- Walk back to the start.
          local out, step = {}, toId
          while step do
            table.insert(out, 1, step)
            step = prev[step]
          end
          return out
        end
        -- Only carry on THROUGH a MOUND you hold. An unheld one can be a
        -- destination but never a staging post -- and a LOCATION is never
        -- a staging post at all, however firmly you hold it. Food does
        -- not extend the network: a grain patch is somewhere to walk to,
        -- not a bridge to the ground beyond it.
        if nb.owner == side and (not nb.isLoc or nb.relay) then
          queue[#queue + 1] = nb
        end
      end
    end
  end
  return nil
end

-- The next mound on the way to a target: the second entry of the path.
function M.nextHop(w, fromId, toId, side)
  local p = M.path(w, fromId, toId, side)
  return p and p[2] or nil
end

-- Everything a side can currently reach from anywhere it holds. This is
-- also what it can SEE: holding ground is how the map opens up.
function M.reachable(w, side)
  local out = {}
  local function from(a)
    if a.owner ~= side then return end
    for j = 1, #w.nodes do
      local b = w.nodes[j]
      if b ~= a and M.inRange(w, a, b) then out[b.id] = true end
    end
    for j = 1, #w.locs do
      local b = w.locs[j]
      if b ~= a and M.inRange(w, a, b) then out[b.id] = true end
    end
  end
  -- Mounds only as SOURCES: reach belongs to colonies. A location you
  -- hold is somewhere your ants are standing, not somewhere they can
  -- throw from.
  for i = 1, #w.nodes do from(w.nodes[i]) end
  return out
end

-- ── the ground's own clock ─────────────────────────────────────────────
-- SOME FOOD COMES BACK AND SOME DOES NOT, and that is the whole
-- difference between the kinds. Grain regrows a stalk at a time forever,
-- which is the reason a colony need never starve outright; aphids and
-- spider legs are taken once and gone.
--
-- It regrows whether or not anybody owns the patch: this is the world's
-- faucet, not a reward for holding ground.
function M.updateLocs(w, dt)
  for i = 1, #w.locs do
    local l = w.locs[i]
    if l.regrow and l.items < l.cap then
      l.regrowT = (l.regrowT or 0) + dt
      while l.regrowT >= l.regrow and l.items < l.cap do
        l.regrowT = l.regrowT - l.regrow
        l.items = l.items + 1
      end
    elseif l.regrow then
      -- Full: hold the clock at zero rather than banking time, or a
      -- patch left alone for a minute dumps three stalks the instant one
      -- is taken.
      l.regrowT = 0
    end
  end
end

-- Seconds per larva PER QUEEN, with the mound's growth stat. A mound with
-- no queen produces nothing at all.
function M.growPeriod(n)
  return (n.baseGrow or 4) / math.max(0.2, n.growStat or 1)
end

function M.digest(w)
  local owned, nurseries, neutral = 0, 0, 0   -- nurseries = total queens
  for i = 1, #w.nodes do
    local n = w.nodes[i]
    if n.owner == "you" then owned = owned + 1
    elseif not n.owner then neutral = neutral + 1 end
    nurseries = nurseries + #(n.queens or {})
  end
  local locs, locOwned, items = #w.locs, 0, 0
  for i = 1, #w.locs do
    local l = w.locs[i]
    if l.owner == "you" then locOwned = locOwned + 1 end
    items = items + (l.items or 0)
  end
  return string.format(
    "nodes=%d owned=%d neutral=%d queens=%d locs=%d locsOwned=%d items=%d",
    #w.nodes, owned, neutral, nurseries, locs, locOwned, items)
end

return M
