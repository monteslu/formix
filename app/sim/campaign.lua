-- campaign.lua - hand-built openings that teach by their SHAPE.
--
-- Small authored levels, each introducing one idea, are how a strategy
-- game becomes learnable without a tutorial popup: the MAP is the lesson. A generated map cannot do this, because
-- it cannot guarantee that the only sensible move is the one being
-- taught.
--
-- No objectives box, no failure, no timer. A level arranges the ground so
-- its lesson is the obvious thing to try, and withholds everything that
-- would muddy it.

local M = {}

-- SPACING IS THE NETWORK. With every mound inside every other mound's
-- radius the graph is complete and the orbit rule says nothing -- there
-- is no "two hops away", no frontier, and no reason to care which mound
-- you take first. Positions are spread so a mound typically has TWO OR
-- THREE neighbours, which is what makes a path a path.
M.levels = {
  {
    id = "gather",
    name = "Gather",
    -- LESSON: send ants, and ten of them make a queen.
    --
    -- You start with several mounds and NOT ENOUGH ants on any one of
    -- them to raise a queen -- but enough in total. So the only move that
    -- goes anywhere is to pull them together, and the moment they arrive
    -- the panel offers the queen. Two ideas (a send moves real ants; ten
    -- ants buy production) taught by arithmetic rather than by text.
    blurb = "No mound has ten ants. Gather them.",
    steps = {
      "Press  A  on a mound to pick up its ants",
      "Aim with the  D-PAD, then  A  to send them",
      "Ten ants in one mound can raise a queen -- press  Y",
      "She lays larvae. They hatch into workers.",
    },
    -- Deliberately no rivals and nothing hostile.
    nodes = {
      { kind = "plain", x = 0, y = 0,    own = true, ants = 4 },
      { kind = "small", x = 688, y = -336, own = true, ants = 3 },
      { kind = "small", x = -608, y = 384,  own = true, ants = 3 },
      { kind = "plain", x = 336, y = 752,  own = true, ants = 2 },
      -- Two neutral mounds in reach, so once a queen is producing there
      -- is somewhere obvious to spend the ants she makes.
      { kind = "plain", x = -832, y = -528 },
      { kind = "rich",  x = 1024, y = 400 },
    },
  },
  {
    id = "settle",
    name = "Settle",
    -- LESSON: a colony is FOUR working mounds, not one. You start with
    -- ten ants and one queen -- exactly the position mission 1 ends in --
    -- and the level is finished when four mounds are yours AND queened.
    --
    -- Ten ants is deliberately not enough to do it directly: ten buys one
    -- queen, so spending them all at the start leaves nothing to expand
    -- with. The rhythm the level forces is take -> let it fill -> queen
    -- it -> let THAT one pay for the next, which is the whole economy in
    -- four steps.
    blurb = "Ten ants. Four mounds, each with a queen of its own.",
    steps = {
      "Send ants to an empty mound to take it",
      "Wait for it to fill, then press  Y  to raise its queen",
      "Each queen pays for the next mound",
      "Four mounds, four queens",
    },
    nodes = {
      { kind = "plain", x = 0, y = 0,   own = true, ants = 10, queens = 1 },
      { kind = "small", x = 768, y = -288 },
      { kind = "small", x = -688, y = 400 },
      { kind = "plain", x = 336, y = 800 },
      -- Two further out, reachable only once a neighbour is held: the
      -- orbit rule taught by the shape of the map rather than by text.
      { kind = "rich",  x = 1568, y = -512 },
      -- 860 UNITS FROM n3, WHICH CAN ACTUALLY REACH IT. At (-1360,-400)
      -- this mound was 1045 from n3 -- and n3 is a `small` mound with a
      -- reach of 1000, so it was short by 44. Every other mound was
      -- further still, which made it unreachable from ANYWHERE and the
      -- level literally unfinishable. Still out of home's 1150 reach
      -- (1268), so it keeps the lesson: take n3 first, then relay.
      { kind = "plain", x = -1241, y = -259 },
    },
  },
  {
    id = "discover",
    name = "Neighbours",
    -- LESSON: the garden is not empty, and ground can be taken FROM
    -- someone. A single red colony sits in the far corner, small and
    -- quiet. It is outside your reach at the start, so the level opens
    -- exactly like Settle -- expand, queen, expand -- until the frontier
    -- touches red ground and the character of the game changes.
    --
    -- IT DOES NOT COME FOR YOU FIRST. `wakeOnContact` keeps the rival
    -- brain asleep until you can actually see it, so a new player is
    -- never punished for exploring slowly. Once discovered it plays the
    -- ordinary rival game: reinforces, queens, and pushes back.
    blurb = "You are not alone out here. Find the red mound.",
    steps = {
      "Expand as before -- take ground, raise queens",
      "Red ants hold ground too",
      "Send more than they have, and the mound changes hands",
    },
    wakeOnContact = true,
    nodes = {
      { kind = "plain", x = 0, y = 0,   own = true, ants = 12, queens = 1 },
      { kind = "small", x = 704, y = -336 },
      { kind = "small", x = -640, y = 352 },
      { kind = "plain", x = 208, y = 848 },
      -- The bridge: holding this is what brings red into reach.
      { kind = "plain", x = 1216, y = 208 },
      -- THE NEIGHBOUR IS A COLONY, not a token.
      --
      -- One mound with eight ants was scenery: the player grew to three
      -- hundred while it slept, walked over and annihilated it without
      -- ever seeing a fight. Two mounds, two queens between them and a
      -- garrison that keeps growing (slowly) while undiscovered makes
      -- contact an actual event -- you have to bring a real column, and
      -- losing the first attack is survivable rather than the end.
      { kind = "plain", x = 1888, y = -160, foe = "red", ants = 20, queens = 2 },
      { kind = "small", x = 1520, y = 560,  foe = "red", ants = 10, queens = 1 },
    },
  },
  {
    id = "war",
    name = "War",
    -- LESSON: everything at once, against opponents who are doing the
    -- same thing you are. Two rival colonies, on opposite sides, both
    -- awake from the first second and both expanding into the neutral
    -- middle. The ground between you is the game.
    --
    -- They fight EACH OTHER as well as you -- rival.update runs per side
    -- and simply attacks the weakest thing in reach -- so the map is a
    -- three-way rather than two-on-one, and letting them meet first is a
    -- real strategy rather than an exploit.
    blurb = "Two colonies. Neither of them yours.",
    steps = {
      "Hold what you take -- an empty mound is an invitation",
      "They expand while you do; the middle is the prize",
      "Take enough of the field and it is over",
    },
    -- THE MAP HAS TO BE SMALL ENOUGH TO FIGHT ON. The first version put
    -- the three colonies in opposite corners of a field 3456 units across
    -- while a mound reaches ~1150 -- so every side expanded into its own
    -- corner, ran out of neutral ground and stopped. Two hundred seconds
    -- in, nobody had ever met anybody: a war map with no war.
    --
    -- These positions are laid out so that ONE mound taken from the middle
    -- puts each colony in reach of the next. The contested rich pair sits
    -- between all three.
    nodes = {
      { kind = "home",  x = 0, y = 0,     own = true, ants = 16, queens = 1 },
      { kind = "small", x = -430, y = 470 },
      { kind = "small", x = 450, y = 500 },
      -- The contested middle: rich ground nobody starts with, inside
      -- everyone's second step.
      { kind = "rich",  x = -250, y = -640 },
      { kind = "rich",  x = 300, y = -660 },
      -- The stepping stones. Each is within reach of a capital AND of the
      -- middle, so holding one is what brings two colonies into contact.
      { kind = "plain", x = -880, y = -170 },
      { kind = "plain", x = 900,  y = -150 },
      -- West colony.
      { kind = "plain", x = -1380, y = -620, foe = "red",  ants = 18, queens = 1 },
      { kind = "small", x = -1180, y = 240,  foe = "red",  ants = 5 },
      -- East colony.
      { kind = "plain", x = 1400, y = -640,  foe = "gold", ants = 18, queens = 1 },
      { kind = "small", x = 1210, y = 220,   foe = "gold", ants = 5 },
    },
  },
  {
    id = "open",
    name = "The open field",
    blurb = "Everything, all at once.",
    generated = true,
  },
}

