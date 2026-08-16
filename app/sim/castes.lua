-- castes.lua - the entire economy screen, in one widget's worth of state.
--
-- Ants inherit their stats from the mound they grew on. The
-- ant version is better because it is a decision rather than a location:
-- you set the ratio the nest RAISES, and the colony you get is the colony
-- you asked for a few minutes ago. The lag is the point -- it makes the
-- triangle a plan, not a lever.

local A = require("sim.agents")

local M = {}

M.cfg = {
  -- The triangle is three integer weights summing to STEPS. Integers,
  -- because a float ratio drifts under repeated nudges and a save/load
  -- round trip must be exact.
  steps = 12,
  minEach = 1,          -- no caste can be zeroed out entirely
  -- Effects at full allocation, interpolated by share.
  nurseBroodMul  = 2.2, -- nurses multiply brood conversion
  soldierDefense = 1.0, -- soldiers reduce hazard losses
  foragerSpeed   = 1.25,
}

function M.new()
  return {
    -- forager / nurse / soldier, in steps
    f = 7, n = 3, s = 2,
    -- derived, recomputed by update()
    speedMul = 1, broodMul = 1, defense = 0,
  }
end

local function clampTriangle(c)
  local steps, minEach = M.cfg.steps, M.cfg.minEach
  c.f = math.max(minEach, math.floor(c.f))
  c.n = math.max(minEach, math.floor(c.n))
  c.s = math.max(minEach, math.floor(c.s))
  -- Renormalise to exactly `steps` by shaving the largest, which keeps the
  -- player's intent (the thing they just raised stays raised).
  local sum = c.f + c.n + c.s
  local guard = 0
  while sum ~= steps and guard < 64 do
    guard = guard + 1
    if sum > steps then
      if c.f >= c.n and c.f >= c.s and c.f > minEach then c.f = c.f - 1
      elseif c.n >= c.s and c.n > minEach then c.n = c.n - 1
      elseif c.s > minEach then c.s = c.s - 1
      else break end
    else
      if c.f <= c.n and c.f <= c.s then c.f = c.f + 1
      elseif c.n <= c.s then c.n = c.n + 1
      else c.s = c.s + 1 end
    end
    sum = c.f + c.n + c.s
  end
end
M.clamp = clampTriangle

-- A nudge from the d-pad or the touch widget: {df, dn, ds}. Applied then
-- renormalised, so the triangle always sums to steps.
function M.nudge(c, d)
  c.f = c.f + (d[1] or 0)
  c.n = c.n + (d[2] or 0)
  c.s = c.s + (d[3] or 0)
  clampTriangle(c)
end

function M.update(c)
  clampTriangle(c)
  local steps = M.cfg.steps
  local fs, ns, ss = c.f / steps, c.n / steps, c.s / steps
  -- Interpolate from 1.0 (no allocation) to the configured full effect.
  c.speedMul = 1 + (M.cfg.foragerSpeed - 1) * (fs * 1.4)
  c.broodMul = 1 + (M.cfg.nurseBroodMul - 1) * (ns * 1.5)
  c.defense  = M.cfg.soldierDefense * ss * 1.5
end

-- Which role the nest should raise next, so the live population converges on
-- the requested ratio. Comparing DEFICIT rather than share means a colony
-- that lost all its soldiers rebuilds them first, which is what a player
-- expects after a predator sweep.
function M.nextRole(c, counts, total)
  if total <= 0 then return A.FORAGER end
  local steps = M.cfg.steps
  local want = { c.f / steps, c.n / steps, c.s / steps }
  local have = { counts[1] / total, counts[2] / total, counts[3] / total }
  local bestRole, bestDeficit = A.FORAGER, -math.huge
  for r = 1, 3 do
    local d = want[r] - have[r]
    if d > bestDeficit then bestRole, bestDeficit = r, d end
  end
  return bestRole
end

function M.digest(c)
  return string.format("f=%d n=%d s=%d", c.f, c.n, c.s)
end

return M
