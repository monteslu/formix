// A QUEEN'S DEATH IS NOT THE END OF THE STORY.
//
// Found live in play, 2026-08-19 (Luis): sieging attackers stayed parked
// on the ordinary milling ring instead of visibly closing on the queen
// they were attacking, and her body -- despite the sim already tracking
// `site.corpses`/`site.corpseValue` on death, and a comment beside that
// code promising "carried home like anything else" -- was never actually
// picked up. Nothing consumed the corpse state; it just sat there. Two
// real bugs were found and fixed building the carry-home half:
//
//   1. `M.spawn` recycles a pool slot's TABLE OBJECT (kill() is a swap-
//      remove) without clearing the new `carryQueen` render flag, so a
//      brand-new hatchling could inherit a stale "I am carrying a dead
//      queen" flag from whichever corpse used to occupy that slot.
//   2. There are TWO bank sites in agents.lua -- the instant "already
//      standing on a queen" shortcut in M.update, and the far more
//      common "arrived after a real walk" path in M.fight's crossing
//      handler. Only the first one cleared `carryQueen`; a carrier that
//      banked via the second (the ordinary case) delivered the food
//      correctly but kept the flag forever, so `carryingQueen` in the
//      `@m` line stuck at 1 long after the real trip was done.
//
// Written to FAIL, per docs/ARCHITECTURE.md: the close-in check has a
// control (an ordinary idling ant, not sieging, at the ordinary wander
// radius); the carry/clear checks assert on the SAME atomic-read
// discipline test-spider's withdrawal gate established (poll the cheap
// `@m` line, not `inspect()`, for a fast-moving transition), and are
// exactly what would have caught bug #2 before it shipped.
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
const CART = buildCart('gatesiege', 'siege-cart.wasc');

async function freshDump(t, d) {
  await d.press('select', 6);
  await d.press('select', 6);
  return d.all();
}

// ── 1. CLOSE-IN: an attacker sieging the queen sits noticeably nearer
//    the mound centre than the ordinary wander ring (wanderInner/Outer
//    is 1.34-1.52 mound radii; the siege orbit is 0.10-0.30) ───────────
{
  const t = api('formix-siege-closein');
  const d = driver(t, CART);
  await d.boot(7, { level: 'gatesiege' });
  let r = await d.inspect();
  const before = (await d.inspect()).mound.n2;
  R.check('the enemy queen starts undamaged, garrison-free', before && before.qhp === 50,
          before ? `qhp=${before.qhp} g=${before.g}` : 'no mound line');

  await d.send(r.pos.n1, r.pos.n2);
  // Give the column time to arrive and start sieging, but stay well
  // short of her death (measured while building this gate: she falls
  // around t~15s against a 12-ant send).
  await d.step(480);

  const mid = (await d.inspect()).mound.n2;
  R.check('the siege has started and is doing damage', mid && mid.qhp < 50 && mid.qhp > 0,
          mid ? `qhp=${mid.qhp}` : 'no mound line');

  // Screenshot the mound and measure how much ant-coloured ink sits in a
  // TIGHT inner ring (close to centre) vs the ordinary wander band. A
  // besieging column should read as clustered near her, not spread out
  // at the mound's edge the way an idle garrison would.
  const lines = await freshDump(t, d);
  const pos = {};
  for (const l of lines) {
    const m = l.match(/^@node (\w+) (-?\d+) (-?\d+)/);
    if (m) pos[m[1]] = [ +m[2], +m[3] ];
  }
  R.check('the enemy mound reports a screen position', !!pos.n2,
          pos.n2 ? `${pos.n2}` : 'no @node n2 line');

  if (pos.n2) {
    const shot = process.cwd() + '/test/shots/siege-closein.png';
    await d.shot(shot);
    const im = readPNG(shot);
    const [cx, cy] = pos.n2;
    // Ant colour (amber/orange, r > g > b, comfortably above the brown
    // mound-fill background) counted separately inside a TIGHT ring
    // (close radius) vs an OUTER band matching the ordinary wander orbit,
    // both computed from the mound's ACTUAL on-screen radius rather than
    // guessed: `plain` is 78 world units (world.lua KINDS.plain), and
    // the default zoom this gate boots at is 0.42 (test-battle.mjs's own
    // measured default), so the mound draws at ~78*0.42 ~= 32.8px here.
    // wanderInner/Outer (1.34-1.52 mound radii, agents.lua cfg) is the
    // ordinary idle band; the siege orbit this plan adds is 0.10-0.30.
    // (An earlier version of this gate guessed 87-99px for the outer
    // band without this arithmetic -- comfortably past the mound's own
    // edge, where no ant is EVER drawn regardless of orbit -- and did
    // not redden when the fix was sabotaged. Fixed by computing the
    // bands from the real geometry instead of a guess.)
    const moundScreenR = 78 * 0.42;
    // MEASURED against a live capture while building this gate: the
    // enemy mound's own red-war fill (rgb ~138,70,44 -- ~3700+ px in a
    // 60px sample around her) also satisfies a bare "r > g > b" test, so
    // that alone cannot tell ant ink from mound fill. What separates them
    // is the g/r RATIO: YOUR_COL (render/ants.lua) is (0.90, 0.64, 0.26)
    // -- g is ~71% of r -- while the mound fill's g sits at ~50% of r.
    // Ant ink, measured live: 230,163,66 (g/r=0.71) and 255,173,66
    // (g/r=0.68). Mound fill: 138,70,44 (g/r=0.51).
    function ringPixels(rIn, rOut) {
      let n = 0;
      for (let dy = -rOut; dy <= rOut; dy++) {
        for (let dx = -rOut; dx <= rOut; dx++) {
          const d2 = dx * dx + dy * dy;
          if (d2 < rIn * rIn || d2 > rOut * rOut) continue;
          const x = cx + dx, y = cy + dy;
          if (x < 0 || y < 0 || x >= im.w || y >= im.h) continue;
          const [rr, gg, bb] = im.at(x, y);
          if (rr > 150 && gg > bb && gg / rr > 0.60 && gg / rr < 0.85) n++;
        }
      }
      return n;
    }
    const inner = ringPixels(0, moundScreenR * 0.30);
    const outer = ringPixels(moundScreenR * 1.34, moundScreenR * 1.52);
    R.check('besieging ants cluster near the centre, not the ordinary wander ring',
            inner > 0 && inner > outer,
            `inner(0-${(moundScreenR * 0.30).toFixed(0)}px)=${inner} ` +
            `outer(${(moundScreenR * 1.34).toFixed(0)}-${(moundScreenR * 1.52).toFixed(0)}px, ordinary wander)=${outer}`);
  }
}

