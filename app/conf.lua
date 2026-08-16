-- The cart declares its own resolution. The engine default is NOT a
-- contract: carts that leaned on it rendered at 720p with the layout
-- spilling off screen the moment a newer engine ran them.
--
-- This is one of exactly four places the screen size may appear. The others
-- are build.sh (the pack manifest), app/manifest.json, and
-- app/render/viewport.lua, which is the only file the game itself reads it
-- from. See docs/DEVPLAN.md section 6.
function love.conf(t)
  t.window.width = 1920
  t.window.height = 1080
end