function M.byId(id)
  for i = 1, #M.levels do
    if M.levels[i].id == id then return M.levels[i], i end
  end
  return nil
end

function M.count() return #M.levels end

function M.next(id)
  local _, i = M.byId(id)
  if not i then return nil end
  return M.levels[i + 1]
end

-- WHICH STEP THE PLAYER IS ON, read from the world rather than a script.
-- A tutorial that advances on a timer tells someone who is stuck to hurry
-- up; one that reads the actual state waits for them.
function M.step(level, world, intents, agents)
  if not level or not level.steps then return nil end
  local A = require("sim.agents")
  -- Any queen beyond the ones the level started with means the lesson
  -- has landed.
  local queens = 0
  for i = 1, #world.nodes do
    queens = queens + #(world.nodes[i].queens or {})
  end
  if level.id == "gather" then
    if queens > 0 then return 4 end
    -- Ten ants gathered anywhere: the queen is now affordable.
    for i = 1, #world.nodes do
      local n = world.nodes[i]
      if n.owner == "you" and A.garrison(agents, n.id, "you") >= 10 then
        return 3
      end
    end
    if intents and intents.selected then return 2 end
    return 1
  end
  if level.id == "settle" then
    local owned, queened = 0, 0
    for i = 1, #world.nodes do
      local n = world.nodes[i]
      if n.owner == "you" then
        owned = owned + 1
        if #(n.queens or {}) > 0 then queened = queened + 1 end
      end
    end
    if queened >= 3 then return 4 end
    if queened >= 2 then return 3 end
    if owned >= 2 then return 2 end
    return 1
  end
  if level.id == "discover" then
    -- The hint follows the frontier: expand, then meet them, then learn
    -- that their ground can be taken like anyone's.
    local foeSeen = false
    for i = 1, #world.nodes do
      local n = world.nodes[i]
      if n.owner and n.owner ~= "you" and n.observed then foeSeen = true end
    end
    if foeSeen then return 3 end
    if queens > 1 then return 2 end
    return 1
  end
  if level.id == "war" then
    local mine = 0
    for i = 1, #world.nodes do
      if world.nodes[i].owner == "you" then mine = mine + 1 end
    end
    if mine >= 4 then return 3 end
    if mine >= 2 then return 2 end
    return 1
  end
  if intents and intents.selected then return 2 end
  return 1
