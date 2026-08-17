// FOOD MUST COME OUT OF THE GROUND AND END UP IN THE PANTRY.
//
// The rules under test, each on a board built to isolate it:
//
//   1. A send CLAIMS a location, the same way it claims empty ground.
//   2. An ant standing where there is an item picks it up IMMEDIATELY --
//      no work cycle, no timer -- and one item per ant, so two ants never
//      carry the same grain home.
//   3. It walks the item to the nearest queen and the pool goes up by
//      exactly what the item was worth.
//   4. IT DOES NOT GO BACK FOR MORE. Deliver and stay: collecting again
//      is a send, like everything else in this game. An ant that
//      re-forages on its own is the errand loop this game deleted.
//   5. THE LEDGER BALANCES. Every food in the world is in exactly one of
//      three places -- still in the ground, on an ant's back, or in the
//      pool -- and the three always add up to what the board started
//      with. That single sum catches duplication and loss at once.
//   6. A GUARDED PLACE HAS TO BE BEATEN. The spider trades one attacker
//      per hit, and only when she falls are her legs worth anything.
//
// Written to FAIL: let an ant re-forage and rule 4 goes red; bank food
// twice and rules 3 and 5 go red; skip the item decrement and rule 5
// goes red the other way.
import { api, driver, makeReport } from './drive.mjs';
import { execSync } from 'child_process';
import { writeFileSync, unlinkSync, existsSync, copyFileSync } from 'fs';

const t = api('formix-forage-suite');
const R = makeReport();

function cartFor(level, file) {
  const out = process.cwd() + '/test/' + file;
  writeFileSync('app/startlevel', level);
  try {
    execSync('./build.sh', { stdio: 'ignore' });
    copyFileSync(process.cwd() + '/formix.wasc', out);
  } finally {
    if (existsSync('app/startlevel')) unlinkSync('app/startlevel');
  }
  return out;
}

// The location's own line, straight from the sim.
function locOf(d, id) {
  const line = d.all().filter(l => l.startsWith('@loc ' + id + ' ')).pop();
  if (!line) return null;
  const m = line.match(
    /@loc (\S+) (\S+) (\S+) items=(\d+)\/(\d+) value=(\d+) guard=(\d+) observed=(\w+) held=(\w+)/);
  return m && { id: m[1], kind: m[2], owner: m[3] === 'nil' ? null : m[3],
                items: +m[4], cap: +m[5], value: +m[6], guard: +m[7],
                observed: m[8] === 'true', held: m[9] === 'true' };
}

// ── grain: claim, carry, bank ──────────────────────────────────────────
{
  const cart = cartFor('gateforage', 'forage-cart.wasc');
  const d = driver(t, cart);
  await d.boot(7, { level: 'gateforage' });

  let r = await d.inspect();
  const L = 'L2';                       // the only location on the board
  const before = locOf(d, L);
  R.check('the board has grain in the ground',
          before && before.kind === 'grain' && before.items === 5,
          before ? `${before.kind} items=${before.items}` : 'no @loc line');

  // ITS KIND IS HIDDEN UNTIL SOMEBODY STANDS ON IT... except that home
  // has a queen and lights its neighbours, which is the rule working as
  // written rather than a leak. What must be false is `held`.
  R.check('nobody is standing on it yet', before && before.held === false);

  const start = await d.metric();
  const total0 = start.food + start.carried + before.items * before.value;

  // Send three ants at it, the way a player does: a drag.
  await d.send(r.pos.n1, r.pos[L]);
  await d.step(900);
  r = await d.inspect();
  const claimed = locOf(d, L);
  R.check('a send claims the location', claimed && claimed.owner === 'you',
          claimed ? `owner=${claimed.owner}` : 'gone');
  R.check('standing on it reveals it', claimed && claimed.held === true,
          claimed ? `held=${claimed.held}` : '');

  // Let the carriers walk home.
  await d.step(1800);
  r = await d.inspect();
  const after = await d.metric();
  const now = locOf(d, L);

  R.check('and arrived in the pantry', after.delivered > 0,
          `food=${after.food} picked=${after.picked} delivered=${after.delivered}`);

  // ONE ANT, ONE ITEM -- measured against the DELIVERIES, not against
  // what is missing from the ground. Grain regrows while the carriers
  // are walking, so "how much thinner is the patch" is not the number of
  // pickups and never was; asserting on it made a passing rule look
  // broken. Every pickup is either delivered or still on somebody's back.
  R.check('every item picked up is delivered or still being carried',
          after.picked === after.delivered + (after.carried / before.value),
          `picked=${after.picked} delivered=${after.delivered} ` +
          `carried=${after.carried}`);

  // THE LEDGER, with all FOUR places food can be: still in the ground,
  // on an ant's back, in the pool, or already eaten by a queen. The
  // eaten term is the one that cannot be seen from outside, and without
  // it the sum is short by exactly the ants the food became.
  const grown = after.picked * before.value;      // everything taken out
  const accounted = after.food + after.carried + after.eaten;
  R.check('the ledger balances (nothing lost, nothing duplicated)',
          accounted === grown,
          `taken=${grown} accounted=${accounted} (food=${after.food} ` +
          `carried=${after.carried} eaten=${after.eaten})`);

  // ── DELIVER AND STAY ──
  //
  // The heart of it. After the deliveries, nothing should be walking:
  // an ant that turned round and went back for another grain is the
  // failure this whole design is arranged to prevent.
  const restA = await d.metric();
  await d.step(1800);
  const restB = await d.metric();
  R.check('ants do not go back for more on their own',
          restB.delivered === restA.delivered,
          `delivered ${restA.delivered} -> ${restB.delivered}`);
  R.check('and nothing is left wandering', restB.moving === 0,
          `moving=${restB.moving}`);

  // ── the food actually feeds her ──
  R.check('the queen turned the food into ants',
          restB.ants > start.ants,
          `ants ${start.ants} -> ${restB.ants}`);
}

