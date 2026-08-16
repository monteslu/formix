-- threats.lua - predators, weather and rival pressure.
--
-- THE LAW (docs/DESIGN.md pillar 1): threats DISPLACE, they never destroy.
-- A spider sits on a route and makes crossing it expensive. Rain washes
-- scent off the map. A rival pushes a border and takes a node's yield. None
-- of them can end the run, and economy.checkInvariant proves it.
--
-- Everything here is a modifier on the graph the ants already read, which is
-- why threats need no special-case code in agents.lua: a hazardous edge is
-- simply an edge with a lower weight.

local M = {}

M.cfg = {
  -- Spiders
  spiderMin      = 22,    -- seconds between arrivals, at pressure 1
  spiderMax      = 48,
  spiderDwell    = 26,    -- how long one sits on an edge
  spiderHazard   = 1.0,
  -- A spider is KILLABLE, which is what makes it an objective rather than
  -- weather. hp is in soldier-seconds: with damage 0.55, three soldiers
  -- crossing repeatedly clear one in a bit under half a minute.
  spiderHp       = 14,
  spiderDamage   = 0.55,  -- per soldier per second on its edge
  -- Soldiers reduce the hazard an occupied edge presents.
  soldierRelief  = 0.55,  -- at defense 1.0, hazard is cut by this fraction

  -- Beetles: the ROAMER. Weaker than a spider and it never stays put, so
  -- camping soldiers on one road does not answer it -- you either escort
  -- your columns or accept the toll.
  beetleFirst    = 300,   -- first one is late; the opening stays quiet
  beetleMin      = 55,
  beetleMax      = 120,
  beetleDwell    = 45,
  beetleHop      = 9,     -- seconds before it wanders to another road
  beetleHazard   = 0.55,
  beetleHp       = 8,

  -- Rain: washes scent, which is the weather that MATTERS mechanically.
  rainMin        = 70,
  rainMax        = 150,
  rainDur        = 12,
  rainScentMul   = 5.0,   -- decay multiplier while raining

  -- Rival pressure: claims a node's yield for a while, then recedes.
  rivalMin       = 90,
  rivalMax       = 190,
  rivalDur       = 40,
  rivalYieldMul  = 0.25,
}

function M.new(rng)
  return {
    rng = rng or math.random,
    spiders = {},         -- {edgeId, left, hp}
    beetles = {},         -- {edgeId, left, hp, hop}
    rain = 0,             -- seconds of rain remaining
    -- NOTHING HAPPENS TO YOU IN THE FIRST FEW MINUTES. A spider at t=20
    -- landed while the player was still working out what a node was, and
    -- a threat you cannot read is just noise. The opening is now quiet
    -- enough to learn the one verb in; pressure arrives once there is an
    -- empire worth pressuring.
    rainNext = 150,
    spiderNext = 210,
    rivals = {},          -- {nodeId, left}
    -- Rivals are the Exterminate phase and arrive last: a border you have
    -- to fight for only means something once you have ground to defend.
    rivalNext = 360,
    -- Counters the gates read.
    spiderCount = 0, rainCount = 0, rivalCount = 0,
    beetleCount = 0, spidersKilled = 0, beetlesKilled = 0,
  }
end

local function pickBusyEdge(t, world)
  -- A spider goes where the traffic is: an ambush on an empty road is not a
  -- threat, it is scenery. Falls back to any edge with strength.
  local best, bestT = nil, 0.05
  for i = 1, #world.edges do
    local e = world.edges[i]
    if e.traffic > bestT and e.hazard == 0 then best, bestT = e, e.traffic end
  end
  if best then return best end
  for i = 1, #world.edges do
    local e = world.edges[i]
    if e.strength > 0.05 and e.hazard == 0 then return e end
  end
  return nil
end

local function pickRichNode(t, world)
  local best, bestF = nil, 1
  for i = 1, #world.nodes do
    local n = world.nodes[i]
    if n.kind ~= "nest" and n.discovered and n.food > bestF and not n.claimed then
      best, bestF = n, n.food
    end
  end
  return best
end

