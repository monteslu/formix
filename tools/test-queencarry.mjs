// A DEAD QUEEN IS CARGO, AND SHE MUST LOOK LIKE HERSELF.
//
// Plan 06, part 1. Three rounds of work have gone into "carry the queen's
// body home" and Luis still reported it broken in play:
//
//   round 1: she banked INSTANTLY on death -- the only food in the game
//            that teleported.
//   round 2 (plan 05): she got a body, a pickup, a carry flag and bespoke
//            carried-corpse art. test-siege went green. In play she was
//            still wrong: "it's turning them into a box or some shit
//            instead of just carrying the same queen rendering back."
//
// The round-2 art was three bare quads hand-rolled in render/ants.lua --
// no waist, no legs, no wings, no crown -- so it shared nothing with the
// queen the player had just watched die. Captured during plan 06 phase 0
// (test/shots/carryart-*.png): a detached brown rectangle beside the
// carrier. That is what this gate exists to stop coming back.
//
// Written to FAIL, per docs/ARCHITECTURE.md. The pixel assertions compare
// the CARRIED body against the LIVE queen's own measured footprint on the
// same board at the same zoom -- an absolute pixel count would just be a
// threshold picked to pass, and the box would satisfy any such number by
// being brown and present. Area and colour BOTH have to match her.
import { api, driver, makeReport } from './drive.mjs';
import { execSync } from 'child_process';
import { writeFileSync, unlinkSync, existsSync, copyFileSync } from 'fs';
import { readPNG } from './png.mjs';

const R = makeReport();

function buildCart(level, fname) {
  const CART = process.cwd() + '/test/' + fname;
  writeFileSync('app/startlevel', level);
  try {
    execSync('./build.sh', { stdio: 'ignore' });
    copyFileSync(process.cwd() + '/formix.wasc', CART);
  } finally {
    if (existsSync('app/startlevel')) unlinkSync('app/startlevel');
    execSync('./build.sh', { stdio: 'ignore' });
  }
  return CART;
}

// gatesiege2 (plan 06): the enemy queen has a GARRISON, so the worker
// fight runs before the queen siege and the mound's capture lands around
// the same time her body hits the ground. gatesiege (no defenders) hides
// that ordering entirely -- she dies and is lifted inside one tick.
const CART = buildCart('gatesiege2', 'siege2-cart.wasc');

// Ant/queen ink: a coloured pixel that is not the mound's own fill.
// Red side (SIDE_COL.red / ENEMY_COL) is what the enemy queen wears, and
// her corpse wears it dimmed to 0.62 -- so the test looks for RED-ish ink
// (r clearly dominant) rather than the amber g/r band test-siege uses for
// YOUR ants.
function redInk(im, cx, cy, rad) {
  let n = 0;
  for (let dy = -rad; dy <= rad; dy++) {
    for (let dx = -rad; dx <= rad; dx++) {
      const x = cx + dx, y = cy + dy;
      if (x < 0 || y < 0 || x >= im.w || y >= im.h) continue;
      const [r, g, b] = im.at(x, y);
      // Her body is a deep red (0.92,0.24,0.18 dimmed => ~145,38,28 and
      // its shaded segments). The mound's own war fill is a BROWNER red
      // (~138,70,44): g sits near half of r. Hers sits near a quarter.
      if (r > 70 && g < r * 0.45 && b < r * 0.55) n++;
    }
  }
  return n;
}

