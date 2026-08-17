-- render/init.lua - the drawing side of the wall.
--
-- Reads a sim snapshot and never writes to it. Everything is GENERATED
-- geometry -- no bitmaps -- so the look scales to any resolution and every
-- mound is unique from its seed.
--
-- Draw order:
--   ground -> range rings + mounds -> orders in flight -> ants -> ui

local ground  = require("render.ground")
local mounds  = require("render.mounds")
local locations = require("render.locations")
local ants    = require("render.ants")
local fx      = require("render.fx")
local orders  = require("render.orders")
local hud     = require("ui.hud")
local menu    = require("ui.menu")
local nodepanel = require("ui.nodepanel")
local minimap = require("ui.minimap")

local M = {}

local initialised = false

local function ensure(vp)
  if initialised then return end
  fx.init(vp)
  ground.init(vp)
  mounds.init(vp)
  ants.init(vp)
  -- Warm every font size BEFORE anything caches a font object: allocating
  -- one mid-frame corrupts the engine's composite blit mesh and drops the
  -- whole run to the software rasterizer.
  require("ui.fonts").warm(vp)
  hud.init(vp)
  initialised = true
end

function M.draw(snap, vp, intents)
  ensure(vp)

  local hdr = fx.beginScene()

  ground.draw(snap, vp)
  -- Locations UNDER the mounds: a patch of grain that overlapped a hill
  -- would draw on top of the thing the map is about.
  locations.draw(snap, vp)
  mounds.draw(snap, vp, intents)
  orders.draw(snap, vp, intents)
  ants.draw(snap, vp)

  if hdr then
    fx.finish({ 1.02, 1.04, 1.0 }, 0, 0.85, 0.34)
  end

  -- FOG AFTER THE COMPOSITE, in screen space. It cannot live inside the
  -- scene pass: it renders to its own canvas, and setCanvas() with no
  -- argument returns to the SCREEN rather than to the scene target -- so
  -- drawing it there silently redirected everything after it and the fog
  -- itself was overwritten by the composite. It is a screen-space overlay
  -- anyway; being outside the bloom is correct as well as necessary,
  -- since unlit ground should not glow.

  -- UI outside the composite: bloomed type is unreadable.
  if not menu.open then
    -- Order text (the send count, refusals) belongs to the world but is
    -- TYPE, so it is painted here rather than inside the scene pass,
    -- where text comes out mirrored and upside down.
    orders.drawLabels(vp)
    nodepanel.draw(vp, snap, intents)
    minimap.draw(snap, vp)
    hud.draw(snap, vp, intents)
    menu.drawPauseButton(vp)
  end
  menu.draw(vp)
end

function M.hdrActive() return fx.available end

return M
