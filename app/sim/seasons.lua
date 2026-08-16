-- seasons.lua - the arc.
--
-- There are no levels. The year IS the structure: spring bloom, summer
-- sprawl, autumn hoarding, winter contraction, and how well you provisioned
-- decides the size you wake at. That gives the game a shape without ever
-- leaving the one persistent terrarium, and it means a "loss" is a small
-- spring rather than a defeat screen.

local M = {}

M.cfg = {
  -- Seconds per season at 1x. A full year is 12 minutes of real time, which
  -- is long enough to feel like an arc and short enough that a playtest can
  -- see two of them.
  seasonLen = 180,
  names = { "spring", "summer", "autumn", "winter" },
}

-- Per-season modifiers. These are the whole difference between the seasons
-- mechanically; everything else is colour and sound.
M.MODS = {
  spring = { yield = 1.15, threatPressure = 0.7,  broodMul = 1.25, decayMul = 1.0 },
  summer = { yield = 1.35, threatPressure = 1.3,  broodMul = 1.0,  decayMul = 1.15 },
  autumn = { yield = 0.85, threatPressure = 1.0,  broodMul = 0.85, decayMul = 1.0 },
  winter = { yield = 0.20, threatPressure = 0.45, broodMul = 0.55, decayMul = 0.7 },
}

function M.new()
  local s = {
    t = 0,                 -- seconds into the current season
    index = 1,             -- 1..4
    year = 1,
    -- Applied modifiers, read by the other sim modules.
    yield = 1, threatPressure = 1, broodMul = 1, decayMul = 1,
    -- Winter bookkeeping: what was in the pantry when winter began, and
    -- what that bought at the thaw.
    winterStores = 0,
    wakeSize = 0,
    justChanged = false,
    changedTo = nil,
  }
  M.applyMods(s)
  return s
end

function M.name(s) return M.cfg.names[s.index] end

function M.applyMods(s)
  local m = M.MODS[M.cfg.names[s.index]]
  s.yield, s.threatPressure = m.yield, m.threatPressure
  s.broodMul, s.decayMul = m.broodMul, m.decayMul
end

function M.update(s, dt)
  s.justChanged = false
  s.t = s.t + dt
  if s.t >= M.cfg.seasonLen then
    s.t = s.t - M.cfg.seasonLen
    s.index = s.index + 1
    if s.index > 4 then
      s.index = 1
      s.year = s.year + 1
    end
    M.applyMods(s)
    s.justChanged = true
    s.changedTo = M.cfg.names[s.index]
  end
end

-- Progress through the current season, 0..1. The HUD's season ring.
function M.progress(s) return s.t / M.cfg.seasonLen end

-- Called at the winter boundary by the campaign layer: how much of the
-- pantry survives into spring, expressed as a colony size the nest wakes
-- with. Provisioning quality IS the score, and it is never punitive: a bad
-- winter means a small spring, not a wipe.
function M.computeWake(s, food, population, minColony)
  s.winterStores = food
  local fed = math.floor(food / 60)
  local wake = math.max(minColony, math.min(population, minColony + fed))
  s.wakeSize = wake
  return wake
end

function M.digest(s)
  return string.format("y=%d %s t=%.1f wake=%d",
    s.year, M.cfg.names[s.index], s.t, s.wakeSize)
end

return M
