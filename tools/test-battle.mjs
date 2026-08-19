// PLAN 05: BATTLES YOU CAN WATCH, PART ONE -- MOUND COMBAT.
//
// The rule (internal-formix/05-battles.md): a worker swings once every
// 3 seconds, hits half the time for 2-4, and can only strike an enemy
// within its own +/-45 degree facing cone. The two sides on a mixed
// mound march the perimeter in OPPOSING directions -- rolled once per
// battle, cleared when the fight ends -- which is what guarantees every
// pair of ants eventually closes and passes rather than orbiting in
// lockstep. A dead ant leaves a corpse (head/abdomen apart, faded and
// swept after corpseLife seconds) instead of vanishing on the kill tick.
//
// Written to FAIL, per docs/ARCHITECTURE.md: every check below either
// has a control that must diverge, or was run against a version of the
// code with the feature disabled to confirm it goes red. See the
// sabotage notes inline.
import { api, driver, makeReport } from './drive.mjs';
import { execSync } from 'child_process';
import { writeFileSync, unlinkSync, existsSync, copyFileSync } from 'fs';
import { readPNG } from './png.mjs';

const R = makeReport();

// TWO FIXTURE LEVELS, both cart-packing, both restored in a `finally`
// (the test-fog3 lesson: a rebuild left mid-suite poisons everything
// that runs after it).
//   gatebattle  -- exactly 1 ant a side. A drag always sends the WHOLE
//                  garrison, so a controlled 1v1 duel needs the source
//                  mound to already hold exactly one ant.
//   gatebattle2 -- 12 a side, for statistics a 1v1 cannot give (damage
//                  bounds needs to SEE both 2 and 4; the spin-rate
//                  comparison needs enough swings to be a real signal).
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
const CART1 = buildCart('gatebattle', 'battle-cart.wasc');
const CART2 = buildCart('gatebattle2', 'battle2-cart.wasc');

// Turn the developer overlay on/off. `d.inspect()` assumes it starts
// CLOSED (press to open, dump, press to close) -- calling it while the
// overlay is already open from a debug combo closes it instead of
// dumping, which prints nothing and silently breaks every assertion
// after it. So: use `d.inspect()` only when the overlay is confirmed
// off (right after boot, before any SELECT combo), and after that use
// `freshDump()` below, which does a closed->open cycle of its own and
// never touches a combo.
async function freshDump(t, d) {
  await d.press('select', 6);   // close (it is open from a prior combo)
  await d.press('select', 6);   // open again -> wantReport fires, dumps
  return d.all();
}
function moundFrom(lines, id) {
  const m = lines.filter(l => l.startsWith(`@mound ${id} `)).pop();
  if (!m) return null;
  const re = /^@mound (\w+) (\S+) g=(\d+) gi=(\d+) fg=(\d+) q=(\d+)\/(\d+) energy=(\d+) reach=(\d+) seen=(\w+) brood=(\d+) held=(\w+) obs=(\w+) contested=(\w+) visited=(\w+) spinYou=(-?\d+) spinFoe=(-?\d+)/;
  const g = m.match(re);
  if (!g) return null;
  return { owner: g[2] === 'nil' ? null : g[2], g: +g[3], gi: +g[4], fg: +g[5],
           held: g[12] === 'true', spinYou: +g[16], spinFoe: +g[17] };
}
// The FIRST corpse's screen position, for a tight crop -- see
// corpsePixels' note on why a wide scan over the whole mound is not
// reliable (the ring art's own gradient bands overlap a corpse's
// luminance).
function firstCorpsePos(lines) {
  const m = lines.find(l => l.startsWith('@corpse 1 '));
  if (!m) return null;
  const g = m.match(/^@corpse \d+ (-?\d+) (-?\d+)/);
  return g ? [+g[1], +g[2]] : null;
}
// SELECT held with a second button: overlay-gated debug ops. Both
// buttons set/released on the SAME frame -- pressed() reads the edge on
// whichever the input layer checks first, and M.comboUsed suppresses
// the plain-overlay-toggle-on-release path either way.
async function dev(d, button) { return d.hold(['select', button], 8); }

