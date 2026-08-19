// THREE FOG STATES, AND NOTHING LEAKS ACROSS THEM.
//
// The rule (internal-formix/04-fog.md):
//
//   PRESENT     your ants are here, or your assault is inbound, or it is
//               your queened colony. Full colour, full information.
//   DISCOVERED  you stood here once, nobody friendly is here now. You
//               keep the IDENTITY -- kind and real size -- rendered grey.
//               No owner, no enemies, no live counts.
//   UNKNOWN     never visited. One medium-grey circle, the SAME circle
//               for every site. Position only.
//
// This gate exists because the game had almost no discovery left: a
// queened colony set `observed` on every neighbour every tick, so kinds,
// item counts and enemy bodies were free from across the board, and every
// site was drawn at its true radius -- so a spider announced itself as
// the biggest circle on the map without anyone walking to it.
//
// Written to FAIL. Each check below has a control or an inverse: if the
// latch stops latching, if the disc starts varying with kind, or if
// adjacency observation comes back, exactly one of these goes red.
import { api, driver, makeReport } from './drive.mjs';
import { execSync } from 'child_process';
import { writeFileSync, unlinkSync, existsSync, copyFileSync } from 'fs';
import { readPNG } from './png.mjs';

const SHOT = process.cwd() + '/test/shots/fog3.png';
const SHOT2 = process.cwd() + '/test/shots/fog3-discover.png';

const t = api('formix-fog3-suite');
const R = makeReport();

const d = driver(t, process.cwd() + '/formix.wasc');
await d.boot(7);

let r = await d.inspect();

// ── PHASE 1: the visited latch ────────────────────────────────────────
//
// `visited` must be set by STANDING somewhere and must survive leaving.
// The inverse matters just as much: a site nobody has walked on must
// report false, or the latch is just "true everywhere" and proves
// nothing.
const home = r.mound.n1;
R.check('your own starting mound counts as visited',
        home && home.visited === true,
        home ? `n1 visited=${home.visited}` : 'no n1');

const unvisited = Object.entries(r.mound)
  .filter(([k, v]) => !v.visited).map(([k]) => k);
R.check('CONTROL: mounds nobody has stood on report unvisited',
        unvisited.length > 0, `unvisited: ${unvisited.join(',') || 'NONE'}`);

// Walk onto a neighbour, then walk off it again.
const target = unvisited.find(k => r.pos[k]);
await d.send(r.pos.n1, r.pos[target]);
await d.step(900);
r = await d.inspect();
R.check('standing on a mound marks it visited',
        r.mound[target] && r.mound[target].visited === true,
        `${target} visited=${r.mound[target] && r.mound[target].visited}`);

// Send them home again; the memory must not go with them.
await d.send(r.pos[target], r.pos.n1);
await d.step(1200);
r = await d.inspect();
R.check('and it STAYS visited after the ants leave',
        r.mound[target] && r.mound[target].visited === true,
        `${target} visited=${r.mound[target] && r.mound[target].visited} ` +
        `held=${r.mound[target] && r.mound[target].held}`);
R.check('...while the ground itself goes back to unheld (test-grey rule)',
        r.mound[target] && r.mound[target].held === false,
        `${target} held=${r.mound[target] && r.mound[target].held}`);

// ── PHASE 2: the latch survives a save round trip ─────────────────────
//
// `visited` is not derivable from anything else in the blob -- ownership
// says where you are NOW, never where you have been -- so if it is not
// written down it is lost, and a reloaded colony forgets every patch it
// ever scouted.
//
// NOT TESTED BY REBOOTING THE CART. romdev hands every loadMedia a fresh
// save sandbox, so a reloaded cart always starts new: an assertion built
// on that measures the harness, not the format, and it passed for the
// wrong reason before this note existed. SELECT+A runs serialize ->
// deserialize against the LIVE sim instead, which is the pair of
// functions that can actually drop a field.
const beforeVisited = Object.entries(r.mound)
  .filter(([, v]) => v.visited).map(([k]) => k).sort();
const beforeUnvisited = Object.entries(r.mound)
  .filter(([, v]) => !v.visited).map(([k]) => k).sort();
R.check('the board has both visited and unvisited mounds to compare',
        beforeVisited.length > 0 && beforeUnvisited.length > 0,
        `visited=[${beforeVisited}] unvisited=[${beforeUnvisited}]`);

await d.press('select');                 // overlay on (roundtrip is gated)
await d.hold(['select', 'a']);
await d.step(30);
const rt = d.all().filter(l => l.startsWith('@roundtrip')).pop();
R.check('the save round trip ran and was accepted',
        rt && /ok=true/.test(rt), rt || 'no @roundtrip line');
await d.press('select');                 // overlay off again

r = await d.inspect();
const afterVisited = Object.entries(r.mound)
  .filter(([, v]) => v.visited).map(([k]) => k).sort();
