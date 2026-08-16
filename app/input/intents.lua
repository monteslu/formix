-- intents.lua - the ONLY file in the game that reads an input device.
--
-- THE CORE GESTURE: press a mound's centre and drag outward. A
-- gauge follows the drag and picks HOW MANY to send -- a few, half, all --
-- and releasing over another node sends them. The quantity is the whole
-- decision in the game, so it belongs in the gesture rather than in a
-- modifier key.
--
-- Both devices express it:
--   touch  press a node, drag; the distance dragged sets the count;
--          release over the target.
--   pad    A on a node opens the same gauge; UP/DOWN change the count;
--          a direction picks the target; A sends.
--
-- Everything downstream consumes intents, so the two paths produce the
-- same stream and the parity gate means something.
--
-- Intents produced:
--   send    {from, to, count}
--   queen   {node}
--   upgrade {node, stat}
--   select  {node}          -- cursor/selection moved (UI only)
--   pan     {dx, dy} / zoom {f}
--   debug   {what}

local vp = require("render.viewport")
local W  = require("sim.world")
local A  = require("sim.agents")

local M = {}

local padPrev, padNow = {}, {}
local PAD_BUTTONS = { "a", "b", "x", "y", "start", "select",
                      "l", "r", "up", "down", "left", "right" }

local PTR_SLOTS = 10
local ptr = {}
for i = 0, PTR_SLOTS - 1 do
  ptr[i] = { active = false, down = false, prevDown = false,
             x = 0, y = 0, downX = 0, downY = 0, startNode = nil,
             dragging = false }
end

local frame = 0
-- Whether the stick is currently outside the deadzone. It must come back
-- inside before it will aim again, so one push is one step.
local stickHeld = false
local DRAG_SLOP = 12
local STICK_DEAD = 0.4

M.padUsed = false
M.pointerUsed = false

-- SELECTION + GAUGE. `selected` is the node the order comes from;
-- `fraction` is how much of its garrison the gesture currently means.
M.selected = nil
M.fraction = 1.0
M.cursor = { node = nil }
M.vp = nil

