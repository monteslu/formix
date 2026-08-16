-- probe.lua - the agent's instrument panel.
--
-- Emits structured lines a gate can parse, and draws a developer overlay.
-- The cart cannot time itself (love.timer is the fixed 1/60 counter), so
-- nothing here claims milliseconds -- it reports what only the cart knows.

local A = require("sim.agents")
local W = require("sim.world")

local M = {}

M.overlay = false
local METRIC_EVERY = 30
local frames = 0

function M.init(S)
  frames = 0
  -- LEVEL IS PART OF THE BOOT REPORT. A cart packed with an
  -- `app/startlevel` marker opens somewhere other than Gather, and a gate
  -- that assumed the usual opening board would otherwise just report
  -- baffling failures -- which is exactly what happened once.
  print(string.format("@boot seed=%d mounds=%d ants=%d level=%s",
    S.seed, #S.world.nodes, S.agents.n, tostring(S.levelId or "open")))
end

function M.noteIntent(it, ok)
  print(string.format("@i %s ok=%s from=%s to=%s node=%s n=%s",
    it.kind, tostring(ok), tostring(it.from), tostring(it.to),
    tostring(it.node), tostring(it.count)))
end

function M.noteCursor(it)
  local intents = require("input.intents")
  print(string.format("@c select node=%s selected=%s frac=%.2f",
    tostring(it.node), tostring(intents.selected), intents.fraction or 0))
end

-- Every mound: who holds it, its garrison, queens and stats. This is the
-- 4X state a gate asserts on.
function M.reportMounds(S)
  for i = 1, #S.world.nodes do
    local n = S.world.nodes[i]
    -- `g` is YOUR ants here; `fg` is the HOLDER's. On your own ground the
    -- two agree, but on an enemy mound `g` alone reads 0 and looks like an
    -- undefended target -- which is exactly the number a gate must not
    -- assert an attack against.
    local hold = n.owner or "you"
    print(string.format(
      "@mound %s %s g=%d gi=%d fg=%d q=%d/%d energy=%.0f reach=%.0f seen=%s brood=%d",
      n.id, tostring(n.owner), A.garrison(S.agents, n.id, "you"),
      A.garrisonIncoming(S.agents, n.id, "you"),
      A.garrison(S.agents, n.id, hold),
      n.queens and #n.queens or 0, n.maxQueens or 0,
      n.energy or 0, W.reach(n), tostring(n.seen),
      n.brood and #n.brood or 0))
  end
end

function M.reportNodes(S, vp)
  for i = 1, #S.world.nodes do
    local n = S.world.nodes[i]
    local x, y = vp.worldToScreen(n.x, n.y)
    print(string.format("@node %s %d %d", n.id,
                        math.floor(x + 0.5), math.floor(y + 0.5)))
  end
end

function M.reportUI(vp)
  local menu = require("ui.menu")
  local intents = require("input.intents")
  if vp then
    local px, py, pw, ph = menu.pauseRect(vp)
    print(string.format("@pause %d %d %d %d",
      math.floor(px), math.floor(py), math.floor(pw), math.floor(ph)))
  end
  print(string.format("@ui menu=%s row=%d cursor=%s selected=%s frac=%.2f",
    tostring(menu.open), menu.index, tostring(intents.cursor.node),
    tostring(intents.selected), intents.fraction or 0))
end

function M.command(S, what)
  if what == "overlay" then
    M.overlay = not M.overlay
    M.wantReport = M.overlay
    print("@dbg overlay=" .. tostring(M.overlay))
  elseif what == "pause" then
    S.paused = not S.paused
    print("@dbg paused=" .. tostring(S.paused))
  end
end

function M.slots(intents)
  if not M.overlay then return end
  local parts = {}
  local slots = intents.slots()
  for i = 0, 9 do
    local p = slots[i]
    if p and p.active then parts[#parts + 1] = i .. (p.down and "+" or "-") end
  end
  if #parts > 0 then print("@slots " .. table.concat(parts, " ")) end
end

function M.update(S, dt)
  frames = frames + 1
  if frames % METRIC_EVERY ~= 0 then return end
  -- The mixer's live state, on the same tick as the metrics. A gate cannot
  -- HEAR the cart (romdev records silence for wasmcart), so this line is
  -- the only evidence that music is playing and which track is up.
  pcall(function() require("audio.init").report() end)
  local n, mine, theirs, moving = A.stats(S.agents)
  local owned, queens, seen = 0, 0, 0
  for i = 1, #S.world.nodes do
    local nd = S.world.nodes[i]
    if nd.owner == "you" then owned = owned + 1 end
    queens = queens + (nd.queens and #nd.queens or 0)
    if nd.seen then seen = seen + 1 end
  end
  print(string.format(
    '@m {"t":%.2f,"ants":%d,"mine":%d,"theirs":%d,"moving":%d,' ..
    '"owned":%d,"queens":%d,"seen":%d,"mounds":%d,"phash":%d}',
    S.time, n, mine, theirs, moving, owned, queens, seen,
    #S.world.nodes, A.positionHash(S.agents)))
end

function M.draw(S, vp, intents)
  if not M.overlay then return end
  if M.wantReport then
    M.wantReport = false
    M.reportNodes(S, vp)
    M.reportMounds(S)
  end
  M.reportUI(vp)
end

return M
