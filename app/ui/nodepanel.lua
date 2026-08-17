-- nodepanel.lua - what the selected mound IS, and what it would cost.
--
-- The panel shows a mound's numbers the moment you select it, and that
-- readout is most of how the game is legible: you cannot decide where to
-- send without knowing what you have and what it would buy.

local fonts = require("ui.fonts")
local W = require("sim.world")
local A = require("sim.agents")
-- Filled discs come from the mound renderer: circle("fill") is evaluated
-- from gl_FragCoord on this engine and lands in the wrong place after a
-- render-target pass, so everything draws them as polygon fans.
local mounds = require("render.mounds")

local M = {}

M.COL = {
  you  = { 0.55, 0.95, 0.62 },
  them = { 0.95, 0.42, 0.35 },
  none = { 0.92, 0.86, 0.60 },
}

local KIND_NAME = {
  home = "Home mound", rich = "Deep mound",
  plain = "Mound", small = "Small mound",
}

-- Pressable rects, rebuilt every frame. Input hit-tests against this;
-- CLEARED FIRST so a panel that stops drawing (nothing selected, or the
-- action became unaffordable) does not leave a live button behind on
-- empty screen -- which would fire on a tap aimed at the ground.
M.hits = {}

-- ── the panel for a place that is not a colony ─────────────────────────
--
-- What it says depends entirely on whether anyone has stood there. From
-- across the map a location is a clump of something, and the only honest
-- caption is "send ants to look" -- naming the kind here would hand over
-- for free the one thing that makes walking up to a strange patch of
-- ground interesting, and would take all the teeth out of the spider.
local LOC_NAME = {
  aphids = "Aphids", grain = "Grain", spider = "Spider",
}
local LOC_BLURB = {
  aphids = "plump and full of sap",
  grain  = "a few seeds, and more coming",
  spider = "she is bigger than you are",
}

function M.drawLoc(vp, snap, intents, l)
  local g = love.graphics
  local w, h = vp.u(430), vp.u(214)
  local x, y = vp.u(28), vp.h - h - vp.u(28)
  local known = l.observed
  local key = (not known) and "none"
           or (l.owner == "you") and "you" or l.owner and "them" or "none"
  local c = M.COL[key]

  g.setColor(0.05, 0.07, 0.06, 0.84)
  g.rectangle("fill", x, y, w, h)
  g.setColor(c[1], c[2], c[3], 0.45)
  g.setLineWidth(math.max(2, vp.u(3)))
  g.line(x, y, x + w, y); g.line(x + w, y, x + w, y + h)
  g.line(x + w, y + h, x, y + h); g.line(x, y + h, x, y)
  g.setLineWidth(1)

  local fTitle = fonts.get(vp, 30)
  local fBody = fonts.get(vp, 24)
  local pad = vp.u(20)
  local ty = y + vp.u(14)

  g.setFont(fTitle)
  g.setColor(c[1], c[2], c[3], 1)
  g.print(known and (LOC_NAME[l.kind] or "Forage") or "Something", x + pad, ty)
  ty = ty + fTitle:getHeight() + vp.u(4)

  g.setFont(fBody)
  local function line(label, value, col)
    col = col or { 0.88, 0.88, 0.82 }
    g.setColor(0.66, 0.68, 0.62, 1)
    g.print(label, x + pad, ty)
    g.setColor(col[1], col[2], col[3], 1)
    g.print(value, x + w - pad - fBody:getWidth(value), ty)
    ty = ty + fBody:getHeight() + vp.u(3)
  end

  if not known then
    line("unexplored", "send ants to look", M.COL.none)
  else
    line("", LOC_BLURB[l.kind] or "")
    if (l.guard or 0) > 0 then
      -- She is the headline. Nothing else about the place matters while
      -- she is standing.
      line("guarded", tostring(l.guard) .. " to beat", M.COL.them)
      line("", "one ant per hit")
    else
      line("food here", tostring(l.items or 0), M.COL.you)
      line("each worth", tostring(l.value or 1))
      if l.regrow then line("", "it grows back") end
      if (l.items or 0) == 0 then
        line("", l.regrow and "wait, or come back later" or "picked clean")
      end
    end
    local mine = A.garrison(snap.agents, l.id, "you")
    if mine > 0 then line("your ants here", tostring(mine), M.COL.you) end
  end
