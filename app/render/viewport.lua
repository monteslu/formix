-- viewport.lua - THE ONLY FILE that knows the screen size.
--
-- The rule (docs/DEVPLAN.md section 6): the literals 1920, 1080, 16 and 9 may
-- appear in conf.lua, manifest.json, build.sh and this file. Nowhere else.
-- Everything downstream asks the viewport, so a taller phone build later is a
-- conf change plus zero layout edits.
--
-- Two coordinate spaces:
--
--   SCREEN space - pixels, origin top-left. UI lives here, anchored to edges
--                  so it survives any aspect.
--   WORLD space  - the colony's own units, origin at the nest. The camera
--                  maps world -> screen. A wider screen shows MORE WORLD
--                  rather than stretching it, which is what keeps the game
--                  honest on a ratio it was not drawn for.

local vp = {}

-- Read from the engine, never assumed. love.graphics.getDimensions is what
-- conf.lua actually produced, so a mismatch between conf and manifest shows
-- up here as a layout that is merely anchored differently, not broken.
function vp.init()
  vp.w, vp.h = love.graphics.getDimensions()
  vp.aspect = vp.w / vp.h

  -- One design unit = 1/1080th of the reference height. Every size in the
  -- game is expressed in these so the layout scales with the window rather
  -- than with a hardcoded pixel count.
  vp.unit = vp.h / 1080

  -- The safe margin: TV overscan is real on the couch, and a phone has
  -- rounded corners and a notch. 3% of the SHORT axis on every edge.
  vp.margin = math.min(vp.w, vp.h) * 0.03

  -- Camera state, in world units.
  -- ZOOMED OUT BY DEFAULT. This is a map game: the player has to see the
  -- FIELD -- where the mounds are, which ones are in reach, where the
  -- frontier is -- and a close view shows one hill and a lot of dark.
  -- (0.30 fits a 2600-unit map on a 1080p screen.)
  vp.cam = { x = 0, y = 0, zoom = 0.42, minZoom = 0.14, maxZoom = 2.0 }

  return vp
end

-- ── zoom steps ─────────────────────────────────────────────────────────
--
-- FIXED RUNGS, not a smooth axis, for the button inputs (pad shoulders).
-- Three reasons: a slow couch game does not need analog zoom to feel
-- responsive; every rung is a composed picture the ant LOD tiers can be
-- tuned against; and a stray press costs exactly one step to undo, which
-- matters because the shoulders do double duty (see input/intents.lua).
--
-- The pinch and the wheel are CONTINUOUS and ignore this ladder -- fingers
-- and a wheel are analog inputs and stepping them feels broken. The rungs
-- are presets, not a constraint on where the zoom may sit.
--
-- The close rung is deliberately CLOSE. Age of Empires II on Xbox was
-- criticised for not zooming in enough to read units on a TV, and this game
-- is meant to be read from a couch (its typeface was chosen for that).
vp.ZOOM_STEPS = { 0.20, 0.42, 0.85, 1.50 }
vp.ZOOM_DEFAULT = 0.42