end

-- Finished when the player has done the thing the level teaches.
function M.complete(level, world, agents)
  if not level or level.generated then return false end
  local owned, total = 0, 0
  local queens = 0
  for i = 1, #world.nodes do
    local n = world.nodes[i]
    total = total + 1
    if n.owner == "you" then owned = owned + 1 end
    queens = queens + #(n.queens or {})
  end
  if level.id == "gather" then
    -- The lesson is the queen, not the map.
    return queens >= 1
  end
  if level.id == "settle" then
    -- FOUR FULLY COLONISED MOUNDS. A queen in each, not merely ground
    -- taken: the lesson is that a mound without a queen is only
    -- territory, so counting ownership would let the player finish
    -- without learning it.
    local queened = 0
    for i = 1, #world.nodes do
      local n = world.nodes[i]
      if n.owner == "you" and #(n.queens or {}) > 0 then queened = queened + 1 end
    end
    return queened >= 4
  end
  if level.id == "discover" then
    -- The lesson is that ground can be taken FROM someone, so the level
    -- ends when no enemy holds any -- not when you have expanded a lot.
    for i = 1, #world.nodes do
      local n = world.nodes[i]
      if n.owner and n.owner ~= "you" then return false end
    end
    return true
  end
  if level.id == "war" then
    -- Both colonies broken. Same rule as `discover` and for the same
    -- reason; the difference is how much stands between you and it.
    for i = 1, #world.nodes do
      local n = world.nodes[i]
      if n.owner and n.owner ~= "you" then return false end
    end
    return true
  end
  return owned >= math.max(2, math.ceil(total * 0.66))
end

-- Build a level's map into an empty world. Returns true if it did; a
-- `generated` level is left to the normal map builder.
function M.build(level, world, W, agents, A)
  if not level or level.generated then return false end
  local made = {}
  for i = 1, #level.nodes do
    local spec = level.nodes[i]
    -- THREE KINDS OF GROUND: yours (`own`), someone else's (`foe`, a side
    -- name like "red"), or nobody's. `foe` is a string rather than a flag
    -- because the late levels field more than one enemy colony and they
    -- have to be able to fight each other as well as you.
    made[i] = W.addNode(world, spec.kind, spec.x, spec.y, {
      owner = spec.own and "you" or spec.foe or nil,
      seen = true,
    })
    if i == 1 then world.homeId = made[i].id end
    for _ = 1, spec.queens or 0 do
      made[i].queens[#made[i].queens + 1] = { layTimer = 0 }
    end
  end
  -- Ants after every mound exists, so spawn can look them up. An ant
  -- belongs to whoever holds the ground it starts on, so an enemy mound
  -- comes with an enemy garrison rather than a free gift.
  for i = 1, #level.nodes do
    local spec = level.nodes[i]
    local side = spec.own and "you" or spec.foe or "you"
    for _ = 1, spec.ants or 0 do
      A.spawn(agents, made[i].id, side)
    end
  end
  return true
end

return M
