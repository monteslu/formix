-- celebrate.lua - a level ending should feel like winning.
--
-- Plan 06, Luis 2026-08-19: "when a level is complete it should be more
-- apparent. maybe a cool dialog and confetti."
--
-- Before this, finishing a level swapped one line of small HUD text
-- ("Done. Press START for the next field.") and nothing else -- a whisper
-- at the top of the screen, easy to play straight past without noticing
-- the level had been won at all.
--
-- Two rows, both devices: NEXT LEVEL (default focus) and KEEP PLAYING.
-- The dialog does NOT pause the sim -- menu.lua's own rule, nothing in
-- this game is urgent, and the colony carrying on underneath is part of
-- what the game is -- so "keep playing" is a dismissal, not an unpause.

local fonts = require("ui.fonts")

local M = {}

M.open = false
M.index = 1
M.wantNext = false
M.wantRetry = false
M.wantMenu = false
M.lost = false
M.levelName = nil

-- CONFETTI. Presentation only: spawned from the render clock, read by
-- nothing in the sim, exactly like the spider's leg sway (plan 05, 6b)
-- and for the same reason -- it is allowed to be frame-timed because no
-- gate measures it as state.
--
-- Deterministic per burst: the seed is fixed when the burst starts, so a
-- replayed capture at the same frame shows the same flakes and the pixel
-- assertion in test-progress is stable.
local flakes = {}
local burstT = 0
local BURST_LIFE = 2.6

-- The side palette plus gold. Open question in the plan (rainbow vs
-- side+gold); built as side+gold, which keeps the celebration in the
-- game's own colours rather than importing a party from somewhere else.
local COLS = {
  { 0.55, 0.95, 0.62 },   -- your green
  { 0.96, 0.84, 0.44 },   -- food amber
  { 0.98, 0.85, 0.30 },   -- crown gold
  { 0.72, 0.94, 0.98 },   -- mission pale blue
  { 0.94, 0.92, 0.86 },   -- bone
}

