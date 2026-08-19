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

-- THE UNEXPLORED PANEL IS ONE PANEL, and that includes its BOX.
--
-- The two site panels are different heights (a mound has more to say
-- than a patch of food once you know it), which is right for every state
-- but this one. Unexplored, both print the same two rows -- and the
-- taller box behind a mound's still told the player which they had
-- clicked, from the silhouette, without a word of text. A gate that only
-- compared the wording passed while the panel leaked by shape.
-- SIZED FOR THE TALLEST STATE EITHER PANEL REACHES IN THIS BOX: title +
-- THREE body rows (a guarded location prints "guarded / N to beat" and
-- "one ant per hit" under its blurb) + padding. 14 + (24+4) + 3*(20+9)
-- + 14 = 143. Sizing it for the two-row case instead clipped the third.
M.UNKNOWN_H = 143

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
  -- THE SAME BOX AN UNVISITED MOUND GETS, from the same constant. These
  -- were two literals that happened to be equal, and the type-scale pass
  -- proved why that is not good enough: picking a new height for each
  -- one separately (150 here, 116 there) made an unexplored mound and an
  -- unexplored patch different SHAPES, which is the exact leak the
  -- M.UNKNOWN_H note describes and which test-fog3 caught immediately.
  -- One constant, referenced twice, cannot drift.
  local w, h = vp.u(370), vp.u(M.UNKNOWN_H)
  local x, y = vp.u(28), vp.h - h - vp.u(28)
  -- IDENTITY IS WHAT VISITING BUYS. `observed` is presence -- true only
  -- while your ants are actually standing here -- so keying the panel on
  -- it made a patch you had scouted go anonymous again the moment they
  -- left, which is the opposite of learning something. `visited` never
  -- clears, so what you found out stays found out.
  local known = l.visited
  -- Ownership is a live fact here too (see the mound panel): a patch you
  -- scouted once must not keep flying an enemy's colour on the panel
  -- border forever after.
  local liveL = l.held or l.owner == "you"
  local key = (not known) and "none"
           or (liveL and l.owner == "you") and "you"
           or (liveL and l.owner) and "them"
           or "none"
  local c = M.COL[key]

  g.setColor(0.05, 0.07, 0.06, 0.84)
  g.rectangle("fill", x, y, w, h)
  g.setColor(c[1], c[2], c[3], 0.45)
  g.setLineWidth(math.max(2, vp.u(3)))
  g.line(x, y, x + w, y); g.line(x + w, y, x + w, y + h)
  g.line(x + w, y + h, x, y + h); g.line(x, y + h, x, y)
  g.setLineWidth(1)

  local fTitle = fonts.get(vp, 24)
  local fBody = fonts.get(vp, 20)
  local pad = vp.u(20)
  local ty = y + vp.u(14)

  g.setFont(fTitle)
  g.setColor(c[1], c[2], c[3], 1)
  -- THE SAME WORD A MOUND USES. "Something" for food and "Mound" for a
  -- hill told the player which was which from the title bar alone,
  -- without walking anywhere -- the fog's whole job, undone by a caption.
  g.print(known and (LOC_NAME[l.kind] or "Forage") or "Unexplored",
          x + pad, ty)
  ty = ty + fTitle:getHeight() + vp.u(4)

  g.setFont(fBody)
  local function line(label, value, col)
    col = col or { 0.88, 0.88, 0.82 }
    g.setColor(0.66, 0.68, 0.62, 1)
    g.print(label, x + pad, ty)
    g.setColor(col[1], col[2], col[3], 1)
    g.print(value, x + w - pad - fBody:getWidth(value), ty)
    ty = ty + fBody:getHeight() + vp.u(9)
  end

  if not known then
    -- NOT "unexplored" AGAIN: the title one line up already says it, and
    -- the row was spending its label restating it instead of telling the
    -- player anything. The pair now reads as a sentence -- Unexplored /
    -- nobody has been here / send ants to look -- and both site types
    -- still print the SAME two rows, which is what keeps a mound and a
    -- spider indistinguishable from the panel alone.
    line("nobody has been here", "", M.COL.none)
    line("", "send ants to look", M.COL.none)
  else
    line("", LOC_BLURB[l.kind] or "")
    local here = l.observed
    -- FOOD IS TERRAIN, A GUARD IS A BODY, and the panel splits on that.
    --
    -- The COUNT is live the moment the place is discovered: a field you
    -- have walked to is a field whose crop you can see standing in it
    -- from a distance, and watching grain come back is information you
    -- earned by scouting, not something to re-earn on every visit. (The
    -- earlier rule showed the number you last saw, which quietly turned a
    -- known patch back into a reason to walk over and re-read it.)
    --
    -- WHO is on it is the half that hides, and it needs presence. See
    -- render/locations.lua, which hides the spider herself by the same
    -- test.
    local count = l.items or 0
    if (l.guard or 0) > 0 and here then
      -- She is the headline. Nothing else about the place matters while
      -- she is standing.
      line("guarded", tostring(l.guard) .. " to beat", M.COL.them)
      line("", "one ant per hit")
    else
      line("food here", tostring(count), M.COL.you)
      line("each worth", tostring(l.value or 1))
      if l.regrow then line("", "it grows back") end
      if count == 0 then
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
  -- SHRUNK FROM 308: measured against its own content (title + up to
  -- three info lines + the button row, the tallest state this panel
  -- reaches), the old height left about 50px of dead plate below the
  -- buttons on every mound that has them. 260 keeps a small margin over
  -- that measured content instead of guessing a rounder number.
  -- UNEXPLORED GROUND GETS THE SAME BOX A LOCATION'S DOES (M.UNKNOWN_H).
  -- Decided HERE, above `x, y`, because the panel is anchored to the
  -- bottom of the screen -- `y` is derived from `h`, so setting the
  -- height further down (next to the `known` that decides it, which is
  -- where this first went) leaves the box the right size at the wrong
  -- place, floating off the bottom edge.
  local unknownBox = not n.visited
  local w, h = vp.u(370), vp.u(unknownBox and M.UNKNOWN_H or 248)
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
  -- Same rule as the location panel: identity is remembered, presence is
  -- not. A mound you scouted keeps its name after your ants leave.
  local known = n.visited
  -- WHOSE IT IS IS A LIVE FACT, AND LIVE FACTS NEED PRESENCE.
  --
  -- `known` (visited) buys the mound's NAME and nothing else. Ownership
  -- is state 1 information: keying the colour and the body lines off
  -- `n.owner` alone meant a mound you had scouted once kept announcing
  -- "defenders: unknown" in enemy red forever after -- which tells you
  -- an enemy holds it, from anywhere on the map, for the price of one
  -- visit however long ago. Your OWN ground is exempt: knowing what you
  -- hold is not a leak.
  local live = n.held or n.contested or n.owner == "you"
  local key = (not known) and "none"
           or (live and n.owner == "you") and "you"
           or (live and n.owner) and "them"
           or "none"
  local c = M.COL[key]

  g.setColor(0.05, 0.07, 0.06, 0.84)
  g.rectangle("fill", x, y, w, h)
  g.setColor(c[1], c[2], c[3], 0.45)
  g.setLineWidth(math.max(2, vp.u(3)))
  g.line(x, y, x + w, y); g.line(x + w, y, x + w, y + h)
  g.line(x + w, y + h, x, y + h); g.line(x, y + h, x, y)
  g.setLineWidth(1)

  local fTitle = fonts.get(vp, 24)
  local fBody = fonts.get(vp, 20)
  local pad = vp.u(20)
  local ty = y + vp.u(14)

  g.setFont(fTitle)
  g.setColor(c[1], c[2], c[3], 1)
  -- Even the NAME is information: "Deep mound" says this one is rich and
  -- worth taking first. Unvisited ground is just a mound.
  -- "Unexplored", NOT "Mound": the word has to match the one an
  -- unvisited location shows, or the panel identifies the site type for
  -- free. Once visited, the real name is the reward -- "Deep mound" says
  -- this one is rich and worth taking first.
  g.print(known and (KIND_NAME[n.kind] or "Mound") or "Unexplored",
          x + pad, ty)
  ty = ty + fTitle:getHeight() + vp.u(4)

  -- ROW PITCH CLEARS THE INK, NOT THE EM BOX (plan 06). getHeight() on
  -- this face returns the REQUESTED size (24.00, measured live), but the
  -- Atkinson Bold glyph box actually inks ~32px at that size -- caps plus
  -- descenders. `getHeight() + 3` therefore advanced 27px for 32px of
  -- ink, and consecutive rows touched: measured on a capture of the live
  -- panel, "your ants here" and "queens" merged into ONE continuous
  -- 58px-tall band of ink instead of two 21px rows. +11 clears the
  -- descender with a readable gap.
  g.setFont(fBody)
  local function line(label, value, col)
    col = col or { 0.88, 0.88, 0.82 }
    g.setColor(0.66, 0.68, 0.62, 1)
    g.print(label, x + pad, ty)
    g.setColor(col[1], col[2], col[3], 1)
    g.print(value, x + w - pad - fBody:getWidth(value), ty)
    ty = ty + fBody:getHeight() + vp.u(9)
  end

  local mine = A.garrison(snap.agents, n.id, "you")
  if not known then
    -- Says only what is true from a distance, and names the move that
    -- would answer the question.
    -- NOT "unexplored" AGAIN: the title one line up already says it, and
    -- the row was spending its label restating it instead of telling the
    -- player anything. The pair now reads as a sentence -- Unexplored /
    -- nobody has been here / send ants to look -- and both site types
    -- still print the SAME two rows, which is what keeps a mound and a
    -- spider indistinguishable from the panel alone.
    line("nobody has been here", "", M.COL.none)
    line("", "send ants to look", M.COL.none)
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
  elseif not live then
    -- DISCOVERED, NOBODY OF YOURS HERE. You know what kind of place this
    -- is (the title says so) and nothing about its present state.
    line("last seen", "nobody home", M.COL.none)
    line("", "send ants to look again")
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
    -- WIDTH COMES FROM THE WIDEST CAPTION, not a constant. A hardcoded
    -- 84 was narrower than the word it had to hold: "queen" at font 15
    -- measures 88px, so the centring term `(BTN - textWidth) * 0.5` went
    -- NEGATIVE and printed the caption starting outside the plate's left
    -- edge, spilling over the panel border. Measuring the labels means
    -- the plate can never be too small for its own text again, at any
    -- font size -- which is exactly the failure the whole type-scale pass
    -- produced when 96 came down to 84.
    local fSmall = fonts.get(vp, 15)
    local BTN = 0
    for _, cap in ipairs({ "queen", "brood", "cost " .. qCost, "cost " .. uCost }) do
      BTN = math.max(BTN, fSmall:getWidth(cap))
    end
    BTN = BTN + vp.u(16)          -- padding either side of the caption
    -- HEIGHT IS MEASURED FROM THE CONTENTS, not guessed. Three nudges at
    -- this constant each left the cost line a few pixels outside the
    -- plate: an icon block plus two text rows plus padding is a sum, so
    -- add it up rather than eyeballing it.
    local lh = fSmall:getHeight()
    -- TALLER, on request ("queen and brood label and cost look a little
    -- crowded"). ICONH grew from 0.52 to 0.62 of the button width, which
    -- pushes the whole text block down and gives the icon itself more
    -- air below it -- the queen icon's abdomen+egg reach 0.82 * icon-size
    -- below its own centre, so the old 0.52 left barely a name's cap-
    -- height of clearance before "queen" printed.
    -- ICON HEIGHT IS ITS OWN NUMBER, not a fraction of the plate's WIDTH.
    -- It used to be `BTN * 0.62`, which was fine while BTN was a constant
    -- -- but BTN is now measured from the widest caption, so a longer
    -- word would silently make the icon (and the whole plate, and the
    -- panel that has to contain it) taller. Width answers "does the text
    -- fit"; height answers "how big is the icon". They are not the same
    -- question and must not be the same number.
    local ICONH = vp.u(52)
    -- GAP is real breathing room between the name and its cost line,
    -- not just whatever the font's own line-height happens to leave.
    -- Widened from a first pass at 6px, which was not enough to read as
    -- SPACING rather than as a slightly-generous line height -- 6px is
    -- under a third of lh, so the two lines still read as one crowded
    -- block. 12px is closer to a whole blank line between them.
    local GAP = vp.u(10)
    local BTNH = ICONH + lh * 2 + GAP + vp.u(20)
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
              by + vp.u(9) + ICONH + lh + GAP)
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
      ty = ty + fBody:getHeight() + vp.u(9)
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
