-- probe.lua - the agent's instrument panel.
--
-- Emits structured lines a gate can parse, and draws a developer overlay.
-- The cart cannot time itself (love.timer is the fixed 1/60 counter), so
-- nothing here claims milliseconds -- it reports what only the cart knows.

local A = require("sim.agents")
local W = require("sim.world")

local M = {}

M.overlay = false
local METRIC_EVERY = 30
local frames = 0

function M.init(S)
  frames = 0
  -- LEVEL IS PART OF THE BOOT REPORT. A cart packed with an
  -- `app/startlevel` marker opens somewhere other than Gather, and a gate
  -- that assumed the usual opening board would otherwise just report
  -- baffling failures -- which is exactly what happened once.
  -- QUEENS AND FOOD ARE PART OF THE BOOT REPORT now that a colony can
  -- starve. Whether a board is survivable from its first frame is a
  -- function of exactly these three numbers, and a gate that had to play
  -- the level to find out would be asserting on its own play instead.
  local sim = require("sim.init")
  local queens, mine = 0, 0
  for i = 1, #S.world.nodes do
    local n = S.world.nodes[i]
    if n.owner == A.YOU then queens = queens + #(n.queens or {}) end
  end
  for i = 1, S.agents.n do
    if S.agents.pool[i].side == A.YOU then mine = mine + 1 end
  end
  print(string.format(
    "@boot seed=%d mounds=%d ants=%d level=%s mine=%d queens=%d food=%d",
    S.seed, #S.world.nodes, S.agents.n, tostring(S.levelId or "open"),
    mine, queens, sim.foodOf(S, A.YOU)))
end

function M.noteIntent(it, ok)
  print(string.format("@i %s ok=%s from=%s to=%s node=%s n=%s",
    it.kind, tostring(ok), tostring(it.from), tostring(it.to),
    tostring(it.node), tostring(it.count)))
end

function M.noteCursor(it)
  local intents = require("input.intents")
  print(string.format("@c select node=%s selected=%s frac=%.2f",
    tostring(it.node), tostring(intents.selected), intents.fraction or 0))
end

-- Every mound: who holds it, its garrison, queens and stats. This is the
-- 4X state a gate asserts on.
function M.reportMounds(S)
  for i = 1, #S.world.nodes do
    local n = S.world.nodes[i]
    -- `g` is YOUR ants here; `fg` is the HOLDER's. On your own ground the
    -- two agree, but on an enemy mound `g` alone reads 0 and looks like an
    -- undefended target -- which is exactly the number a gate must not
    -- assert an attack against.
    local hold = n.owner or "you"
    -- BATTLE SPIN, BY SIDE (plan 05). Read straight off the sim's own
    -- assignment rather than inferred from motion -- the no-deadlock gate
    -- asserts the two sides opposed each other, which is a fact about
    -- what M.fight decided, not something worth re-deriving from
    -- positions two frames apart.
    local spinYou = n.battleSpin and n.battleSpin["you"] or 0
    local spinFoe = 0
    if n.battleSpin then
      for side, sp in pairs(n.battleSpin) do
        if side ~= "you" then spinFoe = sp; break end
      end
    end
    -- QUEEN HP AND HER CORPSE (2026-08-19): the siege-close-in and
    -- carry-home fixes need a gate to see her hp mid-fight and whether
    -- a fallen body is still waiting to be picked up, neither of which
    -- this line reported before.
    local qhp = (n.queens and n.queens[1] and n.queens[1].hp) or -1
    print(string.format(
      "@mound %s %s g=%d gi=%d fg=%d q=%d/%d energy=%.0f reach=%.0f seen=%s brood=%d held=%s obs=%s contested=%s visited=%s spinYou=%d spinFoe=%d qhp=%.0f corpses=%d corpseValue=%d",
      n.id, tostring(n.owner), A.garrison(S.agents, n.id, "you"),
      A.garrisonIncoming(S.agents, n.id, "you"),
      A.garrison(S.agents, n.id, hold),
      n.queens and #n.queens or 0, n.maxQueens or 0,
      n.energy or 0, W.reach(n), tostring(n.seen),
      n.brood and #n.brood or 0, tostring(n.held or false),
      tostring(n.observed or false),
      tostring(n.contested or false),
      tostring(n.visited or false), spinYou, spinFoe,
      qhp, n.corpses or 0, n.corpseValue or 0))
  end
