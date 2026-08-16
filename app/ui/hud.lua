-- hud.lua - the smallest readout that answers "how am I doing".
--
-- This game has almost no HUD, and that restraint is part of why it reads
-- as a world rather than a spreadsheet. The previous build had a season
-- dial, a scent meter, a caste triangle, a hint banner and a stats block;
-- most of those belonged to mechanics that no longer exist. What is left
-- is the two numbers that actually describe your position.

local M = {}

local fontBig, fontSmall

function M.init(vp)
  local fonts = require("ui.fonts")
  fontBig = fonts.get(vp, 46)
  fontSmall = fonts.get(vp, 23)
end

function M.draw(snap, vp, intents)
  local g = love.graphics
  local A = require("sim.agents")
  local _, mine = A.stats(snap.agents)

  local owned, total = 0, #snap.world.nodes
  for i = 1, total do
    if snap.world.nodes[i].owner == "you" then owned = owned + 1 end
  end

  -- ── the level, and the next thing to press ──
  --
  -- A goal ("gather your ants") tells a player who does not know the
  -- controls nothing. The step names the button to press RIGHT NOW and is
  -- derived from the world, so it waits for them rather than running on a
  -- timer.
  if snap.level and not snap.level.generated then
    local fonts = require("ui.fonts")
    local campaign = require("sim.campaign")
    local fT = fonts.get(vp, 26)
    local fS = fonts.get(vp, 24)
    local title = snap.level.name
    local sub = snap.level.blurb
    if snap.levelDone then
      sub = "Done. Press  START  for the next field."
    elseif snap.level.steps then
      local st = campaign.step(snap.level, snap.world, intents, snap.agents)
      if st and snap.level.steps[st] then sub = snap.level.steps[st] end
    end
    local cx = vp.w * 0.5
    g.setFont(fT)
    g.setColor(0.92, 0.90, 0.84, 0.85)
    g.print(title, cx - fT:getWidth(title) * 0.5, vp.u(26))
    g.setFont(fS)
    g.setColor(0.74, 0.86, 0.72, snap.levelDone and 0.95 or 0.8)
    g.print(sub, cx - fS:getWidth(sub) * 0.5, vp.u(26) + fT:getHeight() + vp.u(4))
  end

  local x, y = vp.anchor("tl")
  g.setFont(fontBig)
  g.setColor(0.94, 0.92, 0.86, 0.95)
  g.print(tostring(mine), x, y)
  g.setFont(fontSmall)
  g.setColor(0.70, 0.72, 0.66, 0.9)
  g.print("ants", x + fontBig:getWidth(tostring(mine)) + vp.u(10),
          y + vp.u(20))

  local ly = y + fontBig:getHeight() - vp.u(6)
  g.setFont(fontBig)
  g.setColor(0.60, 0.95, 0.66, 0.95)
  g.print(tostring(owned), x, ly)
  g.setFont(fontSmall)
  g.setColor(0.70, 0.72, 0.66, 0.9)
  g.print("mounds", x + fontBig:getWidth(tostring(owned)) + vp.u(10),
          ly + vp.u(20))
end

return M