// Worked out from the actual render formula (render/ants.lua's
// `corpse()`: the head/gaster segments draw at ENEMY_COL/YOUR_COL *
// 0.35-0.45, alpha 0.85 * fade) and confirmed against live captures
// over BOTH fills this gate produces -- the mound is red war-fill while
// enemy-owned and green once I take it, and the "present" scenario
// below crosses that exact transition mid-test. Measured luminance
// (r+g+b) at four points, r-dominant throughout:
//
//     green fill   273   green corpse   172   (ratio 0.63)
//     red fill     272   red corpse     127   (ratio 0.47)
//     live ant (amber, any fade tier)   368-494
//
// A corpse sits in a clean, wide gap between the two fills (~270) and
// the ant (~370+) regardless of which fill it happens to be on, so
// luminance alone -- not colour, which differs by fill -- is what
// separates it: bounded between 60 (grass-floor noise) and 220 (well
// under either fill, comfortably over both corpse samples), with
// r >= both other channels to exclude the green fill itself (which has
// g > r).
function corpsePixels(path, cx, cy, rad) {
  const im = readPNG(path);
  let n = 0;
  for (let dy = -rad; dy <= rad; dy++) {
    for (let dx = -rad; dx <= rad; dx++) {
      if (dx * dx + dy * dy > rad * rad) continue;
      const x = cx + dx, y = cy + dy;
      if (x < 0 || y < 0 || x >= im.w || y >= im.h) continue;
      const [r, g, b] = im.at(x, y);
      const lum = r + g + b;
      if (lum > 60 && lum < 220 && r >= g && r >= b) n++;
    }
  }
  return n;
}

// ── 1-3: gatebattle, the 1v1 duel ───────────────────────────────────────
{
  const t = api('formix-battle-duel');
  const d = driver(t, CART1);
  await d.boot(7, { level: 'gatebattle' });
  let r = await d.inspect();   // overlay ends CLOSED

  await d.send(r.pos.n1, r.pos.n2);
  // Travel time for one ant over 700 world units is a few seconds; wait
  // generously rather than pin an exact frame count to geometry that
  // could shift with an unrelated speed tweak.
  await d.step(400);

  // ── 1. CADENCE: swing ATTEMPTS, not landings (a miss still resets
  //    the timer and still counts as an attempt -- that is the rule
  //    under test, not the 50% hit roll on top of it). `a.swings` is a
  //    GLOBAL counter, and this is a 1v1 -- BOTH ants are swinging at
  //    each other, so 30 real seconds at a 3.0s cadence is ten attempts
  //    EACH, ~20 total. Desynchronised starts (a.rng() * swingPeriod)
  //    cost at most one swingPeriod of slop per ant either way.
  const before = await d.metric();
  await d.step(1800);   // 30s
  const after = await d.metric();
  const attempts = after.swings - before.swings;
  R.check('two ants (1v1) swing roughly once every 3s each (~20 attempts in 30s)',
          attempts >= 18 && attempts <= 22, `attempts=${attempts}`);

  // ── 2. DAMAGE BOUNDS, sampled from gatebattle2 (needs a real sample
  //    size to SEE both ends of 2-4; see below).

  // ── 3. THE FACING CONE. Lock the player ant's facing away from the
  //    one enemy present -- overlay ON first (report dumps on the
  //    OPEN transition, so this must happen before the lock, not
  //    after, or the dump before the lock would be the useful one).
  //    hpEnemy may already be below max from the cadence measurement
  //    above (this is the SAME ongoing duel, on purpose -- a fresh
  //    cart per assertion would waste the DEVLOOP-cheap gate on cart
  //    rebuilds it does not need); the assertion is that it holds
  //    STEADY while locked away, not that it starts at any particular
  //    value.
  await d.press('select', 6);              // overlay ON
  await dev(d, 'left');                    // facelock = faceaway
  const c0 = await d.metric();
  await d.step(900);                       // 15s facing away
  const c1 = await d.metric();
  R.check('facing AWAY: my side lands nothing more on the enemy',
          c1.hpEnemy === c0.hpEnemy,
          `hpEnemy ${c0.hpEnemy} -> ${c1.hpEnemy}`);

  await dev(d, 'right');                   // facelock = facetoward
  const c2 = await d.metric();
  await d.step(900);
  const c3 = await d.metric();
  R.check('CONTROL: facing TOWARD, the enemy takes damage',
          c3.hpEnemy < c2.hpEnemy,
          `hpEnemy ${c2.hpEnemy} -> ${c3.hpEnemy}`);

  await dev(d, 'up');                      // facelock off, tidy exit
  R.check('no lua errors in the duel', d.errors().length === 0,
          d.errors().slice(0, 2).join(' | '));
}

