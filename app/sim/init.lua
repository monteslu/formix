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
                         { owner = "you", queens = { { layTimer = 0 } }, seen = true })
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
  }
  s.world = W.new(rng)
  s.agents = A.new(s.world, rng)

  if level and not level.generated then
    campaign.build(level, s.world, W, s.agents, A)
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
    -- Everything inside an established colony's radius is watched from it.
    local ns = W.neighbours(s.world, n)
    for k = 1, #ns do ns[k].lit = true; ns[k].observed = true end
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
  for i = 1, s.agents.n do
    local ant = s.agents.pool[i]
    if ant.side == A.YOU and ant.at then
      local n = s.world.node[ant.at]
      if n then
        n.observed = true
        n.held = true
        -- ...and the mounds within its reach, so a squad sees who lives
        -- next door. Ground is NOT lit by this: `lit` still needs a queen.
        local ns = W.neighbours(s.world, n)
        for k = 1, #ns do ns[k].observed = true end
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
    local spent = 0
    for i = s.agents.n, 1, -1 do
      if spent >= M.cost.queen then break end
      local ant = s.agents.pool[i]
      if ant.at == n.id and ant.side == A.YOU then
        A.kill(s.agents, i)
        spent = spent + 1
      end
    end
    n.queens[#n.queens + 1] = { layTimer = 0 }
    print(string.format("@queen node=%s spent=%d queens=%d garrison=%d",
      tostring(n.id), spent, #n.queens, A.garrison(s.agents, n.id, A.YOU)))
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
    local spent = 0
    for i = s.agents.n, 1, -1 do
      if spent >= M.cost.upgrade then break end
      local ant = s.agents.pool[i]
      if ant.at == n.id and ant.side == A.YOU then
        A.kill(s.agents, i)
        spent = spent + 1
      end
    end
    n[stat] = (n[stat] or 1) + 0.35
    n.upgrades = n.upgrades + 1
    s.events[#s.events + 1] = { kind = "upgraded", node = n.id,
                                stat = stat, t = s.time }
    return true
  end
  return false
end

function M.update(s, dt)
  if s.paused then return end
  s.time = s.time + dt
  s.ticks = s.ticks + 1
  s.world.time = s.time

  -- THE RUN CAN NEVER BECOME UNWINNABLE.
  --
  -- Production comes ONLY from queens, and a queen costs ten ants -- so a
  -- colony with no queen and fewer than ten ants can never make another
  -- ant, never raise a queen, and never do anything again. Nothing told
  -- the player, either: the game just sat there. A player who spent their
  -- ants before understanding the economy was simply finished, staring at
  -- a board that would not move.
  --
  -- A queenless colony below the price of a queen gets a slow trickle at
  -- its home mound -- far slower than a real queen, so it is never a
  -- strategy, only a floor. The moment a queen exists this stops entirely.
  do
    local queens, ants = 0, 0
    for i = 1, #s.world.nodes do
      queens = queens + #(s.world.nodes[i].queens or {})
    end
    for i = 1, s.agents.n do
      if s.agents.pool[i].side == A.YOU then ants = ants + 1 end
    end
    if queens == 0 and ants < M.cost.queen then
      s.reliefTimer = (s.reliefTimer or 0) + dt
      if s.reliefTimer >= 6 then
        s.reliefTimer = 0
        local home = s.world.node[s.world.homeId]
        if not (home and home.owner == A.YOU) then
          for i = 1, #s.world.nodes do
            local n = s.world.nodes[i]
            if n.owner == A.YOU then home = n; break end
          end
        end
        if home then A.spawn(s.agents, home.id, A.YOU) end
      end
    else
      s.reliefTimer = 0
    end
  end

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
      for qi = 1, #n.queens do
        local q = n.queens[qi]
        q.layTimer = (q.layTimer or 0) + dt * rate
        if q.layTimer >= period then
          q.layTimer = q.layTimer - period
          if #n.brood < room then
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

  A.update(s.agents, dt)
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
  }
end

function M.dump(s)
  return table.concat({
    string.format("t=%.3f ticks=%d seed=%d", s.time, s.ticks, s.seed),
    "world " .. W.digest(s.world),
    "agents " .. A.digest(s.agents),
  }, "\n")
end

return M
