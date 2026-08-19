-- progress.lua - which levels have been beaten, and nothing else.
--
-- THERE IS ONE SAVE REGION, NOT A FILESYSTEM. wasmcart-lua gives a cart a
-- single 4KB blob: `love.filesystem.write(nil, text)` replaces it and
-- `love.filesystem.load_save()` reads it back. `love.filesystem.write`
-- with a NAME does not persist anything -- reads come from the cart's
-- bundled (read-only) assets. This plan's first attempt put progress in
-- its own named file and it silently evaporated on every reload: the
-- write appeared to succeed, `@progress beaten gather` printed, and the
-- next boot read `beaten=0`.
--
-- So progress shares the blob with the colony, and the whole design
-- problem is keeping it ALIVE when the colony half is thrown away.
-- sim/save.lua is version-gated all-or-nothing: a format bump (v5 -> v6
-- did, v7 will) REJECTS the entire blob and starts fresh. That is right
-- for colony state -- a half-understood board is worse than a new one --
-- and exactly wrong for "which levels have I finished".
--
-- THE SPLIT: progress owns the lines beginning `p `, and reads them
-- itself, straight off the raw blob, BEFORE and INDEPENDENTLY of anything
-- save.lua thinks about the rest. A `p` line has no fields whose meaning
-- can shift the way save.lua's `guard`-became-`hp` column did -- it is a
-- set of level names -- so it is never worth refusing. save.lua then
-- re-emits whatever `p` lines it found when it rewrites the blob, so the
-- two halves survive each other.
--
-- What this deliberately does NOT store: any game state. Luis, 2026-08-19
-- -- "we don't necessarily need to save the game state, but at least know
-- which levels we already beaten so we can go onto the next level."
-- Picking a beaten level from the select screen starts it FRESH; only the
-- one autosaved colony (sim/save.lua) is ever resumed.

local M = {}

M.VERSION = 1

-- The beaten set, as a map. Loaded once at boot, written on every change.
M.beaten = {}

-- The `p` lines this module owns, as text. Appended to whatever else is
-- in the blob by save.lua's writer.
function M.serialize()
  local ids = {}
  for id in pairs(M.beaten) do ids[#ids + 1] = id end
  -- SORTED, so the blob is stable across runs. An unsorted pairs() walk
  -- would rewrite the same set in a different order every save, which
  -- makes the blob useless for telling whether anything actually changed.
  table.sort(ids)
  return "p v " .. M.VERSION .. "\np beaten " .. table.concat(ids, " ")
end

-- Read the `p` lines out of a RAW blob, ignoring everything else in it.
-- Never fails on an unknown version: the file is a set of names, and
-- refusing to read a newer one would throw away real progress for no
-- safety (contrast save.lua, where a column can change units).
function M.deserialize(text)
  if type(text) ~= "string" or #text == 0 then return false end
  local seen, found = {}, false
  for line in text:gmatch("([^\n]+)") do
    local k, rest = line:match("^p%s+(%S+)%s*(.*)$")
    if k == "v" then
      found = true
    elseif k == "beaten" then
      found = true
      for id in rest:gmatch("%S+") do seen[id] = true end
    end
  end
  if not found then return false end
  M.beaten = seen
  return true
end

function M.isBeaten(id) return M.beaten[id] == true end

function M.readBlob()
  local ok, data = pcall(function()
    if love.filesystem.load_save then return love.filesystem.load_save() end
    return nil
  end)
  if not ok or type(data) ~= "string" or #data == 0 then return nil end
  return data
end

-- WRITING PROGRESS ALONE MUST NOT DESTROY THE COLONY. There is one blob,
-- so a naive write of just the `p` lines would wipe the saved game. The
-- colony's own lines are read back out of the existing blob and
-- re-emitted underneath the new progress lines.
function M.write()
  local blob = M.readBlob()
  local rest = {}
  if blob then
    for line in blob:gmatch("([^\n]+)") do
      if not line:match("^p%s") then rest[#rest + 1] = line end
    end
  end
  local text = M.serialize()
  if #rest > 0 then text = text .. "\n" .. table.concat(rest, "\n") end
  local ok, err = pcall(love.filesystem.write, nil, text)
  if not ok then
    print("@progress FAILED " .. tostring(err))
    return false
  end
  return true
end

-- MERGE, NEVER OVERWRITE. Replaying an old level and finishing it again
-- must not un-beat anything later, and a cart that started before another
-- one wrote must not clobber it: the blob is re-read and the new id added
-- to whatever is already recorded there.
function M.markBeaten(id)
  if not id then return false end
  local blob = M.readBlob()
  if blob then
    local keep = M.beaten
    M.deserialize(blob)
    for k in pairs(keep) do M.beaten[k] = true end
  end
  if M.beaten[id] then return false end     -- already recorded
  M.beaten[id] = true
  M.write()
  print("@progress beaten " .. tostring(id))
  return true
end

function M.load()
  -- GATE INSTRUMENT: a `noprogress` marker packed into the cart wipes the
  -- beaten set at boot. test-progress needs the first-boot path (nothing
  -- beaten, no select screen) to be reachable on a cart a previous run
  -- may have written progress into -- and unlike the SELECT+button
  -- instruments, this has to act BEFORE the first frame, which no button
  -- press can do. Same mechanism as `startlevel`: written where the cart
  -- is PACKED, so only a harness can set it.
  if love.filesystem.getInfo and love.filesystem.getInfo("noprogress") then
    M.beaten = {}
    M.write()
    print("@progress cleared by marker")
    return M.beaten
  end
  local blob = M.readBlob()
  if blob then M.deserialize(blob) else M.beaten = {} end
  local n = 0
  for _ in pairs(M.beaten) do n = n + 1 end
  print("@progress loaded beaten=" .. n)
  return M.beaten
end

-- Gate instrument: wipe the beaten set in memory and on the blob.
function M.clear()
  M.beaten = {}
  M.write()
end

return M