end

-- Every ant with business at one site: standing on it, headed for it, or
-- ultimately bound for it. Not wired into the overlay's automatic dump --
-- call it by hand from a debug script with the site id you are chasing.
-- Built to find the stuck-forage bug (a location a rival owned could
-- never change hands, so ants sat on full stock doing nothing -- see
-- M.fight in sim/agents.lua) and worth keeping for the next one like it.
function M.reportAnts(S, siteId)
  local a = S.agents
  for i = 1, a.n do
    local ant = a.pool[i]
    if (ant.at == siteId) or (ant.to == siteId) or (ant.goal == siteId) then
      print(string.format(
        "@ant i=%d side=%s at=%s from=%s to=%s goal=%s stage=%s t=%.3f carry=%s x=%.0f y=%.0f",
        i, tostring(ant.side), tostring(ant.at), tostring(ant.from),
        tostring(ant.to), tostring(ant.goal), tostring(ant.stage),
        ant.t or -1, tostring(ant.carry), ant.x or -1, ant.y or -1))
    end
  end
end

-- Every location: what it is, who holds it, how much is left in it. The
-- kind is reported even when the fog is hiding it from the PLAYER -- a
-- gate has to be able to assert that the screen does not show what this
-- line says.
function M.reportLocs(S)
  local home = S.world.node[S.world.homeId]
  for i = 1, #(S.world.locs or {}) do
    local l = S.world.locs[i]
    print(string.format(
      -- PLAN 05: `guard` is gone (world.lua's spider spec no longer sets
      -- it); `hp` is her current field, meaningless (0) for anything
      -- else. Kept as the same column name so an old gate parsing this
      -- line for a NON-spider location sees no change.
      "@loc %s %s %s items=%d/%d value=%d guard=%d observed=%s held=%s visited=%s lastseen=%d homedist=%.0f homereach=%.0f contested=%s",
      l.id, l.kind, tostring(l.owner), l.items or 0, l.cap or 0,
      l.value or 0, l.hp or 0, tostring(l.observed), tostring(l.held),
      tostring(l.visited or false), l.lastSeenItems or -1,
      -- SIM TRUTH, NOT PLAYER KNOWLEDGE. A gate has to be able to assert
      -- the map-generation guarantee ("always a grain patch inside home's
      -- reach") without that guarantee being visible to the player -- the
      -- whole point of plan 04 is that it is not. Distance and reach are
      -- facts about the board; `observed` above is a fact about what has
      -- been earned.
      home and W.dist(home, l) or -1,
      home and W.reach(home) or -1,
      -- PLAN 05: a spider fight sets this true while ants are engaged
      -- (M.fightSpider), the same signal a mound's `contested` gives --
      -- needed by test-spider's music assertion (05-battles.md section
      -- 7: "a spider fight counts as war"). Trailing, for the same
      -- older-cart-compatibility reason every other trailing field here
      -- is optional in drive.mjs's parser.
      tostring(l.contested or false)))
    if l.kind == "spider" then
      -- PLAN 05's own line: hp, killT, how many of the 8 legs are held
      -- right now, and whether that count is all 8 (subdued). Needed by
      -- test-spider for everything M.fightSpider decides that `@loc`
      -- alone cannot show -- leg occupancy is per-instance state, not a
      -- location field a generic line already reports.
      local held = 0
      if l.spiderLegs then
        for leg = 1, 8 do if l.spiderLegs[leg] then held = held + 1 end end
      end
      print(string.format("@spider %s hp=%d killT=%.2f held=%d subdued=%s",
        l.id, l.hp or 0, l.killT or -1, held, tostring(held >= 8)))
    end
  end
