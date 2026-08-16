-- minimap.lua - the whole world, small, in a corner.
--
-- A World-of-Warcraft-shaped minimap: a fixed panel showing the entire
-- known map at once, with a rectangle marking what the main view is
-- currently looking at. Zoom and pan move that rectangle; they never
-- change the minimap itself, which is the property that makes it useful
-- as an anchor -- the small map is the stable thing you navigate by.
--
-- It earns its space because this is a game about TERRITORY. The main
-- view shows one neighbourhood; the question "where is my empire weak"
-- is about the whole board, and without an overview the player has to
-- pan around to reconstruct something the game already knows.

local M = {}

-- Same three readings as the map overlay, so a node means the same thing
-- here as it does out there.
local COL = {
  you     = { 0.45, 0.95, 0.55 },
  them    = { 0.95, 0.35, 0.30 },
  open    = { 0.92, 0.86, 0.55 },
  food    = { 0.60, 0.78, 0.92 },
}

-- World bounds of everything DISCOVERED, so the minimap grows with what
-- the player knows rather than revealing the map's true extent (which
-- would leak where the unexplored ground is -- the exact information
-- exploration is supposed to cost something).
local function bounds(world)
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  local any = false
  for i = 1, #world.nodes do
    local n = world.nodes[i]
    if n.discovered then
      any = true
      if n.x < x0 then x0 = n.x end
      if n.y < y0 then y0 = n.y end
      if n.x > x1 then x1 = n.x end
      if n.y > y1 then y1 = n.y end
    end
  end
  if not any then return nil end
  -- A margin so nodes never sit exactly on the frame, and a minimum span
  -- so a single known node does not divide by zero.
  local pad = 260
  x0, y0, x1, y1 = x0 - pad, y0 - pad, x1 + pad, y1 + pad
  if x1 - x0 < 1 then x1 = x0 + 1 end
  if y1 - y0 < 1 then y1 = y0 + 1 end
  return x0, y0, x1, y1
end

-- Top-right, BELOW the season dial (y 28..120) and the pause button
-- (y 208..282), which already own that corner. Stacking rather than
-- overlapping: an overview you cannot see under a button is not an
-- overview, and the pause button being unreachable was already a bug
-- once in this project.
function M.rect(vp)
  local s = vp.u(250)
  local x, y = vp.w - s - vp.u(28), vp.u(310)
  return x, y, s, s
end

function M.draw(snap, vp)
  local world = snap.world
  local bx0, by0, bx1, by1 = bounds(world)
  if not bx0 then return end

  local g = love.graphics
  local px, py, pw, ph = M.rect(vp)

  -- ASPECT-CORRECT. Fitting a non-square world into a square panel by
  -- stretching each axis independently would put nodes at the wrong
  -- relative angles, and an overview that lies about direction is worse
  -- than none: the player steers by it.
  local wsx = pw / (bx1 - bx0)
  local wsy = ph / (by1 - by0)
  local ws = math.min(wsx, wsy)
  local ox = px + (pw - (bx1 - bx0) * ws) * 0.5
  local oy = py + (ph - (by1 - by0) * ws) * 0.5
  local function toMap(wx, wy)
    return ox + (wx - bx0) * ws, oy + (wy - by0) * ws
  end

  g.setColor(0.04, 0.06, 0.05, 0.72)
  g.rectangle("fill", px, py, pw, ph, vp.u(10))

  -- Edges first, so nodes sit on top of their connections.
  g.setColor(0.35, 0.45, 0.35, 0.5)
  g.setLineWidth(math.max(1, vp.u(2)))
  for i = 1, #world.edges do
    local e = world.edges[i]
    local a, b = world.node[e.a], world.node[e.b]
    if a.discovered and b.discovered then
      local ax, ay = toMap(a.x, a.y)
      local bxp, byp = toMap(b.x, b.y)
      g.line(ax, ay, bxp, byp)
    end
  end
  g.setLineWidth(1)

  for i = 1, #world.nodes do
    local n = world.nodes[i]
    if n.discovered then
      local x, y = toMap(n.x, n.y)
      -- SAME FOG AS THE MAP: a mound you have never stood on shows as
      -- unclaimed here whatever is really on it. The minimap is the one
      -- place a player looks to read the whole board at a glance, so a
      -- coloured dot for an enemy colony they have never visited would
      -- hand back exactly the information the fog is withholding.
      local known = n.held or n.owner == "you"
      local key = (not known) and (n.colonisable and "open" or "food")
               or (n.owner == "you") and "you"
               or n.owner and "them"
               or (n.colonisable and "open" or "food")
      local c = COL[key]
      -- The nest is the anchor and reads bigger; everything else is one
      -- size, because a minimap that encodes magnitude in radius is
      -- unreadable at this scale.
      local r = (n.kind == "nest") and vp.u(7) or vp.u(5)
      g.setColor(c[1], c[2], c[3], key == "food" and 0.7 or 0.95)
      -- Discs as fans: circle() is viewport-relative on this engine (see
      -- NOTES.md) and lands in the wrong place after a target pass.
      local pxx, pyy
      for k = 0, 10 do
        local th = k / 10 * 6.28318
        local qx, qy = x + math.cos(th) * r, y + math.sin(th) * r
        if pxx then g.polygon("fill", x, y, pxx, pyy, qx, qy) end
        pxx, pyy = qx, qy
      end
    end
  end

  -- THE VIEWPORT RECTANGLE: what the main view is looking at right now.
  -- This is the whole reason the panel is navigable rather than
  -- decorative, and it is why zoom does not need to change the minimap --
  -- zooming just makes this box smaller.
  local vx0, vy0, vx1, vy1 = vp.worldBounds()
  local rx0, ry0 = toMap(vx0, vy0)
  local rx1, ry1 = toMap(vx1, vy1)
  -- Clamp to the panel so a view sitting off the known map still shows an
  -- edge-hugging box rather than drawing outside the frame.
  rx0 = math.max(px, math.min(px + pw, rx0))
  rx1 = math.max(px, math.min(px + pw, rx1))
  ry0 = math.max(py, math.min(py + ph, ry0))
  ry1 = math.max(py, math.min(py + ph, ry1))
  g.setColor(0.95, 0.95, 0.88, 0.75)
  g.setLineWidth(math.max(1, vp.u(2)))
  g.rectangle("line", rx0, ry0, rx1 - rx0, ry1 - ry0)
  g.setLineWidth(1)

  -- Frame last, over the contents.
  g.setColor(0.55, 0.65, 0.55, 0.45)
  g.setLineWidth(math.max(2, vp.u(3)))
  g.rectangle("line", px, py, pw, ph, vp.u(10))
  g.setLineWidth(1)
end

return M