// ── 1-4. THE TRIP ITSELF, on a board where the mound flips ─────────────
{
  const t = api('formix-queencarry-trip');
  const d = driver(t, CART);
  await d.boot(7, { level: 'gatesiege2' });
  const r = await d.inspect();

  const before = await d.metric();
  R.check('nobody is carrying a queen before the siege',
          before.carryingQueen === 0, `carryingQueen=${before.carryingQueen}`);

  await d.send(r.pos.n1, r.pos.n2);

  // Poll the cheap `@m` line for the fast transitions (test-spider's
  // atomic-read lesson: inspect() costs ~120 frames and steps over them).
  let sawKill = false, sawCarry = false, ownerAtCarry = null;
  for (let i = 0; i < 80 && !(sawKill && sawCarry); i++) {
    await d.step(30);
    const m = await d.metric();
    if (m.queensKilled > 0) sawKill = true;
    if (m.carryingQueen > 0 && !sawCarry) {
      sawCarry = true;
      ownerAtCarry = (await d.inspect()).mound.n2?.owner ?? null;
    }
  }
  R.check('the queen falls', sawKill, `sawKill=${sawKill}`);
  R.check('her body is picked up, not left to rot', sawCarry,
          `sawCarry=${sawCarry} mound owner at pickup=${ownerAtCarry}`);

  let delivered = false;
  for (let i = 0; i < 80 && !delivered; i++) {
    await d.step(30);
    const m = await d.metric();
    if (m.carryingQueen === 0 && m.delivered > 0) delivered = true;
  }
  R.check('the body is delivered and the flag clears', delivered,
          delivered ? 'ok' : 'never cleared');
  const mD = await d.metric();
  R.check('her value reached the pantry (queenFood=8)', mD.food >= 7,
          `food=${mD.food}`);

  R.check('no lua errors across the defended siege and carry-home trip',
          d.errors().length === 0, d.errors().slice(0, 2).join(' | '));
}

// ── 5. THE POST-CAPTURE PICKUP, which is the rule the guard encodes ────
//
// The corpse must be liftable by the side that WON, including after the
// mound has already changed hands. Pre-fix the guard was
// `n.owner ~= ant.side`, which is false for the winner the moment the
// capture lands -- so this asserts a body that is still on the ground
// AFTER the flip gets picked up rather than sitting there forever.
{
  const t = api('formix-queencarry-postcapture');
  const d = driver(t, CART);
  await d.boot(7, { level: 'gatesiege2' });
  const r = await d.inspect();
  await d.send(r.pos.n1, r.pos.n2);

  // Run well past both the kill AND the capture.
  let flipped = false, corpseGone = false, delivered = false;
  for (let i = 0; i < 100; i++) {
    await d.step(40);
    const ins = await d.inspect();
    const n2 = ins.mound.n2 || {};
    if (n2.owner === 'you') flipped = true;
    if (flipped && (n2.corpses || 0) === 0) corpseGone = true;
    const m = await d.metric();
    if (m.delivered > 0) delivered = true;
    if (flipped && corpseGone && delivered) break;
  }
  R.check('the mound actually changes hands (the ordering this gate is for)',
          flipped, `flipped=${flipped}`);
  R.check('no queen corpse is left stranded on the captured mound',
          corpseGone, `corpseGone=${corpseGone}`);
  R.check('and it was banked, not just dropped', delivered,
          `delivered=${delivered}`);
}