const afterUnvisited = Object.entries(r.mound)
  .filter(([, v]) => !v.visited).map(([k]) => k).sort();
R.check('visited mounds are still visited after the round trip',
        beforeVisited.every(k => afterVisited.includes(k)),
        `before=[${beforeVisited}] after=[${afterVisited}]`);
R.check('CONTROL: unvisited mounds did NOT become visited',
        beforeUnvisited.every(k => afterUnvisited.includes(k)),
        `before=[${beforeUnvisited}] after=[${afterUnvisited}]`);

// ── PHASE 4: every unknown site is the SAME circle ────────────────────
//
// The claim: a mound and a patch of food that have never been visited
// must be indistinguishable. Not "similar" -- identical. Any per-site
// variation is a channel, and a player who learns the tell reads the
// board through it, which is why the old seeded ring wobble went too.
//
// Measured radially off the real frame: the drawn extent and the centre
// brightness of an unvisited MOUND and an unvisited LOCATION.

// Radial profile: mean brightness per ring, out to where it meets the
// background. Sampling a ring rather than a scanline keeps one stray
// overlay line (the reach circle, the minimap) from deciding the answer.
function mk(px, lum) {
function profile(cx, cy) {
  const prof = [];
  for (let rad = 0; rad < 80; rad++) {
    let sum = 0, n = 0;
    for (let k = 0; k < 48; k++) {
      const a = (k / 48) * 6.28318;
      const x = Math.round(cx + Math.cos(a) * rad);
      const y = Math.round(cy + Math.sin(a) * rad);
      if (x >= 0 && x < px.w && y >= 0 && y < px.h) { sum += lum(x, y); n++; }
    }
    prof.push(n ? sum / n : 0);
  }
  return prof;
}
// THE DISC'S OWN EDGE, not the last bright thing on the ray.
//
// A first version took the OUTERMOST radius brighter than background,
// which is wrong on this map: home's reach ring is a faint circle drawn
// hundreds of units out, so whichever site happened to have it crossing
// nearby measured as twice the size of one that did not. The two discs
// were identical the whole time (74.0, 66, 59, 51 at matching radii) and
// the gate still went red -- a probe disagreeing with a correct game.
//
// The disc is a solid bright core that falls to background ONCE. Walk
// out from the centre and stop at the first crossing; anything past that
// belongs to something else.
function extent(cx, cy) {
  const prof = profile(cx, cy);
  const bg = Math.min(...prof);
  const floor = bg + (prof[0] - bg) * 0.25;
  let e = 0;
  while (e < prof.length && prof[e] > floor) e++;
  return { edge: e, centre: prof[0] };
}
return extent;
}

// MEASURED ON DISCOVER, not on Gather, and that choice is the gate.
//
// Gather's only food is aphids (radius 74), which is close enough to the
// shared unknown radius (70) that a leak there measures as 29px vs 31px
// -- inside any sane tolerance. A control that reintroduced kind-based
// sizing PASSED against Gather, which makes the assertion decorative.
//
// Discover fields a spider (96) alongside `small` mounds (56): a 40-unit
// spread, ~17px on screen at the default zoom. If sizing ever leaks
// again, THAT is the pair that shows it -- and the spider is the thing
// the fog most needs to hide anyway.
const CART = process.cwd() + '/test/discover-cart.wasc';
writeFileSync('app/startlevel', 'discover');
try {
  execSync('./build.sh', { stdio: 'ignore' });
  copyFileSync(process.cwd() + '/formix.wasc', CART);
} finally {
  if (existsSync('app/startlevel')) unlinkSync('app/startlevel');
  // AND PUT `formix.wasc` BACK, always. The build above overwrites the
  // ordinary cart in place with a discover-locked one, and leaving it
  // there poisons every gate that runs afterwards -- and the next manual
  // run, and the next romdev session, all of which boot discover while
  // believing they booted gather. It cost a green run to find that: this
  // gate passed, then failed on a rerun with "cart booted discover, this
  // gate expects gather", because its own previous run had left the
  // wreckage. The copy above is what the gate actually drives; the
  // rebuild here is housekeeping for everyone else.
  execSync('./build.sh', { stdio: 'ignore' });
}
const dd = driver(t, CART);
await dd.boot(7, { level: 'discover' });
const rr = await dd.inspect();
await dd.shot(SHOT2);

const px2 = readPNG(SHOT2);
const lum2 = (x, y) => { const [a, b, c] = px2.at(x, y);
                         return 0.2126 * a + 0.7152 * b + 0.0722 * c; };
const extent2 = mk(px2, lum2);

const clear = ([x, y]) => x > 520 && x < 1440 && y > 120 && y < 760;
const unvisMounds = Object.entries(rr.mound)
  .filter(([k, v]) => !v.visited && rr.pos[k] && clear(rr.pos[k])).map(([k]) => k);
