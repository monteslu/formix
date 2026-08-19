-- levelselect.lua - pick a level at boot.
--
-- Plan 06, Luis 2026-08-19: "when a level is cleared, after a restart you
-- should be able to pick that level or start an uncompleted level."
--
-- Built out of the same parts ui/menu.lua already proves rather than a
-- new widget system: big rows, one focused index, a `handle(kind)` the
-- pad drives and a `hitRow(vp, x, y)` the mouse drives. Both devices
-- reach every row -- that is a requirement of this plan ("both mouse and
-- gamepad need to be able to advance to next level or select previous"),
-- not a nicety, and test-progress asserts each device separately.
--
-- NOT shown at all on a first boot: with nothing beaten and no colony to
-- resume there is exactly one thing a player can do, and making them
-- confirm it is a menu in front of a game that has not started yet.
-- main.lua checks `M.shouldShow()` for this.

local fonts = require("ui.fonts")
local campaign = require("sim.campaign")
local progress = require("sim.progress")

local M = {}

M.open = false
M.index = 1
-- Set when a row is confirmed; main.lua consumes it between frames for
-- the same reason menu.wantNextLevel is consumed there -- rebuilding the
-- world mid-frame strands every ant walking an edge.
M.wantLevel = nil
M.wantContinue = false

-- Rows are rebuilt whenever the screen opens, so a level beaten this
-- session shows as beaten without a restart.
local rows = {}

-- Does a resumable colony exist, and what level is it on? Read from the
-- save blob WITHOUT building a world -- peekLevel/peekSeed exist exactly
-- for this.
local function continuable()
  local save = require("sim.save")
  local blob = save.read()
  if not blob then return nil end
  local lv = save.peekLevel(blob)
  if not lv then return nil end
  local level = campaign.byId(lv)
  -- A save naming a gate fixture (a suite ran here) is not something to
  -- offer a player as "continue".
  if not level or not level.campaign then return nil end
  return lv, level
end

function M.build()
  rows = {}
  local contId, contLevel = continuable()
  if contId then
    rows[#rows + 1] = { key = "continue", label = "Continue",
                        sub = contLevel.name, levelId = contId }
  end
  local sel = campaign.selectable(progress.beaten)
  for i = 1, #sel do
    local e = sel[i]
    rows[#rows + 1] = {
      key = "level", levelId = e.level.id, label = e.level.name,
      sub = e.level.blurb, beaten = e.beaten, locked = e.locked,
    }
  end
  M.index = 1
  return rows
end

function M.rows() return rows end

-- SHOW IT WHEN THERE IS A CHOICE TO MAKE. Nothing beaten and nothing to
-- continue means one playable level and no decision -- boot straight in.
function M.shouldShow()
  local n = 0
  for _ in pairs(progress.beaten) do n = n + 1 end
  if n > 0 then return true end
  return continuable() ~= nil
end

local function firstSelectable(from, dir)
  -- Skip locked rows when moving: a cursor that can land on a row that
  -- refuses to confirm reads as a broken button.
  local n = #rows
  if n == 0 then return 1 end
  local i = from
  for _ = 1, n do
    i = ((i - 1 + dir) % n) + 1
    if not rows[i].locked then return i end
  end
  return from
end

function M.handle(kind)
  if not M.open then return false end
  if #rows == 0 then return false end
  if kind == "up" then
    M.index = firstSelectable(M.index, -1)
    return true
  elseif kind == "down" then
    M.index = firstSelectable(M.index, 1)
    return true
  elseif kind == "confirm" then
    local row = rows[M.index]
    if not row or row.locked then return true end
    if row.key == "continue" then
      M.wantContinue = true
    else
      M.wantLevel = row.levelId
    end
    M.open = false
    return true
  elseif kind == "cancel" then
    -- Cancel means "just play the obvious thing": continue if there is
    -- something to continue, else the frontier. It never leaves the
    -- player on a screen with no way forward.
    for i = 1, #rows do
      if rows[i].key == "continue" then M.wantContinue = true; M.open = false; return true end
    end
    for i = 1, #rows do
      if not rows[i].locked then M.wantLevel = rows[i].levelId; M.open = false; return true end
    end
    return true
  end
  return false
end

-- Geometry, shared by draw and hit-test so the two cannot drift (the same
-- single-source rule menu.pauseRect follows).
-- ROW HEIGHT HAS TO FIT WHAT IS IN A ROW. Each row draws a title AND a
-- blurb; at vp.u(96) with a 34/22 pair the blurb overflowed into the row
-- below and the focus highlight covered only the title. Measured on a
-- real capture (test/shots/manual-levelselect.png, before this fix):
-- the rows visibly ran into each other and the hint line fell outside
-- the card. 132 clears both lines with air between rows.
local function layout(vp)
  local w = vp.u(860)
  local rowH = vp.u(132)
  local x = (vp.w - w) * 0.5
  -- Centred on the ROWS, with the title band and the hint line accounted
  -- for so the card can be drawn around all three without guessing.
  local y0 = (vp.h - rowH * #rows) * 0.5 + vp.u(40)
  return x, y0, w, rowH
end

function M.hitRow(vp, sx, sy)
  if not M.open or #rows == 0 then return nil end
  local x, y0, w, rowH = layout(vp)
  if sx < x or sx > x + w then return nil end
  for i = 1, #rows do
    local y = y0 + (i - 1) * rowH
    if sy >= y and sy < y + rowH then return i end
  end
  return nil
end

-- Mouse click: focus the row AND confirm it, which is what a click means.
-- A locked row is focused-but-refused rather than silently ignored, so
-- the player sees what they hit.
function M.click(vp, sx, sy)
  local i = M.hitRow(vp, sx, sy)
  if not i then return false end
  M.index = i
  if rows[i].locked then return true end
  return M.handle("confirm")
end

-- A BEATEN MARK, drawn rather than glyphed: a filled leaf/check built out
-- of polygons, for the same reason menu.lua's gear is -- circle("fill")
-- is viewport-relative on this engine and lands wrong after a render
-- target pass, and a font glyph would need a font that has it.
local function beatenMark(g, cx, cy, r)
  g.setColor(0.55, 0.95, 0.62, 0.95)
  -- A check: two thick strokes as quads.
  local function stroke(x1, y1, x2, y2, w)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len == 0 then return end
    local px, py = -dy / len * w, dx / len * w
    g.polygon("fill", x1 + px, y1 + py, x2 + px, y2 + py,
                      x2 - px, y2 - py, x1 - px, y1 - py)
  end
  stroke(cx - r * 0.55, cy + r * 0.05, cx - r * 0.12, cy + r * 0.50, r * 0.16)
  stroke(cx - r * 0.12, cy + r * 0.50, cx + r * 0.58, cy - r * 0.45, r * 0.16)
end

function M.draw(vp)
  if not M.open then return end
  local g = love.graphics

  g.setColor(0.02, 0.03, 0.04, 0.92)
  g.rectangle("fill", 0, 0, vp.w, vp.h)

  local fTitle = fonts.get(vp, 34)
  local fRow = fonts.get(vp, 26)
  local fSub = fonts.get(vp, 19)
  local x, y0, w, rowH = layout(vp)

  -- The card wraps the title band, every row, AND the hint line -- the
  -- hint used to be drawn below a card that ended at the last row, so it
  -- floated on the world.
  local padX, padTop = vp.u(34), vp.u(120)
  local padBot = vp.u(76)
  local cardH = rowH * #rows + padTop + padBot
  g.setColor(0.06, 0.08, 0.07, 0.94)
  g.rectangle("fill", x - padX, y0 - padTop, w + padX * 2, cardH, vp.u(18))
  g.setColor(0.42, 0.62, 0.46, 0.35)
  g.setLineWidth(math.max(2, vp.u(3)))
  g.rectangle("line", x - padX, y0 - padTop, w + padX * 2, cardH, vp.u(18))
  g.setLineWidth(1)

  g.setFont(fTitle)
  g.setColor(0.92, 0.90, 0.84, 0.92)
  local title = "The garden"
  g.print(title, (vp.w - fTitle:getWidth(title)) * 0.5, y0 - vp.u(96))

  for i, row in ipairs(rows) do
    local y = y0 + (i - 1) * rowH
    local focused = (i == M.index)
    if focused and not row.locked then
      g.setColor(0.35, 0.72, 0.42, 0.28)
      g.rectangle("fill", x, y, w, rowH - vp.u(14), vp.u(10))
      g.setColor(0.55, 0.95, 0.62, 0.75)
      g.setLineWidth(math.max(2, vp.u(3)))
      g.rectangle("line", x, y, w, rowH - vp.u(14), vp.u(10))
      g.setLineWidth(1)
    elseif focused then
      g.setColor(0.40, 0.40, 0.40, 0.22)
      g.rectangle("fill", x, y, w, rowH - vp.u(14), vp.u(10))
    end

    local alpha = row.locked and 0.34 or (focused and 1 or 0.78)
    g.setFont(fRow)
    g.setColor(0.94, 0.92, 0.86, alpha)
    g.print(row.label, x + vp.u(96), y + vp.u(20))
    if row.sub then
      g.setFont(fSub)
      g.setColor(0.72, 0.86, 0.74, alpha * 0.8)
      g.print(row.sub, x + vp.u(96), y + vp.u(70))
    end

    if row.beaten then
      beatenMark(g, x + vp.u(50), y + vp.u(52), vp.u(24))
    elseif row.locked then
      -- A LOCK, as a plain bar-and-shackle in polygons. Dim, because its
      -- job is to explain why the row will not respond, not to draw the
      -- eye to the thing that cannot be done.
      g.setColor(0.60, 0.60, 0.58, 0.45)
      local cx, cy, r = x + vp.u(50), y + vp.u(52), vp.u(20)
      g.rectangle("fill", cx - r * 0.55, cy - r * 0.05, r * 1.1, r * 0.85,
                  r * 0.15)
      g.setLineWidth(math.max(2, vp.u(4)))
      g.setColor(0.60, 0.60, 0.58, 0.45)
      local n = 10
      local px, py
      for k = 0, n do
        local a = math.pi + (k / n) * math.pi
        local qx = cx + math.cos(a) * r * 0.36
        local qy = cy - r * 0.05 + math.sin(a) * r * 0.36
        if px then g.line(px, py, qx, qy) end
        px, py = qx, qy
      end
      g.setLineWidth(1)
    end
  end

  -- The controls line, because this screen is the first thing a returning
  -- player sees and both devices have to be discoverable from it.
  g.setFont(fSub)
  g.setColor(0.70, 0.74, 0.68, 0.7)
  local hint = "D-PAD / mouse to choose      A / click to play"
  g.print(hint, (vp.w - fSub:getWidth(hint)) * 0.5,
          y0 + rowH * #rows + vp.u(22))
end

return M
