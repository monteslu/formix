-- unknownsite.lua - the one circle every unvisited place wears.
--
-- THIS IS THE WHOLE OF FOG STATE 3, and it has exactly one job: give
-- away nothing. Not the kind, not the size, not the contents, not the
-- owner, not who is standing on it. A mound and a spider and a patch of
-- grain must be pixel-for-pixel the same circle until one of your ants
-- has stood there.
--
-- WHY A SHARED MODULE RATHER THAN A FUNCTION IN EACH RENDERER. Mounds
-- and locations used to draw their unknown state separately, and they
-- drifted: each drew at its OWN kind's radius, so a `rich` mound was a
-- 104-unit circle, a `small` one 56, a spider 96 and an aphid cluster
-- 74. The player could read the size and know what they were looking at
-- from across the map without walking anywhere -- and the spider, the
-- one thing the fog most needs to hide, announced itself as the biggest
-- circle on the board. Two copies of "draw the unknown" is two chances
-- to leak; one function called from both is none.
--
-- NO SEEDED VARIATION EITHER. The earlier version wobbled each ring by
-- up to 10% off a per-site seed, "so no two unknown patches are the same
-- circle". That is a leak wearing a friendly face: any per-site
-- variation is a channel, and a player who learns the tell reads the
-- board through it. Identical means identical.

local flora = require("render.flora")

local M = {}

local disc = flora.disc

-- THE radius, in world units, for every unknown site of every kind.
--
-- Between a small mound (56) and a plain one (78), and well under a
-- rich mound (104) or a spider (96): big enough to read as a destination
-- worth walking to, small enough that the reveal is usually an
-- expansion rather than a shrink. It is one number in one place on
-- purpose -- the moment it is computed from anything about the site, the
-- guarantee is gone.
M.RADIUS = 70

-- Draw an unknown site centred at a SCREEN position. `r` is M.RADIUS
-- already converted to screen scale by the caller (they each have the
-- viewport handy and cull against it).
--
-- Concentric rings darkening inward, still -- nothing breathes out here,
-- only an established colony does that.
function M.draw(g, sx, sy, r)
  for k = 4, 1, -1 do
    local f = k / 4
    local v = 0.17 + (5 - k) * 0.030
    g.setColor(v * 0.96, v * 1.0, v * 1.10, 1)
    disc(sx, sy, r * f)
  end
end

return M
