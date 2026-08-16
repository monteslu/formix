-- cursor.lua - the pad's pointer, and the game's whole tutorial.
--
-- There are no tutorial popups (docs/DEVPLAN.md M7: the game must teach by
-- attraction). That puts the entire teaching burden on affordance, and this
-- is where most of it lives:
--
--   * A ring on the node the cursor is over says "this is a thing".
--   * A second, brighter ring on a SELECTED node says "you have picked it
--     up", and a line from it to the cursor says "you are about to connect
--     these" -- which is the whole game in one gesture.
--   * A hint under the cursor names the one button that does the next
--     thing, and only while it is genuinely the next thing.
--
-- The hints fade out permanently once the player has done each verb a few
-- times. A game that keeps explaining itself after you know how to play is
-- nagging, and nagging is the opposite of this game's whole promise.

local fonts = require("ui.fonts")

local M = {}

-- How many times a verb must be used before its hint stops appearing.
local LEARNED = 3
local counts = { link = 0, danger = 0, caste = 0 }

function M.noteVerb(kind)
  if counts[kind] then counts[kind] = counts[kind] + 1 end
end

-- A verb is "learned" either because the player has done it enough times or
-- because they turned hints off, which is the same statement made
-- explicitly. Routing both through one predicate means the off switch
-- cannot miss a hint added later.
function M.learned(kind)
  if not require("ui.menu").settings.hints then return true end
  return (counts[kind] or 0) >= LEARNED
end

-- Restored from the save so the game does not re-teach a returning player.
function M.setCounts(t)
  for k, v in pairs(t or {}) do counts[k] = v end
end
function M.getCounts() return counts end

-- HOW BIG THE THING ACTUALLY LOOKS. A ring drawn at a flat multiple of
-- node.radius floats off the plant it is meant to be pointing at: a
-- flower's petals only reach ~1.0r while the ring was drawn at 1.34r, and
-- a nest's rings stop at 1.02r, so the highlight read as a circle sitting
-- near a node rather than ON it. Each kind reports its own drawn extent and
-- the ring sits just outside THAT.
-- Every kind currently tops out at about one radius: a flower's petals
-- reach 0.72-1.02r, a nest's outermost ring 1.02r. One number, named, so a
-- future node type that draws bigger has an obvious place to say so.
local VISUAL_EXTENT = 1.02
local function visualR(n) return n.radius * VISUAL_EXTENT end

-- RINGS ARE BUILT FROM LINE SEGMENTS, never circle()/arc().
--
-- docs/NOTES.md already records that the engine evaluates circle("fill")
-- per fragment from gl_FragCoord, which is viewport-relative -- so after a
-- render-target pass it lands somewhere else entirely. The stroked forms
-- have exactly the same flaw, which is why the selection ring sat well
-- off its node and the cursor arcs floated in empty grass while the
-- arithmetic behind them was correct. Explicit geometry is in the same
-- space as everything else this renderer draws.
local SEGS = 40
local function ring(x, y, r, w, col, a)
  local g = love.graphics
  g.setColor(col[1], col[2], col[3], a)
  g.setLineWidth(w)
  local px, py
  for i = 0, SEGS do
    local th = i / SEGS * 6.28318
    local qx, qy = x + math.cos(th) * r, y + math.sin(th) * r
    if px then g.line(px, py, qx, qy) end
    px, py = qx, qy
  end
  g.setLineWidth(1)
end

-- An open arc from a0 to a1, same reasoning as ring().
local function arcLine(x, y, r, a0, a1, w)
  local g = love.graphics
  g.setLineWidth(w)
  local steps = 10
  local px, py
  for i = 0, steps do
    local th = a0 + (a1 - a0) * (i / steps)
    local qx, qy = x + math.cos(th) * r, y + math.sin(th) * r
    if px then g.line(px, py, qx, qy) end
    px, py = qx, qy
  end
  g.setLineWidth(1)
end