end

function M.reportNodes(S, vp)
  for i = 1, #S.world.nodes do
    local n = S.world.nodes[i]
    local x, y = vp.worldToScreen(n.x, n.y)
    print(string.format("@node %s %d %d", n.id,
                        math.floor(x + 0.5), math.floor(y + 0.5)))
  end
  -- Locations are drag targets like anything else, so a gate needs their
  -- screen positions to play the game the way a player does.
  for i = 1, #(S.world.locs or {}) do
    local l = S.world.locs[i]
    local x, y = vp.worldToScreen(l.x, l.y)
    print(string.format("@node %s %d %d", l.id,
                        math.floor(x + 0.5), math.floor(y + 0.5)))
  end
  -- PLAN 05's corpse-fog pixel gate needs a small search radius, not the
  -- whole mound -- the ring art has its own internal gradient bands that
  -- overlap a corpse's luminance, so scanning a wide area around the
  -- mound centre catches the art itself. Screen position of each corpse,
  -- so the gate can crop tight around the real spot instead.
  for i = 1, #S.agents.corpses do
    local c = S.agents.corpses[i]
    local x, y = vp.worldToScreen(c.x, c.y)
    print(string.format("@corpse %d %d %d", i,
                        math.floor(x + 0.5), math.floor(y + 0.5)))
  end
end

function M.reportUI(vp)
  local menu = require("ui.menu")
  local intents = require("input.intents")
  if vp then
    local px, py, pw, ph = menu.pauseRect(vp)
    print(string.format("@pause %d %d %d %d",
      math.floor(px), math.floor(py), math.floor(pw), math.floor(ph)))
  end
  print(string.format("@ui menu=%s row=%d cursor=%s selected=%s frac=%.2f",
    tostring(menu.open), menu.index, tostring(intents.cursor.node),
    tostring(intents.selected), intents.fraction or 0))
  -- THE CAMERA, which no pixel assertion can pin down: a view that panned
  -- and a view that did not look identical in a screenshot of open ground.
  if vp then
    print(string.format("@cam x=%.1f y=%.1f zoom=%.4f", vp.cam.x, vp.cam.y,
                        vp.cam.zoom))
  end
end

