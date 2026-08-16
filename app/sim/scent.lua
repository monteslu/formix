-- scent.lua - the player's entire influence on the world.
--
-- You are not the queen and you do not give orders. You are the scent the
-- colony thinks with: you raise or lower attraction on the graph, and the
-- ants reinterpret the gradient continuously. Two consequences the rest of
-- the code depends on:
--
--   1. Nothing you do is permanent. Trails you stop feeding evaporate.
--   2. You cannot micromanage, because influence is a BUDGET that
--      regenerates slowly. That is a sim value, not a UI convention, so
--      the gate can assert micromanagement is impossible numerically.
--
-- The decay rate is the DESIGN.md dial: at 0 routes are permanent (an
-- order, once given, stands), at high values it is pure gardening. It is
-- exposed as a debug intent so it can be tuned live in a playtest window
-- with a human, which is the only way to settle it.

local M = {}

-- Tunables. Every one of these is read through the config table so a test
-- can drive an extreme without editing code.
M.cfg = {
  budgetMax     = 100,
  budgetRegen   = 7.5,     -- per second: ~13s from empty to full
  costLink      = 18,      -- opening a new road is the expensive verb
  costReinforce = 6,
  costDanger    = 12,
  costAbandon   = 2,       -- letting go is nearly free, by design

  -- Player scent applied per verb.
  linkStrength      = 0.55,
  reinforceStrength = 0.25,
  strengthMax       = 1.0,

  -- THE DIAL. Fraction of strength lost per second with no reinforcement.
  decayPerSec   = 0.045,
  -- Traffic reinforces a road on its own, so a route the colony likes
  -- survives without the player. This is what makes the field feel alive
  -- rather than merely fading -- AND it is what keeps the map lit: trail
  -- brightness is strength, so a road the colony runs hard must sit
  -- visibly high rather than hovering just above zero.
  --
  -- Tuned against the real thing: at ~170 ants a busy road sees roughly 3-6
  -- crossings a second, so trafficGain must be worth more than decayPerSec
  -- over that many crossings or every road fades to invisible no matter how
  -- heavily it is used. The first value (0.0016) needed ~28 crossings a
  -- second just to break even, and the map rendered dark.
  trafficGain   = 0.019,   -- per ant-crossing
  trafficDecay  = 1.6,     -- per second, on the rolling counter

  dangerStrength = 1.0,
  dangerDecay    = 0.06,   -- per second
}

function M.new()
  return { budget = M.cfg.budgetMax, spent = 0, refused = 0 }
end

function M.canAfford(s, cost) return s.budget >= cost end

local function spend(s, cost)
  if s.budget < cost then
    s.refused = s.refused + 1
    return false
  end
  s.budget = s.budget - cost
  s.spent = s.spent + cost
  return true
end
M.spend = spend

-- ── the verbs ──────────────────────────────────────────────────────────
-- Each returns true if it happened. A refused verb is a no-op, never a
-- partial effect.

function M.link(s, world, aId, bId)
  local W = require("sim.world")
  if not spend(s, M.cfg.costLink) then return false end
  local e = W.addEdge(world, aId, bId)
  e.strength = math.min(M.cfg.strengthMax, e.strength + M.cfg.linkStrength)
  -- Opening a road is also how the colony LEARNS a place exists.
  world.node[bId].discovered = true
  world.node[aId].discovered = true
  return true, e
end

function M.reinforce(s, world, edgeId)
  local e = world.edge[edgeId]
  if not e then return false end
  if not spend(s, M.cfg.costReinforce) then return false end
  e.strength = math.min(M.cfg.strengthMax, e.strength + M.cfg.reinforceStrength)
  return true
end

function M.abandon(s, world, edgeId)
  local e = world.edge[edgeId]
  if not e then return false end
  if not spend(s, M.cfg.costAbandon) then return false end
  -- Abandoning does not delete the edge; it drops the scent to nothing and
  -- lets traffic drain. The road can always be reopened.
  e.strength = 0
  return true
end

function M.danger(s, world, nodeId, edgeId)
  if not spend(s, M.cfg.costDanger) then return false end
  if nodeId and world.node[nodeId] then
    world.node[nodeId].danger = M.cfg.dangerStrength
  end
  if edgeId and world.edge[edgeId] then
    world.edge[edgeId].danger = M.cfg.dangerStrength
  end
  return true
end

-- ── per-tick ───────────────────────────────────────────────────────────
-- `decayMul` folds in the two things that change how fast a road forgets:
-- rain (threats.scentMul) and the season (seasons.decayMul). Passing it in
-- keeps this module ignorant of both, which is what lets the unit tests
-- drive decay directly.
function M.update(s, world, dt, decayMul)
  s.budget = math.min(M.cfg.budgetMax, s.budget + M.cfg.budgetRegen * dt)

  local decay = M.cfg.decayPerSec * dt * (decayMul or 1)
  local tDecay = M.cfg.trafficDecay * dt
  local dDecay = M.cfg.dangerDecay * dt

  for i = 1, #world.edges do
    local e = world.edges[i]
    if e.strength > 0 then
      -- Traffic reinforcement is applied by agents.lua as crossings happen;
      -- here we only bleed. A road with heavy traffic nets positive.
      e.strength = e.strength - decay
      if e.strength < 0 then e.strength = 0 end
    end
    if e.traffic > 0 then
      e.traffic = e.traffic - e.traffic * tDecay
      if e.traffic < 0.001 then e.traffic = 0 end
    end
    if e.danger > 0 then
      e.danger = e.danger - dDecay
      if e.danger < 0 then e.danger = 0 end
    end
  end

  for i = 1, #world.nodes do
    local n = world.nodes[i]
    if n.danger > 0 then
      n.danger = n.danger - dDecay
      if n.danger < 0 then n.danger = 0 end
    end
  end
end

-- Called by agents when an ant crosses: traffic keeps a used road alive.
function M.credit(edge, amount)
  edge.traffic = edge.traffic + (amount or 1)
  edge.strength = math.min(M.cfg.strengthMax,
                           edge.strength + M.cfg.trafficGain * (amount or 1))
end

return M