function M.update(t, world, agents, castes, dt, seasonState)
  -- Season pressure scales arrival rates: summer is busy, winter is quiet.
  local pressure = (seasonState and seasonState.threatPressure) or 1.0
  if pressure <= 0 then pressure = 0.0001 end

  -- ── spiders ──
  t.spiderNext = t.spiderNext - dt * pressure
  if t.spiderNext <= 0 then
    local e = pickBusyEdge(t, world)
    if e then
      e.hazard = M.cfg.spiderHazard
      t.spiders[#t.spiders + 1] = { edge = e.id, left = M.cfg.spiderDwell }
      t.spiderCount = t.spiderCount + 1
    end
    t.spiderNext = M.cfg.spiderMin + t.rng() * (M.cfg.spiderMax - M.cfg.spiderMin)
  end

  local relief = 1 - math.min(0.9, castes.defense * M.cfg.soldierRelief)
  for i = #t.spiders, 1, -1 do
    local sp = t.spiders[i]
    sp.left = sp.left - dt
    local e = world.edge[sp.edge]

    -- A SPIDER CAN BE KILLED, and that is the Exterminate verb. Until now
    -- it merely raised an edge's hazard and left on a timer, so the only
    -- answer was to wait it out -- a weather event wearing an animal's
    -- shape. Soldiers crossing its edge fight it, so the caste triangle
    -- is what turns a denied road back into a road, and clearing one is
    -- an objective the player can actually pursue.
    sp.hp = sp.hp or M.cfg.spiderHp
    -- `agents` is optional: threats.update is called from unit tests and
    -- other headless paths that have no colony. Without this guard the
    -- fight loop indexed nil and took the whole sim suite down at the
    -- first spider -- a crash introduced by making spiders killable.
    if e and agents then
      local fighters = 0
      for k = 1, agents.n do
        local ant = agents.pool[k]
        if ant.edge == sp.edge then
          fighters = fighters + ((ant.role == 3) and 1 or 0.15)
        end
      end
      sp.hp = sp.hp - fighters * M.cfg.spiderDamage * dt
    end

    if sp.hp <= 0 then
      if e then e.hazard = 0 end
      t.spidersKilled = (t.spidersKilled or 0) + 1
      table.remove(t.spiders, i)
    elseif sp.left <= 0 then
      if e then e.hazard = 0 end
      table.remove(t.spiders, i)
    elseif e then
      -- A wounded spider is a less dangerous spider, so a fight in
      -- progress is visible as the road getting safer.
      e.hazard = M.cfg.spiderHazard * relief * (sp.hp / M.cfg.spiderHp)
    end
  end

  -- ── beetles: the roamer ──
  --
  -- A different KIND of problem from a spider. It holds nothing and denies
  -- nothing; it walks your supply lines and thins the columns on them, so
  -- the answer is not "kill the thing sitting there" but "escort, or move
  -- your traffic". Wildlife should not all be one puzzle.
  t.beetleNext = (t.beetleNext or M.cfg.beetleFirst) - dt * pressure
  if t.beetleNext <= 0 then
    local e = pickBusyEdge(t, world)
    if e then
      t.beetles[#t.beetles + 1] = { edge = e.id, left = M.cfg.beetleDwell,
                                    hp = M.cfg.beetleHp }
      t.beetleCount = (t.beetleCount or 0) + 1
    end
    t.beetleNext = M.cfg.beetleMin + t.rng() * (M.cfg.beetleMax - M.cfg.beetleMin)
  end
  for i = #t.beetles, 1, -1 do
    local bt = t.beetles[i]
    bt.left = bt.left - dt
    local e = world.edge[bt.edge]
    if e then
      e.hazard = math.max(e.hazard, M.cfg.beetleHazard * relief)
      local fighters = 0
      for k = 1, (agents and agents.n or 0) do
        local ant = agents.pool[k]
        if ant.edge == bt.edge then
          fighters = fighters + ((ant.role == 3) and 1 or 0.15)
        end
      end
      bt.hp = bt.hp - fighters * M.cfg.spiderDamage * dt
    end
    -- It MOVES: every few seconds it wanders to another busy road, which
    -- is what makes it un-campable.
    bt.hop = (bt.hop or M.cfg.beetleHop) - dt
    if bt.hop <= 0 then
      if e then e.hazard = 0 end
      local n2 = pickBusyEdge(t, world)
      if n2 then bt.edge = n2.id end
      bt.hop = M.cfg.beetleHop
    end
    if bt.hp <= 0 or bt.left <= 0 then
      if e then e.hazard = 0 end
      if bt.hp <= 0 then t.beetlesKilled = (t.beetlesKilled or 0) + 1 end
      table.remove(t.beetles, i)
    end
  end

  -- ── rain ──
  if t.rain > 0 then
    t.rain = t.rain - dt
    if t.rain <= 0 then t.rain = 0 end
  else
    t.rainNext = t.rainNext - dt
    if t.rainNext <= 0 then
      t.rain = M.cfg.rainDur
      t.rainCount = t.rainCount + 1
      t.rainNext = M.cfg.rainMin + t.rng() * (M.cfg.rainMax - M.cfg.rainMin)
    end
  end

  -- ── rivals ──
  t.rivalNext = t.rivalNext - dt * pressure
  if t.rivalNext <= 0 then
    local n = pickRichNode(t, world)
    if n then
      n.claimed = true
      n.appeal = n.appeal * M.cfg.rivalYieldMul
      t.rivals[#t.rivals + 1] = { node = n.id, left = M.cfg.rivalDur,
                                  appeal = n.appeal / M.cfg.rivalYieldMul }
      t.rivalCount = t.rivalCount + 1
    end
    t.rivalNext = M.cfg.rivalMin + t.rng() * (M.cfg.rivalMax - M.cfg.rivalMin)
  end
  for i = #t.rivals, 1, -1 do
    local rv = t.rivals[i]
    rv.left = rv.left - dt
    if rv.left <= 0 then
      local n = world.node[rv.node]
      if n then n.claimed = false; n.appeal = rv.appeal end
      table.remove(t.rivals, i)
    end
  end
end

-- The scent-decay multiplier this tick. scent.update reads it through
-- sim/init so the rain has exactly one mechanical effect, in one place.
function M.scentMul(t)
  return (t.rain > 0) and M.cfg.rainScentMul or 1.0
end

function M.isRaining(t) return t.rain > 0 end

function M.digest(t)
  return string.format(
    "spiders=%d beetles=%d rain=%.1f rivals=%d sc=%d bc=%d rc=%d vc=%d k=%d/%d",
    #t.spiders, #(t.beetles or {}), t.rain, #t.rivals,
    t.spiderCount, t.beetleCount or 0, t.rainCount, t.rivalCount,
    t.spidersKilled or 0, t.beetlesKilled or 0)
end

return M