const locIds = Object.keys(rr.pos)
  .filter(k => k.startsWith('L') && clear(rr.pos[k]));

R.check('discover offers unvisited mounds and locations to compare',
        unvisMounds.length > 0 && locIds.length > 0,
        `mounds=[${unvisMounds}] locs=[${locIds}]`);

// EVERY unvisited circle on the board, mound and location alike, must
// measure the same. One pair could agree by luck; the whole set cannot.
const all = [...unvisMounds.map(k => ({ id: k, e: extent2(...rr.pos[k]) })),
             ...locIds.map(k => ({ id: k, e: extent2(...rr.pos[k]) }))];
const edges = all.map(a => a.e.edge);
const spread = Math.max(...edges) - Math.min(...edges);
R.check('EVERY unvisited site is the same size, mound or food',
        spread <= 1,
        all.map(a => `${a.id}=${a.e.edge}px`).join(' ') + ` spread=${spread}`);
const centres = all.map(a => a.e.centre);
R.check('...and the same brightness at the centre',
        Math.max(...centres) - Math.min(...centres) <= 1.5,
        all.map(a => `${a.id}=${a.e.centre.toFixed(1)}`).join(' '));

// ── PHASE 5a: a discovered patch is REMEMBERED, not watched ──────────
//
// Walking onto a grain patch buys its identity for good. Walking away
// must NOT take that back -- and must NOT leave a live feed running
// either: a patch you are nowhere near cannot keep telling you it is
// regrowing, because that is somebody else's ground reporting to you.
//
// Driven on discover, which fields two grain patches west of home,
// inside the opening reach.
let rl = await dd.inspect();
const grainId = Object.entries(rl.loc)
  .filter(([k, v]) => v.kind === 'grain' && !v.visited)
  .map(([k]) => k)[0];
R.check('CONTROL: a grain patch starts unvisited and anonymous',
        !!grainId && rl.loc[grainId].visited === false &&
        rl.loc[grainId].lastSeen === -1,
        grainId ? `${grainId} visited=${rl.loc[grainId].visited} ` +
                  `lastseen=${rl.loc[grainId].lastSeen}` : 'no unvisited grain');

// Find the home mound and walk a column onto the grain.
const homeId = Object.entries(rl.mound)
  .filter(([, v]) => v.owner === 'you' && v.queens > 0).map(([k]) => k)[0];
await dd.send(rl.pos[homeId], rl.pos[grainId]);
await dd.step(1400);
rl = await dd.inspect();
const onIt = rl.loc[grainId];
R.check('standing on a patch marks it visited and latches what was there',
        onIt && onIt.visited === true && onIt.lastSeen >= 0,
        onIt ? `visited=${onIt.visited} observed=${onIt.observed} ` +
               `items=${onIt.items} lastseen=${onIt.lastSeen}` : 'no @loc');
const latched = onIt ? onIt.lastSeen : -1;

// A SPENT PATCH UNDER YOUR FEET IS NOT A HOLLOW RING.
//
// From the manual pass, and invisible to every sim-state assertion: the
// item art IS the drawing of a location, so a patch you had just picked
// clean rendered as a bare outline with NOTHING inside it -- your ants
// working an empty circle, the identity you walked over to earn gone
// from the screen at the moment you earned it. The stubble treatment
// existed but was gated on ABSENCE, so it fixed the remembered case and
// left the present one blank.
//
// Checked HERE rather than at the end of the run: a column is already
// standing on this patch, and by the closing phases the board is deep in
// a war where the colony may hold nothing within reach of any food.
if (onIt && (onIt.items || 0) === 0 && onIt.observed) {
  const SHOT5 = process.cwd() + '/test/shots/fog3-spent.png';
  await dd.shot(SHOT5);
  const [px, py] = rl.pos[grainId];
  // Ink STRICTLY INSIDE, so the ring itself is not what is counted --
  // the bug was a ring with nothing in it, and a test that accepted the
  // ring would have passed on the broken build.
  const im = readPNG(SHOT5);
  let br = 0, bn = 0;
  for (let k = 0; k < 64; k++) {
    const a = (k / 64) * 6.28318;
    const x = Math.round(px + Math.cos(a) * 44), y = Math.round(py + Math.sin(a) * 44);
    if (x < 0 || y < 0 || x >= im.w || y >= im.h) continue;
    const [r, g, b] = im.at(x, y); br += (r + g + b) / 3; bn++;
  }
  const bg = bn ? br / bn : 0;
  let ink = 0;
  for (let dy = -20; dy <= 20; dy++) {
    for (let dx = -20; dx <= 20; dx++) {
      if (dx * dx + dy * dy > 400) continue;
      const x = px + dx, y = py + dy;
      if (x < 0 || y < 0 || x >= im.w || y >= im.h) continue;
      const [r, g, b] = im.at(x, y);
      if (Math.abs((r + g + b) / 3 - bg) > 14) ink++;
    }
  }
  // THE THRESHOLD IS CALIBRATED, NOT GUESSED. The stubble is six small
  // discs at 5.5% of the patch radius, so a correct render puts a few
  // dozen pixels of ink inside the sampling circle -- measured at 33 on
  // the fixed build, and 0 on the hollow-ring bug this is here to catch
  // (nothing is drawn inside the ring at all, so the interior IS the
  // background). A first pass at `> 40` was set above what a handful of
  // dots can produce and failed a build whose render was correct: the
  // gap being asserted on is 0-vs-33, and the line belongs in it.
  R.check('a spent patch underfoot shows stubble, not a hollow ring',
          ink >= 15, `${ink} px of ink inside ${grainId} (items=0, observed)`);
} else {
  R.check('the visited patch was picked clean, so the stubble can be judged',
          false,
          `items=${onIt && onIt.items} observed=${onIt && onIt.observed} ` +
          `-- not stripped, stubble check did not run`);
}

