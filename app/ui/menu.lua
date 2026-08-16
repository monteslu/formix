-- menu.lua - pause and settings.
--
-- The smallest menu that covers what a player actually needs to change,
-- and nothing else. There is no save/load entry (there is one persistent
-- colony, saved automatically), no difficulty (the game has no fail state
-- to be difficult about), and no quit-to-title (there is no title).
--
-- Reachable identically from both devices: START on a pad, or the pause
-- corner on touch. Every row is a big target -- family law is that this is
-- read from a couch and poked with a thumb.

local fonts = require("ui.fonts")

local M = {}

M.open = false
M.index = 1

-- Settings live here and are read by the systems that care. They are part
-- of the save so they survive a session.
M.settings = {
  volume = 3,           -- 0..4
  palette = 1,          -- 1 = natural, 2 = high contrast (colour-blind safe)
  hints = true,
}

-- The NEXT GARDEN row only exists once a garden is finished. Telling a
-- player "the next garden opens when you return" and then giving them no
-- way to go there is the worst of both: they have succeeded and the game
-- has stranded them.
local ROWS_BASE = {
  { key = "volume", label = "Sound" },
  { key = "palette", label = "Colours" },
  { key = "hints", label = "Hints" },
  { key = "resume", label = "Back to the colony" },
}
local ROWS = ROWS_BASE

