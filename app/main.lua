-- main.lua - the cart's entry points, and nothing else.
--
-- The wall this file guards: the SIM knows nothing about drawing, and the
-- RENDERER never writes to the sim. Everything between them goes through
-- an intent (player -> sim) or a snapshot (sim -> renderer).

local vp      = require("render.viewport")
local W       = require("sim.world")
local sim     = require("sim.init")
local intents = require("input.intents")
local probe   = require("debug.probe")
local audio   = require("audio.init")
local save    = require("sim.save")
local menu    = require("ui.menu")
local progress = require("sim.progress")
local levelsel = require("ui.levelselect")
local celebrate = require("ui.celebrate")

local S
local booted = false
-- True when an `app/startlevel` marker chose the board, which suppresses
-- the level-select screen (a gate must land on its fixture, not a menu).
local startLevelForced = false
-- The cursor-follow window: see the nudge in love.update.
local lastCursor = nil
local followFrames = 0
local DT = 1 / 60

-- TEST MODE: if app/testmode exists in the bundle, the cart runs the pure
-- sim suite instead of the game and prints its results.
local testMode = false

function love.load()
  vp.init()

  local info = love.filesystem.getInfo and love.filesystem.getInfo("testmode")
  if info then
    testMode = true
    require("test.simtest").run()
    return
  end

  -- ONE persistent colony. A save names the seed its map was generated
  -- from, so restoring rebuilds the identical field of mounds.
  local blob = save.read()
  local seed = blob and save.peekSeed(blob)
  if not seed then
    seed = math.floor(love.math.random() * 2147483000) + 1
  end
  -- A NEW PLAYER STARTS IN THE CAMPAIGN. The generated field is the full
  -- game with every idea live at once, which is what made this
  -- unreadable to sit down in front of.
  local levelId = blob and save.peekLevel(blob) or "gather"

  -- BUILD-TIME LEVEL OVERRIDE, for gates. A marker file named `startlevel`
  -- holding a level id boots straight into it, so a suite can test the war
  -- map without playing three missions to reach it. The marker is written
  -- where the cart is PACKED, which is somewhere a harness controls --
  -- unlike a host flag, which the cart cannot see. (`opengarden` is the
  -- same idea and had been dead since it was added: build.sh wrote it and
  -- nothing ever read it, so --open silently packed an ordinary cart.)
  -- WHICH LEVELS HAVE BEEN BEATEN (plan 06). Loaded before anything can
  -- ask, and from its own file -- see sim/progress.lua for why it is not
  -- part of the colony blob.
  progress.load()

  -- A gate cart packed with `startlevel` must boot STRAIGHT into that
  -- board: a level-select screen in front of it would swallow the first
  -- inputs of every suite that packs its own fixture.
  startLevelForced = false
  if love.filesystem.getInfo then
    if love.filesystem.getInfo("startlevel") then
      local want = (love.filesystem.read("startlevel") or ""):gsub("%s+", "")
      if want ~= "" then levelId = want; startLevelForced = true end
    elseif love.filesystem.getInfo("opengarden") then
      levelId = nil          -- nil selects the generated field
    end
  end
  S = sim.new(seed, levelId)

  if blob then
    local ok, msg = save.deserialize(S, blob)
    if ok then
      print("@load " .. msg)
    else
      print("@load REJECTED " .. tostring(msg) .. " (starting fresh)")
      S = sim.new(math.floor(love.math.random() * 2147483000) + 1,
                  "gather")
    end
  end

  -- Start looking at home.
  local home = S.world.node[S.world.homeId]
  if home then vp.centreOn(home.x, home.y) end

  audio.init()
  probe.init(S)
  booted = true

  -- THE LEVEL SELECT (plan 06), after the world is built, never instead
  -- of building one. The screen is drawn OVER a live colony rather than
  -- replacing it, so dismissing it always lands somewhere playable --
  -- there is no state in which the player is looking at a menu with no
  -- game behind it.
  --
  -- Skipped entirely on a true first boot (nothing beaten, nothing to
  -- continue): one playable level and no decision to make.
  if not startLevelForced and levelsel.shouldShow() then
    levelsel.build()
    levelsel.open = true
  end
end

-- Rebuild the world for a level, between frames. Shared by the level
-- select and the celebration's "next level" -- both want exactly this,
-- and doing it in two places is how one of them ends up forgetting to
-- reset the intents or re-init the probe.
local function startLevel(levelId, keepSave)
  S = sim.new(math.floor(love.math.random() * 2147483000) + 1, levelId)
  if keepSave then
    local blob = save.read()
    if blob then
      local ok = save.deserialize(S, blob)
      if not ok then S = sim.new(math.floor(love.math.random() * 2147483000) + 1, levelId) end
    end
  end
  local home = S.world.node[S.world.homeId]
  if home then vp.centreOn(home.x, home.y) end
  intents.reset()
  probe.init(S)
  print("@level started " .. tostring(levelId))
end

