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
  --
  -- TEN, AND IT MUST NOT EXCEED THE SATURATION CAP. This was 14, which
  -- was fine while a mound could grow without limit -- but a mound now
  -- stops laying at ten workers per queen, so a one-queen mound can
  -- never reach fourteen by growing and the colony never queens again.
  -- The whole war map deadlocked on that one number: every side frozen
  -- at its opening garrison, no second queen anywhere, nobody ever
  -- clearing the threshold to attack. A threshold above the ceiling is
  -- not a slow rival, it is a stopped one.
  queenAt   = 10,     -- ants at a mound before it spends ten on a queen
  -- Below this it goes foraging instead of expanding or fighting. A
  -- colony that fights while its stores are empty wins the mound and
  -- then starves on it.
  foodLow   = 18,
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
      -- Through the shared spend, so a rival's laden workers bank their
      -- food exactly as the player's do. Two colonies playing by
      -- different accounting rules is how an opponent stops being one.
      local _, banked = A.spend(agents, n.id, r.side, 10)
      if sim and banked > 0 then
        require("sim.init").addFood(sim, r.side, banked)
      end
      n.queens[#n.queens + 1] = { layTimer = 0 }
      return
    end
  end

  -- 1b. EAT. A colony with an empty pantry is a colony that has stopped,
  --     and it stops silently -- the mounds are still there, the queens
  --     are still sitting on them, and nothing grows ever again. So when
  --     the stores run low it goes and gets food, which is the same move
  --     the player makes and for the same reason.
  --
  --     It walks to the nearest place with something in it. Deliberately
  --     not the richest: an opponent that always makes the optimal
  --     foraging choice is doing arithmetic the player cannot see.
  -- `sim` here is the sim STATE, not the module (see the signature); the
  -- module is fetched at call time, which is also how the queen branch
  -- above reaches it without a require cycle.
  local SIM = require("sim.init")
  if sim and SIM.foodOf(sim, r.side) < M.cfg.foodLow then
    local bestL, bestFrom, bestD = nil, nil, math.huge
    for i = 1, #mine do
      local h = mine[i]
      if h.ants - M.cfg.keep > 1 then
        for j = 1, #(world.locs or {}) do
          local L = world.locs[j]
          -- Somewhere with food, that is not somebody else's, and that
          -- is not guarded by something it would only feed.
          if (L.items or 0) > 0 and (L.guard or 0) == 0
             and (L.owner == nil or L.owner == r.side)
             and W.inRange(world, h.node, L) then
            local d = W.dist(h.node, L)
            if d < bestD then bestL, bestFrom, bestD = L, h, d end
          end
        end
      end
    end
    if bestL then
      -- Send only as many as there is food to pick up: one ant carries
      -- one item, so a column of thirty at a patch of four is
      -- twenty-six ants standing about where the enemy can see them.
      local want = math.min(bestFrom.ants - M.cfg.keep, bestL.items)
      if want > 0 and A.send(agents, bestFrom.node.id, bestL.id,
                             want, r.side) > 0 then
        if M.debug then
          print(string.format("@rival %s forages %s with %d", r.side,
                              bestL.id, want))
        end
        return
      end
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

  -- 2b/3. MASS, THEN STRIKE.
  --
  --     It picks the weakest thing it can reach, names the mound of its
  --     own that faces it as the staging ground, and walks ants there
  --     from everywhere else until that one mound can win -- then throws
  --     them. That is what a player does before an assault, and it is the
  --     only way anybody attacks anything now that mounds have a
  --     ceiling.
  --
  --     THE OLD RULE EQUALISED INSTEAD OF CONCENTRATING: ants walked from
  --     the fattest rear mound to the THINNEST front one, which spreads a
  --     colony evenly along its border. That was right while a mound
  --     could grow without limit -- somebody eventually got fat enough to
  --     attack on their own -- but production now stops at ten workers
  --     per queen, so every mound sits at ten, the threshold needs closer
  --     to forty, and an army of a hundred and eighty ants stares at a
  --     home mound it outnumbers six to one for the entire match. Spread
  --     evenly, a big colony is a big colony of small garrisons.
  local tgt, staging, tgtDef = nil, nil, math.huge
  for i = 1, #mine do
    local h = mine[i]
    for j = 1, #world.nodes do
      local t = world.nodes[j]
      if t.owner and t.owner ~= r.side and W.inRange(world, h.node, t) then
        local def = A.garrison(agents, t.id, t.owner) + (t.energy or 0)
        -- Weakest target wins; ties break toward the mound that already
        -- has the most ants standing on it, so the staging ground does
        -- not wander from tick to tick.
        if def < tgtDef or (t == tgt and h.ants > (staging and staging.ants or -1)) then
          tgt, staging, tgtDef = t, h, def
        end
      end
    end
  end

  if tgt and staging then
    local need = tgtDef * M.cfg.attackAt
    local spare = staging.ants - M.cfg.keep
    if spare > need and spare > 3 then
      A.send(agents, staging.node.id, tgt.id, spare, r.side)
      print(string.format("@rival %s attacks %s with %d", r.side, tgt.id,
                          math.floor(spare)))
      return
    end
    -- NOT ENOUGH YET: walk another column in. The donor is the fattest
    -- mound that is not the staging ground itself, and it keeps back
    -- `keep` so nowhere is left completely empty behind the front.
    local donor, donorAnts = nil, -1
    for i = 1, #mine do
      local h = mine[i]
      if h.node ~= staging.node and h.ants > donorAnts then
        donor, donorAnts = h, h.ants
      end
    end
    if donor and donorAnts - M.cfg.keep >= 4 then
      local col = donorAnts - M.cfg.keep
      -- The network must actually connect them; a donor cut off behind
      -- enemy ground cannot help and must not silently swallow the tick.
      if A.send(agents, donor.node.id, staging.node.id, col, r.side) > 0 then
        if M.debug then
          print(string.format("@rival %s masses %d at %s for %s (need %d, have %d)",
                r.side, math.floor(col), staging.node.id, tgt.id,
                math.floor(need), math.floor(spare)))
        end
        return
      end
    end
  end

  -- Why NOT: the reason an AI does nothing is invisible otherwise, and
  -- tuning constants blind is how this stayed broken.
  if M.debug then
    if tgt and staging then
      print(string.format("@rival %s idle: staging %s has %d vs %s def=%d",
        r.side, staging.node.id, math.floor(staging.ants - M.cfg.keep),
        tgt.id, math.floor(tgtDef)))
    else
      print("@rival " .. r.side .. " idle: none-in-range")
    end
  end
end

return M
