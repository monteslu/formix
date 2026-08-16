-- rival.lua - the red colony.
--
-- A rival plays the SAME GAME you do -- it holds mounds, raises queens
-- and sends ants at what it can reach -- because an enemy that follows
-- different rules is a scripted event wearing an opponent's face. Every
-- move it makes is one you could have made, and one you can read.
--
-- It is deliberately not clever. The opponent is patient rather than
-- sharp, and the pleasure is in out-expanding it, not out-twitching it. This one reinforces what it holds, takes empty
-- ground it can reach, and throws itself at your weakest mound when it
-- has the numbers.

local W = require("sim.world")
local A = require("sim.agents")

local M = {}
M.debug = false

M.cfg = {
  think     = 2.6,    -- seconds between decisions; slow on purpose
  keep      = 3,      -- ants it will not send away from a mound
  -- 1.15, NOT 1.35. With `keep` on top, a 1.35 margin meant a colony
  -- needed roughly twice the defender's strength before it would commit --
  -- and since it spends ten ants on every queen it can afford, its mounds
  -- sat at four or five ants and NEVER cleared the bar. Two rival colonies
  -- on the war map expanded into neutral ground, met, and then simply
  -- stared at each other for the rest of the game.
  attackAt  = 1.15,
  -- QUEENS ONLY WHILE THERE IS ROOM TO GROW. At 12 it queened every mound
  -- forever, converting the army into production it had no way to spend.
  -- Above `armyAt` it saves instead, which is what turns production into
  -- an attack.
  queenAt   = 14,     -- ants at a mound before it spends ten on a queen
  armyAt    = 26,     -- total ants above which it stops queening and fights
}

function M.new(rng, side)
  return { rng = rng or math.random, side = side or "rival", timer = 0 }
end

-- Everything this side holds, with how many ants are standing on each.
local function holdings(r, world, agents)
  local out = {}
  for i = 1, #world.nodes do
    local n = world.nodes[i]
    if n.owner == r.side then
      out[#out + 1] = { node = n, ants = A.garrison(agents, n.id, r.side) }
    end
  end
  return out
end

function M.update(r, world, agents, dt, sim)
  r.timer = r.timer - dt
  if r.timer > 0 then return end
  r.timer = M.cfg.think * (0.7 + r.rng() * 0.6)

  local mine = holdings(r, world, agents)
  if #mine == 0 then return end

  -- 1. QUEENS FIRST, UNTIL THERE IS AN ARMY. A rival that never grows is
  --    a target rather than an opponent -- but one that queens forever
  --    converts every ant into production it never spends, which is how
  --    two colonies ended up sitting at four ants a mound, permanently
  --    below the threshold to attack anything.
  local total = 0
  for i = 1, #mine do total = total + mine[i].ants end
  local wantQueens = total < (M.cfg.armyAt or 26)

  for i = 1, #mine do
    local h = mine[i]
    local n = h.node
    if wantQueens and h.ants >= M.cfg.queenAt
       and #(n.queens or {}) < (n.maxQueens or 3) then
      local spent = 0
      for k = agents.n, 1, -1 do
        if spent >= 10 then break end
        local ant = agents.pool[k]
        if ant.at == n.id and ant.side == r.side then
          A.kill(agents, k)
          spent = spent + 1
        end
      end
      n.queens[#n.queens + 1] = { layTimer = 0 }
      return
    end
  end

  -- 2. TAKE EMPTY GROUND it can reach, from whichever mound has the most
  --    to spare. Expansion beats aggression while there is free land --
  --    the same judgement the player is making.
  local best, bestFrom, bestScore = nil, nil, -1
  for i = 1, #mine do
    local h = mine[i]
    local spare = h.ants - M.cfg.keep
    if spare > 2 then
      for j = 1, #world.nodes do
        local t = world.nodes[j]
        if not t.owner and W.inRange(world, h.node, t) then
          -- Prefer big mounds and short trips.
          local score = (t.maxQueens or 2) * 10
                        - W.dist(h.node, t) * 0.01
          if score > bestScore then
            best, bestFrom, bestScore = t, h, score
          end
        end
      end
    end
  end
  if best then
    A.send(agents, bestFrom.node.id, best.id,
           bestFrom.ants - M.cfg.keep, r.side)
    return
  end

  -- 2b. REINFORCE THE FRONT. Without this the colony has no way to
  --     concentrate: every ant stays on the mound whose queen laid it, so
  --     the capital sits on thirty while the border mound facing the enemy
  --     has four and can never clear the attack threshold. Two rival
  --     colonies 550 units apart -- easily in reach -- therefore stared at
  --     each other indefinitely.
  --
  --     A front mound is one that can SEE something hostile. Ants walk
  --     from the fattest rear mound to the thinnest front one, which is
  --     the same thing a player does by hand.
  local front, rear, frontAnts, rearAnts = nil, nil, math.huge, -1
  for i = 1, #mine do
    local h = mine[i]
    local facing = false
    for j = 1, #world.nodes do
      local t = world.nodes[j]
      if t.owner and t.owner ~= r.side and W.inRange(world, h.node, t) then
        facing = true
        break
      end
    end
    if facing then
      if h.ants < frontAnts then front, frontAnts = h, h.ants end
    else
      if h.ants > rearAnts then rear, rearAnts = h, h.ants end
    end
  end
  -- Only worth walking if the rear can actually spare a useful column.
  if front and rear and rearAnts - M.cfg.keep >= 4 and rearAnts > frontAnts + 3 then
    A.send(agents, rear.node.id, front.node.id,
           rearAnts - M.cfg.keep, r.side)
    if M.debug then
      print(string.format("@rival %s reinforces %s from %s with %d", r.side,
            front.node.id, rear.node.id, math.floor(rearAnts - M.cfg.keep)))
    end
    return
  end

  -- 3. ATTACK, but only with the numbers. It looks for the weakest thing
  --    it can reach and only commits when it has a real margin, so a
  --    player who keeps a garrison is genuinely safer -- which is what
  --    makes garrisoning a decision.
  local tgt, from, tgtScore = nil, nil, math.huge
  for i = 1, #mine do
    local h = mine[i]
    local spare = h.ants - M.cfg.keep
    if spare > 3 then
      for j = 1, #world.nodes do
        local t = world.nodes[j]
        if t.owner and t.owner ~= r.side
           and W.inRange(world, h.node, t) then
          local def = A.garrison(agents, t.id, t.owner) + (t.energy or 0)
          if spare > def * M.cfg.attackAt and def < tgtScore then
            tgt, from, tgtScore = t, h, def
          end
        end
      end
    end
  end
  if tgt then
    A.send(agents, from.node.id, tgt.id, from.ants - M.cfg.keep, r.side)
    print(string.format("@rival %s attacks %s with %d", r.side, tgt.id,
                        math.floor(from.ants - M.cfg.keep)))
  elseif M.debug then
    -- Why NOT: the reason an AI does nothing is invisible otherwise, and
    -- tuning constants blind is how this stayed broken.
    local best = "none-in-range"
    for i = 1, #mine do
      local h = mine[i]
      for j = 1, #world.nodes do
        local t = world.nodes[j]
        if t.owner and t.owner ~= r.side and W.inRange(world, h.node, t) then
          best = string.format("%s spare=%d vs %s def=%d", h.node.id,
            math.floor(h.ants - M.cfg.keep), t.id,
            math.floor(A.garrison(agents, t.id, t.owner) + (t.energy or 0)))
        end
      end
    end
    print("@rival " .. r.side .. " idle: " .. best)
  end
end

return M