// Walk them home again. The memory stays; the live channel closes.
await dd.send(rl.pos[grainId], rl.pos[homeId]);
await dd.step(1600);
rl = await dd.inspect();
const gone = rl.loc[grainId];
R.check('the identity SURVIVES leaving (state 2, not back to unknown)',
        gone && gone.visited === true, `visited=${gone && gone.visited}`);
R.check('...but presence does not: `observed` closes when they walk off',
        gone && gone.observed === false && gone.held === false,
        `observed=${gone && gone.observed} held=${gone && gone.held}`);
// FOOD IS TERRAIN AND STAYS READABLE; WHO IS ON IT DOES NOT.
//
// This replaces an assertion that required the opposite -- that a patch
// you walked away from showed the count you LAST SAW rather than the live
// one. That rule was wrong in play: it turned a patch you had already
// scouted back into a reason to walk over and re-read a number, which is
// busywork rather than fog. A field you have found is a field whose crop
// you can see standing in it, and watching grain come back is information
// scouting earned.
//
// The half that still hides is the OCCUPANCY, and phase 5c below gates
// that with a spider.
// Grain regrows. Stand well clear of it and let it: if the count the
// player is SHOWN is live, the crop must visibly grow back on screen
// while nobody is there.
//
// MEASURED IN PIXELS, NOT FROM THE PROBE. A first version compared
// `items` across two inspects and passed under a deliberate sabotage that
// reverted the renderer to the stale latched count -- because `items` is
// the SIM's number, and the sim was never the broken half. The bug being
// guarded against is a renderer that draws a remembered count while the
// sim's real one moves underneath it, and only the screen can tell those
// apart.
const beforeRegrow = gone ? gone.items : -1;
const cropInk = (path, cx, cy, rad) => {
  const im = readPNG(path);
  // Stalks are the yellow-gold ears; the plot under them is dark brown
  // and the grass around it dark green, so a warm-bright test isolates
  // the crop from the field it stands in.
  let n = 0;
  for (let dy = -rad; dy <= rad; dy++) {
    for (let dx = -rad; dx <= rad; dx++) {
      if (dx * dx + dy * dy > rad * rad) continue;
      const x = cx + dx, y = cy + dy;
      if (x < 0 || y < 0 || x >= im.w || y >= im.h) continue;
      const [r, g, b] = im.at(x, y);
      if (r > 110 && g > 95 && b < g * 0.72) n++;
    }
  }
  return n;
};
const EARLY = process.cwd() + '/test/shots/fog3-regrow-early.png';
const LATER = process.cwd() + '/test/shots/fog3-regrow-later.png';
await dd.shot(EARLY);
let rr0 = await dd.inspect();
const inkEarly = cropInk(EARLY, rr0.pos[grainId][0], rr0.pos[grainId][1], 46);

let regrown = null;
for (let i = 0; i < 12 && regrown === null; i++) {
  await dd.step(600);
  const st = await dd.inspect();
  if (st.loc[grainId] && st.loc[grainId].items > beforeRegrow + 1) regrown = st;
}
R.check('the sim regrew the patch while nobody was standing on it',
        regrown !== null,
        regrown ? `items ${beforeRegrow} -> ${regrown.loc[grainId].items}`
                : `items stuck at ${beforeRegrow} over 7200 frames`);
if (regrown) {
  await dd.shot(LATER);
  const inkLater = cropInk(LATER, regrown.pos[grainId][0], regrown.pos[grainId][1], 46);
  R.check('...and the SCREEN shows the new crop (the count is live, not remembered)',
          inkLater > inkEarly,
          `crop ink ${inkEarly} -> ${inkLater} px while ` +
          `observed=${regrown.loc[grainId].observed} ` +
          `(sim items ${beforeRegrow} -> ${regrown.loc[grainId].items})`);
}