// ── 2, 4-7: gatebattle2, the 12v12 bulk fight ───────────────────────────
{
  const t = api('formix-battle-bulk');
  const d = driver(t, CART2);
  await d.boot(7, { level: 'gatebattle2' });
  let r = await d.inspect();

  await d.send(r.pos.n1, r.pos.n2);
  await d.step(3600);   // 60s: long enough for a real sample and a
                         // decisive result at 12v12 (measured: mine
                         // wins outright inside this window)

  // ── 2. DAMAGE BOUNDS: over a real sample, both ends of 2-4 must
  //    appear. A bounds-only check (min>=2, max<=4) would pass a
  //    hitMax of 3 by never trying to reach 4 -- BOTH values observed
  //    is what actually proves the range.
  const m = await d.metric();
  R.check('landed damage never drops below 2', m.dmgMin >= 2, `dmgMin=${m.dmgMin}`);
  R.check('landed damage never exceeds 4', m.dmgMax <= 4, `dmgMax=${m.dmgMax}`);
  R.check('both 2 and 4 were actually rolled',
          m.dmgMin === 2 && m.dmgMax === 4,
          `observed [${m.dmgMin}, ${m.dmgMax}]`);
  R.check('the bigger, undamaged army won the engagement',
          m.mine > 0, `mine=${m.mine} theirs=${m.theirs}`);
  R.check('no lua errors in the bulk fight', d.errors().length === 0,
          d.errors().slice(0, 2).join(' | '));
}

// ── 4a. OPPOSITE MARCHING: the sim's own spin assignment ────────────────
{
  const t = api('formix-battle-spin');
  const d = driver(t, CART2);
  await d.boot(7, { level: 'gatebattle2' });
  let r = await d.inspect();
  await d.send(r.pos.n1, r.pos.n2);
  await d.step(400);
  const lines = await freshDump(t, d);
  const n2 = moundFrom(lines, 'n2');
  R.check('the two sides are assigned OPPOSITE battle spin',
          n2 && n2.spinYou !== 0 && n2.spinYou === -n2.spinFoe,
          n2 ? `spinYou=${n2.spinYou} spinFoe=${n2.spinFoe}` : 'no mound line');
}

// ── 4b. THE NO-DEADLOCK CONTROL: forced-equal spin starves the cone ─────
//
// A bare "zero hits" control does not hold in this sim: wander-band
// breathing on top of circulation still lets facings cross occasionally
// even with both sides spinning the same way, at every garrison size
// tried while building this gate. The honest, uncontaminated signal is
// swing ATTEMPTS -- how often the cone finds anyone to strike at all --
// not landed hits, which the 50% roll dilutes further on top.
{
  const tSame = api('formix-battle-samespin');
  const dSame = driver(tSame, CART2);
  await dSame.boot(7, { level: 'gatebattle2' });
  let r = await dSame.inspect();
  await dSame.press('select', 6);
  await dev(dSame, 'down');            // samespin ON, BEFORE the send
  await dSame.send(r.pos.n1, r.pos.n2);
  await dSame.step(3600);              // 60s
  const same = await dSame.metric();

  const tOpp = api('formix-battle-oppspin');
  const dOpp = driver(tOpp, CART2);
  await dOpp.boot(7, { level: 'gatebattle2' });
  let r2 = await dOpp.inspect();
  await dOpp.send(r2.pos.n1, r2.pos.n2);
  await dOpp.step(3600);
  const opp = await dOpp.metric();

  R.check('forced-equal spin finds a target far less often than opposed',
          same.swings < opp.swings * 0.75,
          `same-spin swings=${same.swings} vs opposed swings=${opp.swings}`);
  R.check('no lua errors under forced-equal spin', dSame.errors().length === 0,
          dSame.errors().slice(0, 2).join(' | '));
}