-- A tiny deterministic PRNG, so the burst does not touch love.math.random
-- (which the sim's determinism rules keep clear of) and repeats exactly
-- for a given seed.
local function lcg(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function()
    s = (s * 16807) % 2147483647
    return s / 2147483647
  end
end

function M.burst(vp, seed)
  flakes = {}
  burstT = 0
  local rnd = lcg(seed or 12345)
  local n = 120
  for i = 1, n do
    -- Spawned across the top of the card's band, falling with a sway.
    flakes[i] = {
      x = vp.w * (0.18 + rnd() * 0.64),
      y = vp.h * (0.16 + rnd() * 0.10),
      vx = (rnd() - 0.5) * 90,
      vy = 60 + rnd() * 190,
      spin = (rnd() - 0.5) * 9,
      rot = rnd() * 6.28318,
      size = vp.u(7 + rnd() * 9),
      swayA = 18 + rnd() * 42,
      swayF = 1.6 + rnd() * 3.2,
      phase = rnd() * 6.28318,
      col = COLS[1 + math.floor(rnd() * #COLS)],
    }
  end
end

-- DEFEAT USES THIS SAME CARD (Luis, 2026-08-20: "i lost my queens and all
-- ants ... game didnt end in a loss"). sim.checkDeath has always latched
-- `gameOver` for the player's side, and until now NOTHING in app/ read the
-- flag -- the sim knew the run was over and the game never said so, so a
-- dead colony just kept rendering an empty garden.
--
-- One card, two moods, rather than a second dialog: the difference is the
-- word, the colour and whether confetti falls. A separate loss screen
-- would have been a second layout to keep in step with this one, which is
-- the drift this file's own history warns about.
function M.show(vp, levelName, seed, lost)
  M.open = true
  M.index = 1
  M.levelName = levelName
  M.lost = lost or false
  M.wantNext = false
  -- No confetti for a defeat. `burst` is what puts flakes in the air, so
  -- simply not calling it leaves the card on a bare scrim.
  if not M.lost then M.burst(vp, seed) end
end

function M.update(dt)
  if burstT < BURST_LIFE then
    burstT = burstT + dt
    for i = 1, #flakes do
      local f = flakes[i]
      f.phase = f.phase + f.swayF * dt
      f.x = f.x + (f.vx + math.sin(f.phase) * f.swayA) * dt
      f.y = f.y + f.vy * dt
      f.rot = f.rot + f.spin * dt
    end
  end
end

local WIN_ROWS = {
  { key = "next", label = "Next level" },
  { key = "stay", label = "Keep playing" },
}
-- A LOST RUN HAS NO "next level" AND NOTHING TO KEEP PLAYING. The colony
-- is gone; the only honest options are to try this field again or step
-- back out to the garden. `retry` is handled in main.lua, which owns
-- level loading -- this file only names the choice.
local LOSE_ROWS = {
  { key = "retry", label = "Try this field again" },
  { key = "menu",  label = "Back to the garden" },
}
local function rows() return M.lost and LOSE_ROWS or WIN_ROWS end

function M.handle(kind)
  if not M.open then return false end
  local R = rows()
  if kind == "up" then
    M.index = ((M.index - 2) % #R) + 1
    return true
  elseif kind == "down" then
    M.index = (M.index % #R) + 1
    return true
  elseif kind == "confirm" then
    local key = R[M.index].key
    if key == "next"  then M.wantNext  = true end
    if key == "retry" then M.wantRetry = true end
    if key == "menu"  then M.wantMenu  = true end
    M.open = false
    return true
  elseif kind == "cancel" then
    -- B / START dismiss without advancing. START must NOT silently skip
    -- to the next level here: it used to mean exactly that on a finished
    -- level (intents.levelDone), and a button that advanced the world
    -- while a dialog offering that choice is on screen would be making
    -- the choice for the player.
    M.open = false
    return true
  end
  return false
end

local function layout(vp)
  local w = vp.u(720)
  -- ROW PITCH FOLLOWS THE ROW FONT. 84 was sized for 32px rows; the type
  -- scale pass took those to 26, and a pitch that does not follow leaves
  -- the bottom-anchored row block reaching UP into the fixed-position
  -- title -- which is exactly what happened: "Next level" printed on top
  -- of "Complete". Rows are laid out from the card's BOTTOM and the title
  -- from its TOP, so the two only stay apart if the card is tall enough
  -- for both -- see the arithmetic in the layout note below.
  local rowH = vp.u(62)
  local h = vp.u(280)
  local x = (vp.w - w) * 0.5
  local y = (vp.h - h) * 0.5
  return x, y, w, h, rowH
end

function M.hitRow(vp, sx, sy)
  if not M.open then return nil end
  local x, y, w, h, rowH = layout(vp)
  local ry = y + h - rowH * #rows() - vp.u(18)
  if sx < x + vp.u(30) or sx > x + w - vp.u(30) then return nil end
  for i = 1, #rows() do
    local yy = ry + (i - 1) * rowH
    if sy >= yy and sy < yy + rowH then return i end
  end
  return nil
end

-- Mouse: a click on a row picks it; a click ANYWHERE ELSE is "keep
-- playing", which is the forgiving reading of a stray click on a dialog
-- that is celebrating rather than asking something important.
function M.click(vp, sx, sy)
  if not M.open then return false end
  local i = M.hitRow(vp, sx, sy)
  if i then
    M.index = i
    return M.handle("confirm")
  end
  M.open = false
  return true
end

-- The flakes, drawn wherever the caller wants them in the layer order.
local function drawFlakes(g)
  if burstT >= BURST_LIFE then return end
  local fade = 1 - (burstT / BURST_LIFE)
  for i = 1, #flakes do
    local f = flakes[i]
    local c, s = math.cos(f.rot), math.sin(f.rot)
    local hw, hh = f.size * 0.5, f.size * 0.34
    g.setColor(f.col[1], f.col[2], f.col[3], 0.95 * fade)
    -- A flat rectangle flake, rotated: four points, always convex (the
    -- engine refuses a concave fill -- see render/ants.lua's note).
    g.polygon("fill",
      f.x + (-hw * c - -hh * s), f.y + (-hw * s + -hh * c),
      f.x + ( hw * c - -hh * s), f.y + ( hw * s + -hh * c),
      f.x + ( hw * c -  hh * s), f.y + ( hw * s +  hh * c),
      f.x + (-hw * c -  hh * s), f.y + (-hw * s +  hh * c))
  end
end

function M.draw(vp)
  local g = love.graphics

  -- CONFETTI OUTLIVES THE DIALOG, briefly: dismissing the card should not
  -- snap the flakes out of the air mid-fall. With the card closed they
  -- are the only thing left to draw, so they go here; with it open they
  -- are drawn again ON TOP of the scrim further down, or the scrim would
  -- bury the celebration it is supposed to be framing.
  if not M.open then
    drawFlakes(g)
    return
  end

  -- A SCRIM, so the card reads as an object in front of the garden rather
  -- than text lying on it. Lighter than the pause menu's 0.88 (this is a
  -- celebration, and the colony carrying on underneath is part of the
  -- reward) but enough to stop a bright trail running through "Complete".
  g.setColor(0.02, 0.03, 0.04, 0.55)
  g.rectangle("fill", 0, 0, vp.w, vp.h)
  -- Over the scrim, under the card: the flakes fall in FRONT of the dimmed
  -- garden and BEHIND the thing that is being celebrated.
  drawFlakes(g)

  local x, y, w, h, rowH = layout(vp)
  local fBig = fonts.get(vp, 38)
  local fName = fonts.get(vp, 26)
  local fRow = fonts.get(vp, 26)

  -- The card. Same construction as menu.draw's panel: one visual system,
  -- not two.
  g.setColor(0.06, 0.08, 0.07, 0.94)
  g.rectangle("fill", x, y, w, h, vp.u(18))
  -- The rim carries the mood: green for a win, a dull ember for a loss.
  if M.lost then g.setColor(0.92, 0.44, 0.34, 0.55)
  else           g.setColor(0.55, 0.95, 0.62, 0.55) end
  g.setLineWidth(math.max(2, vp.u(4)))
  g.rectangle("line", x, y, w, h, vp.u(18))
  g.setLineWidth(1)

  g.setFont(fName)
  g.setColor(0.74, 0.86, 0.72, 0.9)
  local nm = M.levelName or ""
  g.print(nm, x + (w - fName:getWidth(nm)) * 0.5, y + vp.u(26))

  g.setFont(fBig)
  if M.lost then g.setColor(0.96, 0.52, 0.42, 0.98)
  else           g.setColor(0.60, 0.98, 0.68, 0.98) end
  -- "The colony is gone" rather than "Defeat": the sim's loss condition is
  -- literally no ants, no brood and no fed queen, so the word says what
  -- actually happened on the board.
  local done = M.lost and "The colony is gone" or "Complete"
  g.print(done, x + (w - fBig:getWidth(done)) * 0.5, y + vp.u(66))

  local ry = y + h - rowH * #rows() - vp.u(18)
  for i, row in ipairs(rows()) do
    local yy = ry + (i - 1) * rowH
    local focused = (i == M.index)
    if focused then
      -- The focus chip follows the mood too. A GREEN selected row under
      -- "The colony is gone" reads as a win at a glance, which is exactly
      -- the wrong first impression for the one screen that has to land.
      if M.lost then g.setColor(0.62, 0.28, 0.22, 0.34)
      else           g.setColor(0.35, 0.72, 0.42, 0.30) end
      g.rectangle("fill", x + vp.u(30), yy, w - vp.u(60), rowH - vp.u(12),
                  vp.u(10))
      if M.lost then g.setColor(0.94, 0.50, 0.40, 0.8)
      else           g.setColor(0.55, 0.95, 0.62, 0.8) end
      g.setLineWidth(math.max(2, vp.u(3)))
      g.rectangle("line", x + vp.u(30), yy, w - vp.u(60), rowH - vp.u(12),
                  vp.u(10))
      g.setLineWidth(1)
    end
    g.setFont(fRow)
    g.setColor(0.94, 0.92, 0.86, focused and 1 or 0.72)
    g.print(row.label, x + (w - fRow:getWidth(row.label)) * 0.5,
            yy + vp.u(18))
  end
end

return M