// Screen-space distance, used by both 5c and 5b below. Declared up here
// rather than beside its first heavy user: `const` is not hoisted, so a
// declaration further down threw "Cannot access 'dist' before
// initialization" the moment 5c was inserted above it.
const dist = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1]);

// ── PHASE 5c: the half of a location that still hides ────────────────
//
// Food is terrain and stays readable (5a). WHO is on it is a body, and
// bodies need presence -- so a location you have scouted and left must
// show its crop and NOT show its occupants.
//
// TESTED ON THE OWNER WASH, NOT ON THE SPIDER, and the reason is worth
// recording. The obvious drive is "scout a live spider, walk away, assert
// she is not drawn" -- but she is six defenders wearing one body and each
// attacker trades one hit, so any column big enough to reach her kills
// her on arrival. Splitting a smaller force is not drivable from here
// (the quantity UI is a composing gesture this harness does not drive;
// shuffling ants between mounds either left too many or emptied the
// launch mound entirely, both tried), and no mound on this board
// naturally holds fewer than her six hit points within reach of her.
// Forcing the board to produce that state means scripting a sequence
// that the next tuning change breaks.
//
// The rule under test is not spider-specific: it is "occupancy hides".
// A CLAIMED patch carries the same information -- an owner wash and ring
// saying somebody holds this -- and it is trivially reachable, because
// harvesting a patch claims it. So this walks onto a patch, claims it,
// leaves, and asserts the ownership colour goes with the ants while the
// crop stays. Same rule, a state the board actually offers.
//
// (The spider's own hiding is in render/locations.lua on the identical
// `observed` test, so this covers the branch that decides both.)
{
  let oc = await dd.inspect();
  const claimed = Object.entries(oc.loc)
    .filter(([k, v]) => v.visited && v.owner === 'you' && oc.pos[k])
    .map(([k]) => k)[0];
  R.check('the run claimed a location to watch the owner colour on',
          !!claimed, claimed ? `${claimed} owner=${oc.loc[claimed].owner}` : 'none');
  if (claimed) {
    // Colour over the patch: the owner wash and ring are green (the
    // player's side), and nothing else at a food location is.
    const ownerGreen = (path, cx, cy, rad) => {
      const im = readPNG(path);
      let n = 0;
      for (let dy = -rad; dy <= rad; dy++) {
        for (let dx = -rad; dx <= rad; dx++) {
          if (dx * dx + dy * dy > rad * rad) continue;
          const x = cx + dx, y = cy + dy;
          if (x < 0 || y < 0 || x >= im.w || y >= im.h) continue;
          const [r, g, b] = im.at(x, y);
          if (g > 90 && g > r * 1.35 && g > b * 1.35) n++;
        }
      }
      return n;
    };
    const ON = process.cwd() + '/test/shots/fog3-owner-present.png';
    const OFF = process.cwd() + '/test/shots/fog3-owner-away.png';

    // Make sure we are standing on it, then look.
    const near = Object.entries(oc.mound)
      .filter(([k, v]) => v.owner === 'you' && v.g > 0 && oc.pos[k])
      .filter(([k, v]) => dist(oc.pos[k], oc.pos[claimed]) <=
                          v.reach * ((oc.cam && oc.cam.zoom) || 1) * 1.02)
      .sort((a, b) => b[1].g - a[1].g).map(([k]) => k)[0];
    if (near) { await dd.send(oc.pos[near], oc.pos[claimed]); await dd.step(1200); }
    oc = await dd.inspect();
    if (oc.loc[claimed] && oc.loc[claimed].observed) {
      await dd.shot(ON);
      const [ox, oy] = oc.pos[claimed];
      const present = ownerGreen(ON, ox, oy, 40);

      // Walk them off; the colour must leave with them.
      if (near) await dd.send(oc.pos[claimed], oc.pos[near]);
      for (let i = 0; i < 8; i++) {
        await dd.step(600);
        const st = await dd.inspect();
        if (st.loc[claimed] && !st.loc[claimed].observed) break;
      }
      const gone2 = await dd.inspect();
      await dd.shot(OFF);
      const [ax, ay] = gone2.pos[claimed];
      const away = ownerGreen(OFF, ax, ay, 40);
      // Calibrated against both states, not guessed: the owner wash on a
      // patch this size measures ~116px present and 0px away, so the line
      // goes in that gap. A first pass at 150 sat ABOVE the real present
      // value and failed a build whose render was correct -- the same
      // mistake the stubble threshold made, and the reason both are now
      // written with the measured numbers beside them.
      R.check('CONTROL: a patch you are STANDING on wears your colour',
              present > 40, `${present}px of owner colour while present`);
      R.check('...and a claimed patch you LEFT does not (occupancy hides)',
              gone2.loc[claimed] && gone2.loc[claimed].observed === false &&
              away < present / 3,
              `present=${present}px away=${away}px ` +
              `owner=${gone2.loc[claimed] && gone2.loc[claimed].owner} ` +
              `observed=${gone2.loc[claimed] && gone2.loc[claimed].observed}`);
    } else {
      R.check('the column reached the claimed patch to compare against',
              false, `observed=${oc.loc[claimed] && oc.loc[claimed].observed}`);
    }
  }
}