// ── 2-5. THE CARRY-HOME TRIP: pickup, atomic bank, carryQueen clears,
//    delivered food actually reaches the pantry ───────────────────────
{
  const t = api('formix-siege-carry');
  const d = driver(t, CART);
  await d.boot(7, { level: 'gatesiege' });
  let r = await d.inspect();

  const before = await d.metric();
  R.check('nobody is carrying a queen before the siege', before.carryingQueen === 0,
          `carryingQueen=${before.carryingQueen}`);

  await d.send(r.pos.n1, r.pos.n2);

  // Poll the CHEAP `@m` line, not inspect() -- same reasoning
  // test-spider's withdrawal gate documents: a fast transition (here,
  // her death and the instant pickup that follows) can land inside a
  // window inspect()'s own ~120-frame cost would step straight over.
  let sawKill = false, sawCarry = false;
  for (let i = 0; i < 60 && !(sawKill && sawCarry); i++) {
    await d.step(30);
    const m = await d.metric();
    if (m.queensKilled > 0) sawKill = true;
    if (m.carryingQueen > 0) sawCarry = true;
  }
  R.check('the queen falls', sawKill, `sawKill=${sawKill}`);
  R.check('her body is picked up (not left to rot)', sawCarry, `sawCarry=${sawCarry}`);

  const mAfterKill = await d.metric();
  R.check('picked counts the queen the same way it counts any prize',
          mAfterKill.picked >= 1, `picked=${mAfterKill.picked}`);

  // Now poll for delivery -- carryingQueen must return to 0 and stay
  // there (bug #2's exact regression: it clears once, briefly, then a
  // stale flag on a LATER hatchling could bring it back to 1 -- so this
  // checks it stays at 0 across several more polls, not just once).
  let delivered = false;
  for (let i = 0; i < 60 && !delivered; i++) {
    await d.step(30);
    const m = await d.metric();
    if (m.carryingQueen === 0 && m.delivered > 0) delivered = true;
  }
  R.check('the body is delivered (carryingQueen clears, a delivery is counted)',
          delivered, delivered ? 'ok' : 'never cleared');

  const mDelivered = await d.metric();
  R.check('food actually reached the pantry',
          mDelivered.food > 0, `food=${mDelivered.food}`);

  // STAYS clear across further ticks -- this is exactly what bug #2
  // looked like: cleared once, then a fresh hatchling in a recycled
  // pool slot brought it back to 1 without ever touching a real corpse.
  let staysCleared = true;
  for (let i = 0; i < 10; i++) {
    await d.step(60);
    const m = await d.metric();
    if (m.carryingQueen !== 0) { staysCleared = false; break; }
  }
  R.check('CONTROL: carryingQueen stays at 0 -- no later hatchling inherits a stale flag',
          staysCleared, `staysCleared=${staysCleared}`);

  R.check('no lua errors across the siege and carry-home trip',
          d.errors().length === 0, d.errors().slice(0, 2).join(' | '));
}

process.exit(R.done() ? 0 : 1);
