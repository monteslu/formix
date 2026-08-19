-- save.lua - one persistent colony.
--
-- The map is regenerated from the seed, so what persists is the STATE of
-- the field: who holds what, how many queens are in each mound, the stats
-- they have been fed, and how big each garrison is. Ants themselves are
-- restored as counts and respawned at their mound -- an ant is weather,
-- not history.

local W = require("sim.world")
local A = require("sim.agents")

local M = {}
-- 4: food. The pool per side, and what is left in every location.
-- 5: fog. `visited` per site -- what the player has LEARNED, which is not
--    derivable from anything else in the blob: ownership says where you
--    are now, never where you have been. A location also carries the item
--    count as it looked when you last stood on it, because a discovered
--    patch draws from memory rather than from the live number.
-- 6: plan 05. Corpses (a battle's dead bodies must not reset to nothing
--    on a reload mid-fade) and each spider's subdual state (hp, which
--    legs are held, her kill clock) -- see the "S" line below. Field 6
--    of the "L" line changes MEANING for a spider from this version on:
--    it was `guard` (a countdown of arrivals left to trade), it is now
--    her hit points (damageable only while subdued). A pre-v6 save
--    cannot be reinterpreted -- the field is the same column but a
--    different unit -- so the version bump refuses it outright rather
--    than loading a spider with the wrong kind of number in her hp.
M.VERSION = 6
M.FILE = "colony"

local function n2(v) return string.format("%.2f", v) end

