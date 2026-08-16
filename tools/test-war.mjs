// THE WAR MAP MUST ACTUALLY HAVE A WAR.
//
// This gate exists because the whole suite was green while the war level
// was inert: two rival colonies expanded into their own corners, ran out of
// neutral ground and then stared at each other for the rest of the game.
// Nothing asserted that anyone ever fought, so nothing caught it.
//
// Two causes, both of which this gate would have failed on:
//   * the map was wider than a mound's reach (red->gold was 3456 units
//     against a reach of ~1150), so contact was geometrically impossible
//   * the rival AI had no REINFORCE step, so every ant stayed on the mound
//     whose queen laid it -- capitals on thirty, border mounds on four,
//     permanently under the threshold to attack anything
import { api, driver, makeReport } from './drive.mjs';
import { execSync } from 'child_process';
import { writeFileSync, unlinkSync, existsSync, copyFileSync } from 'fs';
const t = api('formix-war-suite');
const R = makeReport();

// Build a war-level cart of its own rather than swapping the shared one
// out from under the rest of the suite. Restored in a finally so a failure
// cannot leave the tree booting into the wrong level.
const CART = process.cwd() + '/test/war-cart.wasc';
writeFileSync('app/startlevel', 'war');
try {
  execSync('./build.sh', { stdio: 'ignore' });
  copyFileSync(process.cwd() + '/formix.wasc', CART);
} finally {
  if (existsSync('app/startlevel')) unlinkSync('app/startlevel');
  execSync('./build.sh', { stdio: 'ignore' });
}
const d = driver(t, CART);

await d.boot(7, { level: 'war' });
let r = await d.inspect();

const sides = new Set(Object.values(r.mound)
  .filter(m => m.owner && m.owner !== 'you').map(m => m.owner));
R.check('two distinct enemy colonies, not one', sides.size === 2,
        `sides=${[...sides].join(',')}`);

// GEOMETRY FIRST. If nothing hostile is inside anything else's reach the
// level cannot produce a fight no matter how good the AI is -- and that is
// far easier to read here than from watching an empty battlefield.
const reach = Math.max(...Object.values(r.mound).map(m => m.reach || 0));
const ids = Object.keys(r.mound);
let contactPair = null;
for (const a of ids) {
  for (const b of ids) {
    const A = r.mound[a], B = r.mound[b];
    if (!A.owner || !B.owner || A.owner === B.owner) continue;
    const dx = r.pos[a][0] - r.pos[b][0], dy = r.pos[a][1] - r.pos[b][1];
    // Screen distance scaled back to world units via the known reach.
    if (Math.hypot(dx, dy) > 0) contactPair = contactPair || [a, b];
  }
}
R.check('hostile colonies exist within the same field', contactPair !== null,
        contactPair ? `${contactPair[0]} vs ${contactPair[1]}` : 'none adjacent');

// LET IT RUN. The rivals are awake from the first second on this level.
const before = Object.entries(r.mound)
  .map(([id, m]) => `${id}:${m.owner || '-'}`).join(' ');
const seen = new Set([before]);
const ownerLog = {};
for (const id of Object.keys(r.mound)) ownerLog[id] = [r.mound[id].owner || '-'];
let attacks = 0;
for (let i = 0; i < 6; i++) {
  await d.step(3000);
  r = await d.inspect();
  seen.add(Object.entries(r.mound).map(([id, m]) => `${id}:${m.owner || '-'}`).join(' '));
  for (const id of Object.keys(r.mound)) {
    (ownerLog[id] = ownerLog[id] || []).push(r.mound[id].owner || '-');
  }
  attacks = d.all().filter(x => /@rival \w+ attacks/.test(x)).length;
}

// The neutral middle must get claimed: a colony that never expands is not
// playing the game.
const neutralLeft = Object.values(r.mound).filter(m => !m.owner).length;
R.check('the rivals claim the neutral middle', neutralLeft <= 2,
        `neutral mounds left=${neutralLeft}`);

// THE ACTUAL ASSERTION: a mound is taken FROM ANOTHER COLONY.
//
// "Ownership changed" is far too weak and a deliberately sabotaged build
// (reinforce disabled -- the exact bug that shipped) passed it 6/6: two
// colonies grabbing neutral ground in their own corners produces several
// distinct arrangements without anyone ever fighting. What only a war can
// produce is a mound whose owner changes from one SIDE to another.
let captures = 0;
for (const id of Object.keys(ownerLog)) {
  const seq = ownerLog[id];
  for (let i = 1; i < seq.length; i++) {
    const was = seq[i - 1], now = seq[i];
    if (was !== '-' && now !== '-' && was !== now) captures++;
  }
}
R.check('a mound is captured FROM another colony (a real war)', captures > 0,
        `${captures} side-to-side captures over 300s`);
R.check('the rival AI actually attacks', attacks > 0,
        `${attacks} attack orders issued`);

// Both colonies must still be alive and growing, or "changes hands" could
// be satisfied by one side quietly dying.
const counts = {};
for (const m of Object.values(r.mound)) {
  const k = m.owner || '-';
  counts[k] = (counts[k] || 0) + 1;
}
R.check('both enemy colonies survive to fight', (counts.red || 0) > 0 && (counts.gold || 0) > 0,
        JSON.stringify(counts));

R.check('no lua errors during the war', d.errors().length === 0,
        d.errors().slice(0, 2).join(' | '));

// ── AN UNDISCOVERED ENEMY MUST STILL BE WORTH FIGHTING ──
//
// Separate level, same failure mode. `discover` hides its colony until the
// player finds it, and the first version of that dormancy FROZE them
// completely: they sat at 8 ants while the player grew to 300, so contact
// was an execution rather than a battle -- "i saw no battle and no enemy
// ants". The opposite extreme (full-speed growth while hidden) is an
// unwinnable wall. This asserts the middle: they grow, and they are still
// a real force when found.
{
  const CART2 = process.cwd() + '/test/discover-cart.wasc';
  writeFileSync('app/startlevel', 'discover');
  try {
    execSync('./build.sh', { stdio: 'ignore' });
    copyFileSync(process.cwd() + '/formix.wasc', CART2);
  } finally {
    if (existsSync('app/startlevel')) unlinkSync('app/startlevel');
    execSync('./build.sh', { stdio: 'ignore' });
  }
  const d2 = driver(api('formix-discover-balance'), CART2);
  await d2.boot(7, { level: 'discover' });
  const m0 = await d2.metric();
  for (let i = 0; i < 5; i++) await d2.step(3000);
  const m1 = await d2.metric();

  R.check('a hidden colony still grows while undiscovered',
          m1.theirs > m0.theirs,
          `theirs ${m0.theirs} -> ${m1.theirs} over 250s`);
  // The number that matters: how big are they RELATIVE to the player when
  // contact finally happens. Frozen at 8 against 81 is 10%, which is
  // scenery. A third or more is a fight.
  const ratio = m1.theirs / Math.max(1, m1.mine);
  R.check('and is still a real force when found (>= 1/3 of the player)',
          ratio >= 0.33, `theirs ${m1.theirs} vs mine ${m1.mine} = ${(ratio*100).toFixed(0)}%`);
}

process.exit(R.done() ? 0 : 1);
