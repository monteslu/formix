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

local function newId(w, prefix)
  w._nextId = w._nextId + 1
  return prefix .. w._nextId
end

function M.new(rng)
  return {
    nodes = {}, node = {},
    _nextId = 0,
    rng = rng or math.random,
    time = 0,
  }
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
  return M.dist(from, to) <= M.reach(from)
end

-- THE NEIGHBOUR LIST: every mound inside THIS one's radius. That is the
-- network -- one hop, and no further. Recomputed rather than stored
-- because a mound's range stat can grow, and a network that went stale
-- when you upgraded would be a lie the player could not see.
function M.neighbours(w, n)
  local out = {}
  for i = 1, #w.nodes do
    local o = w.nodes[i]
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
  local from, to = w.node[fromId], w.node[toId]
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
        -- Only carry on THROUGH a mound you hold. An unheld one can be a
        -- destination but never a staging post.
        if nb.owner == side then queue[#queue + 1] = nb end
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
  for i = 1, #w.nodes do
    local a = w.nodes[i]
    if a.owner == side then
      for j = 1, #w.nodes do
        local b = w.nodes[j]
        if b ~= a and M.inRange(w, a, b) then out[b.id] = true end
      end
    end
  end
  return out
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
  return string.format("nodes=%d owned=%d neutral=%d queens=%d",
    #w.nodes, owned, neutral, nurseries)
end

return M