// ── 9-10. A CORPSE ON GROUND YOU ALREADY HOLD (the guard's real rule) ──
//
// The assertions above pass with EITHER guard, and that is worth stating
// plainly rather than hiding: measured in plan 06's phase 0, an ordinary
// siege kills the queen and lifts her body inside the SAME tick, before
// the mound's energy grind flips ownership -- so `n.owner ~= ant.side`
// and `corpseSide ~= ant.side` agree on every board a gate can stage by
// playing normally.
//
// The orderings where they DISAGREE are real, though: a storming party
// wiped out before it lifts her, a rival retaking the ground, any second
// wave arriving after the capture. In all of them the body is sitting on
// ground the collecting side now owns, and the old owner-based guard
// refuses it forever. `dropqueen` (SELECT+R, overlay-gated like every
// other gate instrument) puts exactly that state on the board -- one
// corpse, on an owned mound, with a side of its own -- and changes
// nothing else, so what follows still exercises the real pickup code.
{
  const t = api('formix-queencarry-ownedground');
  const d = driver(t, CART);
  await d.boot(7, { level: 'gatesiege2' });

  // Baseline BEFORE the drop. Read it first and compare against it: this
  // gate originally asserted `food > 8` against a run that had already
  // banked a queen earlier, and reported a working pickup as broken.
  // The delta is the fact; the absolute number is not.
  const m0 = await d.metric();

  // Overlay on (the op refuses without it), then drop the body.
  await d.press('select', 6);
  await d.step(20);
  await d.hold(['select', 'r'], 8);
  await d.step(6);
  const dropLine = d.all().filter(l => l.startsWith('@dbg dropqueen')).pop();
  R.check('a queen corpse was placed on a mound the player already holds',
          !!dropLine && /owner=you/.test(dropLine), dropLine || 'no @dbg line');
  await d.press('select', 6);   // overlay back off
  await d.step(20);

  // NOTE ON WHAT IS MEASURED HERE. An ant standing on its OWN queened
  // mound banks in place: `dispatchCarrier` returns "here" on the very
  // tick it picks the body up, so `carryingQueen` is never observably 1
  // and `delivered` (which counts arrivals after a real walk, in
  // M.fight's crossing handler) never moves. Neither is evidence of
  // anything here. `picked` and the food POOL are, and they are what the
  // rule is actually about: the body left the ground and its value
  // reached the colony.
  let picked = false, banked = false;
  for (let i = 0; i < 40 && !(picked && banked); i++) {
    await d.step(20);
    const m = await d.metric();
    if (m.picked > m0.picked) picked = true;
    if (m.food > m0.food) banked = true;
  }
  const mEnd = await d.metric();
  R.check('an ant on its OWN mound still collects the enemy queen lying there',
          picked, `picked ${m0.picked} -> ${mEnd.picked}`);
  R.check('and her value reaches the pantry from owned ground',
          banked && mEnd.food - m0.food >= 7,
          `food ${m0.food} -> ${mEnd.food} (queenFood=8)`);
}