-- SPLIT IN TWO, because the two halves live in different spaces.
--
-- drawRings runs INSIDE the scene pass (before the HDR composite), so the
-- rings rasterise in the same coordinates as the nodes they circle. draw()
-- runs after, in screen space, for the text hint -- bloomed type is
-- unreadable, which is why the UI was outside the composite to begin with.
-- Drawing the rings out there too was the bug: they landed ~115px off.
function M.drawRings(snap, vp, intents)
  local g = love.graphics
  local world = snap.world
  local s = vp.worldScale()
  local t = snap.time

  -- A pad player needs to see the cursor; a touch player does not (their
  -- finger IS the cursor). Showing a phantom cursor on a phone is clutter,
  -- so it appears only once the pad has actually been used.
  if not intents.padUsed then return end

  local cur = intents.cursor.node and world.node[intents.cursor.node]
  local sel = intents.selected and world.node[intents.selected]

  -- The pending connection, drawn first so the rings sit on top.
  if sel and cur and sel ~= cur then
    local ax, ay = vp.worldToScreen(sel.x, sel.y)
    local bx, by = vp.worldToScreen(cur.x, cur.y)
    local pulse = 0.55 + 0.45 * math.sin(t * 4)
    g.setColor(0.55, 0.95, 0.62, 0.30 + pulse * 0.25)
    g.setLineWidth(math.max(2, vp.u(5)))
    g.line(ax, ay, bx, by)
    g.setLineWidth(1)
  end

  if sel then
    local x, y = vp.worldToScreen(sel.x, sel.y)
    local r = visualR(sel) * s * 1.12
    local pulse = 0.5 + 0.5 * math.sin(t * 3.5)
    ring(x, y, r, math.max(3, vp.u(7)), { 0.60, 0.98, 0.68 }, 0.55 + pulse * 0.35)
  end

  if cur then
    local x, y = vp.worldToScreen(cur.x, cur.y)
    local r = visualR(cur) * s * 1.20
    -- Four short arcs rather than a full ring, so the cursor never reads as
    -- part of the world (every other ring in this game means something).
    g.setColor(0.95, 0.95, 0.88, 0.85)
    g.setLineWidth(math.max(2, vp.u(5)))
    for k = 0, 3 do
      local a0 = k * 1.5708 + 0.35 + math.sin(t * 1.2) * 0.05
      arcLine(x, y, r, a0, a0 + 0.55, math.max(2, vp.u(5)))
    end
    g.setLineWidth(1)

  end
end

-- The text half, drawn AFTER the composite in screen space so the type is
-- sharp rather than bloomed.
function M.draw(snap, vp, intents)
  local g = love.graphics
  local world = snap.world
  local s = vp.worldScale()
  if not intents.padUsed then return end
  local cur = intents.cursor.node and world.node[intents.cursor.node]
  if not cur then return end
  local sel = intents.selected and world.node[intents.selected]

  -- One line, naming one button, only while it is still news. The verbs it
  -- names are the 4X ones now: pick up a garrison, send it somewhere.
  -- THE HINT KNOWS WHAT THE PLAYER IS LOOKING AT, which is what turns it
  -- from a button legend into teaching. A first-time player does not need
  -- to be told a button exists; they need to be told that expansion is
  -- the game, and the moment to say so is when the cursor is sitting on
  -- ground they could take.
  local msg
  if sel and sel ~= cur then
    if not cur.colonisable then
      msg = "food -- work it from a base nearby"
    elseif cur.owner == "you" then
      if not M.learned("link") then msg = "A  reinforce" end
    elseif cur.owner then
      msg = "A  attack (" .. (cur.garrison or 0) .. " defenders)"
    elseif not M.learned("link") then
      msg = "A  send ants -- " .. (cur.takeCost or 0) .. " take it"
    end
  elseif cur.owner == "you" and (cur.garrison or 0) > 0 then
    if not M.learned("link") then
      msg = "A  pick up " .. cur.garrison .. " ants"
    end
  elseif not M.learned("danger") then
    msg = "X  warn away"
  end
  if not msg then return end

  local x, y = vp.worldToScreen(cur.x, cur.y)
  local r = visualR(cur) * s * 1.20
  local f = fonts.get(vp, 24)
  g.setFont(f)
  local w = f:getWidth(msg)
  local hx, hy = x - w * 0.5, y + r + vp.u(14)
  g.setColor(0, 0, 0, 0.45)
  g.rectangle("fill", hx - vp.u(10), hy - vp.u(4),
              w + vp.u(20), f:getHeight() + vp.u(8), vp.u(6))
  g.setColor(0.95, 0.95, 0.88, 0.92)
  g.print(msg, hx, hy)
end

return M
