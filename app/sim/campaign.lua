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
    campaign = true,
    name = "Gather",
    -- LESSON: send ants, and ten of them make a queen.
    --
    -- You start with several mounds and NOT ENOUGH ants on any one of
    -- them to raise a queen -- but enough in total. So the only move that
    -- goes anywhere is to pull them together, and the moment they arrive
    -- the panel offers the queen. Two ideas (a send moves real ants; ten
    -- ants buy production) taught by arithmetic rather than by text.
    blurb = "No mound has ten ants. Gather them.",
    -- THE LESSON GREW ONE CLAUSE when queens started eating. It used to
    -- end at "she lays larvae", which is now only true if somebody has
    -- fed her -- so the level teaches the whole loop: gather, raise her,
    -- and bring her something to eat. The aphids are placed in easy
    -- reach and are the first food a player ever sees.
    --
    -- AND THE FOOD STEP BECAME A SCOUTING STEP when the three-state fog
    -- landed. It used to say "Send ants to the aphids", which stopped
    -- being true the moment nothing is named until you have stood on it:
    -- at boot both clusters are anonymous grey circles, so an instruction
    -- naming the aphids would be telling the player something the game
    -- has deliberately stopped telling them. Discovery is now part of the
    -- first lesson rather than something the tutorial routes around --
    -- walk to a grey clump and find out. Here it is always aphids; later
    -- it is sometimes a spider, and the player has already learned the
    -- move that finds out which.
    steps = {
      "Press  A  on a mound to pick up its ants",
      "Aim with the  D-PAD, then  A  to send them",
      "Ten ants in one mound can raise a queen -- press  Y",
      "She needs food. Send ants to a grey clump and look.",
      "They carry it home. She lays. They hatch.",
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
    -- Two clusters, both inside the opening position's reach, so the
    -- first meal is never a puzzle about geography. Aphids rather than
    -- grain because they are worth four each: one trip visibly changes
    -- the number, which is what makes the lesson land.
    locations = {
      { kind = "aphids", x = -260, y = -760, items = 4 },
      -- Moved off (880,300): the rich mound sits at (1024,400) with a
      -- 104-unit radius, and an aphid patch's own radius is 74 -- 175
      -- units apart, their circles overlapped by 3. Small in world
      -- units, real on screen: the mound's earth fill and grit spill
      -- draw past its bare radius, so the aphids sat partly on top of
      -- the hill. Caught by tools/test-overlap.mjs, which checks every
      -- hand-built level for exactly this.
      { kind = "aphids", x = 700,  y = 700,  items = 4 },
    },
  },
  {
    id = "settle",
    campaign = true,
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
    -- Grain, and this is where the player meets the slow faucet: it
    -- comes back, so the mound beside it is worth holding rather than
    -- stripping. One patch near the start and one out by the far
    -- ground, so expanding and eating pull in the same direction.
    locations = {
      { kind = "grain",  x = 420,  y = -640, items = 6 },
      { kind = "aphids", x = -900, y = 820,  items = 5 },
      { kind = "grain",  x = 1500, y = 300,  items = 4 },
    },
  },
  {
    id = "discover",
    campaign = true,
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
    -- A BIG ARMY WITH NO SUPPLY LINE. This is the first board with an
    -- enemy on it, and it should be a fight the player WINS -- the lesson
    -- is "ground can be taken from someone", not "you are outmatched".
    --
    -- So red is dangerous the way a standing garrison is dangerous, not
    -- the way an economy is: she starts with more ants than you and a
    -- pantry that runs out. Twelve food is a dozen larvae and then
    -- nothing, because every location on this map is on the PLAYER's side
    -- of it. She cannot forage her way back into the game; she can only
    -- spend what she was given.
    --
    -- (Contrast the war map, where both rivals get 90 and a grain patch
    -- behind each colony. That is the board where the enemy is supposed
    -- to compound.)
    startFood = { red = 12 },
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
      -- HEADROOM UNDER THE CAP, or she is asleep AND full and the
      -- "keeps growing while undiscovered" promise above is a lie. A
      -- mound stops laying at ten workers per queen, and this pair was
      -- authored at exactly 20/2 and 10/1 -- both already at the ceiling,
      -- so red sat at thirty ants for the whole exploration and arrived
      -- as the same statue the frozen-rival note warns about. Two queens
      -- over twelve workers leaves room to actually fill up.
      -- THE FIRST ENEMY A PLAYER EVER MEETS SHOULD BE EASY (Luis,
      -- 2026-08-20: "the first time discovering an enemy in the previous
      -- level should be easy"). The note above had the right INTENT -- "a
      -- fight the player WINS" -- and then authored twenty-two ants and
      -- three queens against the player's twelve and one. Nearly twice the
      -- bodies and triple the queens is not an introduction, it is a wall,
      -- and a player who walks in on their first contact loses the column
      -- and the lesson with it.
      --
      -- Red still fields MORE than you, because "send more than they have"
      -- is the step this board teaches and a garrison you outnumber
      -- teaches nothing. Fourteen against twelve is a real fight you can
      -- win with one good column instead of a build-up: enough that
      -- walking in with six loses, little enough that the first honest
      -- attempt works. Two queens, not three, so she grows slower than
      -- the player who is taking ground.
      --
      -- Her pantry still runs dry (12 food, every location on the
      -- player's side), so the "an army is something you BUILD toward"
      -- lesson survives intact -- it is just no longer gated behind
      -- losing once to learn it.
      -- 14 ANTS, BUT KEEP THE SECOND QUEEN. The ant count is what makes
      -- the first contact winnable; the QUEENS are what keep red a living
      -- colony that regrows behind its front instead of a fixed garrison
      -- the player rolls straight through. Cutting both at once (a first
      -- pass went 22/3 -> 14/2 by dropping the capital to one queen) made
      -- the walk in test-fog3 capture BOTH red mounds, leaving the board
      -- with nothing discovered-but-enemy-held to render grey -- a gate
      -- failure that was really a level-design change.
      { kind = "plain", x = 1888, y = -160, foe = "red", ants = 10, queens = 2 },
      { kind = "small", x = 1520, y = 560,  foe = "red", ants = 4,  queens = 1 },
    },
    -- A SPIDER ON THE WAY TO RED, and this is where a grey clump first
    -- bites. It sits off the direct line rather than blocking it, so
    -- walking into her is a choice the player made about ground that
    -- looked worth having -- and she is worth having: eight legs is a
    -- bigger meal than anything else on the board.
    -- THE FOOD IS ALL ON YOUR SIDE, and that is the map's whole balance.
    --
    -- Red starts bigger but with a pantry that runs dry; you start smaller
    -- next to two grain patches that never do. Every location sits WEST of
    -- home, red is far to the east, and the mounds you hold are between
    -- them -- so for red to reach a food line she would have to take a
    -- couple of your mounds first, which is a fight she has to win before
    -- she can afford to fight. In practice she cannot, which is exactly
    -- the "easy first win" this level is for.
    --
    -- Grain rather than aphids for the two near ones, because grain grows
    -- back: the player's advantage should compound quietly while they work
    -- out what to do with it.
    locations = {
      { kind = "grain",  x = -420, y = -520, items = 6 },
      { kind = "grain",  x = -560, y = 620,  items = 6 },
      { kind = "aphids", x = 208,  y = 1180, items = 5 },
      -- Still off the road to red: a grey clump that bites, met by choice.
      { kind = "spider", x = 1180, y = -560 },
    },
  },
  {
    id = "war",
    campaign = true,
    name = "War",
    -- LESSON: one opponent doing exactly what you are doing, awake from
    -- the first tick. Discover taught you that someone else is out here;
    -- this is the first level where they are AWAKE, FED, and expanding
    -- toward you while you expand toward them. The ground between you is
    -- the game.
    --
    -- ONE RIVAL, NOT TWO (Luis, 2026-08-20: "ramping up 2 enemies at that
    -- point is too much ... right now war is way too hard compared to
    -- previous level"). The jump this replaces was not a ramp, it was a
    -- cliff, and the numbers say so plainly:
    --
    --            rivals   their food   awake from t=0   their ants
    --   discover    1           12          no (*)         22
    --   war (old)   2         90 + 90       yes            46
    --   war (new)   1           45          yes            23
    --
    --   (*) discover's rival sleeps until you find it, so a careless
    --       player meets it on their own schedule. War's does not sleep,
    --       and that alone is the step up this level is for.
    --
    -- So the new War changes ONE variable at a time: same single rival as
    -- discover, comparable ant count, but awake, fed for a real match,
    -- and placed where expansion must collide. Two simultaneous fronts is
    -- a different lesson and belongs to the level AFTER this one (Luis:
    -- "the following level can have multiple enemies").
    blurb = "One colony, awake and coming for the middle.",
    steps = {
      "Hold what you take -- an empty mound is an invitation",
      "They expand while you do; the middle is the prize",
      "Take enough of the field and it is over",
    },
    -- FED FOR A REAL MATCH, NOT FOR A SIEGE. 45 keeps the rival queening
    -- and pushing for the length of a match without the bottomless 90 that
    -- let the old pair out-produce anything the player could answer.
    startFood = { red = 45 },
    -- THE MAP HAS TO BE SMALL ENOUGH TO FIGHT ON. The first version put
    -- the colonies in opposite corners of a field 3456 units across while
    -- a mound reaches ~1150 -- so every side expanded into its own corner,
    -- ran out of neutral ground and stopped. Two hundred seconds in,
    -- nobody had ever met anybody: a war map with no war.
    --
    -- OPPOSITE SIDES, one axis. The player holds the west, the rival the
    -- east, and everything worth having is on the line between them.
    -- Laid out so ONE mound taken from the middle puts each colony in
    -- reach of the next (home reaches 1500, plain 1150, small 1000).
    nodes = {
      { kind = "home",  x = -1150, y = 0,    own = true, ants = 16, queens = 1 },
      -- The player's shoulder pair: safe first expansions, and the ground
      -- a counter-attack has to come through.
      { kind = "small", x = -1500, y = 620 },
      { kind = "small", x = -1520, y = -600 },
      -- The stepping stones, one per side, each in reach of its capital
      -- AND of the middle. Holding one is what brings the colonies into
      -- contact, so the fight starts where both players chose it.
      { kind = "plain", x = -540,  y = -300 },
      { kind = "plain", x = 560,   y = -280 },
      -- THE CONTESTED MIDDLE: rich ground nobody starts with, inside
      -- everyone's second step. This is the prize.
      { kind = "rich",  x = 0,     y = 380 },
      { kind = "rich",  x = 20,    y = -800 },
      -- East colony. ONE rival, mirroring the player's own opening rather
      -- than doubling it: a capital plus one small, same as the shoulder
      -- pair, so neither side starts the match ahead.
      -- A `home`, NOT a `plain`. Measured on the first cut of this map:
      -- a plain capital caps at THREE queens, so red spent its whole
      -- pantry queening to that ceiling, sat at five-ant garrisons, and
      -- with `keep = 3` never had the four spare ants `spare > 3` needs to
      -- attack ANYTHING. Three mounds, three queens, zero attacks in 300
      -- seconds -- the exact "expanded, met, then stared at each other"
      -- deadlock the rival cfg comments already warn about twice.
      --
      -- A home mound (maxQueens 4, reach 1500) matches the player's own
      -- capital, which is the point: this is a mirror match, and the rival
      -- needs the same room to grow that the player has.
      { kind = "home",  x = 1200,  y = 0,    foe = "red", ants = 20, queens = 1 },
      { kind = "small", x = 1520,  y = 600,  foe = "red", ants = 6 },
    },
    -- FOOD IN THE MIDDLE, where the fighting is. Grain in the contested
    -- centre makes the ground everyone wants also the ground everyone
    -- needs, so the war is over something rather than for its own sake.
    --
    -- MORE FOOD ON THE PLAYER'S SIDE (Luis, 2026-08-20: "player should
    -- have a little more access to food"). The old map gave each side one
    -- 5-item grain patch behind its capital and put everything else in the
    -- contested centre -- so a player who lost the first exchange had
    -- nothing to rebuild ON, and the level was decided by one fight.
    -- The west now has a patch pair in easy reach of home plus the aphid
    -- windfall, which buys a second attempt without handing over the
    -- middle: the contested food is still the richest ground on the map,
    -- so taking it is still the winning move rather than an optional one.
    locations = {
      -- The player's pantry: both inside home's 1500 reach.
      { kind = "grain",  x = -1560, y = 180,  items = 7 },
      { kind = "grain",  x = -1180, y = -760, items = 6 },
      -- A windfall on the player's shoulder, worth a deliberate send.
      { kind = "aphids", x = -1420, y = 900,  items = 6 },
      -- THE CONTESTED PANTRY, richest on the map and equidistant.
      { kind = "grain",  x = 0,     y = -300, items = 8 },
      { kind = "aphids", x = 40,    y = 900,  items = 6 },
      -- The rival's own patch, or it loses the middle once and stops
      -- being an opponent.
      { kind = "grain",  x = 1560,  y = -300, items = 5 },
    },
  },
  {
    id = "open",
    campaign = true,
    name = "The open field",
    -- LESSON: two fronts at once, and you cannot answer both.
    --
    -- THIS WAS A PLACEHOLDER AND THE CAMPAIGN COULD NOT BE FINISHED.
    -- It was `{ id = "open", campaign = true, generated = true }` and
    -- nothing else -- the last row of the level select, with no nodes, no
    -- locations and no lesson. Worse, `M.complete` returns false for any
    -- generated level, so `open` could never be beaten by anyone: the
    -- final row of the campaign was permanently unwinnable and the game
    -- had no ending.
    --
    -- AUTHORED, NOT GENERATED, for the reason at the top of this file: a
    -- generated map cannot guarantee that the only sensible move is the
    -- one being taught, and the thing being taught here is specifically
    -- SHAPE -- two enemies placed so that committing to one exposes you
    -- to the other. A scatter cannot promise that; it can only promise
    -- that there are two of them somewhere.
    --
    -- TWO ENEMIES (Luis, 2026-08-20: "the following level can have
    -- multiple enemies"). War was cut to a single rival because two awake
    -- colonies straight after discover's one dormant one was a cliff.
    -- That fight did not stop being worth having -- it stopped being the
    -- right SECOND enemy. It is the right fifth one, after a mirror match
    -- has taught what one awake opponent costs.
    blurb = "Two colonies, two directions. You cannot answer both.",
    steps = {
      "Two enemies, and they fight each other as readily as you",
      "Committing everything to one front opens the other",
      "Break them both and the field is yours",
    },
    -- BOTH FED, AND UNEQUALLY. Red is the aggressor with the bigger
    -- pantry; gold starts smaller and slower. Equal opponents would make
    -- the board symmetrical and the choice arbitrary -- which front to
    -- take first should have a right answer that the map states in its
    -- shape and its numbers rather than one the player guesses.
    --
    -- MEASURED AND CUT (2026-08-20). The first authored cut of this board
    -- gave red 55 and gold 40 against a player capital of 18 ants, and a
    -- scripted greedy player was ELIMINATED by 200 seconds -- while the
    -- SAME script on the war map survived the full run. That comparison
    -- is what makes this a level problem rather than a bad script: one
    -- opponent at 45 food is a match, two at 55+40 is not two fronts, it
    -- is a rout. The pantries come down to a shade under War's single
    -- rival EACH, so the pair together is a step up from War rather than
    -- double it -- which is the ramp this level is supposed to be.
    --
    -- They still compound (a patch behind each capital, below), so
    -- neither stops being an opponent after losing the middle once.
    startFood = { red = 40, gold = 30 },
    -- THE SHAPE: you at the west point of a triangle, red north-east,
    -- gold south-east, with the prize in the middle of all three. Each
    -- rival is closer to the middle than you are, so the centre cannot
    -- simply be taken and held early -- and they are within reach of
    -- EACH OTHER, which is the pressure valve that keeps two opponents
    -- from being twice one opponent: each rival brain attacks the
    -- weakest thing in its reach, and sometimes that is the other rival.
    nodes = {
      -- Your capital and the shoulder pair, the same opening the player
      -- has had since War -- so the thing that is new here is the number
      -- of enemies, not the hand you start with.
      -- TWENTY-FOUR AND TWO QUEENS, not eighteen and one. The player has
      -- to garrison two directions from the first minute, and a single
      -- capital's output cannot do that: the measured run above lost the
      -- shoulder pair and then home, because every ant spent on one front
      -- was an ant missing from the other. Two queens is the smallest
      -- change that makes holding two fronts arithmetically possible
      -- rather than a matter of playing perfectly, and it is the same
      -- shape as the lesson -- the answer to two fronts is more
      -- production, not better aim.
      { kind = "home",  x = -1600, y = 0,     own = true, ants = 24, queens = 2 },
      -- The shoulder pair starts GARRISONED here, unlike War's empty
      -- pair. On a one-front board an empty shoulder is a free expansion;
      -- with two rivals it is an open door on whichever side the player
      -- is not looking at, and both were being taken before the player
      -- could reach them.
      { kind = "small", x = -1900, y = 700,  own = true, ants = 4 },
      { kind = "small", x = -1920, y = -680, own = true, ants = 4 },
      -- Your stepping stones, one toward each front. Taking BOTH is what
      -- a player instinctively does and is exactly what the level is
      -- about: it splits a garrison that was only ever big enough for one.
      { kind = "plain", x = -820,  y = -560 },
      { kind = "plain", x = -800,  y = 580 },
      -- THE CONTESTED MIDDLE, richest ground on the board and inside
      -- everyone's second step.
      { kind = "rich",  x = 120,   y = 0 },
      -- THE TWO APPROACHES, one per front, and their positions are a
      -- CONNECTIVITY REQUIREMENT rather than a matter of taste.
      --
      -- At (260,-900) and (240,920) this board was BROKEN: every mound
      -- was reachable from something, but nothing the player could hold
      -- reached either enemy capital, so all four enemy mounds were
      -- stranded and the level could never be won. `test-reachable`
      -- caught it on the first full-suite run and that is exactly what
      -- that gate is for -- the BFS carries forward only through the
      -- SOURCE mound's reach, so "A is 1242 from B and B reaches 1500"
      -- does not connect A to B.
      --
      -- Pushed out to (560,-980) and (540,1000), each approach lands
      -- inside its own enemy capital's reach (954 and 911 against a plain
      -- mound's 1150) and neither reaches the other's (2040 and 2058).
      -- That asymmetry is the design surviving the fix: taking the north
      -- approach opens red and only red.
      { kind = "plain", x = 560,   y = -980 },
      { kind = "plain", x = 540,   y = 1000 },
      -- RED, north-east: the aggressor. A home capital so she has the
      -- room to grow that a plain mound's three-queen ceiling denies --
      -- the exact deadlock the war map hit when its rival was authored
      -- as a plain.
      { kind = "home",  x = 1500,  y = -820, foe = "red",  ants = 18, queens = 1 },
      { kind = "small", x = 1820,  y = -1400, foe = "red", ants = 5 },
      -- GOLD, south-east: smaller and further from the middle, so the
      -- two fronts are not the same fight twice. A player who reads the
      -- board can take gold first and turn on red with one flank quiet.
      { kind = "home",  x = 1440,  y = 860,  foe = "gold", ants = 14, queens = 1 },
      { kind = "small", x = 1800,  y = 1420, foe = "gold", ants = 4 },
    },
    -- FOOD ON EVERY SIDE, weighted to the player. Two enemies means two
    -- rebuilds after two lost exchanges, so the west has to support that
    -- or the level is decided by whichever front goes wrong first.
    locations = {
      -- The player's pantry, both inside home's 1500 reach.
      { kind = "grain",  x = -2000, y = 240,  items = 8 },
      { kind = "grain",  x = -1560, y = -820, items = 7 },
      { kind = "aphids", x = -1880, y = 1020, items = 6 },
      -- The contested centre: the richest ground on the map, equidistant
      -- from all three capitals.
      { kind = "grain",  x = 100,   y = -320, items = 9 },
      { kind = "aphids", x = 140,   y = 380,  items = 7 },
      -- One patch behind each rival, so neither stops being an opponent
      -- after losing the middle once.
      { kind = "grain",  x = 1900,  y = -600, items = 6 },
      { kind = "grain",  x = 1860,  y = 1000, items = 5 },
      -- A SPIDER BETWEEN THE TWO FRONTS, on the line a player walks when
      -- they swing an army from one enemy to the other. Every other
      -- spider in the campaign is met by choice; this one is met by
      -- changing your mind, which is the last thing this board has to
      -- say about committing.
      { kind = "spider", x = 620,   y = 0 },
    },
  },

  -- ── GATE-ONLY BOARDS, past the end of the campaign ────────────────────
  --
  -- Everything below is reachable ONLY by packing an `app/startlevel`
  -- marker naming it. `next()` walks this list in order and stops at the
  -- end of the campaign: `open` is the last level with `campaign = true`,
  -- and beating it sets `nextLevelId` to nil rather than advancing into
  -- the fixtures. (This used to rest on `open` being unwinnable, which
  -- was true and was also the bug -- the campaign had no ending. The
  -- guard is now the campaign flag, which is a rule rather than an
  -- accident.)
  -- They exist because a rule is only proved on a board built to prove
  -- it: gathering twelve ants by hand to reach the interesting state is
  -- how gates end up asserting on the setup instead of on the rule.
  {
    id = "gatefog",
    name = "Gate: fog states",
    blurb = "A mound you can walk to, and one you cannot.",
    generated = false,
    -- PLAN 04's FOG GATE FIXTURE, and it exists to break a coupling.
    --
    -- test-fog3 used to produce its "discovered but enemy-held" state by
    -- walking toward `discover`'s red colony and waiting for the board to
    -- hand one over -- which works only while red is strong enough to
    -- still hold something when the walk ends. The 2026-08-20 tuning pass
    -- (red 22 ants -> 14) broke exactly that, and the gate went red for a
    -- LEVEL BALANCE change while the fog rendering it tests was untouched.
    -- Restoring red's second queen fixed it and left the dependency in
    -- place for the next tuning pass to trip over.
    --
    -- A gate asserting on a RENDER RULE must not be able to fail because
    -- a level got easier. So the state is authored here instead of hoped
    -- for:
    --
    --   n1  your home, with a column big enough to take n3 ONCE.
    --   n2  a neutral stepping stone, so the walk is a real two-hop walk.
    --   n3  THE SUBJECT: weakly held by red and inside your reach, so a
    --       column can take it -- which is what makes it `visited`.
    --   n4  red's fed, queened capital behind it, close enough to n3 to
    --       retake it and strong enough to do so reliably.
    --
    -- `visited` IS SET ON ARRIVAL, NOT ON SIGHT (sim/init.lua: "Set on
    -- arrival only (`at`), never on approach"). A first attempt at this
    -- fixture put the subject mound OUTSIDE the player's reach so it
    -- could never be taken by accident -- which would have been a tidier
    -- shape and cannot work, because a mound you can never stand on
    -- never becomes discovered at all. The state the gate needs is
    -- necessarily "stood on once, lost since", so the board is built to
    -- GUARANTEE the losing half rather than to prevent the taking half.
    --
    -- THE PLAYER'S COLUMN IS DELIBERATELY THIN. Ten ants takes n3's five
    -- and leaves too few to hold it against what n4 sends back. On
    -- `discover` this was left to whether red happened to still be strong
    -- after the walk -- which is precisely the level-balance dependency
    -- this fixture exists to delete.
    --
    -- RED IS FED AND QUEENED so it regrows behind its front -- the
    -- property that made `discover` usable for this and the property that
    -- the ant-count tuning threatened. Here it is the fixture's own
    -- requirement rather than something borrowed from a level whose job
    -- is to teach.
    startFood = { red = 30 },
    -- RED SLEEPS UNTIL THE PLAYER ARRIVES, and on a fixture that is a
    -- determinism requirement rather than a kindness.
    --
    -- Awake from t=0, red's capital simply RUSHED: it took the neutral
    -- stepping stone while the player's column was still walking to it,
    -- so the second hop had no mound of ours to launch from, the subject
    -- was never taken, never became `visited`, and the gate sat watching
    -- an UNKNOWN mound for 140 seconds reporting that the state never
    -- appeared. Every retune of the ant counts moved which of those two
    -- races was won and none of them made the order reliable.
    --
    -- `wakeOnContact` removes the race outright: red does nothing until
    -- the player's frontier reaches it, so the walk always completes and
    -- the counter-attack always happens AFTER the take. The fixture then
    -- tests what it is for -- a mound remembered and lost -- instead of
    -- testing whose ants arrived first.
    wakeOnContact = true,
    nodes = {
      { kind = "plain", x = 0,    y = 0,    own = true,  ants = 14, queens = 1 },
      -- THE REAR BASE, and the control assault is what it is for.
      --
      -- After the exchange the player has usually been pushed off
      -- everything forward of home, so the phase that re-attacks the lost
      -- mound -- proving that an INBOUND column reveals defenders a
      -- merely-discovered one hides -- had nowhere to launch from and
      -- went untested. This mound sits BEHIND home, garrisoned, out of
      -- red's line of advance, and in reach of home so its ants can come
      -- forward when they are needed. It is a launch pad, not a second
      -- front.
      --
      -- ITS DISTANCE IS MEASURED AGAINST THE STEPPING STONE, not against
      -- home. The stone at (1000,0) is the mound the player takes and
      -- then loses, so it is the ground the control assault re-attacks; a
      -- launch pad that reaches only home is no use, because the walk
      -- empties home on its way out. Two placements BEHIND home failed
      -- exactly that way (x=-900 and x=-500, leaving the stone 798 then
      -- 630 screen pixels away against a 483px reach) while twelve ants
      -- stood two mounds back doing nothing.
      --
      -- OFF THE AXIS instead of behind it. (400,-600) is 849 world units
      -- from the stone and 721 from home -- both comfortably inside a
      -- plain mound's 1150 reach -- so this mound can reinforce home OR
      -- strike the stone directly, whichever the exchange leaves needed.
      -- It is still off red's line of advance (which runs west along
      -- y=0), so it survives to do it.
      { kind = "plain", x = 400,  y = -600, own = true,  ants = 12, queens = 1 },
      -- THE STEPPING STONE, and it must stay in reach of the subject
      -- AFTER the subject is lost. The gate's control assault re-sends at
      -- the retaken mound to prove that an inbound column reveals its
      -- defenders, and it needs somewhere to send FROM: at 900 apart the
      -- player kept n2 but could not reach n3 from it (1900 > a plain
      -- mound's 1150), so the control had no launch point and the whole
      -- reveal half of the phase went untested.
      { kind = "plain", x = 1000, y = 0 },
      -- THE SUBJECT. Held by a garrison the player's ten CAN take but
      -- cannot then hold: the point of this board is a mound that is
      -- yours for a moment and red's afterwards.
      --
      -- TUNED AGAINST A REAL FAILURE, worth recording because the
      -- symptom was misleading. At five defenders the column took n3 and
      -- then STUCK there -- `held=true` for the whole of a 150-second
      -- watch, with the survivors grinding against red's trickle of
      -- reinforcements and neither side ever finishing. `held` is what
      -- the gate's "quiet" predicate excludes, so the state never
      -- appeared and the failure read as "the counter-attack is broken"
      -- when the real answer was that nobody ever left.
      --
      -- Eight defenders makes the exchange DECISIVE instead: the ten
      -- spend themselves taking it, red's capital walks in behind them,
      -- and n3 is enemy-held with none of yours on it -- which is exactly
      -- the state, and it arrives by the fight ENDING rather than by
      -- either side being lucky.
      { kind = "small", x = 1800, y = 0,    foe = "red", ants = 6 },
      -- RED'S CAPITAL, in easy reach of the subject. A `home` for the
      -- same reason war's rival is one: a plain mound caps at three
      -- queens and stops being able to spare anything.
      { kind = "home",  x = 2850, y = 0,    foe = "red", ants = 22, queens = 2 },
    },
    locations = {
      -- Something to forage so the player's column has a reason to exist
      -- and the board is not purely two mounds staring at each other.
      { kind = "grain", x = -600, y = 320, items = 6 },
    },
  },
  {
    id = "gatefood",
    name = "Gate: food",
    blurb = "One mound, one queen, four workers.",
    generated = false,
    -- Four ants and a queen, with the saturation cap at ten: room for
    -- exactly six larvae, so a fed run has one right answer.
    nodes = {
      { kind = "plain", x = 0, y = 0, own = true, ants = 4, queens = 1 },
    },
  },
  {
    id = "gateforage",
    name = "Gate: forage",
    blurb = "A queen, a few workers, and grain next door.",
    generated = false,
    -- One mound with a queen and room under the cap, one grain patch in
    -- easy reach holding a known number of items, and nothing else on
    -- the board. Every food in this world is countable, which is what
    -- makes the ledger assertion possible.
    nodes = {
      { kind = "plain", x = 0, y = 0, own = true, ants = 6, queens = 1 },
    },
    locations = {
      -- 700 units out: well inside a plain mound's 1150 reach.
      { kind = "grain", x = 700, y = 0, items = 5 },
    },
  },
  {
    id = "gatebridge",
    name = "Gate: food is not a bridge",
    blurb = "A patch of grain between here and there.",
    generated = false,
    -- THE SHAPE THAT PROVES IT. n1 and n2 are 1900 apart -- far outside a
    -- plain mound's 1150 reach -- with a grain patch sitting exactly
    -- halfway, within reach of both. If a location could relay, taking
    -- the grain would open a route to n2 and the far mound would become
    -- sendable. It must not: food is somewhere to walk to, never a
    -- stepping stone, so n2 stays unreachable until a MOUND bridges it.
    nodes = {
      { kind = "plain", x = 0, y = 0, own = true, ants = 12, queens = 1 },
      { kind = "plain", x = 1900, y = 0 },
    },
    locations = {
      { kind = "grain", x = 950, y = 0, items = 6 },
      -- Out past everyone's reach, so it stays an unknown grey circle:
      -- the state a player sees most often, and the one worth being able
      -- to look at on demand.
      { kind = "aphids", x = -1400, y = 260 },
    },
  },
  {
    id = "gatebattle",
    name = "Gate: battle",
    blurb = "Two mounds, in reach, at war from the first tick.",
    generated = false,
    -- PLAN 05's mound-combat gate fixture. Two adjacent mounds, no
    -- queens on either side to complicate the arithmetic -- a garrison
    -- count is exactly what the gate spends and what it counts. `plain`
    -- reaches 1150 world units; 700 apart puts them well inside range so
    -- a send is never refused by geometry.
    --
    -- ONE ANT EACH SIDE, on purpose: a drag always sends the WHOLE
    -- garrison (the fraction control in input/intents.lua only steps
    -- 25/50/100%, not an exact count), so a controlled 1v1 duel requires
    -- the source mound to already hold exactly one ant. Gates that need
    -- a specific facing use the SELECT+LEFT/RIGHT debug op
    -- (probe.command "faceaway"/"facetoward"); gates that need more
    -- bodies get their own fixture level rather than widening this one.
    nodes = {
      { kind = "plain", x = 0,   y = 0, own = true,  ants = 1, queens = 0 },
      { kind = "plain", x = 700, y = 0, foe = "red", ants = 1, queens = 0 },
    },
  },
  {
    id = "gatebattle2",
    name = "Gate: battle (bulk)",
    blurb = "Twelve a side, for statistics a 1v1 cannot give.",
    generated = false,
    -- The damage-bounds and no-deadlock assertions need enough landed
    -- hits to see the full 2-4 range and enough ants to prove the two
    -- sides never lock step; a 1v1 duel (gatebattle) is too small a
    -- sample and too fragile a window for either.
    nodes = {
      { kind = "plain", x = 0,   y = 0, own = true,  ants = 12, queens = 0 },
      { kind = "plain", x = 700, y = 0, foe = "red", ants = 12, queens = 0 },
    },
  },
  {
    id = "gatespider",
    name = "Gate: spider",
    blurb = "She is bigger than you are.",
    generated = false,
    -- Plenty of workers, no queen to distract the arithmetic, and one
    -- spider holding eight legs.
    nodes = {
      { kind = "plain", x = 0, y = 0, own = true, ants = 20, queens = 0 },
    },
    locations = {
      { kind = "spider", x = 700, y = 0 },
    },
  },
  {
    id = "gatespider2",
    name = "Gate: spider (withdrawal)",
    blurb = "A second mound to fall back to.",
    generated = false,
    -- PLAN 05, section 6c: `gatespider` has nowhere to withdraw TO. A
    -- second plain mound sits close enough to be reachable the moment
    -- the player holds n1, which is from the first tick. A drag always
    -- sends the WHOLE garrison (touch's fraction gauge only steps
    -- 25/50/100%, never an exact count), so an "engage N" test needs its
    -- OWN precisely-sized garrison, same discipline gatebattle uses.
    --
    -- FIFTEEN, NOT TWELVE (Luis, 2026-08-20). Twelve was sized against a
    -- SIX second kill period; when it halved to 3s she ate the column
    -- before all eight legs were ever held, and the subdual and
    -- withdrawal halves of test-spider had no fight left to measure.
    --
    -- Fifteen is deliberately ABOVE `LKINDS.spider.cap = 8`. The cap is
    -- how many may ENGAGE her at once, not a limit on the drag: the
    -- surplus waits its turn and replaces the ants she kills, which is
    -- what keeps eight legs held long enough to subdue her at the faster
    -- rate. (A 16-ant attempt looked like a refused send while I was
    -- reading `send()`'s return -- that helper returns drained LOG lines,
    -- not a send result, so `[]` means "nothing printed this tick", never
    -- "refused". Do not read it as a status.)
    nodes = {
      { kind = "plain", x = 0,    y = 0, own = true, ants = 15, queens = 0 },
      { kind = "plain", x = -700, y = 0, own = true, ants = 0,  queens = 0 },
    },
    locations = {
      { kind = "spider", x = 700, y = 0 },
    },
  },
  {
    id = "gatespiderwin",
    name = "Gate: spider (committed send)",
    blurb = "Fifteen in.",
    generated = false,
    -- test-spider #2's WIN half: exactly the tuned win-count from cfg
    -- (section on the spider's arithmetic: "likely 15"), sized as its
    -- own fixture so a 100%-fraction send moves the precise number the
    -- assertion needs -- the same reasoning gatebattle documents for why
    -- a controlled count needs a controlled board rather than a fraction
    -- of a bigger one.
    nodes = {
      { kind = "plain", x = 0, y = 0, own = true, ants = 15, queens = 0 },
    },
    locations = {
      { kind = "spider", x = 700, y = 0 },
    },
  },
  {
    id = "gatespiderlose",
    name = "Gate: spider (undercommitted send)",
    blurb = "Nine in.",
    generated = false,
    -- test-spider #2's LOSE half: the tuned lose-count, below the cliff
    -- (05-battles.md's arithmetic: 9 in leaves one striker, a death
    -- spiral). Same reasoning as gatespiderwin above.
    nodes = {
      { kind = "plain", x = 0, y = 0, own = true, ants = 9, queens = 0 },
    },
    locations = {
      { kind = "spider", x = 700, y = 0 },
    },
  },
  {
    id = "gatesiege",
    name = "Gate: siege",
    blurb = "An undefended queen, ripe for the taking.",
    generated = false,
    -- 2026-08-19: gate fixture for the queen-siege close-in and carry-
    -- home behaviours (Luis: "let them get closer to the queen" /
    -- "carry queen's body back to hive"). The enemy mound has a queen
    -- and NO garrison, so M.fight's siege branch (`defenders == 0 and
    -- attacker`) starts the instant the player's column arrives -- no
    -- worker-vs-worker fight to wait out first. The player's OWN mound
    -- has a queen too, so the carried-home body has somewhere to bank --
    -- without one the ant would hold her forever ("nowhere to take it"
    -- is a real, working fallback, not a bug, but it means delivery
    -- itself is untestable on a queenless board).
    nodes = {
      { kind = "plain", x = 0,   y = 0, own = true,  ants = 12, queens = 1 },
      { kind = "plain", x = 700, y = 0, foe = "red", ants = 0,  queens = 1 },
    },
  },
  {
    -- COLOUR CHECK FIXTURE: one red queen and one gold queen, both held by
    -- the player's ants so both are visible at once. The queen colour bug
    -- (every enemy queen drawn with a hardcoded reddish literal, so gold's
    -- queens came out red) is only visible on a board with TWO rival
    -- colours, which is why it survived every earlier gate.
    id = "gatequeencol",
    name = "Gate: queen colour",
    blurb = "A red queen and a gold queen, side by side.",
    generated = false,
    nodes = {
      -- The player sends a SMALL column to each: enough to stand on the
      -- ground (which is what reveals an enemy queen -- see the `held`
      -- rule in render/ants.lua) but not enough to take it, so both
      -- queens stay alive and on screen to be photographed.
      -- TWO player mounds, one facing each enemy, so a column can be sent
      -- to each independently -- a single source sends its WHOLE garrison
      -- (the drag fraction only steps 25/50/100%), so one mound could
      -- only ever hold one of them.
      { kind = "plain", x = 0,    y = -400, own = true, ants = 6,  queens = 0 },
      { kind = "plain", x = 0,    y = 400,  own = true, ants = 6,  queens = 0 },
      { kind = "plain", x = 700,  y = -400, foe = "red",  ants = 14, queens = 1 },
      { kind = "plain", x = 700,  y = 400,  foe = "gold", ants = 14, queens = 1 },
    },
  },
  {
    id = "gatesiege2",
    name = "Gate: defended siege",
    blurb = "A queen behind her workers.",
    generated = false,
    -- PLAN 06 fixture, and the difference from `gatesiege` is the whole
    -- point: this queen has a GARRISON. On gatesiege (no defenders) the
    -- siege branch opens instantly, she falls within a second or two of
    -- the column arriving, and her body is picked up in the same window
    -- -- BEFORE the mound flips. That ordering is why test-siege passed
    -- while the feature was broken in play.
    --
    -- With defenders the real sequence happens: worker-vs-worker fight
    -- first (3s swings, cone forfeits -- plan 05 made this take a while),
    -- THEN the queen siege, and the mound's energy grind can complete the
    -- CAPTURE around or before an idle ant gets a chance to lift the body.
    -- Post-capture the old pickup guard (`n.owner ~= ant.side`) is false
    -- forever for the winning side, so the corpse sits on your own new
    -- mound, uneaten. This board is built to hit that ordering.
    --
    -- Player brings enough to win decisively (the fight should end, not
    -- grind), and has a queen at home so a carried body has somewhere to
    -- bank -- same requirement gatesiege documents.
    nodes = {
      { kind = "plain", x = 0,   y = 0, own = true,  ants = 24, queens = 1 },
      { kind = "plain", x = 700, y = 0, foe = "red", ants = 6,  queens = 1 },
    },
  },
  {
    id = "gatedeath",
    name = "Gate: starvation",
    blurb = "A mound, and nothing on it.",
    generated = false,
    -- Ground held, nobody home, nothing in the pantry: the exact shape
    -- of the loss condition, true from the first tick.
    nodes = {
      { kind = "plain", x = 0, y = 0, own = true, ants = 0, queens = 0 },
    },
  },
  {
    id = "gatelive",
    name = "Gate: not dead",
    blurb = "A queen with one meal in the pantry.",
    generated = false,
    -- The CONTROL for gatedeath: no ants either, but a queen and a
    -- grain of food, so the side is alive and must NOT be declared out.
    -- A loss check that cannot tell these two boards apart is a loss
    -- check that will end somebody's game by surprise.
    nodes = {
      { kind = "plain", x = 0, y = 0, own = true, ants = 0, queens = 1 },
    },
    startFood = 1,
  },
}

function M.byId(id)
  for i = 1, #M.levels do
    if M.levels[i].id == id then return M.levels[i], i end
  end
  return nil
end

function M.count() return #M.levels end

-- THE PLAYABLE CAMPAIGN, for the level select (plan 06).
--
-- Marked with an explicit `campaign = true` field rather than inferred
-- from the id ("everything not starting with `gate`"), because a naming
-- convention is not a rule the code can enforce: the next fixture added
-- with a tidier name would silently appear in a player's level list.
-- The gate boards are past the end of the list on purpose (see the
-- GATE-ONLY BOARDS banner above) and this is the second lock on that.
function M.playable()
  local out = {}
  for i = 1, #M.levels do
    if M.levels[i].campaign then out[#out + 1] = M.levels[i] end
  end
  return out
end

-- WHICH LEVELS THE PLAYER MAY START, given what they have beaten.
--
-- Every beaten level (replayable -- there is no reason to lock someone
-- out of ground they have already taken), plus the FIRST unbeaten one:
-- the frontier. Later unbeaten levels stay locked, so "start an
-- uncompleted level" means the next one rather than skipping straight to
-- the war map on a fresh file.
--
-- `open` is the last campaign level, so when it is the frontier there is
-- nothing after it for a frontier to hide.
function M.selectable(beaten)
  local list = M.playable()
  local out, frontierTaken = {}, false
  for i = 1, #list do
    local lv = list[i]
    local done = beaten and beaten[lv.id] or false
    if done then
      out[#out + 1] = { level = lv, beaten = true, locked = false }
    elseif not frontierTaken then
      frontierTaken = true
      out[#out + 1] = { level = lv, beaten = false, locked = false }
    else
      out[#out + 1] = { level = lv, beaten = false, locked = true }
    end
  end
  return out
end

-- THE NEXT CAMPAIGN LEVEL, or nil at the end of the campaign.
--
-- THE CAMPAIGN FLAG IS THE STOP, not the end of the array. This walked
-- `M.levels[i + 1]` unconditionally, which was harmless only because
-- `open` could never be completed -- the moment it could, beating the
-- last campaign level would have handed the player `gatefood`: a
-- one-mound gate fixture, offered as "the next garden", with the
-- celebration card advertising it. Making `open` winnable is exactly the
-- change that would have shipped that, so the guard goes in with it.
--
-- Returning nil is already a state everything downstream handles:
-- `s.nextLevelId` is nil, ui/celebrate.lua's dialog drops its "next
-- garden" row, and intents.lua's START stays the pause menu.
function M.next(id)
  local _, i = M.byId(id)
  if not i then return nil end
  local nxt = M.levels[i + 1]
  if not nxt or not nxt.campaign then return nil end
  return nxt
end

-- WHICH STEP THE PLAYER IS ON, read from the world rather than a script.
-- A tutorial that advances on a timer tells someone who is stuck to hurry
-- up; one that reads the actual state waits for them.
function M.step(level, world, intents, agents, food)
  if not level or not level.steps then return nil end
  local A = require("sim.agents")
  -- Any queen beyond the ones the level started with means the lesson
  -- has landed.
  local queens = 0
  for i = 1, #world.nodes do
    queens = queens + #(world.nodes[i].queens or {})
  end
  if level.id == "gather" then
    -- Once she exists the hint follows the FOOD, because that is the
    -- next thing standing between the player and an ant hatching: step 4
    -- says go and get some, step 5 says watch what happens. Reading the
    -- pantry rather than a timer means it waits for them.
    if queens > 0 then
      return (food or 0) > 0 and 5 or 4
    end
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
  if level.id == "open" then
    -- THE CAMPAIGN HAS AN ENDING NOW. `open` was generated, and
    -- `M.complete` refuses every generated level outright (the first line
    -- of this function), so the last row of the campaign could not be
    -- beaten by anybody -- a player who reached it was finished with the
    -- game whether they won or not, and `progress.markBeaten` never fired
    -- for it.
    --
    -- BOTH ENEMIES GONE, not a territory fraction. The 66%-of-the-board
    -- fallback below would let a player finish while one rival still held
    -- a corner, which on the level whose whole lesson is "you cannot
    -- answer both fronts" is precisely the state that must not count as
    -- an answer. Same rule as war and discover, against two colonies
    -- instead of one.
    for i = 1, #world.nodes do
      local n = world.nodes[i]
      if n.owner and n.owner ~= "you" then return false end
    end
    return true
  end
  return owned >= math.max(2, math.ceil(total * 0.66))
end

-- A level may seed a side's pantry, as a number (yours) or a table keyed
-- by side. YOU always start hungry in the campaign proper -- the first
-- food a player sees should be food they carried home.
--
-- RIVALS DO NOT, and that is not a favour to them. A colony with no food
-- cannot lay, so a rival at zero is not a slow opponent but a STATUE:
-- the war map went completely inert the moment queens had to eat, with
-- both colonies frozen at their starting garrison for the whole match.
-- Until they can forage for themselves they are handed a pantry, which
-- is the same thing the map does for them with ants and ground.
function M.startFood(level, side)
  local f = level and level.startFood
  if not f then return 0 end
  if type(f) == "number" then
    return (side == nil or side == "you") and f or 0
  end
  return f[side] or 0
end

-- Every side a level mentions, so the pantry can be seeded per colony.
function M.sides(level)
  local out, seen = { "you" }, { you = true }
  for i = 1, #(level and level.nodes or {}) do
    local foe = level.nodes[i].foe
    if foe and not seen[foe] then seen[foe] = true; out[#out + 1] = foe end
  end
  return out
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
      made[i].queens[#made[i].queens + 1] = A.newQueen()
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
  -- Food in the ground. Hand-placed, because where the first meal sits
  -- is the whole of what a level teaches about foraging.
  for i = 1, #(level.locations or {}) do
    local spec = level.locations[i]
    W.addLoc(world, spec.kind, spec.x, spec.y, {
      items = spec.items, seen = true,
    })
  end
  return true
end

return M
