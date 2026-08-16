-- economy.lua - food in, brood out, stores through the winter.
--
-- The DISPLACEMENT INVARIANT lives here (docs/DEVPLAN.md section 3): no code
-- path may take the colony below MIN_COLONY, and the nest is never
-- destroyed. Threats push borders and cut routes; they do not end runs. The
-- floor is enforced as a clamp AND asserted by a gate whose control removes
-- it, so a regression is caught rather than argued about.

local A = require("sim.agents")
local castes = require("sim.castes")

local M = {}

M.cfg = {
  -- YOU START SMALL. Sixty ants and a fully-connected map meant the game
  -- was already running at full tilt before the player touched it -- food
  -- flowed, brood hatched, a spider arrived at t=20 -- so there was no
  -- ramp and nothing legible to learn from. Ten ants is enough to take the
  -- one cheap node in reach (a seed costs 5) and not much else, which
  -- makes the first move obvious and the second one earned.
  startPop      = 16,
  -- foodPerAnt now LIVES in agents.cfg (which owns spawning) and is
  -- forwarded here by the metatable at the bottom of this file, so tuning
  -- it in one place really tunes every path -- the same single-source
  -- arrangement minColony uses.
  broodTime     = 2.4,     -- seconds of nurse work per ant, before broodMul
  upkeepPerAnt  = 0.10,    -- food per ant per second
  storeCap      = 26000,
  -- Starvation is soft: with no food, ants are not raised and the colony
  -- shrinks by attrition to the floor. It never spikes into a wipe.
  starveRate    = 0.6,     -- ants lost per second at zero food
  lifespan      = 240,     -- seconds; ants age out, which keeps flow honest
}

-- THE FLOOR is DEFINED in agents.lua (A.minColony), because that module owns
-- every kill site and cannot import this one without a cycle. Reading and
-- writing it here forwards to there, so there is exactly one value in the
-- program and a test that lowers `economy.cfg.minColony` (the control) really
-- does disarm the clamp inside agents.lua too. A plain copied field is what
-- would let the two drift, which is the bug this indirection prevents.
setmetatable(M.cfg, {
  __index = function(_, k)
    if k == "minColony" then return A.minColony end
    if k == "foodPerAnt" then return A.cfg.foodPerAnt end
    return nil
  end,
  __newindex = function(t, k, v)
    if k == "minColony" then A.minColony = v
    elseif k == "foodPerAnt" then A.cfg.foodPerAnt = v
    else rawset(t, k, v) end
  end,
})

function M.new()
  return {
    food = 500,
    brood = 0,             -- progress toward the next ant, 0..1
    stores = 0,            -- what is set aside for winter
    starved = 0,
    raised = 0,
  }
end

-- THERE IS EXACTLY ONE PLACE ANTS ARE BORN, and it is not here any more.
--
-- This function used to raise ants at the nest from stored food, while
-- agents.lua ALSO grew them at every owned node -- two independent
-- production systems stacked, which took a colony from 10 to 69 ants in
-- sixty seconds with no player input. The game played itself, which is
-- the same disease the first build had.
--
-- Production now belongs to nodes (agents.lua), because that is what
-- makes the map an engine: what you HOLD determines what you grow. Food
-- did not stop mattering -- it is the fuel that growth spends, and the
-- upkeep that a big colony pays. The nurse caste and broodMul feed into
-- the node growth rate instead of a separate nest queue.
--
-- Kept as a stub returning 0 rather than deleted, so the season/famine
-- paths that call it read the same and the sim tests keep their shape.
local function raise(e, a, c, world, dt)
  return 0
end

function M.update(e, a, c, world, dt)
  -- Upkeep: a colony eats. This is what makes an over-large population a
  -- real cost rather than a free score.
  local upkeep = a.n * M.cfg.upkeepPerAnt * dt
  e.food = e.food - upkeep

  if e.food < 0 then
    e.food = 0
    -- Attrition, clamped at the floor. Ants age out from the END of the
    -- live prefix; swap-remove makes that O(1) and order carries no meaning.
    local loss = M.cfg.starveRate * dt
    e.starved = e.starved + loss
    while e.starved >= 1 and a.n > M.cfg.minColony do
      e.starved = e.starved - 1
      A.kill(a, a.n)
    end
    if e.starved > 4 then e.starved = 4 end
  else
    e.starved = 0
  end

  local born = raise(e, a, c, world, dt)

  -- Age-out. Also floor-clamped: a colony at the floor stops dying of old
  -- age rather than flickering at the boundary.
  local i = 1
  while i <= a.n do
    if a.pool[i].age > M.cfg.lifespan and a.n > M.cfg.minColony then
      A.kill(a, i)
    else
      i = i + 1
    end
  end

  if e.food > M.cfg.storeCap then e.food = M.cfg.storeCap end
  return born
end

-- THE INVARIANT, callable from anywhere. Returns ok, message.
function M.checkInvariant(e, a, world)
  if a.n < M.cfg.minColony then
    return false, string.format("colony below floor: %d < %d", a.n, M.cfg.minColony)
  end
  if not world.node[world.nestId] then
    return false, "nest node destroyed"
  end
  if e.food < 0 then
    return false, string.format("negative food: %.2f", e.food)
  end
  return true, "ok"
end

function M.digest(e)
  return string.format("food=%.1f brood=%.3f stores=%.1f raised=%d",
    e.food, e.brood, e.stores, e.raised)
end

return M