function love.update()
  if testMode or not booted then return end

  -- ADVANCE THE CAMPAIGN, between frames.
  --
  -- The menu (and the START prompt on a finished level) can only ASK for
  -- this: rebuilding the world mid-frame would strand every ant currently
  -- walking an edge. It is done here, before anything reads the world.
  --
  -- This was dead for the whole campaign's life -- menu.wantNextLevel was
  -- set and nothing ever consumed it, so "next field" silently did
  -- nothing and every level after the first was unreachable in play.
  if menu.wantNextLevel then
    menu.wantNextLevel = false
    local nextId = S.nextLevelId
    if nextId then startLevel(nextId) end
  end

  -- PLAN 06: the same rebuild, asked for by the celebration dialog or by
  -- the level select. Both are consumed here, between frames, for the
  -- reason above -- rebuilding mid-frame strands every ant on an edge.
  if celebrate.wantNext then
    celebrate.wantNext = false
    local nextId = S.nextLevelId
    if nextId then startLevel(nextId) end
  end
  if levelsel.wantLevel then
    local id = levelsel.wantLevel
    levelsel.wantLevel = nil
    startLevel(id)
  end
  if levelsel.wantContinue then
    levelsel.wantContinue = false
    -- Resume the autosaved colony exactly as an ordinary boot does. The
    -- blob names its own level (save.lua's `level` line means the CURRENT
    -- board again since plan 06), so this rebuilds that board and
    -- overlays the saved state onto it.
    local blob = save.read()
    local lv = blob and save.peekLevel(blob)
    if lv then startLevel(lv, true) end
  end

  -- THE WIN, ONCE (plan 06). `levelJustDone` is set on the rising edge in
  -- sim.update; consuming it here means the dialog fires exactly once per
  -- completion rather than every frame the level stays finished.
  if S.levelJustDone then
    S.levelJustDone = false
    -- Seeded from the sim's own clock so a deterministic replay shows the
    -- same confetti -- see ui/celebrate.lua's note.
    celebrate.show(vp, S.level and S.level.name or "",
                   math.floor((S.time or 0) * 1000) + 7919)
  end
  celebrate.update(DT)

  -- So START can mean "next field" on a finished level (see intents).
  intents.levelDone = S.levelDone and S.nextLevelId ~= nil
  local list = intents.poll(S.world, vp, S.agents)
  for i = 1, #list do
    local it = list[i]
    if it.kind == "debug" then
      probe.command(S, it.what)
    elseif it.kind == "pan" then
      vp.moveCamera(it.dx, it.dy)
      vp.clampToWorld(S.world)
    elseif it.kind == "zoom" then
      -- THREE SHAPES, ONE INTENT. Every input that changes the scale
      -- arrives here so the clamp and the anchor cannot be forgotten by
      -- whichever one is added next:
      --   {reset}          R3 / the view-reset button
      --   {step}           pad shoulders: the fixed rungs
      --   {f, sx, sy}      pinch and wheel: continuous, anchored
      if it.reset then
        vp.cam.zoom = vp.ZOOM_DEFAULT
        local n = intents.cursor.node and W.site(S.world, intents.cursor.node)
        if n then vp.centreOn(n.x, n.y) end
      elseif it.step then
        -- Anchored at the screen centre, which for a step IS the natural
        -- anchor: the pad has no pointer to zoom toward.
        vp.zoomStepAt(vp.w * 0.5, vp.h * 0.5, it.step)
      elseif it.f then
        vp.zoomAt(it.sx or vp.w * 0.5, it.sy or vp.h * 0.5, it.f)
      end
      vp.clampToWorld(S.world)
    elseif it.kind == "select" then
      probe.noteCursor(it)
    else
      local ok = sim.apply(S, it)
      probe.noteIntent(it, ok)
      audio.onIntent(it.kind, ok)
    end
  end

  -- THE CAMERA FOLLOWS THE CURSOR when it would otherwise walk off screen,
  -- but ONLY FOR A MOMENT AFTER THE CURSOR ACTUALLY MOVES.
  --
  -- That window is the whole of the loose coupling this camera is built on
  -- (the Civ VI rule): moving the cursor recalls the view, and moving the
  -- VIEW is never undone. Left running continuously, the nudge fought every
  -- manual camera control -- suspending it mid-gesture was not enough,
  -- because the instant a pinch ended it dragged the view ~6 units a frame
  -- back toward the off-screen cursor and quietly threw away the anchored
  -- zoom the player had just performed. A camera that creeps back to where
  -- it was is a camera the player cannot aim.
  --
  -- 45 frames is a little longer than the 10%-per-frame ease takes to
  -- converge, so a cursor hop still glides rather than snapping.
  if intents.cursor.node ~= lastCursor then
    lastCursor = intents.cursor.node
    followFrames = 45
  end
  if followFrames > 0 then followFrames = followFrames - 1 end

  if intents.cursor.node and not intents.camHeld and followFrames > 0 then
    local n = S.world.node[intents.cursor.node]
    if n then
      local sx, sy = vp.worldToScreen(n.x, n.y)
      local mx, my = vp.w * 0.24, vp.h * 0.24
      local sc = vp.worldScale()
      local dx, dy = 0, 0
      if sx < mx then dx = (sx - mx) / sc
      elseif sx > vp.w - mx then dx = (sx - (vp.w - mx)) / sc end
      if sy < my then dy = (sy - my) / sc
      elseif sy > vp.h - my then dy = (sy - (vp.h - my)) / sc end
      if dx ~= 0 or dy ~= 0 then vp.moveCamera(dx * 0.10, dy * 0.10) end
    end
  end

  sim.update(S, DT)
  audio.update(S, DT)

  -- Autosave every half minute of play: there is one colony and nothing
  -- to lose by walking away.
  S._saveTimer = (S._saveTimer or 0) + DT
  if S._saveTimer > 30 then
    S._saveTimer = 0
    save.write(S)
  end

  probe.update(S, DT)
  probe.slots(intents)
end

function love.draw()
  if testMode then
    return
  end
  if not booted then return end

  local render = require("render.init")
  render.draw(sim.snapshot(S), vp, intents)
  -- OVER the world and the HUD, under the developer overlay: these are
  -- the two screens that are meant to interrupt.
  celebrate.draw(vp)
  levelsel.draw(vp)
  probe.draw(S, vp, intents)
end

function love.mousepressed() end