// ── 5-6. CORPSES: appear on death, fade after corpseLife, survive a
//    save round trip mid-fade ──────────────────────────────────────────
{
  const t = api('formix-battle-corpses');
  const d = driver(t, CART1);
  await d.boot(7, { level: 'gatebattle' });
  let r = await d.inspect();
  await d.send(r.pos.n1, r.pos.n2);

  // Poll in small steps until the very first corpse appears -- a 1v1
  // duel produces at most one death to watch, which is what makes the
  // fade timing measurable without a second death muddying the count.
  // The engagement can run long before either side actually connects
  // (the 50% roll is real variance); give it a wide but bounded window.
  let m, deathT = null;
  for (let i = 0; i < 200 && deathT === null; i++) {
    await d.step(60);
    m = await d.metric();
    if (m.corpses > 0) deathT = m.t;
  }
  R.check('a death produces a corpse', deathT !== null,
          deathT === null ? 'no death within the window' : `at t=${deathT}`);

  if (deathT !== null) {
    // Metric polling is coarse (0.5-1s per sample), so the schedule below
    // checks the DIRECTION of the fade rather than pinning corpseLife
    // (20s, raised from 10 -- Luis, 2026-08-19: bodies were fading before
    // a player looking at the fight had time to register them) to the
    // exact frame.
    while ((await d.metric()).t < deathT + 8) await d.step(30);
    const stillThere = (await d.metric()).corpses > 0;
    R.check('the corpse is still fading well before corpseLife elapses',
            stillThere, `corpses at deathT+8s: ${stillThere}`);

    // ROUND TRIP MID-FADE, DELIBERATELY LATE (deathT+18s, two seconds
    // before it should vanish) -- not right after death. If the
    // roundtrip dropped or reset `t`, the corpse would get a FRESH 20s
    // from here and still be visible past deathT+23s below; rolling the
    // trip early would let the fade complete on its own by then and the
    // bug would pass unnoticed. Late is what makes this a real proof.
    while ((await d.metric()).t < deathT + 18) await d.step(30);
    await d.press('select', 6);
    await dev(d, 'a');   // roundtrip
    const rtLines = d.all().filter(l => l.startsWith('@roundtrip'));
    R.check('save round trip mid-fade succeeds',
            rtLines.some(l => l.includes('ok=true')), rtLines.join(' | '));

    while ((await d.metric()).t < deathT + 23) await d.step(30);
    const goneByNow = (await d.metric()).corpses === 0;
    R.check('and swept well after corpseLife -- the roundtrip did not restart the fade',
            goneByNow, `corpses at deathT+23s: ${goneByNow ? 0 : 'still present'}`);
  }
  R.check('no lua errors across the corpse lifecycle', d.errors().length === 0,
          d.errors().slice(0, 2).join(' | '));
}

// ── 6. PIXELS, AND THE FOG PARTNER: a corpse pile is live information
//    (04-fog.md), so it must obey the same rule a live ant does -- drawn
//    only where the ground is currently visible, gone the moment the
//    mound goes back to merely-discovered. Measured in pixels, because
//    the sim will happily keep a corpse in `a.corpses` long after the
//    renderer is correctly hiding it -- "is it drawn" is a screen
//    question, not a state question.
//
//    BOTH HALVES USE THE SAME SCREEN COORDINATES on purpose: the "PRESENT"
//    run records exactly where its corpse rendered (`@corpse`, added to
//    the debug dump for this gate); the "ABSENT" run then samples THOSE
//    SAME coordinates rather than guessing a spot in its own capture.
//    This sidesteps a real trap found building this gate: the mound's
//    ring art is a gradient with its own internal bands, so scanning a
//    wide area for "anything dark and reddish" also matches the fill
//    itself (thousands of false-positive pixels, measured), and even
//    matches DIFFERENTLY depending on whether the mound is red war-fill
//    or the green I-hold-it colour a decisive win flips it to. Comparing
//    ink at the identical coordinates across present-vs-absent needs no
//    colour model at all -- absent's own art at that exact spot is the
//    baseline, whatever colour it happens to be. ─────────────────────
let corpseScreenPos = null;
{
  const t = api('formix-battle-corpsefog');
  const d = driver(t, CART1);
  await d.boot(7, { level: 'gatebattle' });
  let r = await d.inspect();

  await d.send(r.pos.n1, r.pos.n2);
  await d.step(400);

  // PRESENT: my ant WINS this duel (no facing lock -- both sides fight
  // normally), so the loser's corpse sits at a mound I still hold --
  // present ground, corpse ink expected. Polled in SHORT steps (10
  // frames) once the fight is underway, and the position/screenshot are
  // captured the instant a corpse is seen -- the fade is fast enough
  // (10s) that a coarse poll can catch it most of the way to invisible.
  let m, wonT = null;
  for (let i = 0; i < 30 && !(m && m.theirs === 0); i++) {
    await d.step(180);
    m = await d.metric();
  }
  for (let i = 0; i < 60 && wonT === null; i++) {
    await d.step(10);
    m = await d.metric();
    if (m.corpses > 0) wonT = m.t;
  }
  R.check('a decisive duel produces a corpse on ground I hold', wonT !== null,
          wonT === null ? 'no decisive win with a corpse in the window' : `at t=${wonT}`);

  if (wonT !== null) {
    const lines = await freshDump(t, d);
    corpseScreenPos = firstCorpsePos(lines);
    R.check('the corpse reports a screen position', corpseScreenPos !== null,
            corpseScreenPos ? `${corpseScreenPos}` : 'no @corpse line');

    if (corpseScreenPos) {
      const shot1 = process.cwd() + '/test/shots/battle-corpse-present.png';
      await d.shot(shot1);
      const present = corpsePixels(shot1, ...corpseScreenPos, 15);
      R.check('corpse ink IS drawn on ground my ants hold',
              present > 0, `${present}px`);
    }
  }
}