// ── PHASE 5b: the adjacency leak, and the control that must still pass ─
//
// THE OLD BUG: a queened colony set `observed` on every neighbour every
// tick, so an enemy garrison next door was drawn permanently, for free,
// to a player who had never gone there. Deleting that adjacency is the
// heart of plan 04 -- and the risk of deleting it is that plan 03's
// assault reveal goes with it, which would put us back to "an attacker
// dies on arrival and the ants killing your army are drawn by nothing".
//
// So this is a pair, and the pair is the gate: NOT drawn while merely
// discovered, DRAWN the moment your column is inbound. Measured in red
// pixels over the mound, because "is the enemy on screen" is a question
// only the screen can answer.
const SHOT3 = process.cwd() + '/test/shots/fog3-quiet.png';
const SHOT4 = process.cwd() + '/test/shots/fog3-contested.png';

// HOW MUCH ENEMY COLOUR IS ON SCREEN over a patch of ground -- because
// "is the enemy drawn" is a question only the screen can answer, and the
// sim will happily report a garrison the renderer is correctly hiding.
//
// Rival sides wear warm colours (red is 0.95/0.35/0.30, gold warmer
// still); the player is green and the ground is grey-brown. Counting
// pixels whose red channel clearly dominates BOTH others catches either
// rival without hard-coding which one turned up.
function enemyPixels(path, cx, cy, rad) {
  const im = readPNG(path);
  let n = 0;
  for (let dy = -rad; dy <= rad; dy++) {
    for (let dx = -rad; dx <= rad; dx++) {
      if (dx * dx + dy * dy > rad * rad) continue;
      const x = cx + dx, y = cy + dy;
      if (x < 0 || y < 0 || x >= im.w || y >= im.h) continue;
      const [r, g, b] = im.at(x, y);
      if (r > 110 && r > g * 1.7 && r > b * 1.7) n++;
    }
  }
  return n;
}

// THE STATE THIS PHASE NEEDS: a mound that is `visited` (you walked over
// it once) and enemy-held RIGHT NOW, with none of your ants on it.
//
// It cannot be manufactured by attacking and waiting, and both attempts
// to do so are worth writing down, because both look reasonable:
//
//   "attack something too strong and let them die" -- 15 against 20 is a
//   GRIND under plan 03's HP combat, not a rout. Six thousand frames in
//   the defenders were at 14 and the column was still standing there
//   swinging: `held=true`, state 1, the whole time.
//
//   "attack, then withdraw" -- a column already in a fight is not
//   selectable, so the withdrawing drag emits no intent at all. And
//   while the gate waited, the fight resolved the other way: twelve ants
//   TOOK the mound (state 1, ours), and red counter-attacked and retook
//   the mound behind it.
//
// That last accident is the drive. Take ground toward the rival, let the
// AI push back -- which is what this level is for, and `test-war`
// already gates that it does -- and the board produces the state on its
// own: ground you stood on, in enemy hands, nobody of yours there. This
// WAITS FOR that state rather than scripting it, and says so plainly if
// the board never produces one.
let rm = await dd.inspect();
const redSide = Object.values(rm.mound).map(m => m.owner)
  .find(o => o && o !== 'you');
R.check('discover fields a rival colony to be seen by', !!redSide,
        `owners=${[...new Set(Object.values(rm.mound).map(m => m.owner))]}`);

// Reach is in WORLD units and positions come back in SCREEN pixels, so
// the walk needs the scale between them; `@cam` reports zoom, which is
// exactly that factor.
//
// NOT PROBED BY TRYING SENDS AND SEEING WHICH STICK, which was an
// earlier version and the instructive one. An out-of-reach send does not
// merely fail: the drag that made it lands on empty ground, and a drag
// on empty ground PANS THE CAMERA (plan 02). So each rejected probe
// scrolled the board, every screen position banked before it went stale,
// and the loop then failed to pick up even the neighbour it had
// successfully sent to a moment earlier -- reporting "no route" for a
// board where the route was fine and the view had walked off it. Probing
// by attempt is not free here; the attempt is a move.
const route = (st, fromId, toId) => {
  const z = (st.cam && st.cam.zoom) || 1;
  const ids = Object.keys(st.mound).filter(k => st.pos[k]);
  const canReach = (a, b) =>
    dist(st.pos[a], st.pos[b]) <= (st.mound[a].reach * z) * 1.02;
  // Breadth-first over the reach graph: the shortest chain of hops
  // rather than the greedily-nearest one, which walks into corners on
  // any board with a detour in it.
  const prev = { [fromId]: null };
  const q = [fromId];
  while (q.length) {
    const a = q.shift();
    if (a === toId) break;
    for (const k of ids) {
      if (prev[k] !== undefined || !canReach(a, k)) continue;
      prev[k] = a; q.push(k);
    }
  }
  if (prev[toId] === undefined) return null;
  const path = [];
  for (let k = toId; k; k = prev[k]) path.unshift(k);
  return path;
};

