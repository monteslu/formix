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
-- TWO SOUND SETTINGS, NOT ONE (Luis, 2026-08-20). Both 0..4, both
-- defaulting to "normal" -- the DEFAULT LOUDNESS of each layer is set in
-- audio/init.lua (M.musicVolume / M.sfxVolume at scalar 1.0), not here,
-- so this file stays a slider position and the mix stays in the mixer.
-- That is what lets "sound effects should be louder" be a one-number
-- change in audio/init.lua rather than a re-tune of every call site.
M.settings = {
  music = 3,            -- 0..4
  sfx = 3,              -- 0..4
  palette = 1,          -- 1 = natural, 2 = high contrast (colour-blind safe)
  hints = true,
}

-- The NEXT GARDEN row only exists once a garden is finished. Telling a
-- player "the next garden opens when you return" and then giving them no
-- way to go there is the worst of both: they have succeeded and the game
-- has stranded them.
-- CHOOSE A LEVEL is reachable from the pause menu (plan 06), not only at
-- boot. Two reasons it belongs here rather than being boot-only: romdev's
-- wasmcart host does not persist the save region across a cart load, so
-- boot-only would make the screen unreachable in any gate AND in any
-- playtest that starts fresh; and a player who wants to replay Gather
-- should not have to close the game to do it.
local ROWS_BASE = {
  { key = "levels", label = "Choose a level" },
  -- "Music" and "Sound effects" rather than "Sound" and "Effects": the
  -- pair has to be readable as two halves of the same thing from a couch,
  -- and "Sound" next to "Effects" leaves a player guessing which one the
  -- clanks are.
  { key = "music", label = "Music" },
  { key = "sfx", label = "Sound effects" },
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

-- THE SLIDER CURVE. "normal" (setting 3) is 1.0 -- the layer at the
-- volume it was actually tuned for -- and "loud" is a real boost above
-- it, not the only setting at which the mix is correct.
--
-- A plain `setting / 4` was the first cut and it is wrong in a way worth
-- recording: it makes the DEFAULT 0.75, so every layer in the game plays
-- at three quarters of its tuned volume unless the player finds the menu
-- and turns it up. The mix in audio/init.lua was settled by ear at full
-- strength; a scale whose default silently attenuates it means the ear
-- tuning and the shipped sound are different sounds. Under that curve
-- the sfx split did not even deliver what it was for -- a shot landed at
-- 0.8 x 0.75 = 0.60, QUIETER than the 0.68 the single master used to
-- give it, which is the opposite of the request.
--
-- One table, so the two sliders can never drift apart, and so the shape
-- is visible rather than being an arithmetic expression to decode.
local VOLUME_SCALE = { [0] = 0, 0.35, 0.65, 1.0, 1.25 }

-- What the music layer sits at when its slider says "normal". The old
-- single master was 0.85 and applied to EVERYTHING; keeping it for the
-- music alone is what leaves the tracks mixed as they were while letting
-- the effects come up.
local MUSIC_HEADROOM = 0.85

local function scalarFor(v)
  return VOLUME_SCALE[math.max(0, math.min(4, v or 3))] or 1.0
end

function M.musicScalar() return scalarFor(M.settings.music) end
function M.sfxScalar()   return scalarFor(M.settings.sfx) end

-- ONE PLACE THAT PUSHES SETTINGS INTO THE MIXER. Three call sites used to
-- each write `masterVolume = scalar * 0.85` by hand, which is three copies
-- of the same arithmetic and, with two sliders, would have been six.
--
-- The old expression baked 0.85 into every write; the headroom is now a
-- named constant above (MUSIC_HEADROOM) applied to ONE layer, so "normal"
-- means "this layer at the volume it was tuned for" rather than "every
-- layer at 0.85 of it".
function M.applyVolumes()
  local audio = require("audio.init")
  -- MUSIC KEEPS ITS HEADROOM, SFX DO NOT. That asymmetry IS the "sound
  -- effects should be louder than current default" request: at the same
  -- slider position a shot lands at its full call-site volume while a
  -- track sits under it, which is the balance an ambient game wants
  -- anyway (rule 1 of audio/init.lua: nothing is a notification, so the
  -- one-shots are already quiet by design and were being quietened
  -- again by the shared master).
  audio.musicVolume = M.musicScalar() * MUSIC_HEADROOM
  audio.sfxVolume = M.sfxScalar()
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
  if row.key == "music" or row.key == "sfx" then
    local v = s[row.key] + dir
    if wrap then v = v % 5
    else v = math.max(0, math.min(4, v)) end
    s[row.key] = v
    M.applyVolumes()
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
    elseif row.key == "levels" then
      -- Hand off to the level select, which owns its own rows and both
      -- devices' handling. Rebuilt on the way in so a level beaten this
      -- session shows as beaten without a restart.
      local levelsel = require("ui.levelselect")
      levelsel.build()
      levelsel.open = true
      M.open = false
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

-- THE PAUSE BUTTON. Top-right corner itself now -- it used to sit 180px
-- BELOW that corner, reserved for a season dial that this build does not
-- have (the comment describing it as "under the season dial" outlived the
-- dial by a long way, and the button just sat in empty space with nothing
-- above it). This ONE rect is still the single source for both drawing
-- and hit-testing so the two can never drift apart.
function M.pauseRect(vp)
  local x, y = vp.anchor("tr")
  local s = vp.u(74)
  return x - s, y, s, s
end

function M.hitPause(vp, sx, sy)
  if not vp then return false end
  local x, y, w, h = M.pauseRect(vp)
  return sx >= x and sx <= x + w and sy >= y and sy <= y + h
end

-- Drawn with the HUD (not with the menu), because it is what you press to
-- OPEN the menu and therefore must be visible while the menu is closed.
--
-- A GEAR, not two bars. Two vertical bars is the universal glyph for
-- "pause", but this button does not pause anything by itself -- it opens
-- the settings menu (volume, palette, hints), and pausing is one row
-- inside it. A gear is the honest icon for "options live here"; the old
-- glyph promised a different, more specific action than the button
-- actually performs.
--
-- Drawn as a ring of teeth (trapezoid wedges) around a hollow hub, all in
-- polygon fills for the same reason every other icon in this file avoids
-- `circle("fill")`: it is viewport-relative on this engine and lands in
-- the wrong place after a render-target pass (see the disc() note in
-- render/mounds.lua). A ring of straight-edged wedges needs no circle
-- primitive at all.
function M.drawPauseButton(vp)
  if M.open then return end
  local g = love.graphics
  local x, y, w, h = M.pauseRect(vp)
  g.setColor(0.05, 0.07, 0.06, 0.42)
  g.rectangle("fill", x, y, w, h, vp.u(12))

  local cx, cy = x + w * 0.5, y + h * 0.5
  local rOuter, rInner, rHub = w * 0.34, w * 0.24, w * 0.14
  local teeth = 8
  g.setColor(0.80, 0.86, 0.78, 0.55)
  -- Each tooth is a wedge: two points on the inner radius, two on the
  -- outer, at slightly different angles so the tooth has a flat outer
  -- face instead of coming to a point -- the silhouette a gear actually
  -- has, not a starburst.
  for i = 0, teeth - 1 do
    local a0 = (i / teeth) * 6.28318
    local a1 = a0 + (0.5 / teeth) * 6.28318
    local aMid0 = a0 - (0.12 / teeth) * 6.28318
    local aMid1 = a1 + (0.12 / teeth) * 6.28318
    g.polygon("fill",
      cx + math.cos(aMid0) * rInner, cy + math.sin(aMid0) * rInner,
      cx + math.cos(a0) * rOuter,    cy + math.sin(a0) * rOuter,
      cx + math.cos(a1) * rOuter,    cy + math.sin(a1) * rOuter,
      cx + math.cos(aMid1) * rInner, cy + math.sin(aMid1) * rInner)
  end
  -- The body between teeth, so the ring reads as one continuous gear
  -- rather than eight separate wedges with gaps at the inner radius.
  local px, py
  for k = 0, 24 do
    local a = k / 24 * 6.28318
    local qx, qy = cx + math.cos(a) * rInner, cy + math.sin(a) * rInner
    if px then g.polygon("fill", cx, cy, px, py, qx, qy) end
    px, py = qx, qy
  end
  -- The hollow hub, punched out in the background colour so the gear
  -- reads as a ring with a hole rather than a solid disc.
  g.setColor(0.05, 0.07, 0.06, 0.92)
  px, py = nil, nil
  for k = 0, 16 do
    local a = k / 16 * 6.28318
    local qx, qy = cx + math.cos(a) * rHub, cy + math.sin(a) * rHub
    if px then g.polygon("fill", cx, cy, px, py, qx, qy) end
    px, py = qx, qy
  end
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
  if row.key == "music" or row.key == "sfx" then
    return VOLUME_LABEL[s[row.key] + 1]
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

  local fTitle = fonts.get(vp, 30)
  local fRow = fonts.get(vp, 26)
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
-- FOUR FIELDS NOW, and the SFX one is appended rather than inserted so an
-- older three-field string still reads correctly: music takes the old
-- volume's place (a player who had turned the sound down was turning the
-- music down too, which is the closest honest reading of that number) and
-- sfx falls back to the default rather than to whatever they had set.
function M.serialize()
  local s = M.settings
  return string.format("%d %d %d %d", s.music, s.palette,
                       s.hints and 1 or 0, s.sfx)
end

function M.deserialize(text)
  local a, b, c = text:match("(%d+) (%d+) (%d+)")
  if not a then return false end
  M.settings.music = math.max(0, math.min(4, tonumber(a)))
  M.settings.palette = (tonumber(b) == 2) and 2 or 1
  M.settings.hints = tonumber(c) == 1
  -- The fourth field, absent in a pre-split save.
  local d = text:match("%d+ %d+ %d+ (%d+)")
  M.settings.sfx = d and math.max(0, math.min(4, tonumber(d))) or 3
  M.applyVolumes()
  return true
end

return M
