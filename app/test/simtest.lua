-- simtest.lua - the pure-sim unit suite, run INSIDE the engine.
--
-- There is no host Lua on the dev box and, per the project rule, a cart is
-- tested through romdev rather than through a side driver. So the suite runs
-- as a cart mode: main.lua sees `test = true` in app/testmode and calls
-- run(), which prints machine-readable lines the gate driver parses:
--
--   SIMTEST PASS <name>
--   SIMTEST FAIL <name> <detail>
--   SIMTEST DONE <pass> <fail>
--
-- Every assertion here is on the pure sim modules -- no love.graphics, no
-- frames, no pixels. That is what makes it fast enough to run on every edit
-- and precise enough that a failure names one behaviour.

local sim     = require("sim.init")
local W       = require("sim.world")
local A       = require("sim.agents")
local scent   = require("sim.scent")
local castes  = require("sim.castes")
local economy = require("sim.economy")
local seasons = require("sim.seasons")
local threats = require("sim.threats")

local M = {}

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then
    pass = pass + 1
    print("SIMTEST PASS " .. name)
  else
    fail = fail + 1
    print("SIMTEST FAIL " .. name .. " " .. tostring(detail or ""))
  end
end

local function approx(a, b, eps)
  return math.abs(a - b) <= (eps or 1e-6)
end

-- Advance a sim by wall-seconds at the fixed tick.
local function run(s, seconds)
  local dt = 1 / 60
  for _ = 1, math.floor(seconds * 60) do sim.update(s, dt) end
end