const homeId2 = Object.entries(rm.mound)
  .filter(([, v]) => v.owner === 'you' && v.queens > 0).map(([k]) => k)[0]
  || homeId;
const enemyId = Object.entries(rm.mound)
  .filter(([k, v]) => v.owner === redSide && rm.pos[k])
  .sort((a, b) => b[1].fg - a[1].fg).map(([k]) => k)[0];
const path = route(rm, homeId2, enemyId);
R.check('a route from home to the rival exists on this board',
        path && path.length > 1,
        path ? path.join(' -> ') : 'NO PATH (reach graph disconnected?)');

// PLAN 05 SLOWED COMBAT ~3x (1s swings -> 3s, plus the facing cone
// forfeiting a swing whenever nobody is in the +/-45 degree cone), so a
// defended hop that fell inside the old 1500-frame (25s) budget can now
// still be fighting when this loop moves on -- `after.mound[...]` never
// reports `you`, `at` never advances, and everything downstream (which
// friendly mound is left in reach of the eventual "quiet" mound) is
// built on a walk that silently stalled partway. 4500 frames (75s) is
// generous rather than tightly retuned: this loop's job is to make
// progress along the path, not to measure combat speed, which
// test-battle already does precisely.
let at = homeId2;
for (let i = 1; i < (path || []).length; i++) {
  const st = await dd.inspect();
  await dd.send(st.pos[at], st.pos[path[i]]);
  await dd.step(4500);
  const after = await dd.inspect();
  if (after.mound[path[i]] && after.mound[path[i]].owner === 'you') at = path[i];
}

// Now wait for the board to hand us the state.
let quietId = null;
for (let i = 0; i < 14 && !quietId; i++) {
  const st = await dd.inspect();
  quietId = Object.entries(st.mound)
    .filter(([k, v]) => v.visited && v.owner && v.owner !== 'you' &&
                        !v.held && !v.contested && v.fg > 0 && st.pos[k])
    .map(([k]) => k)[0] || null;
  if (!quietId) await dd.step(600);
}
R.check('the board produced a DISCOVERED-but-enemy-held mound to look at',
        !!quietId, quietId || 'none appeared in 8400 frames');

if (quietId) {
  const st = await dd.inspect();
  const [qx, qy] = st.pos[quietId];
  await dd.shot(SHOT3);
  const quietRed = enemyPixels(SHOT3, qx, qy, 90);
  R.check('a discovered-but-absent enemy garrison is NOT drawn',
          quietRed <= 12,
          `${quietRed} enemy px over ${quietId} ` +
          `(fg=${st.mound[quietId].fg}, owner=${st.mound[quietId].owner})`);

  // THE CONTROL THAT MUST STILL PASS. If this one goes red, plan 04 took
  // plan 03's assault reveal down with it and an attacker once again
  // dies to ants nobody drew.
  //
  // Launched from whichever mound of ours can actually reach it -- the
  // board has moved since the walk above, and picking the launch point
  // by hand is how a gate ends up asserting on a send that never
  // happened.
  const mine = Object.entries(st.mound)
    .filter(([k, v]) => v.owner === 'you' && v.g > 0 && st.pos[k])
    .filter(([k, v]) => dist(st.pos[k], st.pos[quietId]) <=
                        v.reach * ((st.cam && st.cam.zoom) || 1) * 1.02)
    .sort((a, b) => b[1].g - a[1].g).map(([k]) => k)[0];
  R.check('we hold a mound within reach to launch the control assault from',
          !!mine, mine || 'nothing of ours reaches it');
  if (mine) {
    const out = await dd.send(st.pos[mine], st.pos[quietId]);
    const sent = (out || []).filter(l => l.startsWith('@i send')).pop();
    // A FEW FRAMES ONLY: `contested` is the INBOUND state and it ends the
    // moment the column lands. Stepping a comfortable margin here
    // measures the fight instead of the reveal.
    await dd.step(200);
    const rc = await dd.inspect();
    await dd.shot(SHOT4);
    const [cx2, cy2] = rc.pos[quietId];
    const hotRed = enemyPixels(SHOT4, cx2, cy2, 90);
    // WHAT THIS CONTROL DOES AND DOES NOT PROVE, stated because the
    // distinction decides whether it is worth anything.
    //
    // It proves the REVEAL: the same mound, the same garrison, invisible
    // one moment and drawn the next, with `contested` the only thing that
    // changed. That is the plan-03 behaviour plan 04 could have taken
    // down with it, and it is what the assertion is for.
    //
    // It does NOT prove that OUR send is what contested it. This board is
    // in an active war by now and the rival attacks on its own, so the
    // contest is sometimes ours and sometimes theirs -- `sent` records
    // which, and the assertion deliberately does not require it to be
    // ours. Demanding it would make the gate flaky about something it is
    // not testing; `test-war` already gates that a player send starts a
    // fight. What matters here is that a contested mound SHOWS its
    // defenders and a merely-discovered one does not.
    R.check('CONTROL: the SAME garrison IS drawn once an assault is inbound',
            rc.mound[quietId] && rc.mound[quietId].contested === true &&
            hotRed > quietRed * 3 + 20,
            `contest started by ${sent ? 'our send' : 'the rival'} (${sent || 'no send intent'}) ` +
            `contested=${rc.mound[quietId] && rc.mound[quietId].contested} ` +
            `quiet=${quietRed}px contested=${hotRed}px`);
  }
}