end

function M.draw(vp, snap, intents)
  M.hits = {}
  local id = intents.cursor and intents.cursor.node
  local n = id and snap.world.node[id]
  -- A LOCATION GETS ITS OWN PANEL. It shares nothing with a mound's --
  -- no queens, no garrison to raise, no upgrade -- and pouring it
  -- through the mound layout below would offer a queen on a patch of
  -- grain.
  if not n then
    local l = id and snap.world.loc and snap.world.loc[id]
    if l then return M.drawLoc(vp, snap, intents, l) end
  end
  if not n or not n.seen then return end

  local g = love.graphics
  local w, h = vp.u(430), vp.u(308)
  local x, y = vp.u(28), vp.h - h - vp.u(28)

  -- WHAT YOU KNOW ABOUT A MOUND YOU HAVE NEVER STOOD ON: that it is
  -- there. Nothing else.
  --
  -- EXPLORING HAS TO BE WORTH DOING. The panel used to name the mound's
  -- kind, its owner and its energy the moment the cursor touched it, from
  -- anywhere on the map -- so there was never anything to find out, and a
  -- scouting send bought information the player already had. `held` (one
  -- of your ants physically present, the same flag that warms the mound
  -- from stone to earth) is what turns a shape into a known place.
  local known = n.held or n.owner == "you"
  local key = (not known) and "none"
           or (n.owner == "you") and "you" or n.owner and "them" or "none"
  local c = M.COL[key]

  g.setColor(0.05, 0.07, 0.06, 0.84)
  g.rectangle("fill", x, y, w, h)
  g.setColor(c[1], c[2], c[3], 0.45)
  g.setLineWidth(math.max(2, vp.u(3)))
  g.line(x, y, x + w, y); g.line(x + w, y, x + w, y + h)
  g.line(x + w, y + h, x, y + h); g.line(x, y + h, x, y)
  g.setLineWidth(1)

  local fTitle = fonts.get(vp, 30)
  local fBody = fonts.get(vp, 24)
  local pad = vp.u(20)
  local ty = y + vp.u(14)

  g.setFont(fTitle)
  g.setColor(c[1], c[2], c[3], 1)
  -- Even the NAME is information: "Deep mound" says this one is rich and
  -- worth taking first. Unvisited ground is just a mound.
  g.print(known and (KIND_NAME[n.kind] or "Mound") or "Mound", x + pad, ty)
  ty = ty + fTitle:getHeight() + vp.u(4)

  g.setFont(fBody)
  local function line(label, value, col)
    col = col or { 0.88, 0.88, 0.82 }
    g.setColor(0.66, 0.68, 0.62, 1)
    g.print(label, x + pad, ty)
    g.setColor(col[1], col[2], col[3], 1)
    g.print(value, x + w - pad - fBody:getWidth(value), ty)
    ty = ty + fBody:getHeight() + vp.u(3)
  end

  local mine = A.garrison(snap.agents, n.id, "you")
  if not known then
    -- Says only what is true from a distance, and names the move that
    -- would answer the question.
    line("unexplored", "send ants to look", M.COL.none)
  elseif key == "you" then
    line("your ants here", tostring(mine), M.COL.you)
    local nq = n.queens and #n.queens or 0
    line("queens", nq .. " / " .. (n.maxQueens or 3),
         nq > 0 and M.COL.you or nil)
    if n.brood and #n.brood > 0 then
      line("larvae", tostring(#n.brood))
    end
  elseif key == "them" then
    -- FOG APPLIES TO THE PANEL TOO, and this was the widest leak of all:
    -- printing an exact defender count for any enemy mound made scouting
    -- pointless, because the number that decides whether to attack was
    -- free from across the map. You learn the garrison by standing in it
    -- -- the same `held` rule that reveals their ants and warms the mound
    -- from stone to earth.
    if n.held then
      local theirs = A.garrison(snap.agents, n.id, n.owner)
      line("defenders", tostring(theirs), M.COL.them)
      line("energy", string.format("%d", math.ceil(n.energy or 0)), M.COL.them)
    else
      line("defenders", "unknown", M.COL.them)
      line("", "send ants to find out")
    end
  else
    line("unclaimed", "send ants to take it", M.COL.none)
  end

  -- WHAT IT WOULD COST. The panel is a control, not a readout: it names
  -- the price of the two things ants can be spent on, and whether you can
  -- afford one is said by the plate being lit or dim rather than by the
  -- label changing. An action drawn identically whether or not it is
  -- available teaches the player that the game ignores them.
  if key == "you" then
    local cost = snap.cost or {}
    local qCost = cost.queen or 10
    local uCost = cost.upgrade or 8
    local full = (n.queens and #n.queens or 0) >= (n.maxQueens or 3)
    ty = ty + vp.u(6)

    -- THE ACTIONS ARE BUTTONS, not captions. They were drawn as plain text
    -- naming a pad button ("Y raise a queen"), which meant a player on
    -- touch or mouse -- with no Y to press -- could not raise a queen AT
    -- ALL. The whole first mission is unreachable that way.
    --
    -- Each row records its rect in M.hits so input can hit-test it.
    --
    -- SQUARE BUTTONS IN A ROW, not full-width bars. A bar spanning the
    -- panel reads as a list item -- something to select -- while a square
    -- of thumb size reads as something to PRESS, and a row of them says
    -- "these are your options here" at a glance without being read.
    --
    -- The icon carries the meaning and the label underneath names it, so
    -- the button works before the player has learned the icon. The pad
    -- letter stays in the corner: a controller player should never have to
    -- aim at a button they can trigger with a press.
    -- Wide enough for the longest label plus its cost line at font 17; a
    -- button that clips its own caption is worse than no icon.
    local BTN = vp.u(96)
    -- HEIGHT IS MEASURED FROM THE CONTENTS, not guessed. Three nudges at
    -- this constant each left the cost line a few pixels outside the
    -- plate: an icon block plus two text rows plus padding is a sum, so
    -- add it up rather than eyeballing it.
    local fSmall = fonts.get(vp, 17)
    local lh = fSmall:getHeight()
    local ICONH = BTN * 0.52
    local BTNH = ICONH + lh * 2 + vp.u(26)
    local bx0 = x + pad
    local by0 = ty + vp.u(4)
    local slot = 0

    local function action(icon, name, letter, affordable, kind)
      local bx = bx0 + slot * (BTN + vp.u(12))
      local by = by0
      slot = slot + 1

      if affordable then
        g.setColor(0.20, 0.30, 0.20, 0.95)
        g.rectangle("fill", bx, by, BTN, BTNH, vp.u(6))
        g.setColor(0.45, 0.95, 0.55, 0.70)
        g.setLineWidth(math.max(1, vp.u(2)))
        g.rectangle("line", bx, by, BTN, BTNH, vp.u(6))
        g.setLineWidth(1)
        M.hits[#M.hits + 1] = { x = bx, y = by, w = BTN, h = BTNH,
                                kind = kind, node = n.id }
      else
        -- Still drawn, so the player can see what this mound WILL offer --
        -- an option that vanishes when unaffordable teaches nothing.
        g.setColor(0.12, 0.14, 0.12, 0.85)
        g.rectangle("fill", bx, by, BTN, BTNH, vp.u(6))
        g.setColor(0.40, 0.42, 0.38, 0.55)
        g.setLineWidth(math.max(1, vp.u(1.5)))
        g.rectangle("line", bx, by, BTN, BTNH, vp.u(6))
        g.setLineWidth(1)
      end

      local dim = affordable and 1 or 0.45
      icon(bx + BTN * 0.5, by + vp.u(6) + ICONH * 0.5, BTN * 0.20, dim)

      -- Name and cost BOTH INSIDE the square, stacked under the icon.
      -- Printing the cost below the button ran the two buttons' captions
      -- together into one unreadable line ("10 ants8 ants").
      g.setFont(fSmall)
      g.setColor(0.90, 0.92, 0.84, affordable and 0.98 or 0.5)
      g.print(name, bx + (BTN - fSmall:getWidth(name)) * 0.5,
              by + vp.u(9) + ICONH)
      -- "cost 10", not "10 ants": the panel already says the currency
      -- ("your ants here"), and a bare price reads faster on a button.
      -- ALWAYS THE PRICE, never the shortfall. A button that switches to
      -- "need 8" is doing subtraction the player can do themselves -- the
      -- panel says how many ants are here two lines above -- and it makes
      -- the label move when nothing about the action changed. The price is
      -- a fact about the action; whether you can afford it is already said
      -- by the plate being lit or dim.
      local note = "cost " .. (kind == "queen" and qCost or uCost)
      g.setColor(0.66, 0.62, 0.46, affordable and 0.92 or 0.8)
      g.print(note, bx + (BTN - fSmall:getWidth(note)) * 0.5,
              by + vp.u(9) + ICONH + lh)
      -- The pad letter sits in the corner, small: a controller player
      -- triggers this with a press and never has to aim at it.
      g.setColor(0.70, 0.86, 0.68, affordable and 0.8 or 0.35)
      g.print(letter, bx + vp.u(5), by + vp.u(3))
      g.setFont(fBody)
    end

    -- Icons, drawn rather than bundled: a queen is a big body with a
    -- brood dot, an upgrade is an upward chevron. Both read at 23px.
    local function queenIcon(cx, cy, s, dim)
      g.setColor(0.95, 0.80, 0.36, dim)
      mounds.disc(cx, cy - s * 0.35, s * 0.34)          -- head
      mounds.disc(cx, cy + s * 0.30, s * 0.52)          -- abdomen
      g.setColor(0.95, 0.90, 0.70, dim * 0.9)
      mounds.disc(cx + s * 0.72, cy + s * 0.55, s * 0.20)  -- an egg beside her
    end
    local function broodIcon(cx, cy, s, dim)
      g.setColor(0.72, 0.92, 0.60, dim)
      g.setLineWidth(math.max(2, vp.u(3)))
      g.line(cx - s * 0.7, cy + s * 0.35, cx, cy - s * 0.5)
      g.line(cx, cy - s * 0.5, cx + s * 0.7, cy + s * 0.35)
      g.line(cx - s * 0.7, cy + s * 0.9, cx, cy + s * 0.05)
      g.line(cx, cy + s * 0.05, cx + s * 0.7, cy + s * 0.9)
      g.setLineWidth(1)
    end

    if full then
      g.setColor(0.42, 0.44, 0.40, 0.85)
      g.print("queen chamber full", x + pad, ty)
      ty = ty + fBody:getHeight() + vp.u(3)
    else
      action(queenIcon, "queen", "Y", mine >= qCost, "queen")
    end
    -- THE UPGRADE IS HIDDEN UNTIL THERE IS A QUEEN, and this cost a
    -- player ten ants. "faster brood" speeds up a queen's laying, so with
    -- no queen it buys literally nothing -- yet it was offered at 8 ants
    -- while the queen costs 10, so gathering TOWARD a queen crosses the
    -- upgrade threshold two ants early and one press spends the ants you
    -- were saving, irreversibly, on a stat that does nothing. On the
    -- opening level, whose only goal is the queen, that is a trap sitting
    -- directly beside the goal.
    -- The brood upgrade is CAPPED per mound, so a maxed one says so
    -- rather than offering a button that silently refuses.
    local upMax = cost.upgradeMax or 2
    local ups = n.upgrades or 0
    if #(n.queens or {}) > 0 then
      if ups >= upMax then
        g.setColor(0.42, 0.44, 0.40, 0.85)
        g.print("brood fully improved", x + pad, by0 + vp.u(4))
      else
        action(broodIcon, "brood", "X", mine >= uCost, "upgrade")
      end
    end
  end
end

return M