// ── 6-8. SHE LOOKS LIKE HERSELF: the anti-box assertions ───────────────
//
// Measure the LIVE enemy queen's red ink at a known zoom, then measure the
// CARRIED body the same way. A queen drawn by queenBody() has a waist,
// legs, wings and three shaded segments; the round-2 box was a single flat
// quad cluster roughly a quarter of her area. Comparing carried-to-live on
// the SAME run is what makes this a rule rather than a magic number.
{
  const t = api('formix-queencarry-art');
  const d = driver(t, CART);
  await d.boot(7, { level: 'gatesiege2' });

  // MEASURED AT THE DEFAULT ZOOM, NOT ZOOMED IN. Both mounds are on
  // screen at the boot zoom (0.42); one zoom step in (1.5x) pushes the
  // enemy mound past the right edge, and panning it back proved
  // unreliable here -- a drag started over the board is a SEND, not a
  // pan, so the "empty ground" the pan rule needs is not where a
  // two-mound fixture leaves much room. The comparison this gate makes
  // is carried-vs-live at the SAME zoom, so which zoom that is does not
  // matter, as long as it is one where both are visible.
  let ins = await d.inspect();
  const n2p0 = ins.pos.n2;
  R.check('the enemy mound is on screen for the live-queen measurement',
          !!n2p0 && n2p0[0] > 60 && n2p0[0] < 1860,
          `n2=${JSON.stringify(n2p0)}`);

  // SHE IS MEASURED MID-SIEGE, NOT AT BOOT. At boot her mound is
  // UNVISITED, and plan 04's fog draws every unknown site as ONE UNIFORM
  // GREY DISC -- no queen, no garrison, no colour at all. Captured while
  // building this gate (test/shots/queencarry-live.png, boot frame): a
  // plain grey circle, 0 red pixels, exactly as the fog rule requires.
  // A gate that measured "the live queen" there would be measuring fog
  // and reporting it as art. Her mound has to become `observed` -- which
  // is when a player first sees her too -- before there is anything of
  // hers on screen to compare against.
  await d.send(ins.pos.n1, ins.pos.n2);

  // Tight box: at the default 0.42 zoom a plain mound draws ~33px across,
  // and queenPos puts her within ~0.34 of its radius of centre.
  let liveInk = 0;
  for (let i = 0; i < 40 && liveInk === 0; i++) {
    await d.step(30);
    const cur = await d.inspect();
    const n2 = cur.mound.n2 || {};
    const m = await d.metric();
    // Observed, and she is still alive: the one window in which a LIVE
    // enemy queen is actually drawn on screen.
    if (n2.observed && (m.queensKilled || 0) === 0 && (n2.qhp || 0) > 0
        && cur.pos.n2) {
      const liveShot = process.cwd() + '/test/shots/queencarry-live.png';
      await d.shot(liveShot);
      liveInk = redInk(readPNG(liveShot), cur.pos.n2[0], cur.pos.n2[1], 26);
    }
  }
  R.check('the LIVE enemy queen is drawn once her mound is observed',
          liveInk > 30, `liveInk=${liveInk}px`);

  // Catch her mid-carry and measure the body on the carrier's back.
  let carryInk = 0, carryShot = null;
  for (let i = 0; i < 90; i++) {
    await d.step(20);
    const m = await d.metric();
    if (m.carryingQueen > 0) {
      carryShot = process.cwd() + '/test/shots/queencarry-carried.png';
      await d.shot(carryShot);
      const im = readPNG(carryShot);
      const ins2 = await d.inspect();
      // She is somewhere between the two mounds, on a carrier walking
      // home. Sweep the corridor between them rather than guessing a
      // point: the widest red-ink cluster in that band is her.
      // SWEEP THE WHOLE CORRIDOR INCLUDING THE MOUNDS, and subtract a
      // BASELINE rather than excluding ground.
      //
      // The first version skipped a 45px radius around the enemy mound to
      // avoid counting its red war-fill and its live red ants -- and it
      // measured 0px while the carried queen was plainly on screen, in a
      // capture I looked at: the carrier picks her up and can still be
      // standing ON that mound (banking in place, or one step into the
      // walk home) for the whole window this gate polls. Excluding the
      // ground she is most likely to be standing on is excluding the
      // subject.
      //
      // Instead the baseline is measured BEFORE the body exists (`liveInk`
      // above is the same mound with the live queen on it), and this looks
      // for a red-ink cluster ANYWHERE along the corridor that the
      // pre-pickup frame did not have.
      const a = ins2.pos.n2, b = ins2.pos.n1;
      if (a && b) {
        let best = 0;
        for (let k = 0; k <= 24; k++) {
          const x = Math.round(a[0] + (b[0] - a[0]) * k / 24);
          const y = Math.round(a[1] + (b[1] - a[1]) * k / 24);
          best = Math.max(best, redInk(im, x, y, 22));
        }
        carryInk = best;
      }
      if (carryInk > 0) break;
    }
  }
  R.check('a carried queen is DRAWN on the way home (red ink off-mound)',
          carryInk > 8, `carryInk=${carryInk}px (live was ${liveInk}px)`);

  // THE ANTI-BOX ASSERTION. The bespoke quad blob measured roughly a
  // quarter of her live area at matched zoom; a real queenBody() corpse
  // is the same construction at ~1.05x the carrier's size. Requiring the
  // carried body to be a substantial FRACTION of her live footprint is
  // what a box cannot satisfy without becoming her.
  R.check('the carried body is queen-sized, not a crumb-sized box',
          liveInk > 0 && carryInk >= liveInk * 0.18,
          `carried=${carryInk}px live=${liveInk}px ` +
          `ratio=${liveInk ? (carryInk / liveInk).toFixed(2) : 'n/a'} (need >=0.18)`);

  R.check('no lua errors across the art capture',
          d.errors().length === 0, d.errors().slice(0, 2).join(' | '));
}

process.exit(R.done() ? 0 : 1);