// ── PHASE 7: what the manual pass turned up ──────────────────────────
//
// Things only a human walking the level could see, gated so they cannot
// come back. (The spent-patch check lives up in phase 5a, where a column
// is already standing on a patch it has just stripped.)
//
// 2. THE UNEXPLORED PANEL STUTTERED. Title "Unexplored" over a row
//    labelled "unexplored" -- the row spent its only label restating the
//    heading. It now reads as a sentence. What the gate actually
//    protects is the invariant underneath: both site types must print
//    the SAME panel, or the panel identifies the site type for free.
//
//    Compared as PIXELS over the panel region, which is the only way to
//    catch a divergence in wording, colour or row count at once.
{
  const st = await dd.inspect();
  const unMound = Object.entries(st.mound)
    .filter(([k, v]) => !v.visited && st.pos[k]).map(([k]) => k)[0];
  const unLoc = Object.entries(st.loc)
    .filter(([k, v]) => !v.visited && st.pos[k]).map(([k]) => k)[0];
  R.check('an unvisited mound AND an unvisited location are both on screen',
          !!unMound && !!unLoc, `mound=${unMound} loc=${unLoc}`);
  if (unMound && unLoc) {
    const A = process.cwd() + '/test/shots/fog3-panel-mound.png';
    const B = process.cwd() + '/test/shots/fog3-panel-loc.png';
    await dd.tap(...st.pos[unMound]); await dd.step(20); await dd.shot(A);
    await dd.tap(...st.pos[unLoc]);   await dd.step(20); await dd.shot(B);
    const im1 = readPNG(A), im2 = readPNG(B);
    // COMPARE THE TEXT, NOT THE PLATE.
    //
    // The panel is translucent (alpha 0.84), so the map shows faintly
    // through it -- and between the two captures the map has genuinely
    // moved: this board is in a live war and ants walk about. A straight
    // pixel diff over the panel region therefore reports a few hundred
    // differing pixels for two panels that are drawing identical text,
    // as a 1-3px-per-row haze across the whole height. That is the map,
    // not the panel, and asserting on it measures the wrong thing.
    //
    // The glyphs are far brighter than either the plate or anything
    // bleeding through it, so thresholding to a text MASK and comparing
    // the masks isolates what the panel actually says. A wording change,
    // an extra row, or a different box height all move the mask; ants
    // walking behind it do not.
    const mask = im => {
      const m = [];
      for (let y = Math.floor(im.h * 0.74); y < im.h - 2; y++) {
        for (let x = 20; x < Math.floor(im.w * 0.25); x++) {
          const [r, g, b] = im.at(x, y);
          m.push((r + g + b) / 3 > 110 ? 1 : 0);
        }
      }
      return m;
    };
    const m1 = mask(im1), m2 = mask(im2);
    let diff = 0;
    for (let i = 0; i < m1.length; i++) if (m1[i] !== m2[i]) diff++;
    const ink = m1.reduce((a, v) => a + v, 0);
    R.check('CONTROL: the unexplored panel actually has text on it',
            ink > 300, `${ink} lit px in the mound panel's text mask`);
    R.check('an unvisited MOUND and an unvisited LOCATION show the SAME panel',
            diff === 0,
            `${diff} differing text px (${unMound} vs ${unLoc}), ink=${ink}`);
  }
}

R.check('no lua errors in the discover run', dd.errors().length === 0,
        dd.errors()[0] || '');
R.check('no lua errors', d.errors().length === 0, d.errors()[0] || '');
process.exit(R.done() ? 0 : 1);
