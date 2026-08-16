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
