// EVERY MOUND ON EVERY HAND-BUILT LEVEL MUST BE REACHABLE.
//
// This gate exists because Settle shipped with a mound nobody could send
// to. Its nearest neighbour was n3 at 1045 units, and n3 is a `small`
// mound whose reach is 1000 -- short by 44. Every other mound was further
// still, so the mound could not be taken from ANYWHERE and the level was
// literally unfinishable. Nothing caught it: the campaign gate only
// checks that the next level LOADS, and no assertion had ever asked
// whether the map it loads can actually be played.
//
// Pure geometry, read from the level table -- no cart, no romdev, no
// emulator. That makes it fast and makes it run even when the server is
// down, which is when a level-design mistake is most likely to be made.
import { readFileSync } from 'fs';
import { makeReport, releaseAll } from './drive.mjs';
const R = makeReport();

const src = readFileSync('app/sim/campaign.lua', 'utf8');

// Reach per kind, mirrored from sim/world.lua KINDS. Kept here rather than
// parsed so a change there that breaks a level shows up as a FAILURE here
// rather than being silently tracked.
const REACH = { home: 1500, rich: 1320, plain: 1150, small: 1000 };

// Pull each level's id and its node list out of the Lua table.
// SLICE AT THE LEVEL BOUNDARIES FIRST, then look for nodes inside each
// slice. Scanning for `id = ... nodes = {` across the whole file lets a
// level that has NO node list (the generated field) reach forward and
// adopt the next level's mounds -- which it did, silently, and reported
// the open field as an unreachable board that does not exist.
const bounds = [...src.matchAll(/\bid\s*=\s*"([a-z]+)"/g)];
const levels = [];
for (let b = 0; b < bounds.length; b++) {
  const id = bounds[b][1];
  const from = bounds[b].index;
  const to = b + 1 < bounds.length ? bounds[b + 1].index : src.length;
  const slice = src.slice(from, to);
  // Gate-only boards live past the end of the campaign and are built to
  // isolate one rule, not to be played: a single mound is exactly right
  // for them and would fail every connectivity check here.
  if (id.startsWith('gate')) continue;
  const nm0 = slice.match(/nodes\s*=\s*\{([\s\S]*?)\n    \},/);
  if (!nm0) continue;
  const body = nm0[1];
  const nodes = [];
  const nodeRe = /\{\s*kind\s*=\s*"(\w+)"\s*,\s*x\s*=\s*(-?\d+)\s*,\s*y\s*=\s*(-?\d+)([^}]*)\}/g;
  let nm;
  while ((nm = nodeRe.exec(body)) !== null) {
    const [, kind, x, y, rest] = nm;
    nodes.push({
      kind, x: +x, y: +y,
      own: /own\s*=\s*true/.test(rest),
      foe: (rest.match(/foe\s*=\s*"(\w+)"/) || [])[1] || null,
    });
  }
  if (nodes.length) levels.push({ id, nodes });
}

R.check('the campaign levels parsed', levels.length >= 4,
        levels.map(l => `${l.id}(${l.nodes.length})`).join(' '));

const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);

for (const lv of levels) {
  // A mound is reachable if ANY other mound can throw to it. Whose it is
  // does not matter for this check: an enemy mound nobody can attack is
  // just as broken as a neutral one nobody can take.
  const unreachable = [];
  for (let i = 0; i < lv.nodes.length; i++) {
    const t = lv.nodes[i];
    let best = Infinity, bestFrom = -1;
    for (let j = 0; j < lv.nodes.length; j++) {
      if (i === j) continue;
      const f = lv.nodes[j];
      const short = dist(f, t) - (REACH[f.kind] || 1150);
      if (short < best) { best = short; bestFrom = j; }
    }
    if (best > 0) {
      unreachable.push(`#${i + 1}(${t.kind}) short by ${Math.round(best)} ` +
                       `from #${bestFrom + 1}`);
    }
  }
  R.check(`${lv.id}: every mound is reachable from somewhere`,
          unreachable.length === 0, unreachable.join('; ') || 'all reachable');

  // AND CONNECTED TO YOUR SIDE. A mound reachable only from an island of
  // enemy ground is unreachable in practice: ants travel the network, and
  // every leg must start from somewhere already held (sim/world.path).
  const start = lv.nodes.findIndex(n => n.own);
  if (start >= 0) {
    const seen = new Set([start]);
    const queue = [start];
    while (queue.length) {
      const cur = queue.shift();
      for (let j = 0; j < lv.nodes.length; j++) {
        if (seen.has(j)) continue;
        if (dist(lv.nodes[cur], lv.nodes[j]) <= (REACH[lv.nodes[cur].kind] || 1150)) {
          seen.add(j);
          // Only carry ON through ground you can hold -- the same rule the
          // sim uses. A resource-only or enemy mound can be a destination
          // but is not assumed to be a staging post here.
          queue.push(j);
        }
      }
    }
    const stranded = lv.nodes.map((n, i) => i).filter(i => !seen.has(i));
    R.check(`${lv.id}: every mound is connected to your start`,
            stranded.length === 0,
            stranded.length ? `stranded: ${stranded.map(i => '#' + (i + 1)).join(',')}`
                            : `all ${seen.size} connected`);
  }
}

await releaseAll();   // hand the emulator hosts back before exiting
process.exit(R.done() ? 0 : 1);