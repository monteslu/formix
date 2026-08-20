// NO TWO CIRCLES ON A HAND-BUILT LEVEL MAY OVERLAP.
//
// This gate exists because Gather shipped with an aphid cluster at
// (880, 300) and the rich mound at (1024, 400) only 175 units apart --
// their radii (74 and 104) sum to 178, so the two circles overlapped by
// about 3 units. Small in world-space, but visually real: the mound's
// earth fill and grit spill draw well past its bare radius, so the
// aphid sprites sat partly on top of the hill instead of beside it.
// Reported directly from play ("aphids overlapping a large mound").
//
// Every hand-authored level (gate-only boards included -- a broken gate
// board is still a broken board even though it skips the reachability
// gate) is checked three ways: mound-vs-mound, mound-vs-location, and
// location-vs-location. The procedurally generated `open` field is NOT
// checked here -- it already enforces its own, more generous spacing at
// scatter time (sim/init.lua: locations clear radius*3.2 from every
// mound and 520 units from every other location) and has no fixed
// coordinates to check against.
//
// Pure geometry, read from the level table -- no cart, no romdev, no
// emulator, so this runs even when the server is down, which is when a
// level-design mistake is most likely to be made.
import { readFileSync } from 'fs';
import { makeReport, releaseAll } from './drive.mjs';
const R = makeReport();

const src = readFileSync('app/sim/campaign.lua', 'utf8');

// Mirrored from sim/world.lua KINDS / LKINDS. Kept here rather than
// parsed so a radius change there that creates a NEW overlap shows up as
// a FAILURE here instead of silently drawing two circles on top of each
// other.
const NODE_R = { home: 118, rich: 104, plain: 78, small: 56 };
const LOC_R = { aphids: 74, grain: 80, spider: 96 };

const bounds = [...src.matchAll(/\bid\s*=\s*"([a-z]+)"/g)];
const levels = [];
for (let b = 0; b < bounds.length; b++) {
  const id = bounds[b][1];
  const from = bounds[b].index;
  const to = b + 1 < bounds.length ? bounds[b + 1].index : src.length;
  const slice = src.slice(from, to);

  const circles = [];
  const nm0 = slice.match(/nodes\s*=\s*\{([\s\S]*?)\n    \},/);
  if (nm0) {
    const nodeRe = /\{\s*kind\s*=\s*"(\w+)"\s*,\s*x\s*=\s*(-?\d+)\s*,\s*y\s*=\s*(-?\d+)/g;
    let nm;
    while ((nm = nodeRe.exec(nm0[1])) !== null) {
      const [, kind, x, y] = nm;
      const r = NODE_R[kind];
      if (r) circles.push({ label: `mound(${kind})`, x: +x, y: +y, r });
    }
  }
  const lm0 = slice.match(/locations\s*=\s*\{([\s\S]*?)\n    \},/);
  if (lm0) {
    const locRe = /\{\s*kind\s*=\s*"(\w+)"\s*,\s*x\s*=\s*(-?\d+)\s*,\s*y\s*=\s*(-?\d+)/g;
    let lm;
    while ((lm = locRe.exec(lm0[1])) !== null) {
      const [, kind, x, y] = lm;
      const r = LOC_R[kind];
      if (r) circles.push({ label: `loc(${kind})`, x: +x, y: +y, r });
    }
  }
  if (circles.length) levels.push({ id, circles });
}

R.check('the campaign levels parsed', levels.length >= 4,
        levels.map(l => `${l.id}(${l.circles.length})`).join(' '));

for (const lv of levels) {
  const overlaps = [];
  for (let i = 0; i < lv.circles.length; i++) {
    for (let j = i + 1; j < lv.circles.length; j++) {
      const a = lv.circles[i], b = lv.circles[j];
      const d = Math.hypot(a.x - b.x, a.y - b.y);
      const slack = a.r + b.r - d;
      if (slack > 0) {
        overlaps.push(`${a.label}@(${a.x},${a.y}) x ${b.label}@(${b.x},${b.y}) ` +
                       `overlap ${Math.round(slack)}`);
      }
    }
  }
  R.check(`${lv.id}: no two circles overlap`, overlaps.length === 0,
          overlaps.join('; ') || 'clear');
}

await releaseAll();   // hand the emulator hosts back before exiting
process.exit(R.done() ? 0 : 1);