-- Called by the HUD/menu draw each frame so the row list matches the
-- state of play.
function M.setLevelDone(done)
  if done and #ROWS == #ROWS_BASE then
    ROWS = { { key = "next", label = "Next garden" } }
    for i = 1, #ROWS_BASE do ROWS[i + 1] = ROWS_BASE[i] end
    M.index = 1
  elseif not done and #ROWS > #ROWS_BASE then
    ROWS = ROWS_BASE
    M.index = math.min(M.index, #ROWS)
  end
end

local VOLUME_LABEL = { "off", "quiet", "low", "normal", "loud" }
local PALETTE_LABEL = { "natural", "high contrast" }

-- The palette choice is a real accessibility feature, not a skin: the
-- natural palette leans on green-vs-amber to distinguish a fed road from a
-- busy one, which is exactly the pair a red-green colour-blind player
-- cannot separate. High contrast re-keys those to brightness and blue.
function M.paletteIsHighContrast() return M.settings.palette == 2 end

function M.volumeScalar()
  return (M.settings.volume) / 4
end

-- dir = +1/-1 steps a value; wrap = true lets it roll over the end.
--
-- WRAPPING IS NOT A FLOURISH, it is the only way a touch player can turn
-- the sound DOWN. Touch has no left/right -- a tap is a single "next" --
-- so a volume that clamps at 4 is a volume that can never be reduced
-- again once raised. The pad still gets non-wrapping left/right, because
-- there a clamp is the familiar behaviour and nothing is unreachable.
local function adjust(row, dir, wrap)
  local s = M.settings
  if row.key == "volume" then
    local v = s.volume + dir
    if wrap then v = v % 5
    else v = math.max(0, math.min(4, v)) end
    s.volume = v
    require("audio.init").masterVolume = M.volumeScalar() * 0.85
  elseif row.key == "palette" then
    s.palette = (s.palette == 1) and 2 or 1
  elseif row.key == "hints" then
    s.hints = not s.hints
  end
end

-- Returns true if the menu consumed the input.
function M.handle(kind, arg)
  if not M.open then return false end
  if kind == "up" then
    M.index = ((M.index - 2) % #ROWS) + 1
    return true
  elseif kind == "down" then
    M.index = (M.index % #ROWS) + 1
    return true
  elseif kind == "left" then
    adjust(ROWS[M.index], -1); return true
  elseif kind == "right" then
    adjust(ROWS[M.index], 1); return true
  elseif kind == "confirm" then
    local row = ROWS[M.index]
    if row.key == "resume" then M.open = false
    elseif row.key == "next" then
      -- The cart cannot rebuild its world mid-frame safely (ants are
      -- walking edges that would vanish), so this asks main.lua to do it
      -- between frames.
      M.wantNextLevel = true
      M.open = false
    else adjust(row, 1, true) end          -- wraps: see adjust()
    return true
  elseif kind == "cancel" then
    M.open = false
    return true
  end
  return false
end

-- THE PAUSE BUTTON. Top-right, under the season dial and clear of
-- everything else: the first version was an invisible hotspot in the
-- bottom-right corner, which put it underneath the caste widget's bars --
-- so on a phone the corner either adjusted a caste or hit empty grass, and
-- the menu was simply unreachable by touch. An invisible affordance that
-- overlaps a visible one loses, every time. It is drawn now, and this ONE
-- rect is the single source for both drawing and hit-testing so the two can
-- never drift apart.
function M.pauseRect(vp)
  local x, y = vp.anchor("tr")
  local s = vp.u(74)
  return x - s, y + vp.u(180), s, s
end

function M.hitPause(vp, sx, sy)
  if not vp then return false end
  local x, y, w, h = M.pauseRect(vp)
  return sx >= x and sx <= x + w and sy >= y and sy <= y + h
end

-- Drawn with the HUD (not with the menu), because it is what you press to
-- OPEN the menu and therefore must be visible while the menu is closed.
function M.drawPauseButton(vp)
  if M.open then return end
  local g = love.graphics
  local x, y, w, h = M.pauseRect(vp)
  g.setColor(0.05, 0.07, 0.06, 0.42)
  g.rectangle("fill", x, y, w, h, vp.u(12))
  g.setColor(0.80, 0.86, 0.78, 0.55)
  -- Two bars: the universal pause glyph, and no text to translate.
  local bw, bh = w * 0.14, h * 0.42
  local cy = y + (h - bh) * 0.5
  g.rectangle("fill", x + w * 0.30 - bw * 0.5, cy, bw, bh, bw * 0.35)
  g.rectangle("fill", x + w * 0.70 - bw * 0.5, cy, bw, bh, bw * 0.35)
end

-- Touch: which row is under this point, if any.
function M.hitRow(vp, sx, sy)
  local w = vp.u(700)
  local rowH = vp.u(86)
  local x = (vp.w - w) * 0.5
  local y0 = (vp.h - rowH * #ROWS) * 0.5
  if sx < x or sx > x + w then return nil end
  for i = 1, #ROWS do
    local y = y0 + (i - 1) * rowH
    if sy >= y and sy < y + rowH then return i end
  end
  return nil
end

function M.valueText(row)
  local s = M.settings
  if row.key == "volume" then return VOLUME_LABEL[s.volume + 1]
  elseif row.key == "palette" then return PALETTE_LABEL[s.palette]
  elseif row.key == "hints" then return s.hints and "on" or "off"
  end
  return ""
end

function M.draw(vp)
  if not M.open then return end
  local g = love.graphics

  -- Dim the world rather than hiding it: the colony keeps working while
  -- the menu is open (nothing in this game is urgent), and seeing that is
  -- more reassuring than a black screen.
  -- 0.72 was not enough: the trails are additive and bright, so a road
  -- ran straight through the word "Sound" and the nest sat behind the
  -- focused row. The scrim has to beat the glow it is covering.
  g.setColor(0.02, 0.03, 0.04, 0.88)
  g.rectangle("fill", 0, 0, vp.w, vp.h)

  local fTitle = fonts.get(vp, 40)
  local fRow = fonts.get(vp, 34)
  local w = vp.u(700)
  local rowH = vp.u(86)
  local x = (vp.w - w) * 0.5
  local y0 = (vp.h - rowH * #ROWS) * 0.5

  -- A card behind the rows. Without it the labels float directly on the
  -- world and every row needs its own scrim to stay legible; one panel is
  -- cheaper and reads as an object you are holding rather than as text
  -- projected onto the garden.
  local padX, padTop = vp.u(34), vp.u(120)
  g.setColor(0.06, 0.08, 0.07, 0.92)
  g.rectangle("fill", x - padX, y0 - padTop,
              w + padX * 2, rowH * #ROWS + padTop + vp.u(28), vp.u(18))
  g.setColor(0.42, 0.62, 0.46, 0.35)
  g.setLineWidth(math.max(2, vp.u(3)))
  g.rectangle("line", x - padX, y0 - padTop,
              w + padX * 2, rowH * #ROWS + padTop + vp.u(28), vp.u(18))
  g.setLineWidth(1)

  g.setFont(fTitle)
  g.setColor(0.92, 0.90, 0.84, 0.9)
  local title = "Paused"
  g.print(title, (vp.w - fTitle:getWidth(title)) * 0.5, y0 - vp.u(90))

  for i, row in ipairs(ROWS) do
    local y = y0 + (i - 1) * rowH
    local focused = (i == M.index)
    if focused then
      g.setColor(0.35, 0.72, 0.42, 0.28)
      g.rectangle("fill", x, y, w, rowH - vp.u(8), vp.u(10))
      g.setColor(0.55, 0.95, 0.62, 0.75)
      g.setLineWidth(math.max(2, vp.u(3)))
      g.rectangle("line", x, y, w, rowH - vp.u(8), vp.u(10))
      g.setLineWidth(1)
    end
    g.setFont(fRow)
    g.setColor(0.94, 0.92, 0.86, focused and 1 or 0.72)
    g.print(row.label, x + vp.u(28), y + vp.u(18))
    local v = M.valueText(row)
    if v ~= "" then
      g.setColor(0.72, 0.92, 0.76, focused and 1 or 0.6)
      g.print(v, x + w - vp.u(28) - fRow:getWidth(v), y + vp.u(18))
    end
  end
end

-- Serialised into the save alongside the colony.
function M.serialize()
  local s = M.settings
  return string.format("%d %d %d", s.volume, s.palette, s.hints and 1 or 0)
end

function M.deserialize(text)
  local a, b, c = text:match("(%d+) (%d+) (%d+)")
  if not a then return false end
  M.settings.volume = math.max(0, math.min(4, tonumber(a)))
  M.settings.palette = (tonumber(b) == 2) and 2 or 1
  M.settings.hints = tonumber(c) == 1
  require("audio.init").masterVolume = M.volumeScalar() * 0.85
  return true
end

return M