function M.command(S, what)
  local sim = require("sim.init")
  if what == "overlay" then
    M.overlay = not M.overlay
    M.wantReport = M.overlay
    print("@dbg overlay=" .. tostring(M.overlay))
  elseif what == "pause" then
    S.paused = not S.paused
    print("@dbg paused=" .. tostring(S.paused))
  elseif what == "feed" or what == "starve" then
    -- INSTRUMENTS, NOT MECHANICS.
    --
    -- The player never handles food: queens eat it themselves and there
    -- is no way to spend, stockpile or withhold it by hand. These two
    -- exist so a GATE can set up a fed or empty pantry before anything
    -- that forages has been built -- otherwise the rule that hunger
    -- stops a queen laying could not be proved until three phases later.
    --
    -- Both are locked behind the developer overlay so no stray press in
    -- ordinary play can reach them. A cheat one button-combination away
    -- from a real player is a cheat that will happen by accident.
    if not M.overlay then
      print("@dbg refused " .. what .. " (overlay off)")
      return
    end
    if what == "feed" then
      sim.addFood(S, A.YOU, 20)
      print(string.format("@food you=%d granted=20", sim.foodOf(S, A.YOU)))
    else
      S.food = S.food or {}
      S.food[A.YOU] = 0
      print("@food you=0 starved")
    end
  elseif what == "roundtrip" then
    -- SERIALIZE, THEN DESERIALIZE BACK INTO THE LIVE SIM, in place.
    --
    -- The save/load path cannot be gated by rebooting the cart: romdev
    -- hands every loadMedia a fresh save sandbox, so a reloaded cart
    -- always starts new and an assertion built on that is testing the
    -- harness, not the format. This exercises the actual pair of
    -- functions against the actual state, which is the thing that can
    -- silently drop a field.
    if not M.overlay then
      print("@dbg refused roundtrip (overlay off)")
      return
    end
    -- SPIDER STATE, BEFORE AND AFTER, IN THIS SAME ATOMIC COMMAND. A
    -- gate that reads state via a separate `@spider` line before this
    -- and another one after would be comparing across real elapsed
    -- frames -- and an ongoing fight keeps dealing damage on its own
    -- clock in between, which reads as the round trip losing state when
    -- it did not. Snapshotting immediately before serialize and
    -- immediately after deserialize, with no frame gap, isolates the
    -- round trip's own fidelity from the fight continuing around it.
    local function spiderSnap()
      for li = 1, #S.world.locs do
        local l = S.world.locs[li]
        if l.kind == "spider" then
          local held = 0
          if l.spiderLegs then
            for leg = 1, 8 do if l.spiderLegs[leg] then held = held + 1 end end
          end
          return l.hp or 0, l.killT or -1, held
        end
      end
      return -1, -1, -1
    end
    local hpBefore, killTBefore, heldBefore = spiderSnap()
    local sv = require("sim.save")
    local blob = sv.serialize(S)
    local ok, msg = sv.deserialize(S, blob)
    local hpAfter, killTAfter, heldAfter = spiderSnap()
    print(string.format(
      "@roundtrip ok=%s %s bytes=%d spiderBefore=%d,%.2f,%d spiderAfter=%d,%.2f,%d",
      tostring(ok), tostring(msg), #blob,
      hpBefore, killTBefore, heldBefore, hpAfter, killTAfter, heldAfter))
  elseif what == "food" then
    print(string.format("@food you=%d carried=%d dead=%s",
      sim.foodOf(S, A.YOU), A.carried(S.agents, A.YOU),
      tostring(S.dead and S.dead[A.YOU] or false)))
  elseif what == "faceaway" or what == "facetoward" or what == "faceoff" then
    -- PLAN 05, test-battle's cone gate ONLY. Toggles a PERSISTENT lock
    -- pinning every player ant's FACING away from, or toward, its
    -- nearest enemy -- re-applied every tick from M.update (see
    -- `debugFaceLock` there), because a one-time snap does not hold: a
    -- milling ant's `ant.dir` is re-derived from its actual displacement
    -- every frame (M.face), so a static write is overwritten on the very
    -- next tick the ant takes a step.
    --
    -- Why this exists at all: the cone is a fact about `ant.dir`, and
    -- the ordinary way to get an ant facing a particular way is to walk
    -- it there -- which for "pinned with an enemy directly behind" is a
    -- geometry problem a gate should not have to solve by choreographing
    -- a battle-spin orbit to the millisecond. This pins the ONE thing
    -- the cone test cares about and leaves position, hp and everything
    -- else untouched, so the assertion is still testing the real
    -- target-selection code in M.fight, not a fabricated state.
    if not M.overlay then
      print("@dbg refused " .. what .. " (overlay off)")
      return
    end
    S.agents.debugFaceLock = (what == "faceoff") and nil or what
    print("@dbg facelock=" .. tostring(S.agents.debugFaceLock))
  elseif what == "samespin" then
    -- PLAN 05, test-battle's no-deadlock CONTROL only. Toggles the
    -- sabotage flag M.fight reads when rolling a NEW battle's spin
    -- assignment -- forcing every side to spin the same way, which is
    -- exactly what opposite-direction marching exists to prevent. Only
    -- takes effect on a battle that has not yet rolled a spin, so it
    -- must be set BEFORE the two sides are put in the same mound.
    if not M.overlay then
      print("@dbg refused samespin (overlay off)")
      return
    end
    S.agents.debugForceSameSpin = not S.agents.debugForceSameSpin
    print("@dbg samespin=" .. tostring(S.agents.debugForceSameSpin))
  elseif what == "killholder" then
    -- PLAN 05, test-spider #4 ONLY: force-kill one of the PLAYER's
    -- current spider leg-holders, so the gate can prove a holder's death
    -- frees the leg and drops `subdued` that same tick without waiting
    -- on the spider's own kill clock to happen to pick one.
    --
    -- Reports the leg-held count IMMEDIATELY, in this same print, rather
    -- than leaving the gate to read it off the next `@spider` line: the
    -- ordinary M.fightSpider tick that runs right after this command
    -- INSTANTLY refills a freed leg from any remaining non-holder
    -- engaged ant (that is the correct rule -- ruling 1's "auto-refill
    -- legs" -- not a bug), so a gate reading state one frame later would
    -- see the leg already retaken whenever a striker is still available.
    -- The un-subdued MOMENT is real and is what this line proves.
    if not M.overlay then
      print("@dbg refused killholder (overlay off)")
      return
    end
    local a = S.agents
    for li = 1, #S.world.locs do
      local l = S.world.locs[li]
      if l.kind == "spider" and l.spiderLegs then
        for leg = 1, 8 do
          local pid = l.spiderLegs[leg]
          local ant = pid and a.pool[pid]
          if ant and ant.side == A.YOU then
            -- hp READ BEFORE THE KILL, in this same atomic command, so
            -- the gate compares hpBefore/hpAfter with zero frame gap --
            -- the only honest way to prove killholder itself deals no
            -- damage, since the fight's own ongoing clock keeps moving
            -- hp on its own between any two separately-polled reads.
            local hpBeforeKill = l.hp or 0
            l.spiderLegs[leg] = nil
            A.pushCorpse(a, ant.x, ant.y, ant.side, ant.at)
            A.kill(a, pid)
            local held = 0
            for k = 1, 8 do if l.spiderLegs[k] then held = held + 1 end end
            print(string.format(
              "@dbg killholder killed leg=%d hpBefore=%d hp=%d held=%d subdued=%s",
              leg, hpBeforeKill, l.hp or 0, held, tostring(held >= 8)))
            return
          end
        end
      end
    end
    print("@dbg killholder found nothing to kill")
  end
end

function M.slots(intents)
  if not M.overlay then return end
  local parts = {}
  local slots = intents.slots()
  for i = 0, 9 do
    local p = slots[i]
    if p and p.active then parts[#parts + 1] = i .. (p.down and "+" or "-") end
  end
  if #parts > 0 then print("@slots " .. table.concat(parts, " ")) end
end

function M.update(S, dt)
  frames = frames + 1
  if frames % METRIC_EVERY ~= 0 then return end
  -- The mixer's live state, on the same tick as the metrics. A gate cannot
  -- HEAR the cart (romdev records silence for wasmcart), so this line is
  -- the only evidence that music is playing and which track is up.
  pcall(function() require("audio.init").report() end)
  local n, mine, theirs, moving = A.stats(S.agents)
  -- MINIMUM HP PER SIDE (plan 05's cone gate). A full-strength ant has
  -- never taken a landed hit; the moment either side's minimum drops
  -- below maxHp, SOMEBODY on that side has been struck. -1 (not 0) when
  -- a side has no ants at all, so "nobody has been hit" and "nobody
  -- exists to hit" print as visibly different numbers.
  local hpMine, hpEnemy = -1, -1
  for i = 1, S.agents.n do
    local ant = S.agents.pool[i]
    if ant.hp then
      if ant.side == A.YOU then
        hpMine = (hpMine < 0) and ant.hp or math.min(hpMine, ant.hp)
      else
        hpEnemy = (hpEnemy < 0) and ant.hp or math.min(hpEnemy, ant.hp)
      end
    end
  end
  local owned, queens, seen = 0, 0, 0
  for i = 1, #S.world.nodes do
    local nd = S.world.nodes[i]
    if nd.owner == "you" then owned = owned + 1 end
    queens = queens + (nd.queens and #nd.queens or 0)
    if nd.seen then seen = seen + 1 end
  end
  local locs, locsMine, items = 0, 0, 0
  -- SPIDER HP/HELD, ON THE CHEAP METRIC LINE (plan 05). `@spider` only
  -- prints inside the overlay dump, which costs a full press/step/press
  -- cycle (~120+ frames via the driver's inspect()) -- too coarse to
  -- poll a fight where a 12-ant column can go from "nobody arrived" to
  -- "fully subdued" inside a ~40-frame window (measured while building
  -- test-spider's withdrawal gate). `@m` already fires every tick with
  -- no overlay cost, so a gate that needs to catch a fast-moving spider
  -- fight polls THIS, not inspect(). First spider found only -- no
  -- fixture in this plan has more than one on the board at once.
  local spiderHp, spiderHeld = -1, -1
  for i = 1, #(S.world.locs or {}) do
    local l = S.world.locs[i]
    locs = locs + 1
    if l.owner == "you" then locsMine = locsMine + 1 end
    items = items + (l.items or 0)
    if l.kind == "spider" and spiderHp < 0 then
      spiderHp = l.hp or 0
      spiderHeld = 0
      if l.spiderLegs then
        for leg = 1, 8 do if l.spiderLegs[leg] then spiderHeld = spiderHeld + 1 end end
      end
    end
  end
  local sim = require("sim.init")
  -- CARRYING-A-QUEEN COUNT, ON THE CHEAP LINE (2026-08-19): same reason
  -- spiderHp/spiderHeld are here rather than only in the overlay dump --
  -- polling `inspect()` for a fast-moving carry-home trip is coarse and
  -- expensive; `@m` fires every tick for free.
  local carryingQueen = 0
  for i = 1, S.agents.n do
    if S.agents.pool[i].carryQueen then carryingQueen = carryingQueen + 1 end
  end
  print(string.format(
    '@m {"t":%.2f,"ants":%d,"mine":%d,"theirs":%d,"moving":%d,' ..
    '"owned":%d,"queens":%d,"seen":%d,"mounds":%d,"phash":%d,' ..
    '"food":%d,"carried":%d,"dead":%s,' ..
    '"locs":%d,"locsMine":%d,"items":%d,"picked":%d,"delivered":%d,' ..
    '"eaten":%d,"hits":%d,"corpses":%d,"swings":%d,' ..
    '"dmgMin":%d,"dmgMax":%d,"corpsesDropped":%d,' ..
    '"hpMine":%.1f,"hpEnemy":%.1f,"spiderHp":%d,"spiderHeld":%d,' ..
    '"queensKilled":%d,"carryingQueen":%d}',
    S.time, n, mine, theirs, moving, owned, queens, seen,
    #S.world.nodes, A.positionHash(S.agents),
    sim.foodOf(S, "you"), A.carried(S.agents, "you"),
    tostring(S.dead and S.dead["you"] or false),
    locs, locsMine, items,
    S.agents.pickedBy["you"] or 0, S.agents.deliveredBy["you"] or 0,
    sim.eatenBy(S, "you"), S.agents.hits or 0, #S.agents.corpses,
    S.agents.swings or 0,
    S.agents.dmgMin or -1, S.agents.dmgMax or -1,
    S.agents.corpsesDropped or 0, hpMine, hpEnemy, spiderHp, spiderHeld,
    S.agents.queensKilled or 0, carryingQueen))
end

function M.draw(S, vp, intents)
  if not M.overlay then return end
  if M.wantReport then
    M.wantReport = false
    M.reportNodes(S, vp)
    M.reportMounds(S)
    M.reportLocs(S)
  end
  M.reportUI(vp)
end

return M