function M.serialize(s)
  local out = {}
  local function put(...) out[#out + 1] = table.concat({ ... }, " ") end
  put("v", M.VERSION)
  put("seed", s.seed)
  -- THE LEVEL THIS BLOB DESCRIBES, not the one after it (plan 06).
  --
  -- This used to write `s.nextLevelId or s.levelId`, so the instant a
  -- level completed the autosave started naming the NEXT level while
  -- every L/n line below still described the OLD board. On restart,
  -- main.lua built the next level's world from that name and then
  -- deserialize() overlaid the finished level's mounds onto it BY INDEX
  -- -- a different board's ownership, garrisons and queens written into
  -- whatever node happened to sit at the same position in the list. The
  -- seed check cannot catch it (same save, same seed).
  --
  -- Advancing a level was the only thing that trick bought, and
  -- sim/progress.lua owns that now: the beaten set says where the player
  -- has got to, and this line says only what it can honestly say --
  -- which board the numbers underneath belong to.
  put("level", s.levelId or "-")
  put("t", n2(s.time))
  put("rng", s._rngState())

  -- ── the pantry ───────────────────────────────────────────────────────
  --
  -- IN-FLIGHT FOOD IS BANKED ON SAVE. An ant is weather, not history --
  -- carriers are restored as plain garrison counts at their mound, so a
  -- crumb halfway across the field has nowhere to be written down. Adding
  -- it to the pool instead conserves the total, which is the property
  -- that matters; the alternative is food that evaporates when a player
  -- closes the game at the wrong moment.
  do
    local sides, seen = {}, {}
    local function add(x) if x and not seen[x] then seen[x] = true; sides[#sides+1] = x end end
    add("you")
    for i = 1, #s.world.nodes do add(s.world.nodes[i].owner) end
    for i = 1, #s.world.locs do add(s.world.locs[i].owner) end
    for i = 1, #sides do
      local side = sides[i]
      local pool = (s.food and s.food[side]) or 0
      put("food", side, pool + A.carried(s.agents, side))
    end
  end

  -- Every location, by position, with what is left in it and how far
  -- along its regrowth is. A spider's remaining fight is part of the
  -- state too: reloading must not resurrect her, nor kill her early.
  for i = 1, #s.world.locs do
    local l = s.world.locs[i]
    put("L", i, l.owner or "-", l.items or 0, n2(l.regrowT or 0),
        l.guard or 0,
        l.visited and 1 or 0, l.lastSeenItems or -1)
  end

  for i = 1, #s.world.nodes do
    local n = s.world.nodes[i]
    -- Positional identity, stable because the map is generated from the
    -- seed and never reordered.
    -- THE SIDE IS SAVED BY NAME, not as a yes/no flag. The old format
    -- wrote 2 for "somebody else" and restored it as the literal side
    -- "rival", which was harmless while exactly one enemy existed and
    -- silently merges red and gold into one colony now that the war map
    -- fields two. Field 10 carries the name; older saves without it still
    -- load as "rival".
    put("n", i,
        (n.owner == "you") and 1 or (n.owner and 2 or 0),
        n.queens and #n.queens or 0,
        n2(n.growStat or 1), n2(n.rangeStat or 1), n2(n.speedStat or 1),
        n2(n.energy or 0),
        n.seen and 1 or 0,
        A.garrison(s.agents, n.id, "you"),
        n.owner and n.owner ~= "you"
          and A.garrison(s.agents, n.id, n.owner) or 0,
        (n.owner and n.owner ~= "you") and n.owner or "-",
        n.visited and 1 or 0)
  end

  -- ── THE DEAD (plan 05, v6) ────────────────────────────────────────────
  --
  -- A body mid-fade must not silently reset to fully-opaque (or vanish
  -- early) across a save/load -- `t` is the fact that makes the fade
  -- continuous rather than restarting. `seed` travels too: the renderer
  -- must draw the SAME scatter after a reload, never re-roll it, or a
  -- save/load in the middle of a battle would visibly shuffle every
  -- corpse on the ground.
  for i = 1, #s.agents.corpses do
    local c = s.agents.corpses[i]
    put("C", n2(c.x), n2(c.y), c.side, n2(c.t), c.seed, c.at or "-")
  end
  return table.concat(out, "\n")
end

function M.deserialize(s, text)
  if type(text) ~= "string" or #text == 0 then return false, "empty save" end
  local sawVersion = false
  local restored = 0

  -- Clear whatever sim.new spawned; the blob says where everyone lives.
  while s.agents.n > 0 do A.kill(s.agents, s.agents.n) end
  -- Same for corpses (plan 05): a fresh sim starts with none, and the
  -- blob is authoritative on what is currently fading.
  s.agents.corpses = {}

  for line in text:gmatch("([^\n]+)") do
    local f = {}
    for tok in line:gmatch("%S+") do f[#f + 1] = tok end
    local k = f[1]
    if k == "v" then
      sawVersion = true
      if tonumber(f[2]) ~= M.VERSION then
        return false, "save version " .. tostring(f[2])
      end
    elseif k == "seed" then
      if tonumber(f[2]) ~= s.seed then
        return false, "save is for another map"
      end
    elseif k == "level" then
      -- Read by peekLevel before the world is built.
    elseif k == "t" then
      s.time = tonumber(f[2]) or 0
    elseif k == "rng" then
      local st = tonumber(f[2])
      if st and st > 0 then s._setRng(st) end
    elseif k == "food" then
      s.food = s.food or {}
      s.food[f[2]] = tonumber(f[3]) or 0
    elseif k == "L" then
      local i = tonumber(f[2])
      local l = i and s.world.locs[i]
      if l then
        local own = f[3]
        l.owner = (own and own ~= "-" and own ~= "") and own or nil
        l.items = tonumber(f[4]) or 0
        l.regrowT = tonumber(f[5]) or 0
        l.guard = tonumber(f[6]) or 0
        -- BACKFILL FOR PRE-v5 SAVES: a location you own is one you have
        -- certainly stood on (claiming requires arriving), so it loads as
        -- visited. Everything else re-earns its discovery, which is the
        -- least-wrong direction to be wrong in -- it gives knowledge back
        -- rather than inventing it.
        if f[7] ~= nil then
          l.visited = f[7] == "1"
          local ls = tonumber(f[8])
          l.lastSeenItems = (ls and ls >= 0) and ls or nil
        else
          l.visited = l.owner == "you"
          l.lastSeenItems = l.visited and l.items or nil
        end
      end
    elseif k == "n" then
      local i = tonumber(f[2])
      local nd = i and s.world.nodes[i]
      if nd then
        local own = tonumber(f[3]) or 0
        -- Field 12 is the side's NAME. Absent (an older save) it falls
        -- back to "rival", which is what that format meant.
        local foe = f[12]
        if not foe or foe == "-" or foe == "" then foe = "rival" end
        nd.owner = (own == 1) and "you" or (own == 2) and foe or nil
        nd.queens = {}
        for _ = 1, tonumber(f[4]) or 0 do
          nd.queens[#nd.queens + 1] = A.newQueen()
        end
        nd.growStat  = tonumber(f[5]) or 1
        nd.rangeStat = tonumber(f[6]) or 1
        nd.speedStat = tonumber(f[7]) or 1
        nd.energy    = tonumber(f[8]) or nd.maxEnergy
        nd.seen      = f[9] == "1"
        nd.brood = {}
        for _ = 1, tonumber(f[10]) or 0 do A.spawn(s.agents, nd.id, "you") end
        -- Enemy ants belong to the side that holds the ground, so a
        -- reloaded war map still has red and gold rather than one merged
        -- colony wearing both their mounds.
        for _ = 1, tonumber(f[11]) or 0 do A.spawn(s.agents, nd.id, foe) end
        -- Field 13: what you have LEARNED about this mound. Same
        -- backfill rule as a location's -- ground you own is ground you
        -- have stood on, and everything else re-earns its discovery.
        if f[13] ~= nil then
          nd.visited = f[13] == "1"
        else
          nd.visited = nd.owner == "you"
        end
        restored = restored + 1
      end
    elseif k == "C" then
      -- x y side t seed at. `at` restores as-is even though its mound may
      -- no longer be mixed by the time the game resumes -- a corpse does
      -- not depend on the fight that produced it still being live, only
      -- on its own fade clock.
      local at = f[7]
      s.agents.corpses[#s.agents.corpses + 1] = {
        x = tonumber(f[2]) or 0, y = tonumber(f[3]) or 0,
        side = f[4], t = tonumber(f[5]) or 0,
        seed = tonumber(f[6]) or 0,
        at = (at and at ~= "-") and at or nil,
      }
    end
  end

  if not sawVersion then return false, "no version record" end
  return true, string.format("restored %d mounds, %d ants",
                             restored, s.agents.n)
end

function M.peekLevel(text)
  if type(text) ~= "string" then return nil end
  local v = text:match("\nlevel (%S+)") or text:match("^level (%S+)")
  if not v or v == "-" then return nil end
  return v
end

function M.peekSeed(text)
  if type(text) ~= "string" then return nil end
  local v = text:match("\nseed (%d+)") or text:match("^seed (%d+)")
  return v and tonumber(v) or nil
end

function M.write(s)
  local text = M.serialize(s)
  -- CARRY THE PROGRESS LINES THROUGH (plan 06). There is ONE save blob,
  -- not a filesystem (see sim/progress.lua's header), so writing the
  -- colony without re-emitting the `p` lines would silently erase which
  -- levels the player has beaten on the very next autosave -- 30 seconds
  -- into any session.
  local progress = require("sim.progress")
  text = progress.serialize() .. "\n" .. text
  local ok, err = pcall(love.filesystem.write, nil, text)
  if not ok then
    print("@save FAILED " .. tostring(err))
    return false
  end
  print(string.format("@save wrote %d bytes", #text))
  return true, #text
end

function M.read()
  local ok, data = pcall(function()
    if love.filesystem.load_save then return love.filesystem.load_save() end
    return love.filesystem.read(M.FILE)
  end)
  if not ok or type(data) ~= "string" or #data == 0 then return nil end
  return data
end

return M
