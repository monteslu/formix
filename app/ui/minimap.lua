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

-- Same readings as the map overlay, so a node means the same thing here
-- as it does out there.
--
-- IT GATES ON `seen`, NOT ON `discovered`. `discovered` belonged to the
-- old fog and nothing in the live sim has set it for a long time, so
-- every loop here was skipping every mound and the panel drew an empty
-- box in the corner of the screen -- a minimap of nothing, which is
-- exactly as useless as no minimap and takes up the same room. The fog
-- is still honoured: `seen` says the SHAPE of the field is never hidden,
-- and `held` below is what decides whether a dot admits who is on it.
local COL = {
  you     = { 0.45, 0.95, 0.55 },
  them    = { 0.95, 0.35, 0.30 },
  open    = { 0.92, 0.86, 0.55 },
  food    = { 0.60, 0.78, 0.92 },
  -- Somewhere with something to eat, once you have been there.
  forage  = { 0.90, 0.78, 0.36 },
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
    if n.seen then
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

-- BOTTOM-RIGHT, matching the mound/location panel's footprint in the
-- opposite corner (430x260 -- see ui/nodepanel.lua) rather than the old
-- fixed 250x250 square. Same size, same margin, mirrored: the two panels
-- read as a matched pair instead of one being an afterthought stuck under
-- wherever the pause button happened to be.
--
-- It moved out from under the pause button on purpose -- that spot was
-- only ever "below the season dial", and this build has no season dial
-- (the button itself has moved back up to the bare top-right corner; see
-- ui/menu.lua). Nothing about the minimap needs to live near the pause
-- button at all.
function M.rect(vp)
  local w, h = vp.u(430), vp.u(260)
  local x, y = vp.w - w - vp.u(28), vp.h - h - vp.u(28)
  return x, y, w, h
end

-- Hit-test: is this point inside the panel at all. Kept separate from the
-- click-to-navigate handler in intents.lua so input code never has to
-- know the panel's geometry -- only whether a point landed in it and,
-- if so, what world position that point maps to (M.screenToWorld).
function M.hit(vp, sx, sy)
  local x, y, w, h = M.rect(vp)
  return sx >= x and sx <= x + w and sy >= y and sy <= y + h
end

-- THE SAME PROJECTION draw() uses, run backward: a screen point inside the
-- panel to the world position it represents. Recomputing bounds() here
-- rather than caching the last draw's numbers means a click always reads
-- against the CURRENT known map, never a stale frame from before the last
-- mound was discovered.
function M.screenToWorld(vp, world, sx, sy)
  local bx0, by0, bx1, by1 = bounds(world)
  if not bx0 then return nil end
  local px, py, pw, ph = M.rect(vp)
  local wsx = pw / (bx1 - bx0)
  local wsy = ph / (by1 - by0)
  local ws = math.min(wsx, wsy)
  local ox = px + (pw - (bx1 - bx0) * ws) * 0.5
  local oy = py + (ph - (by1 - by0) * ws) * 0.5
  return bx0 + (sx - ox) / ws, by0 + (sy - oy) / ws
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

  -- THERE ARE NO EDGES TO DRAW. This used to walk `world.edges` and
  -- stroke a line per connection, from a build where the map really was
  -- a stored graph. Reach is computed from positions now -- world.lua
  -- says so at the top, and the ring on the main map IS the rule -- so
  -- the table has been gone for a long time.
  --
  -- It never crashed because it was never reached: the loop above gated
  -- on `discovered`, which nothing has set in just as long, so bounds()
  -- returned nil and the whole panel bailed out one line earlier. Two
  -- dead things propping each other up, and fixing the first one turned
  -- the second into `attempt to get length of a nil value (field
  -- 'edges')` on every frame. Worth remembering next time a "safe"
  -- revival of dormant code looks free.

  for i = 1, #world.nodes do
    local n = world.nodes[i]
    if n.seen then
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

  -- FOOD, as small diamonds -- a different SHAPE, not just a different
  -- colour, because the one question this panel answers at a glance is
  -- "where is my empire weak" and a fourth colour of dot does not
  -- survive being glanced at. Grey until visited, like everything else.
  for i = 1, #(world.locs or {}) do
    local l = world.locs[i]
    if l.seen then
      local x, y = toMap(l.x, l.y)
      local r = vp.u(4)
      local c = l.observed and ((l.owner == "you") and COL.you
                            or l.owner and COL.them or COL.forage)
                or { 0.42, 0.44, 0.46 }
      g.setColor(c[1], c[2], c[3], l.observed and 0.95 or 0.6)
      g.polygon("fill", x, y - r, x + r, y, x, y + r, x - r, y)
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