-- ── world ──────────────────────────────────────────────────────────────
local function testWorld()
  local w = W.new(function() return 0.5 end)
  local a = W.addNode(w, "nest", 0, 0)
  local b = W.addNode(w, "flower", 100, 0)
  local e1 = W.addEdge(w, a.id, b.id)
  check("world.edge_len", approx(e1.len, 100, 0.001), e1.len)

  -- A duplicate edge must return the existing one, not double the graph.
  local e2 = W.addEdge(w, b.id, a.id)
  check("world.no_duplicate_edge", e1 == e2 and #w.edges == 1, #w.edges)

  check("world.other", W.other(e1, a.id) == b.id, W.other(e1, a.id))
  check("world.adjacency", #w.adj[a.id] == 1 and #w.adj[b.id] == 1)

  -- Bounds only count DISCOVERED nodes: an undiscovered flower must not
  -- drag the camera toward a place the player has never seen. Asserted as a
  -- RELATIVE fact (the bound grows when the far node becomes known) rather
  -- than against a literal, because node radii are a tuning value and a
  -- hardcoded "< 100" turned into a false failure the moment they grew.
  local _, _, x1 = W.bounds(w)
  b.discovered = true
  local _, _, x1b = W.bounds(w)
  check("world.bounds_discovered_only", x1b > x1,
        string.format("%.1f -> %.1f", x1, x1b))
  check("world.bounds_include_radius", x1b >= b.x, string.format("%.1f", x1b))

  local ok = pcall(W.addEdge, w, a.id, a.id)
  check("world.rejects_self_edge", not ok)
end

-- ── scent ──────────────────────────────────────────────────────────────
local function testScent()
  local w = W.new(function() return 0.5 end)
  local a = W.addNode(w, "nest", 0, 0)
  local b = W.addNode(w, "flower", 200, 0)
  local s = scent.new()

  local before = s.budget
  local ok = scent.link(s, w, a.id, b.id)
  check("scent.link_succeeds", ok)
  check("scent.link_costs", approx(s.budget, before - scent.cfg.costLink, 1e-9),
        s.budget)
  local e = w.edges[1]
  check("scent.link_lays_strength", e.strength > 0, e.strength)
  check("scent.link_discovers", w.node[b.id].discovered)

  -- Decay: a road with no traffic forgets.
  local st = e.strength
  scent.update(s, w, 1.0, 1)
  check("scent.decays", e.strength < st, e.strength)
  check("scent.decay_rate",
        approx(e.strength, st - scent.cfg.decayPerSec, 1e-6), e.strength)

  -- The decay multiplier is what rain and winter ride on.
  e.strength = 0.5
  scent.update(s, w, 1.0, 4)
  check("scent.decay_multiplier",
        approx(e.strength, 0.5 - scent.cfg.decayPerSec * 4, 1e-6), e.strength)

  -- Traffic keeps a used road alive: enough crossings must NET positive.
  e.strength = 0.5
  for _ = 1, 60 do scent.credit(e, 1) end
  scent.update(s, w, 1.0, 1)
  check("scent.traffic_beats_decay", e.strength > 0.5, e.strength)

  -- Strength is capped, so a highway cannot become infinitely sticky.
  for _ = 1, 5000 do scent.credit(e, 1) end
  check("scent.strength_capped", e.strength <= scent.cfg.strengthMax + 1e-9,
        e.strength)

  -- THE BUDGET LAW: micromanagement must be impossible. Spend everything,
  -- and further verbs are refused rather than partially applied.
  local s2 = scent.new()
  local w2 = W.new(function() return 0.5 end)
  local n1 = W.addNode(w2, "nest", 0, 0)
  local n2 = W.addNode(w2, "flower", 100, 0)
  local n3 = W.addNode(w2, "flower", 0, 100)
  local links = 0
  for _ = 1, 20 do
    if scent.link(s2, w2, n1.id, n2.id) then links = links + 1 end
  end
  check("scent.budget_limits_actions",
        links == math.floor(scent.cfg.budgetMax / scent.cfg.costLink), links)
  check("scent.refusals_counted", s2.refused > 0, s2.refused)
  local budgetAfter = s2.budget
  scent.link(s2, w2, n1.id, n3.id)
  check("scent.refused_is_noop", approx(s2.budget, budgetAfter, 1e-9),
        s2.budget)

  -- Regen: the budget comes back on its own, so waiting is a real strategy.
  scent.update(s2, w2, 2.0, 1)
  check("scent.budget_regens", s2.budget > budgetAfter, s2.budget)

  -- Abandon drops the road to nothing but keeps the edge: a route can
  -- always be reopened, which is the no-fail promise in miniature.
  local s3 = scent.new()
  scent.link(s3, w2, n1.id, n2.id)
  local eid = w2.edges[1].id
  scent.abandon(s3, w2, eid)
  check("scent.abandon_zeroes", w2.edge[eid].strength == 0)
  check("scent.abandon_keeps_edge", w2.edge[eid] ~= nil)
end

-- ── castes ─────────────────────────────────────────────────────────────
local function testCastes()
  local c = castes.new()
  check("castes.sums_to_steps", c.f + c.n + c.s == castes.cfg.steps,
        c.f + c.n + c.s)

  -- A nudge preserves the sum, always. This is what makes save/load exact.
  for i = 1, 40 do
    castes.nudge(c, { (i % 3 == 0) and 1 or 0, (i % 3 == 1) and 1 or 0,
                      (i % 3 == 2) and 1 or 0 })
    if c.f + c.n + c.s ~= castes.cfg.steps then break end
  end
  check("castes.nudge_preserves_sum", c.f + c.n + c.s == castes.cfg.steps,
        c.f + c.n + c.s)

  -- No caste can be zeroed: a colony with no nurses would be a dead end the
  -- player could walk into by accident.
  local c2 = castes.new()
  for _ = 1, 50 do castes.nudge(c2, { 1, -1, 0 }) end
  check("castes.floor_respected",
        c2.n >= castes.cfg.minEach and c2.s >= castes.cfg.minEach,
        c2.n .. "," .. c2.s)

  -- Effects move in the right direction.
  local cf, cn = castes.new(), castes.new()
  cf.f, cf.n, cf.s = 10, 1, 1
  cn.f, cn.n, cn.s = 1, 10, 1
  castes.update(cf); castes.update(cn)
  check("castes.forager_is_faster", cf.speedMul > cn.speedMul,
        cf.speedMul .. " vs " .. cn.speedMul)
  check("castes.nurse_broods_faster", cn.broodMul > cf.broodMul,
        cn.broodMul .. " vs " .. cf.broodMul)

  -- nextRole chases the DEFICIT, so a wiped caste rebuilds first.
  local c3 = castes.new()
  c3.f, c3.n, c3.s = 4, 4, 4
  local role = castes.nextRole(c3, { 100, 100, 0 }, 200)
  check("castes.rebuilds_deficit", role == A.SOLDIER, role)
end

-- ── economy + the displacement invariant ───────────────────────────────
local function testEconomy()
  local s = sim.new(4242)
  local ok, msg = economy.checkInvariant(s.economy, s.agents, s.world)
  check("econ.invariant_at_start", ok, msg)

  -- A total famine: zero the pantry, empty every source AND stop it growing
  -- back. Killing regrow matters now that sources recover -- without it the
  -- map refills within seconds and the "famine" is a light lunch, which is
  -- exactly what silently defanged this test (and its control) when
  -- regrowth landed.
  local function famine (s)
    s.economy.food = 0
    for i = 1, #s.world.nodes do
      local n = s.world.nodes[i]
      n.food, n.cap, n.regrow = 0, 0, 0
    end
  end

  -- Starvation must never breach the floor.
  local s2 = sim.new(777)
  famine(s2)
  run(s2, 400)
  check("econ.floor_holds", s2.agents.n >= economy.cfg.minColony, s2.agents.n)
  check("econ.nest_survives", s2.world.node[s2.world.nestId] ~= nil)
  local ok2, msg2 = economy.checkInvariant(s2.economy, s2.agents, s2.world)
  check("econ.invariant_after_famine", ok2, msg2)
  check("econ.food_never_negative", s2.economy.food >= 0, s2.economy.food)

  -- The famine above must also survive PREDATION, which is the death path
  -- that actually broke the floor the first time: economy.lua clamped
  -- starvation and age-out, agents.lua's hazard kill did not, and a long
  -- famine on a hazardous road walked the colony one ant under. Force a
  -- permanent spider onto every edge and starve at the same time.
  local s2b = sim.new(31415)
  famine(s2b)
  for i = 1, #s2b.world.edges do
    s2b.world.edges[i].strength = 0.9
    s2b.world.edges[i].hazard = 1.0
  end
  for _ = 1, 60 * 300 do
    sim.update(s2b, 1 / 60)
    -- Re-arm: threats.update expires spiders, and this test is about the
    -- kill path, not the spider lifecycle.
    for i = 1, #s2b.world.edges do s2b.world.edges[i].hazard = 1.0 end
  end
  check("econ.floor_holds_under_predation",
        s2b.agents.n >= economy.cfg.minColony, s2b.agents.n)

  -- CONTROL: the same famine with the floor removed MUST breach. A test
  -- that cannot fail is not a test (see the project's run-a-control rule).
  -- Writing economy.cfg.minColony forwards to agents.minColony through the
  -- metatable, so this really does disarm every kill site, not just two.
  local realMin = economy.cfg.minColony
  economy.cfg.minColony = 0
  local s3 = sim.new(777)
  famine(s3)
  run(s3, 400)
  local breached = s3.agents.n < realMin
  economy.cfg.minColony = realMin
  check("econ.CONTROL_floor_removed_breaches", breached, s3.agents.n)
  check("econ.CONTROL_restores_floor", economy.cfg.minColony == realMin
        and A.minColony == realMin, economy.cfg.minColony .. "/" .. A.minColony)

  -- REGROWTH. Sources recover toward their cap, which is what makes this a
  -- terrarium rather than a countdown: before regrowth existed the map held
  -- ~5500 food total, the colony ate all of it by t=190 and then starved,
  -- so every run ended in a bust however well it was played.
  local s6 = sim.new(1234)
  local flower
  for i = 1, #s6.world.nodes do
    if s6.world.nodes[i].regrow > 0 then flower = s6.world.nodes[i] break end
  end
  check("econ.map_has_regrowing_sources", flower ~= nil)
  if flower then
    flower.food = 0
    run(s6, 20)
    check("econ.sources_regrow", flower.food > 0, flower.food)
    check("econ.regrow_respects_cap", flower.food <= flower.cap,
          flower.food .. "/" .. flower.cap)
    -- And it must actually stop at the cap, not creep past it forever.
    flower.food = flower.cap
    run(s6, 30)
    check("econ.regrow_stops_at_cap", flower.food <= flower.cap + 1e-6,
          flower.food)
  end

  -- Winter really is lean: the same empty flower recovers far less.
  local s7 = sim.new(1234)
  local f7
  for i = 1, #s7.world.nodes do
    if s7.world.nodes[i].regrow > 0 then f7 = s7.world.nodes[i] break end
  end
  f7.food = 0
  s7.seasons.index = 4          -- winter
  seasons.applyMods(s7.seasons)
  run(s7, 20)
  local winterGrowth = f7.food
  local s8 = sim.new(1234)
  local f8
  for i = 1, #s8.world.nodes do
    if s8.world.nodes[i].regrow > 0 then f8 = s8.world.nodes[i] break end
  end
  f8.food = 0
  run(s8, 20)                   -- spring, the default
  check("econ.winter_regrows_less", winterGrowth < f8.food,
        string.format("winter %.1f vs spring %.1f", winterGrowth, f8.food))

  -- THE STEADY STATE, which is the whole point: left alone with roads open,
  -- a colony must still be alive and fed after a long run. This is the
  -- assertion that would have caught the boom-bust immediately.
  local s9 = sim.new(555)
  for i = 1, #s9.world.edges do s9.world.edges[i].strength = 0.8 end
  for i = 1, #s9.world.nodes do s9.world.nodes[i].discovered = true end
  run(s9, 900)                  -- 15 minutes, most of a year
  check("econ.reaches_steady_state",
        s9.agents.n > economy.cfg.minColony * 2 and s9.economy.food > 0,
        string.format("%d ants, %.0f food", s9.agents.n, s9.economy.food))

  -- With food, the colony grows. A game where tending does nothing is not
  -- a game.
  local s4 = sim.new(99)
  local n0 = s4.agents.n
  s4.economy.food = 20000
  run(s4, 60)
  check("econ.grows_when_fed", s4.agents.n > n0, n0 .. " -> " .. s4.agents.n)

  -- Upkeep is real: a huge colony with no income loses food.
  local s5 = sim.new(31)
  s5.economy.food = 1000
  -- A FAMINE HAS TO STAY A FAMINE. Zeroing `food` alone is not one: every
  -- source regrows (a flower at 5.5/s), and since owned nodes also work
  -- their neighbours the colony refilled to 1155 and the assertion
  -- inverted -- the same way this suite's earlier famine control defanged
  -- itself. Kill regrowth and the ceiling too.
  for i = 1, #s5.world.nodes do
    local nd = s5.world.nodes[i]
    nd.food, nd.regrow, nd.cap = 0, 0, 0
  end
  local f0 = s5.economy.food
  run(s5, 30)
  check("econ.upkeep_costs", s5.economy.food < f0, s5.economy.food)
end

-- ── agents / flow ──────────────────────────────────────────────────────
local function testAgents()
  -- Ants must actually deliver food along a road the player opened. This is
  -- the core loop in one assertion.
  local s = sim.new(2026)
  local nest = s.world.nestId
  -- Open every possible road so foraging can start immediately.
  for i = 2, #s.world.nodes do
    s.world.edges[i - 1].strength = 0.8
    s.world.nodes[i].discovered = true
  end
  local delivered0 = s.agents.delivered
  run(s, 60)
  check("agents.deliver_food", s.agents.delivered > delivered0,
        s.agents.delivered)
  check("agents.crossings_happen", s.agents.crossings > 0, s.agents.crossings)

  -- CONTROL: delivery must depend on the ROADS, not happen regardless.
  --
  -- The first version of this control zeroed only wExplore and asserted
  -- delivery == 0. It FAILED at 1400 food, and the failure was the test's,
  -- not the game's: ants still choose edges on destination APPEAL alone, so
  -- an unroaded colony still forages -- slowly, wandering, but it forages.
  -- That is correct behaviour and worth keeping (a colony that does nothing
  -- until told is not alive), so the control asserts the right property
  -- instead: roads make the colony MUCH more productive than no roads.
  -- Same seed, same duration, only the roads differ.
  local roadedDelivery
  do
    local sr = sim.new(4711)
    for i = 1, #sr.world.edges do sr.world.edges[i].strength = 0.9 end
    for i = 1, #sr.world.nodes do sr.world.nodes[i].discovered = true end
    sr.economy.food = 100000
    run(sr, 40)
    roadedDelivery = sr.agents.delivered
  end
  local bareDelivery
  do
    local sb = sim.new(4711)
    for i = 1, #sb.world.edges do sb.world.edges[i].strength = 0 end
    for i = 1, #sb.world.nodes do sb.world.nodes[i].discovered = true end
    sb.economy.food = 100000
    run(sb, 40)
    bareDelivery = sb.agents.delivered
  end
  check("agents.roads_multiply_yield", roadedDelivery > bareDelivery * 1.25,
        string.format("roaded %.0f vs bare %.0f", roadedDelivery, bareDelivery))

  -- And the true zero control: with every edge severed from the graph there
  -- is nowhere to walk, so delivery must be exactly zero. This is the
  -- assertion that can actually fail if foraging is ever made unconditional.
  local sz = sim.new(4711)
  for i = 1, #sz.world.nodes do
    sz.world.adj[sz.world.nodes[i].id] = {}
  end
  sz.economy.food = 100000
  run(sz, 20)
  check("agents.CONTROL_no_edges_no_delivery", sz.agents.delivered == 0,
        sz.agents.delivered)

  -- Ants prefer the stronger road. Two equal flowers, one road loved.
  local w = W.new(function() return 0.5 end)
  local nest2 = W.addNode(w, "nest", 0, 0)
  w.nestId = nest2.id
  local f1 = W.addNode(w, "flower", 300, 0, { discovered = true })
  local f2 = W.addNode(w, "flower", -300, 0, { discovered = true })
  local e1 = W.addEdge(w, nest2.id, f1.id)
  local e2 = W.addEdge(w, nest2.id, f2.id)
  e1.strength, e2.strength = 0.9, 0.0
  local rngv = 0
  local rng = function() rngv = (rngv + 0.37) % 1; return rngv end
  local ag = A.new(w, rng)
  local ant = A.spawn(ag, A.FORAGER, nest2.id)
  local toStrong, toWeak = 0, 0
  for _ = 1, 400 do
    local e = A.chooseEdge(ag, ant, nest2.id)
    if e == e1 then toStrong = toStrong + 1 else toWeak = toWeak + 1 end
  end
  check("agents.prefer_strong_road", toStrong > toWeak * 3,
        toStrong .. " vs " .. toWeak)

  -- Danger repels. Same graph, aversion on the strong road.
  e1.danger = 1.0
  local d1, d2 = 0, 0
  for _ = 1, 400 do
    local e = A.chooseEdge(ag, ant, nest2.id)
    if e == e1 then d1 = d1 + 1 else d2 = d2 + 1 end
  end
  check("agents.danger_repels", d2 > d1, d1 .. " vs " .. d2)
  e1.danger = 0

  -- A laden ant heads home rather than deeper into the map.
  local f3 = W.addNode(w, "flower", 600, 0, { discovered = true })
  W.addEdge(w, f1.id, f3.id)
  local carrier = A.spawn(ag, A.FORAGER, f1.id)
  carrier.carrying = 10
  carrier.from = f3.id
  local home, away = 0, 0
  for _ = 1, 400 do
    local e = A.chooseEdge(ag, carrier, f1.id)
    if W.other(e, f1.id) == nest2.id then home = home + 1 else away = away + 1 end
  end
  check("agents.laden_returns_home", home > away, home .. " vs " .. away)

  -- The pool never exceeds its cap, however hard it is pushed.
  local ag2 = A.new(w, rng)
  for _ = 1, A.cfg.maxAgents + 500 do A.spawn(ag2, A.FORAGER, nest2.id) end
  check("agents.pool_capped", ag2.n == A.cfg.maxAgents, ag2.n)

  -- Discovery: an ant reaching an unknown node reveals it.
  local s3 = sim.new(31337)
  for i = 1, #s3.world.edges do s3.world.edges[i].strength = 0.9 end
  local hidden = 0
  for i = 1, #s3.world.nodes do
    if not s3.world.nodes[i].discovered then hidden = hidden + 1 end
  end
  run(s3, 45)
  local stillHidden = 0
  for i = 1, #s3.world.nodes do
    if not s3.world.nodes[i].discovered then stillHidden = stillHidden + 1 end
  end
  check("agents.exploration_discovers", stillHidden < hidden,
        hidden .. " -> " .. stillHidden)
end

-- ── seasons ────────────────────────────────────────────────────────────
local function testSeasons()
  local s = seasons.new()
  check("seasons.starts_spring", seasons.name(s) == "spring", seasons.name(s))
  seasons.update(s, seasons.cfg.seasonLen + 0.001)
  check("seasons.advances", seasons.name(s) == "summer", seasons.name(s))
  check("seasons.flags_change", s.justChanged)

  -- A full year returns to spring and increments the year.
  local s2 = seasons.new()
  for _ = 1, 4 do seasons.update(s2, seasons.cfg.seasonLen + 0.001) end
  check("seasons.year_wraps", seasons.name(s2) == "spring" and s2.year == 2,
        seasons.name(s2) .. " y" .. s2.year)

  -- Winter really is lean, and spring really does bloom.
  check("seasons.winter_is_lean",
        seasons.MODS.winter.yield < seasons.MODS.spring.yield)

  -- The wake size is never below the floor and never above what you had.
  local s3 = seasons.new()
  local wake = seasons.computeWake(s3, 0, 500, 24)
  check("seasons.wake_floor", wake == 24, wake)
  local wake2 = seasons.computeWake(s3, 1e9, 100, 24)
  check("seasons.wake_capped_by_population", wake2 == 100, wake2)
  local wake3 = seasons.computeWake(s3, 6000, 500, 24)
  check("seasons.wake_scales_with_stores", wake3 > 24 and wake3 < 500, wake3)
end

-- ── threats ────────────────────────────────────────────────────────────
local function testThreats()
  -- Rain multiplies scent decay while it falls, and only while it falls.
  local t = threats.new(function() return 0.5 end)
  check("threats.dry_by_default", threats.scentMul(t) == 1.0)
  t.rain = 5
  check("threats.rain_washes_scent", threats.scentMul(t) > 1.0,
        threats.scentMul(t))

  -- A spider lands on a BUSY road, not an empty one: an ambush nobody walks
  -- into is scenery, not a threat.
  local w = W.new(function() return 0.5 end)
  local n = W.addNode(w, "nest", 0, 0); w.nestId = n.id
  local f1 = W.addNode(w, "flower", 200, 0)
  local f2 = W.addNode(w, "flower", -200, 0)
  local busy = W.addEdge(w, n.id, f1.id)
  local quiet = W.addEdge(w, n.id, f2.id)
  busy.traffic, busy.strength = 40, 0.9
  local t2 = threats.new(function() return 0.5 end)
  t2.spiderNext = 0
  local c = castes.new(); castes.update(c)
  threats.update(t2, w, nil, c, 1 / 60, { threatPressure = 1 })
  check("threats.spider_picks_busy_road", busy.hazard > 0 and quiet.hazard == 0,
        busy.hazard .. "/" .. quiet.hazard)

  -- Soldiers reduce the hazard a spider presents. Same spider, more army.
  local hazardWeak = busy.hazard
  local c2 = castes.new(); c2.f, c2.n, c2.s = 1, 1, 10; castes.update(c2)
  threats.update(t2, w, nil, c2, 1 / 60, { threatPressure = 1 })
  check("threats.soldiers_relieve_hazard", busy.hazard < hazardWeak,
        hazardWeak .. " -> " .. busy.hazard)

  -- A spider leaves. Displacement, not destruction.
  for _ = 1, 60 * 40 do
    threats.update(t2, w, nil, c2, 1 / 60, { threatPressure = 0.0001 })
  end
  check("threats.spider_departs", busy.hazard == 0 or #t2.spiders == 0,
        busy.hazard)

  -- A long run must never breach the colony invariant, however unlucky.
  local s = sim.new(8888)
  for i = 1, #s.world.edges do s.world.edges[i].strength = 0.7 end
  run(s, 300)
  local ok, msg = economy.checkInvariant(s.economy, s.agents, s.world)
  check("threats.invariant_survives_pressure", ok, msg)
end

-- ── determinism ────────────────────────────────────────────────────────
local function testDeterminism()
  local a = sim.new(555)
  local b = sim.new(555)
  run(a, 30); run(b, 30)
  check("determinism.same_seed_same_dump", sim.dump(a) == sim.dump(b))

  -- CONTROL: a different seed must diverge, or the comparison above proves
  -- nothing (a dump that never changes would "pass" forever).
  local c = sim.new(556)
  run(c, 30)
  check("determinism.CONTROL_different_seed_diverges", sim.dump(a) ~= sim.dump(c))

  -- The same applies with player input in the mix.
  local d = sim.new(777)
  local e = sim.new(777)
  local function drive(s)
    for i = 1, 30 * 60 do
      sim.update(s, 1 / 60)
      if i % 120 == 0 then
        local target = s.world.nodes[2 + (i // 120) % 4]
        sim.apply(s, { kind = "link", from = s.world.nestId, to = target.id })
      end
    end
  end
  drive(d); drive(e)
  check("determinism.same_input_same_result", sim.dump(d) == sim.dump(e))
end

-- ── intents / apply ────────────────────────────────────────────────────
local function testApply()
  local s = sim.new(1)
  local b = s.world.nodes[2].id
  local ok = sim.apply(s, { kind = "link", from = s.world.nestId, to = b })
  check("apply.link_works", ok)

  -- A refused intent (no budget) reports false rather than lying.
  s.scent.budget = 0
  local ok2 = sim.apply(s, { kind = "link", from = s.world.nestId,
                             to = s.world.nodes[3].id })
  check("apply.refuses_when_broke", ok2 == false, tostring(ok2))

  -- Caste nudges route through apply and stay normalised.
  sim.apply(s, { kind = "caste", d = { 1, -1, 0 } })
  check("apply.caste_normalised",
        s.castes.f + s.castes.n + s.castes.s == castes.cfg.steps)

  -- An unknown intent is a no-op, not a crash. The input layer is allowed
  -- to grow verbs before the sim implements them.
  local ok3 = sim.apply(s, { kind = "nonsense" })
  check("apply.unknown_intent_safe", ok3 == false)

  -- Abandon by node pair (the pad form) finds the same edge as by id.
  local s2 = sim.new(2)
  local target = s2.world.nodes[2].id
  sim.apply(s2, { kind = "link", from = s2.world.nestId, to = target })
  local eid
  for _, id in ipairs(s2.world.adj[s2.world.nestId]) do
    local e = s2.world.edge[id]
    if e.a == target or e.b == target then eid = id end
  end
  check("apply.abandon_by_pair",
        sim.apply(s2, { kind = "abandon", from = s2.world.nestId, to = target })
        and s2.world.edge[eid].strength == 0)
end

-- ── the watchability property, measured ────────────────────────────────
local function testWatchability()
  -- DESIGN.md's bar, as a number: with no input at all, the colony must
  -- keep MOVING. A still screen is the failure this catches.
  local s = sim.new(4321)
  for i = 1, #s.world.edges do s.world.edges[i].strength = 0.6 end
  run(s, 5)
  local h1 = A.positionHash(s.agents)
  run(s, 1)
  local h2 = A.positionHash(s.agents)
  check("watch.ants_keep_moving", h1 ~= h2, h1 .. "/" .. h2)

  -- And the world must keep CHANGING, not just jiggling: food moves from
  -- the map into the nest without any player action.
  local before = s.agents.delivered
  run(s, 30)
  check("watch.unattended_progress", s.agents.delivered > before,
        before .. " -> " .. s.agents.delivered)

  -- Trails must evolve on their own: traffic reinforces, neglect fades.
  local s2 = sim.new(4321)
  local e = s2.world.edges[1]
  e.strength = 0.5
  local far = s2.world.edges[#s2.world.edges]
  far.strength = 0.5
  run(s2, 40)
  check("watch.trails_evolve", e.strength ~= 0.5 or far.strength ~= 0.5,
        e.strength .. "/" .. far.strength)
end

-- ── campaign ───────────────────────────────────────────────────────────
local function testCampaign()
  local campaign = require("sim.campaign")

  check("campaign.has_levels", campaign.count() >= 4, campaign.count())

  -- Every level builds a real map. A typo in a level table would
  -- otherwise surface as an empty garden the first time a player reached
  -- it -- the worst possible place to find out.
  for i = 1, campaign.count() do
    local lv = campaign.levels[i]
    local s2 = sim.new(999, lv.id)
    if lv.generated then
      check("campaign." .. lv.id .. ".generated_map", #s2.world.nodes > 3,
            #s2.world.nodes)
    else
      check("campaign." .. lv.id .. ".builds", #s2.world.nodes == #lv.nodes,
            #s2.world.nodes .. " vs " .. #lv.nodes)
      check("campaign." .. lv.id .. ".has_nest",
            s2.world.node[s2.world.nestId] ~= nil, "no nest")
      check("campaign." .. lv.id .. ".nest_is_yours",
            s2.world.node[s2.world.nestId].owner == "you",
            tostring(s2.world.node[s2.world.nestId].owner))
      -- Every level must offer somewhere to GO, or its lesson cannot be
      -- performed at all.
      local targets = 0
      for k = 1, #s2.world.nodes do
        local n = s2.world.nodes[k]
        if n.colonisable and n.owner == nil then targets = targets + 1 end
      end
      check("campaign." .. lv.id .. ".has_a_target", targets > 0, targets)
    end
  end

  -- The spider level's premise is a blocked road, so it must actually
  -- have a creature on one. Declaring spiderOn without acting on it left
  -- this level as a lesson about clearing a road with nothing in the way.
  local sp = sim.new(4, "the-spider")
  check("campaign.spider_level_has_a_spider", #sp.threats.spiders == 1,
        #sp.threats.spiders)
  if #sp.threats.spiders == 1 then
    local e = sp.world.edge[sp.threats.spiders[1].edge]
    check("campaign.spider_blocks_a_road", e ~= nil and e.hazard > 0,
          tostring(e and e.hazard))
  end

  -- Completion: a fresh level is NOT complete (the control -- otherwise
  -- every garden would open the next one instantly), and taking the
  -- ground it asks for finishes it.
  local c1 = sim.new(7, "first-ground")
  check("campaign.CONTROL_fresh_level_incomplete",
        campaign.complete(c1.level, c1.world) == false, "complete at t=0")
  for i = 2, #c1.world.nodes do
    if c1.world.nodes[i].colonisable then
      c1.world.nodes[i].owner = "you"
      break
    end
  end
  check("campaign.taking_ground_completes_it",
        campaign.complete(c1.level, c1.world) == true, "still incomplete")

  -- A named lesson must be the one performed: "reach" is about the soil
  -- beside the fruit, and taking any other seed must NOT satisfy it.
  local c2 = sim.new(7, "reach")
  local lvl = campaign.byId("reach")
  for i = 2, #c2.world.nodes do
    local n = c2.world.nodes[i]
    if n.colonisable and not (lvl.nodes[i] and lvl.nodes[i].mustHold) then
      n.owner = "you"
    end
  end
  check("campaign.CONTROL_wrong_ground_does_not_complete",
        campaign.complete(c2.level, c2.world) == false,
        "the named ground was not required")
  for i = 2, #c2.world.nodes do
    if lvl.nodes[i] and lvl.nodes[i].mustHold then
      c2.world.nodes[i].owner = "you"
    end
  end
  check("campaign.named_ground_completes_it",
        campaign.complete(c2.level, c2.world) == true, "still incomplete")

  -- The campaign ends by handing over the real game.
  local last = campaign.levels[campaign.count()]
  check("campaign.ends_generated", last.generated == true, tostring(last.id))
  check("campaign.next_walks_forward",
        campaign.next("first-ground") ~= nil, "no level after the first")
  check("campaign.next_ends", campaign.next(last.id) == nil, "past the end")
end

-- ── save / load ────────────────────────────────────────────────────────
local function testSave()
  local save = require("sim.save")

  local a = sim.new(24680)
  -- Give it a real history: roads, discovery, spent budget, a part-year.
  for i = 2, math.min(4, #a.world.nodes) do
    sim.apply(a, { kind = "link", from = a.world.nestId, to = a.world.nodes[i].id })
  end
  run(a, 120)

  local text = save.serialize(a)
  check("save.produces_text", type(text) == "string" and #text > 0, #text)

  -- THE SIZE CONSTRAINT IS REAL: a wasmcart save blob is 4096 bytes. A save
  -- that overflows it is not "mostly fine", it is truncated -- so this is
  -- asserted rather than hoped for.
  check("save.fits_in_blob", #text <= 4096, #text .. " bytes")

  check("save.peek_seed", save.peekSeed(text) == 24680, save.peekSeed(text))

  -- Restore into a fresh world of the same seed and compare the things a
  -- player could notice. Ant POSITIONS deliberately do not survive (an ant
  -- is weather, not history), so the comparison is on the colony's shape.
  local b = sim.new(24680)
  local ok, msg = save.deserialize(b, text)
  check("save.restores", ok, msg)

  check("save.food", math.abs(a.economy.food - b.economy.food) < 0.02,
        a.economy.food .. " vs " .. b.economy.food)
  check("save.population", a.agents.n == b.agents.n,
        a.agents.n .. " vs " .. b.agents.n)
  check("save.caste", castes.digest(a.castes) == castes.digest(b.castes),
        castes.digest(a.castes) .. " vs " .. castes.digest(b.castes))
  check("save.season", seasons.digest(a.seasons) == seasons.digest(b.seasons),
        seasons.digest(a.seasons) .. " vs " .. seasons.digest(b.seasons))
  check("save.time", math.abs(a.time - b.time) < 0.02, a.time .. " vs " .. b.time)
  check("save.delivered",
        math.abs(a.agents.delivered - b.agents.delivered) < 0.02,
        a.agents.delivered .. " vs " .. b.agents.delivered)

  -- The ROADS are the save. Every edge's strength must come back.
  local edgesMatch = (#a.world.edges == #b.world.edges)
  if edgesMatch then
    for i = 1, #a.world.edges do
      if math.abs(a.world.edges[i].strength - b.world.edges[i].strength) > 0.001 then
        edgesMatch = false
        break
      end
    end
  end
  check("save.roads", edgesMatch,
        #a.world.edges .. " vs " .. #b.world.edges .. " edges")

  -- Discovery state survives: a reload must not re-hide the map.
  local discA, discB = 0, 0
  for i = 1, #a.world.nodes do
    if a.world.nodes[i].discovered then discA = discA + 1 end
    if b.world.nodes[i].discovered then discB = discB + 1 end
  end
  check("save.discovery", discA == discB, discA .. " vs " .. discB)

  -- THE PLAYER'S OWN STATE rides in the same blob: what they have learned,
  -- and what they have set. Saving it is only worth anything if it comes
  -- back, so the round-trip is asserted here rather than in a gate -- the
  -- host reloads a cart with an EMPTY blob, so a reload-through-romdev
  -- cannot see this at all and an assertion there tests the harness.
  local menu = require("ui.menu")
  local cursor = require("ui.cursor")
  cursor.setCounts({ link = 5, danger = 2, caste = 1 })
  menu.settings.music = 1
  menu.settings.sfx = 4
  menu.settings.palette = 2
  menu.settings.hints = false
  local text2 = save.serialize(a)
  check("save.fits_with_player_state", #text2 <= 4096, #text2 .. " bytes")

  -- THE BLOB HAS TO CONTAIN THEM, asserted on the TEXT.
  --
  -- This check is the one that would have caught the bug the two below
  -- it missed for as long as the settings have existed: menu.serialize
  -- was never called by anything, so the blob carried no settings at
  -- all, and the restore assertions still passed because they read the
  -- live module the test itself had written. An assertion about what is
  -- in the save has to look at the save.
  check("save.carries_player_state",
        text2:match("\nset ") ~= nil and text2:match("\ncur ") ~= nil,
        "set/cur lines present")

  -- Wipe to the opposite of everything above, so a no-op deserialize
  -- cannot pass by leaving the values where they already were.
  cursor.setCounts({ link = 0, danger = 0, caste = 0 })
  menu.settings.music = 4
  menu.settings.sfx = 0
  menu.settings.palette = 1
  menu.settings.hints = true

  local e = sim.new(24680)
  save.deserialize(e, text2)
  local counts = cursor.getCounts()
  check("save.learning_restored",
        counts.link == 5 and counts.danger == 2 and counts.caste == 1,
        string.format("%d/%d/%d", counts.link, counts.danger, counts.caste))
  check("save.settings_restored",
        menu.settings.music == 1 and menu.settings.sfx == 4 and
        menu.settings.palette == 2 and menu.settings.hints == false,
        string.format("music=%d sfx=%d pal=%d hints=%s", menu.settings.music,
                      menu.settings.sfx, menu.settings.palette,
                      tostring(menu.settings.hints)))
  -- THE TWO SLIDERS ARE INDEPENDENT, proved on the numbers that reach the
  -- mixer rather than on the settings that produced them. music=1 and
  -- sfx=4 above are deliberately opposite ends, so a build that wired
  -- both rows to one control lands them equal here.
  local audio = require("audio.init")
  check("save.volumes_independent",
        audio.musicVolume < audio.sfxVolume,
        string.format("music=%.2f sfx=%.2f", audio.musicVolume,
                      audio.sfxVolume))

  -- A PRE-SPLIT SAVE STILL LOADS. The old three-field form had one
  -- volume; it reads as the music setting and sfx falls back to default,
  -- rather than the whole line being refused.
  menu.settings.music = 0
  menu.settings.sfx = 0
  menu.deserialize("2 2 0")
  check("save.settings_pre_split",
        menu.settings.music == 2 and menu.settings.sfx == 3,
        string.format("music=%d sfx=%d", menu.settings.music,
                      menu.settings.sfx))

  -- Leave the defaults as the rest of the suite (and the game) expect.
  cursor.setCounts({ link = 0, danger = 0, caste = 0 })
  menu.settings.music = 3
  menu.settings.sfx = 3
  menu.settings.palette = 1
  menu.settings.hints = true
  menu.applyVolumes()

  -- OWNERSHIP ROUND-TRIPS, which since the 4X rebuild is the whole save.
  -- The colony's shape used to be its roads; now it is which ground you
  -- hold, and a node record that forgot owner/siege would restore a
  -- player's entire empire as neutral -- silent, total loss dressed up as
  -- a successful load.
  local ow = sim.new(24680)
  local taken = nil
  for i = 2, #ow.world.nodes do
    if ow.world.nodes[i].colonisable then
      taken = ow.world.nodes[i]
      taken.owner = "you"
      taken.discovered = true
      break
    end
  end
  local sieged = nil
  for i = 2, #ow.world.nodes do
    local nd = ow.world.nodes[i]
    if nd.colonisable and nd ~= taken then
      sieged = nd
      nd.siege = 3
      nd.discovered = true
      break
    end
  end
  check("save.setup_had_ground", taken ~= nil and sieged ~= nil,
        tostring(taken) .. "/" .. tostring(sieged))

  if taken and sieged then
    local otext = save.serialize(ow)
    local ow2 = sim.new(24680)
    save.deserialize(ow2, otext)
    local t2 = ow2.world.node[taken.id]
    local s2 = ow2.world.node[sieged.id]
    check("save.ownership_restored", t2 and t2.owner == "you",
          tostring(t2 and t2.owner))
    check("save.siege_restored", s2 and s2.siege == 3,
          tostring(s2 and s2.siege))
    -- CONTROL: a node nobody took must come back neutral, or "restored"
    -- would just mean "everything is yours".
    local neutral = nil
    for i = 2, #ow.world.nodes do
      local nd = ow2.world.nodes[i]
      if nd.id ~= taken.id and nd.id ~= sieged.id then neutral = nd break end
    end
    check("save.CONTROL_unowned_stays_unowned",
          neutral ~= nil and neutral.owner == nil,
          tostring(neutral and neutral.owner))

    -- The colony is spread over the ground it holds rather than teleported
    -- home: the pop record rebuilds everyone at the nest, so a reload
    -- without the redistribute pass leaves outposts owned and empty.
    local atTaken = 0
    for i = 1, ow2.agents.n do
      if ow2.agents.pool[i].home == taken.id then atTaken = atTaken + 1 end
    end
    check("save.colony_spread_over_owned_ground", atTaken > 0,
          atTaken .. " ants at the restored outpost")
  end

  -- CONTROL: a save must be REJECTED when it does not belong to this world.
  -- Silently restoring another seed's colony into this map would put roads
  -- between nodes that are somewhere else entirely.
  local c = sim.new(13579)
  local okWrong = save.deserialize(c, text)
  check("save.CONTROL_rejects_foreign_seed", okWrong == false, tostring(okWrong))

  -- CONTROL: a version bump must reject rather than half-read.
  local bumped = text:gsub("^v %d+", "v 999", 1)
  local d = sim.new(24680)
  local okVer = save.deserialize(d, bumped)
  check("save.CONTROL_rejects_other_version", okVer == false, tostring(okVer))

  -- Garbage must fail cleanly, not crash: a corrupt blob costs the save,
  -- never the run.
  local e = sim.new(24680)
  local okGarbage, gErr = pcall(save.deserialize, e, "this is not a save\nat all")
  check("save.garbage_is_safe", okGarbage, tostring(gErr))
  local okEmpty = save.deserialize(sim.new(1), "")
  check("save.empty_rejected", okEmpty == false)

  -- The RNG STREAM continues rather than replaying. Without this a reloaded
  -- colony meets the same spiders in the same order every time.
  local f1 = sim.new(24680)
  run(f1, 60)
  local t1 = save.serialize(f1)
  local g1 = sim.new(24680)
  save.deserialize(g1, t1)
  run(f1, 30); run(g1, 30)
  check("save.rng_continues",
        math.abs(f1.threats.spiderNext - g1.threats.spiderNext) < 0.5,
        f1.threats.spiderNext .. " vs " .. g1.threats.spiderNext)
end

function M.run()
  pass, fail = 0, 0
  print("SIMTEST BEGIN")
  testWorld()
  testScent()
  testCastes()
  testEconomy()
  testAgents()
  testSeasons()
  testThreats()
  testDeterminism()
  testApply()
  testSave()
  testCampaign()
  testWatchability()
  print(string.format("SIMTEST DONE %d %d", pass, fail))
  return pass, fail
end

return M