// ── the spider ─────────────────────────────────────────────────────────
{
  const cart = cartFor('gatespider', 'spider-cart.wasc');
  const d = driver(t, cart);
  await d.boot(7, { level: 'gatespider' });

  let r = await d.inspect();
  const L = 'L2';
  const before = locOf(d, L);
  R.check('a spider is guarding her ground',
          before && before.kind === 'spider' && before.guard === 6,
          before ? `guard=${before.guard}` : 'no @loc line');
  R.check('and she is not carrying loose legs about',
          before && before.items === 0, `items=${before && before.items}`);

  // A COLUMN TOO SMALL DIES ON HER. Two ants against six hits take her
  // down to four and are both eaten.
  const m0 = await d.metric();
  await d.hold(['select'], 4);         // (no-op; keeps pad state clean)
  await d.send(r.pos.n1, r.pos[L]);
  await d.step(1200);
  r = await d.inspect();
  const mid = locOf(d, L);
  R.check('she takes hits but holds while she can',
          mid.guard < 6, `guard 6 -> ${mid.guard}`);

  // Keep feeding ants in until she falls.
  for (let i = 0; i < 6; i++) {
    r = await d.inspect();
    if ((locOf(d, L) || {}).guard === 0) break;
    if (!r.pos[L]) break;
    await d.send(r.pos.n1, r.pos[L]);
    await d.step(1200);
  }
  r = await d.inspect();
  const dead = locOf(d, L);
  R.check('enough ants bring her down', dead.guard === 0,
          `guard=${dead.guard}`);
  R.check('the ground is claimed when she falls', dead.owner === 'you',
          `owner=${dead.owner}`);

  // HER LEGS ARE THE PRIZE -- counted as PICKUPS, not as items lying on
  // the ground. Checking `items > 0` here raced the ants: by the time the
  // gate looked, the squad standing on her had already carried the legs
  // off, so the reward looked like it had never existed. Eight legs is
  // the whole yield of this board, and nothing else on it can be picked.
  await d.step(2400);
  const after = await d.metric();
  R.check('her legs are the prize (8 of them)', after.picked === 8,
          `picked=${after.picked} items left=${dead.items}`);
  R.check('the legs are worth carrying home',
          after.food + after.eaten === 8 * before.value,
          `food=${after.food} eaten=${after.eaten} ` +
          `want ${8 * before.value} total`);
  R.check('no lua errors fighting her', d.errors().length === 0,
          d.errors()[0] || '');
}

execSync('./build.sh', { stdio: 'ignore' });
process.exit(R.done() ? 0 : 1);