local out = {}
local function emit(kind, t)
  t = t or {}
  t.kind = kind
  out[#out + 1] = t
end

-- Quantity from how far the finger has moved away from the node. Short
-- pull = a few, long pull = everything. Three stops rather than a
-- continuum, because a precise number is not a decision anyone enjoys
-- making with a thumb.
local function fractionFromDrag(dist, vpu)
  if dist < vpu * 90 then return 0.25 end
  if dist < vpu * 190 then return 0.5 end
  return 1.0
end
M.fractionFromDrag = fractionFromDrag

local function pickNode(world, wx, wy, radius)
  local best, bestD = nil, radius * radius
  for i = 1, #world.nodes do
    local n = world.nodes[i]
    if n.seen then
      local dx, dy = n.x - wx, n.y - wy
      local d = dx * dx + dy * dy
      if d < bestD then best, bestD = n.id, d end
    end
  end
  return best
end

-- THE CURSOR IS A SPATIAL CURSOR, NOT A GRAPH WALKER.
--
-- Restricting it to the current mound's NEIGHBOURS is what made the pad
-- unplayable, and it took four tries to see why. Neighbours are defined
-- by the mound's radius, so at the edge of the map, or on a mound whose
-- neighbours all lie behind you, there is nothing in the pressed
-- direction and the cursor simply FREEZES. Measured on the real level:
-- left from n5 does nothing, down from n3 does nothing, and a realistic
-- wander reads
--   up:n5 left:STUCK down:n3 down:STUCK right:n1 right:n6 up:n2 ...
-- -- half the presses dead and the other half landing somewhere with no
-- obvious relationship to the last. That is unplayable, and no amount of
-- tuning the scoring fixes it, because the candidate set is wrong.
--
-- So the cursor considers EVERY mound you can see. The network still
-- governs what a send may do (sim/agents.send checks W.path, and the
-- panel says when a target is out of reach) -- but you must be able to
-- LOOK anywhere, or you cannot plan a route you have not yet built.
--
-- Two earlier failures are worth keeping in mind, because this is the
-- code path where they happened, and both came from a BAD SCORE rather
-- than from the candidate set:
--   * ranking by alignment ALONE made every press jump to the same far
--     favourite -- a distant mound that happened to line up beat every
--     near one.
--   * a "nearest reachable" fallback bounced the cursor back to where it
--     had just come from, n5/n2/n5/n2 forever, which read as inverted.
-- The score below is the standard spatial-navigation one, which avoids
-- both: distance ALONG the pressed axis, plus a heavy penalty for
-- distance ACROSS it. Near-and-straight-ahead wins; far wins only when
-- nothing is nearer; and something 90 degrees off never wins at all.
local function pickDirectional(world, fromId, sx, sy)
  local from = world.node[fromId]
  if not from then return world.homeId end
  local len = math.sqrt(sx * sx + sy * sy)
  if len < 1e-4 then return nil end
  local nx, ny = sx / len, sy / len

  local best, bestScore = nil, math.huge
  for i = 1, #world.nodes do
    local n = world.nodes[i]
    if n ~= from and n.seen then
      local dx, dy = n.x - from.x, n.y - from.y
      -- Split the offset into "along the direction pressed" and "across
      -- it". Only things genuinely ahead are candidates.
      local along  = dx * nx + dy * ny
      local across = math.abs(dx * -ny + dy * nx)
      -- ACCEPTANCE IS NEARLY 90 DEGREES, and it has to be. The obvious
      -- gate -- "more ahead than aside", a 45-degree half-angle -- looks
      -- principled and empties the map: this game's mounds sit on
      -- diagonals, and a typical one is MORE sideways than forward. n5 is
      -- (-349,-222) from home, so for "up" along=222 against across=349
      -- and a 45-degree cone rejects it. With that gate in place, up from
      -- home hit nothing at all. Anything genuinely on the pressed side
      -- is a candidate; the SCORE decides, not the gate.
      if along > 0 then
        -- ACROSS IS PENALISED 3x. This is the whole trick: it makes the
        -- cursor prefer what is straight ahead over what is merely far
        -- ahead and off to one side, so repeated presses travel in a
        -- line instead of wandering.
        local score = along + across * 3
        if score < bestScore then best, bestScore = n.id, score end
      end
    end
  end
  -- Genuinely nothing that way (the edge of the map): STAY.
  return best
end

local function padDown(b)
  local ok, v = pcall(love.pad.isDown, 1, b)
  if not ok then return false end
  return v
end

-- ALL, BY DEFAULT. Picking up a mound means picking up its workers --
-- all of them -- and L/R trims that down if you want to leave a garrison
-- behind. Defaulting to half meant every advance took two orders and the
-- game felt like it was rationing your own ants back to you.
local FRACTIONS = { 0.25, 0.5, 1.0 }
local fracIndex = 3

local function updatePad(world, agents)
  for _, b in ipairs(PAD_BUTTONS) do
    padPrev[b] = padNow[b]
    padNow[b] = padDown(b)
    if padNow[b] then M.padUsed = true end
  end
  local function pressed(b) return padNow[b] and not padPrev[b] end

  local menu = require("ui.menu")
  if menu.open then
    if pressed("select") then emit("debug", { what = "overlay" }) end
    if pressed("up") then menu.handle("up") end
    if pressed("down") then menu.handle("down") end
    if pressed("left") then menu.handle("left") end
    if pressed("right") then menu.handle("right") end
    if pressed("a") then menu.handle("confirm") end
    if pressed("b") or pressed("start") then menu.handle("cancel") end
    return
  end
  if pressed("start") and not padNow.select then
    -- ON A FINISHED LEVEL, START MEANS "NEXT FIELD" -- which is what the
    -- HUD has been promising ("Done. Press START for the next field.")
    -- while START actually opened the pause menu. Same button, and the
    -- menu still has the row, but the prompt now does what it says.
    if M.levelDone then
      menu.wantNextLevel = true
      return
    end
    menu.open = true
    return
  end

  -- The cursor starts on home, so the first press is already useful.
  if not M.cursor.node then M.cursor.node = world.homeId end

  -- THE D-PAD IS AUTHORITATIVE when it is being used. Mixing it with the
  -- analog axes meant pressing UP produced (stick_x, -1) -- and an idle
  -- stick reporting a little drift on X was enough to swing the aim into
  -- a mound off to one side, which reads as "up went somewhere else" or
  -- as an inverted control. A direction press means exactly that
  -- direction and nothing else.
  --
  -- (World +y is screen DOWN -- worldToScreen does not flip -- so up is
  -- -1 here and that part was right all along; the bug was the axes
  -- leaking in beside it.)
  local dpad = padNow.left or padNow.right or padNow.up or padNow.down
  local dx, dy
  if dpad then
    dx = padNow.left and -1 or (padNow.right and 1 or 0)
    dy = padNow.up and -1 or (padNow.down and 1 or 0)
  else
    dx = love.pad.axis(1, "leftx") or 0
    dy = love.pad.axis(1, "lefty") or 0
    -- Deadzone, so stick noise never aims anything.
    if math.abs(dx) < STICK_DEAD then dx = 0 end
    if math.abs(dy) < STICK_DEAD then dy = 0 end
  end

  -- THE DIRECTION COMES FROM THE PRESS ITSELF, not from whatever the pad
  -- happens to be reporting when the branch runs. `pressed()` is an EDGE
  -- (down this frame, up last), and on a short tap the button can already
  -- have been released by the time the aim code reads padNow -- so dx,dy
  -- were (0,0), pickDirectional bailed on its zero-length guard, and the
  -- cursor did not move. Latching the edge makes a tap always aim.
  -- EIGHT DIRECTIONS, NOT FOUR. Holding two d-pad directions aims on the
  -- diagonal, which this map badly needs: mounds are scattered on
  -- diagonals, so with only N/S/E/W a press is almost never pointing at
  -- anything squarely and the nearest-to-the-axis rule has to stretch a
  -- long way off-angle to find a target. NE/SE/SW/NW let the player say
  -- exactly which one they mean.
  --
  -- The combination is read from what is HELD (padNow) as well as from
  -- the edge, because two buttons are never pressed on the same frame --
  -- taking only the first edge, as this used to, threw the second half of
  -- every diagonal away. A press fires the aim; whatever else is held at
  -- that moment joins it.
  local flick = false
  local ex = (pressed("left") and -1) or (pressed("right") and 1) or 0
  local ey = (pressed("up") and -1) or (pressed("down") and 1) or 0
  if ex ~= 0 or ey ~= 0 then
    flick = true
    -- Start from the edge, then fold in the other axis if it is held.
    dx, dy = ex, ey
    if dx == 0 then
      dx = (padNow.left and -1) or (padNow.right and 1) or 0
    end
    if dy == 0 then
      dy = (padNow.up and -1) or (padNow.down and 1) or 0
    end
  end

  -- THE STICK IS EDGE-TRIGGERED TOO, and this is the last place the aim
  -- could still run away. The d-pad latches its press, but the stick fell
  -- through to the raw axes with no edge at all -- so holding it aimed
  -- EVERY FRAME, each time from the mound the previous frame had just
  -- moved to. One push walked the cursor several mounds in a few frames
  -- and stopped somewhere unrelated to the direction pushed, which is
  -- indistinguishable from an inverted or broken control.
  --
  -- One push, one step: the stick has to return inside the deadzone
  -- before it will aim again.
  if not dpad then
    local mag = math.sqrt(dx * dx + dy * dy)
    if mag >= STICK_DEAD then
      if not stickHeld then
        stickHeld = true
        flick = true
      else
        -- Held: already consumed by the push that started it.
        dx, dy = 0, 0
      end
    else
      stickHeld = false
      dx, dy = 0, 0
    end
  end

  -- QUANTITY IS ON THE SHOULDERS, in every state. It used to sit on
  -- up/down while an order was being composed, which stole half the d-pad
  -- from aiming: pressing up moved nothing and silently changed the count
  -- instead, so the cursor read as broken and inverted. A direction should
  -- always mean "look that way".
  if pressed("r") then
    fracIndex = math.min(#FRACTIONS, fracIndex + 1)
    M.fraction = FRACTIONS[fracIndex]
  elseif pressed("l") then
    fracIndex = math.max(1, fracIndex - 1)
    M.fraction = FRACTIONS[fracIndex]
  end

  if M.selected then
    -- ORDER IN PROGRESS: any direction aims, A sends, B cancels.
    if flick then
      local t = pickDirectional(world, M.selected, dx, dy)
      if t then M.cursor.node = t; emit("select", { node = t }) end
    end
    if pressed("a") then
      if M.cursor.node and M.cursor.node ~= M.selected then
        local have = A.garrison(agents, M.selected, A.YOU)
        emit("send", { from = M.selected, to = M.cursor.node,
                       count = math.max(1, math.floor(have * M.fraction + 0.5)) })
        M.selected = nil
      else
        M.selected = nil
      end
    end
    if pressed("b") then M.selected = nil end
  else
    if flick then
      -- Free look walks the SAME network an order does, so what the
      -- cursor can reach and what a send can reach are the same thing.
      -- (The old fallback here searched every visible mound when the
      -- network offered nothing, which is how the cursor could land on
      -- somewhere no order could follow it to.)
      local t = pickDirectional(world, M.cursor.node, dx, dy)
      if t then M.cursor.node = t; emit("select", { node = t }) end
    end
    if pressed("a") and M.cursor.node then
      local n = world.node[M.cursor.node]
      if n and n.owner == A.YOU
         and A.garrison(agents, n.id, A.YOU) > 0 then
        M.selected = M.cursor.node
        -- Picking up a mound picks up ALL of it; L/R trims.
        fracIndex = 3
        M.fraction = FRACTIONS[fracIndex]
        emit("select", { node = M.cursor.node })
      else
        -- A REFUSAL HAS TO SAY SO. Pressing A on a mound that is not
        -- yours (or is empty) did nothing at all and nothing appeared --
        -- indistinguishable from a broken button. The UI reads this and
        -- flashes the reason.
        M.refused = (n and n.owner ~= A.YOU) and "not yours" or "no ants here"
        M.refusedFrames = 110
      end
    end
  end

  -- Y raises a queen, X spends on the mound's growth stat: both turn ants
  -- into permanent capability, which is what makes them a currency rather
  -- than only an army.
  if pressed("y") and M.cursor.node then
    emit("queen", { node = M.cursor.node })
  end
  if pressed("x") and M.cursor.node then
    emit("upgrade", { node = M.cursor.node, stat = "growStat" })
  end

  if pressed("select") then emit("debug", { what = "overlay" }) end
end

local function updatePointer(world, agents)
  -- THE CART-FACING POINTER API IS love.mouse AND love.touch.
  --
  -- `love.wasmcart.pointer` does not exist -- `wc` is the prelude's own
  -- internal handle, not something a cart can reach -- so the whole
  -- pointer loop was silently dead and touch did nothing at all. Same
  -- class of mistake as inventing a deterministic flag earlier: a
  -- conditional on an API that is not there compiles, runs and does
  -- nothing. love.mouse is slot 0 (the desktop pointer); love.touch
  -- enumerates the fingers.
  for i = 0, PTR_SLOTS - 1 do
    ptr[i].prevDown = ptr[i].down
    ptr[i].active = false
    ptr[i].down = false
  end

  -- Slot 0: the mouse.
  do
    local p = ptr[0]
    local mx, my = love.mouse.getPosition()
    p.x, p.y = mx, my
    p.active = true
    p.down = love.mouse.isDown(1) and true or false
    if p.down then M.pointerUsed = true end
  end

  -- Slots 1..9: fingers currently touching.
  local touches = love.touch.getTouches()
  for k = 1, #touches do
    local id = touches[k]
    if id >= 1 and id < PTR_SLOTS then
      local p = ptr[id]
      local ok, tx, ty = pcall(love.touch.getPosition, id)
      if ok then
        p.x, p.y = tx, ty
        p.active = true
        p.down = true
        M.pointerUsed = true
      end
    end
  end

  for i = 0, PTR_SLOTS - 1 do
    local p = ptr[i]
    -- A lifted finger is down -> INACTIVE, not down -> up, so a slot that
    -- WAS down is processed one more time or its release is never seen.
    if p.active or p.prevDown then
      local wx, wy = vp.screenToWorld(p.x, p.y)
      local pickR = 120 / vp.cam.zoom

      if p.down and not p.prevDown then
        p.downX, p.downY = p.x, p.y
        p.dragging = false
        local menu = require("ui.menu")
        if menu.open then
          local row = menu.hitRow(M.vp, p.x, p.y)
          if row then menu.index = row; menu.handle("confirm")
          else menu.open = false end
          p.startNode = nil
        elseif menu.hitPause(M.vp, p.x, p.y) then
          menu.open = true
          p.startNode = nil
        elseif M.panelHit(p.x, p.y) then
          -- A PANEL BUTTON, handled before the world pick. The queen and
          -- upgrade actions used to be pad-only captions ("Y raise a
          -- queen"), so a touch or mouse player could not raise a queen at
          -- all and the first mission was unfinishable for them. This has
          -- to come first, or the tap falls through to the map underneath
          -- the panel and moves the cursor instead.
          --
          -- AND IT MUST STOP HERE. Folding the world-pick into this branch
          -- (rather than the else below) killed touch entirely: every tap
          -- that missed a button fell through to nothing, so the map could
          -- not even be SELECTED, let alone played.
          p.startNode = nil
        else
          local n = pickNode(world, wx, wy, pickR)
          p.startNode = n
          if n then
            M.cursor.node = n
            emit("select", { node = n })
            local nd = world.node[n]
            -- A TAP SELECTS. ONLY A DRAG SENDS.
            --
            -- Tap-tap used to send, on the theory that it is the natural
            -- touch gesture for "from here, to there". In practice it made
            -- the map dangerous: with a mound picked up, ANY tap on
            -- another mound flung its whole garrison there -- including a
            -- tap meant only to look at what a neighbour has. An
            -- irreversible move should never be one stray tap away, and
            -- looking around is the most common thing a player does.
            --
            -- So the gesture is explicit: drag from the source to the
            -- target. That also carries the quantity (distance picks the
            -- fraction), which a tap never could, and it matches the pad,
            -- where aiming with a direction is a deliberate second step.
            -- PRESS NEVER DESELECTS, because a press is also the first
            -- half of a drag. Clearing the selection here (and with it
            -- `p.startNode`) broke the most natural gesture in the game:
            -- tap a mound to look at it, then drag from that SAME mound --
            -- which did nothing at all, because the press had just thrown
            -- the source away. You had to tap somewhere else first, which
            -- nobody would ever guess.
            --
            -- Putting a mound down is a TAP, so it is handled on release
            -- (see the not-dragging branch below) where a drag has already
            -- been ruled out.
            -- Was it ALREADY picked up before this press? The release
            -- handler needs to know, so a second tap on the same mound can
            -- put it down without a press-time deselect breaking drags.
            p.tapWasSelected = (M.selected == n)
            if nd and nd.owner == A.YOU then
              M.selected = n
              M.fraction = 1.0
            end
          end
        end

      elseif p.down and p.prevDown and p.startNode then
        local moved = math.abs(p.x - p.downX) + math.abs(p.y - p.downY)
        if moved > DRAG_SLOP then p.dragging = true end
        if p.dragging and M.selected == p.startNode then
          -- THE GAUGE: how far you have pulled sets how many go.
          local dx, dy = p.x - p.downX, p.y - p.downY
          M.fraction = fractionFromDrag(math.sqrt(dx * dx + dy * dy),
                                        (M.vp and M.vp.unit) or 1)
          local t = pickNode(world, wx, wy, pickR)
          if t and t ~= p.startNode then M.cursor.node = t end
        end

      elseif (not p.down) and p.prevDown then
        if p.startNode and p.dragging and M.selected == p.startNode then
          local target = pickNode(world, wx, wy, pickR)
          if target and target ~= p.startNode then
            local have = A.garrison(agents, p.startNode, A.YOU)
            emit("send", { from = p.startNode, to = target,
                           count = math.max(1,
                                     math.floor(have * M.fraction + 0.5)) })
          end
          M.selected = nil
        elseif p.startNode and not p.dragging then
          -- A TAP THAT DID NOT BECOME A DRAG. This is where putting a
          -- mound DOWN belongs -- on release, once a drag has been ruled
          -- out -- and not at press time, where it stole the source out
          -- from under the very next drag.
          --
          -- Tapping the same mound twice toggles it off, so there is a way
          -- to clear a selection; tapping any other mound just moves the
          -- selection there, which is what "looking around" should do.
          if M.selected == p.startNode and p.tapWasSelected then
            M.selected = nil
          end
        end
        p.startNode = nil
        p.dragging = false
      end
    end
  end
end

function M.poll(world, viewport, agents)
  frame = frame + 1
  -- Kept so pendingOrder can ask the network whether the composed order
  -- is legal; it is called from the renderer, which has no world handle.
  M.world = world
  if M.refusedFrames and M.refusedFrames > 0 then
    M.refusedFrames = M.refusedFrames - 1
  end
  M.vp = viewport or M.vp
  for i = #out, 1, -1 do out[i] = nil end
  updatePad(world, agents)
  updatePointer(world, agents)
  return out
end

-- For the renderer: the order being composed right now, if any.
-- The order being composed, plus WHETHER IT IS LEGAL. The fifth return is
-- true only when the network actually connects the two mounds through
-- ground you hold -- so the arrow can be drawn as a refusal rather than
-- as a promise. Without it the UI happily drew a send reaching well past
-- the edge of the range ring to an unclaimed mound, and the panel said
-- "send ants to take it" for an order the sim would silently drop.
function M.pendingOrder(agents)
  if not M.selected then return nil end
  local have = A.garrison(agents, M.selected, A.YOU)
  local world = M.world
  local ok = false
  if world and M.cursor.node and M.cursor.node ~= M.selected then
    ok = W.path(world, M.selected, M.cursor.node, A.YOU) ~= nil
  end
  return M.selected, M.cursor.node, M.fraction,
         math.max(1, math.floor(have * M.fraction + 0.5)), ok
end

function M.slots() return ptr end

-- Did this point land on a node-panel action button? Emits the intent if
-- so and returns true, so the caller knows not to treat it as a map tap.
--
-- The rects come from the renderer (ui.nodepanel fills M.hits while it
-- draws), which is the only thing that knows where the rows ended up --
-- the panel's height depends on how many lines the mound needed.
function M.panelHit(sx, sy)
  local panel = require("ui.nodepanel")
  local hits = panel.hits
  if not hits then return false end
  for i = 1, #hits do
    local b = hits[i]
    if sx >= b.x and sx <= b.x + b.w and sy >= b.y and sy <= b.y + b.h then
      -- Same payload the pad sends, `stat` included -- an upgrade intent
      -- without it is a different action, and the two paths must not
      -- diverge.
      if b.kind == "upgrade" then
        emit("upgrade", { node = b.node, stat = "growStat" })
      else
        emit(b.kind, { node = b.node })
      end
      return true
    end
  end
  return false
end

function M.reset()
  M.selected, M.cursor.node = nil, nil
  M.fraction, fracIndex = 1.0, 3
end

return M