// A SEPARATE gate/session for the ABSENT half: MY ant needs to LOSE this
// time, so the mound ends up enemy-held and unheld/uncontested by me --
// discovered-but-quiet, the state a corpse must NOT leak through. The
// facing lock (test-battle 3's device) guarantees the loss
// deterministically rather than hoping a 50% roll cooperates.
//
// THIS SESSION FETCHES ITS OWN `@corpse` POSITION -- caught while
// building this gate: the mound sits at the same spot both times, but
// the DEATH does not. Milling ants wander a spot on the ring rather
// than a fixed point, and the facing lock changes which ant lands which
// hit when, so the two sessions' RNG streams diverge before either ant
// dies -- reusing the PRESENT half's coordinates here sampled the wrong
// pixels and the assertion passed while a real sabotage (fog check
// deleted entirely) sat right next to it, undetected. `@corpse` is sim
// state, always printed regardless of whether the renderer is correctly
// hiding the body, so it is available here even though the pixel it
// names should come back empty.
if (corpseScreenPos) {
  const t = api('formix-battle-corpsefog-absent');
  const d = driver(t, CART1);
  await d.boot(7, { level: 'gatebattle' });
  let r = await d.inspect();

  await d.send(r.pos.n1, r.pos.n2);
  await d.step(400);
  await d.press('select', 6);
  await dev(d, 'left');   // facelock = faceaway: my ant cannot fight back

  let m, deathT = null;
  for (let i = 0; i < 200 && deathT === null; i++) {
    await d.step(60);
    m = await d.metric();
    if (m.mine === 0) deathT = m.t;
  }
  R.check('a forced loss produces a corpse on ground the enemy now holds',
          deathT !== null,
          deathT === null ? 'my ant never died' : `at t=${deathT}`);

  if (deathT !== null) {
    await d.step(60);   // let the mound's held/contested flags settle
    const lines = await freshDump(t, d);
    const n2 = moundFrom(lines, 'n2');
    R.check('the mound is discovered-but-quiet (sim state, not pixels)',
            n2 && n2.held === false && n2.owner !== 'you',
            n2 ? `held=${n2.held} owner=${n2.owner}` : 'no mound line');

    const myCorpsePos = firstCorpsePos(lines);
    R.check('this session also has its own corpse position to check',
            myCorpsePos !== null, myCorpsePos ? `${myCorpsePos}` : 'no @corpse line');

    if (myCorpsePos) {
      const shot2 = process.cwd() + '/test/shots/battle-corpse-absent.png';
      await d.shot(shot2);
      const absent = corpsePixels(shot2, ...myCorpsePos, 15);
      R.check('corpse ink is NOT drawn once the ground is only discovered',
              absent === 0, `${absent}px at ${myCorpsePos}`);
    }
  }
}

// ── 7. SOUND: the sim's own hit counter is the ground truth the audio
//    layer diffs, per its own comment -- assert on THAT counter rather
//    than on anything audio-side, since romdev records silence for
//    wasmcart and there is no signal to sample downstream of it. This
//    doubles as re-confirming `a.hits` still counts every landed blow
//    after the cadence and cone changes above (it is the same counter
//    test-battle 1-4 already exercised; this check is here for the
//    record the plan asks for, not because it is a new code path). ────
{
  const t = api('formix-battle-clangsource');
  const d = driver(t, CART2);
  await d.boot(7, { level: 'gatebattle2' });
  let r = await d.inspect();
  await d.send(r.pos.n1, r.pos.n2);
  const before = await d.metric();
  await d.step(1800);   // 30s
  const after = await d.metric();
  R.check('landed hits accumulate on the counter the audio layer diffs',
          after.hits > before.hits, `hits ${before.hits} -> ${after.hits}`);
}

process.exit(R.done() ? 0 : 1);