-- Move one rung. Snaps to the nearest rung first when the zoom is sitting
-- between them (which pinch and the wheel do all the time), so the first
-- press after a pinch is never a no-op or a jump backwards.
function vp.zoomStep(dir)
  local steps = vp.ZOOM_STEPS
  local z = vp.cam.zoom
  local best, bestD = 1, math.huge
  for i = 1, #steps do
    local d = math.abs(steps[i] - z)
    if d < bestD then best, bestD = i, d end
  end
  -- If we are between rungs, stepping "in" should go to the rung above the
  -- current zoom rather than to the neighbour of the nearest one.
  local i = best
  if dir > 0 then
    if steps[i] <= z + 1e-6 then i = i + 1 end
  else
    if steps[i] >= z - 1e-6 then i = i - 1 end
  end
  i = math.max(1, math.min(#steps, i))
  vp.cam.zoom = steps[i]
  return vp.cam.zoom
end

-- Scale a design-unit measurement to screen pixels.
function vp.u(n) return n * vp.unit end

-- Anchor helpers. Each returns a screen position measured from the named
-- edge, inside the safe margin. UI code never writes an absolute coordinate.
--   corner: "tl" "tr" "bl" "br" "tc" "bc" "lc" "rc" "cc"
function vp.anchor(corner, dx, dy)
  dx, dy = dx or 0, dy or 0
  local m = vp.margin
  local x, y
  if     corner == "tl" then x, y = m,             m
  elseif corner == "tr" then x, y = vp.w - m,      m
  elseif corner == "bl" then x, y = m,             vp.h - m
  elseif corner == "br" then x, y = vp.w - m,      vp.h - m
  elseif corner == "tc" then x, y = vp.w * 0.5,    m
  elseif corner == "bc" then x, y = vp.w * 0.5,    vp.h - m
  elseif corner == "lc" then x, y = m,             vp.h * 0.5
  elseif corner == "rc" then x, y = vp.w - m,      vp.h * 0.5
  elseif corner == "cc" then x, y = vp.w * 0.5,    vp.h * 0.5
  else error("vp.anchor: unknown corner '" .. tostring(corner) .. "'", 2)
  end
  return x + dx * vp.unit, y + dy * vp.unit
end

-- ── camera ─────────────────────────────────────────────────────────────
--
-- The world scale is pinned to the SHORT axis, so a wider window reveals
-- more world horizontally instead of magnifying everything. That is the
-- whole aspect-independence trick in one line.
function vp.worldScale()
  return math.min(vp.w, vp.h) / 1080 * vp.cam.zoom
end

-- MIRROR A SCENE-PASS SCREEN POSITION BACK INTO REAL SCREEN SPACE.
--
-- The HDR target is blitted with a -1 y-scale (see render/fx.lua), so a
-- y recorded inside the scene pass is measured from the other edge. Text
-- collected during the pass and painted after the composite has to come
-- back through here, or it lands mirrored about the centre -- which is
-- exactly what "6 ready" did.
function vp.unflip(y) return vp.h - y end

function vp.worldToScreen(wx, wy)
  local s = vp.worldScale()
  return (wx - vp.cam.x) * s + vp.w * 0.5,
         (wy - vp.cam.y) * s + vp.h * 0.5
end

function vp.screenToWorld(sx, sy)
  local s = vp.worldScale()
  return (sx - vp.w * 0.5) / s + vp.cam.x,
         (sy - vp.h * 0.5) / s + vp.cam.y
end

-- The world rectangle currently visible, in world units. Renderers cull
-- against this; the sim never sees it.
function vp.worldBounds()
  local x0, y0 = vp.screenToWorld(0, 0)
  local x1, y1 = vp.screenToWorld(vp.w, vp.h)
  return x0, y0, x1, y1
end

function vp.moveCamera(dx, dy)
  vp.cam.x = vp.cam.x + dx
  vp.cam.y = vp.cam.y + dy
end

-- Put a world point in the middle of the screen. Used at boot so the
-- player starts looking at home rather than at the origin of a map whose
-- home may not be there.
function vp.centreOn(x, y)
  vp.cam.x, vp.cam.y = x, y
end

function vp.zoomBy(f)
  local z = vp.cam.zoom * f
  vp.cam.zoom = math.max(vp.cam.minZoom, math.min(vp.cam.maxZoom, z))
end

-- ZOOM ABOUT A SCREEN POINT, keeping the world under it still.
--
-- This is the whole difference between a zoom that feels like a lens and
-- one that feels like a teleport. Pinch a corner of the map, or spin the
-- wheel with the cursor over a far mound: the thing you are pointing AT is
-- the thing you mean, and it must not slide out from under you while the
-- scale changes. Everyone implements zoom about the screen centre first and
-- it is visibly wrong on the first try.
--
-- Note the order: remember the world point, change the scale, ask where
-- that same screen point landed, and shift the camera by the difference.
function vp.zoomAt(sx, sy, factor)
  local wx0, wy0 = vp.screenToWorld(sx, sy)
  vp.zoomBy(factor)
  local wx1, wy1 = vp.screenToWorld(sx, sy)
  vp.cam.x = vp.cam.x + (wx0 - wx1)
  vp.cam.y = vp.cam.y + (wy0 - wy1)
end

-- Same, for a step: the rung ladder with an anchor.
function vp.zoomStepAt(sx, sy, dir)
  local wx0, wy0 = vp.screenToWorld(sx, sy)
  vp.zoomStep(dir)
  local wx1, wy1 = vp.screenToWorld(sx, sy)
  vp.cam.x = vp.cam.x + (wx0 - wx1)
  vp.cam.y = vp.cam.y + (wy0 - wy1)
end

-- ── keeping the field on screen ────────────────────────────────────────
--
-- The extents of everything that matters, cached per world. Panning by hand
-- makes a runaway camera real for the first time -- before this, the view
-- only ever moved a nudge at a time toward a mound, so it could not get
-- lost. A player who flicks the stick and finds themselves in featureless
-- dark with no idea which way is back has been handed a bug, however
-- correct the maths was.
--
-- Recomputed when the world changes identity (a new level), not per frame:
-- mounds and locations do not move, and W.dist over 30 sites every frame to
-- learn a number that never changes is waste.
local extents = { world = nil, x0 = 0, y0 = 0, x1 = 0, y1 = 0 }

function vp.worldExtents(world)
  if extents.world == world then
    return extents.x0, extents.y0, extents.x1, extents.y1
  end
  local x0, y0 = math.huge, math.huge
  local x1, y1 = -math.huge, -math.huge
  local function add(s)
    local r = s.radius or 0
    if s.x - r < x0 then x0 = s.x - r end
    if s.y - r < y0 then y0 = s.y - r end
    if s.x + r > x1 then x1 = s.x + r end
    if s.y + r > y1 then y1 = s.y + r end
  end
  for i = 1, #world.nodes do add(world.nodes[i]) end
  for i = 1, #(world.locs or {}) do add(world.locs[i]) end
  if x0 > x1 then x0, y0, x1, y1 = -500, -500, 500, 500 end
  extents.world = world
  extents.x0, extents.y0, extents.x1, extents.y1 = x0, y0, x1, y1
  return x0, y0, x1, y1
end

-- Clamp against a world's own extents. The one call site every camera
-- change funnels through, so there is no way to add a new pan or zoom path
-- and forget the bound.
function vp.clampToWorld(world)
  if not world then return end
  local x0, y0, x1, y1 = vp.worldExtents(world)
  vp.clampCamera(x0, y0, x1, y1)
end

-- Clamp the camera so the colony's bounding box can never leave the screen
-- entirely. Called after any camera move; takes world-space extents.
function vp.clampCamera(x0, y0, x1, y1)
  local s = vp.worldScale()
  local halfW, halfH = vp.w * 0.5 / s, vp.h * 0.5 / s
  -- Allow the view to sit one half-screen outside the content on each side.
  local minX, maxX = x0 - halfW * 0.5, x1 + halfW * 0.5
  local minY, maxY = y0 - halfH * 0.5, y1 + halfH * 0.5
  if minX > maxX then minX, maxX = (x0 + x1) * 0.5, (x0 + x1) * 0.5 end
  if minY > maxY then minY, maxY = (y0 + y1) * 0.5, (y0 + y1) * 0.5 end
  vp.cam.x = math.max(minX, math.min(maxX, vp.cam.x))
  vp.cam.y = math.max(minY, math.min(maxY, vp.cam.y))
end

return vp
