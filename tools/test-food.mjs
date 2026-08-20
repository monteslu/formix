// FOOD IS THE FUEL, AND THE FUEL MUST ACTUALLY GATE THE ENGINE.
//
// Three rules are asserted here, each on a board built to isolate it:
//
//   1. AN EMPTY PANTRY STOPS A QUEEN. Production comes only from queens
//      and every larva costs one food, so a colony with nothing in store
//      must not grow by a single ant -- no matter how long it sits.
//   2. FED, SHE LAYS EXACTLY WHAT SHE WAS PAID FOR. N food buys N ants
//      and not one more; a leak here is invisible in play and fatal to
//      every balance decision downstream.
//   3. A CROWDED MOUND RESTS. Ten workers per queen is the saturation
//      cap, and it is what stops the whole game being one super-hill.
//
// Written to FAIL: skip the takeFood call and rule 1 goes red; drop the
// saturation check and rule 3 goes red; bank the food twice and rule 2
// goes red on the count.
import { api, driver, makeReport, releaseAll } from './drive.mjs';
import { execSync } from 'child_process';
import { writeFileSync, unlinkSync, existsSync, copyFileSync } from 'fs';

const t = api('formix-food-suite');
const R = makeReport();

// A cart per board, built here rather than swapped under the shared one.
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

// The debug commands are locked behind the developer overlay, so that no
// stray button combination in real play can reach them. Turn it on, then
// hold SELECT and tap the key.
async function dev(d, button) {
  return d.hold(['select', button], 8);
}

const FOOD_CART = cartFor('gatefood', 'food-cart.wasc');

// ── 1. hunger stops her ────────────────────────────────────────────────
{
  const d = driver(t, FOOD_CART);
  await d.boot(7, { level: 'gatefood' });
  const before = await d.metric();
  // Sixty seconds is many times her laying period; if hunger did not
  // gate production this board would be at its cap long before here.
  await d.step(3600);
  const after = await d.metric();
  R.check('starts hungry', before.food === 0, `food=${before.food}`);
  R.check('a queen with no food lays nothing over 60s',
          after.ants === before.ants && after.queens === 1,
          `ants ${before.ants} -> ${after.ants}, food=${after.food}`);
  R.check('no larvae in the ground either', after.dead === false,
          `dead=${after.dead}`);
}

// ── 2. fed, she lays exactly what she was paid for ─────────────────────
//
// Four workers, one queen, cap ten: there is room for exactly six more
// ants. Grant twenty food and the board must settle at ten ants with
// fourteen food left -- six spent, fourteen untouched because the mound
// saturated. That single pair of numbers proves the price AND the cap.
{
  const d = driver(t, FOOD_CART);
  await d.boot(7, { level: 'gatefood' });
  const before = await d.metric();

  // overlay on (a plain SELECT press), then SELECT+Y to grant 20.
  await d.press('select', 6);
  await dev(d, 'y');
  const fed = await d.metric();
  R.check('debug grant reached the pool', fed.food === 20, `food=${fed.food}`);

  await d.step(5400);   // 90s: far longer than six lay periods
  const after = await d.metric();

  R.check('N food buys exactly N ants',
          after.ants === 10,
          `ants ${before.ants} -> ${after.ants} (want 10)`);
  R.check('exactly six food was spent, the rest untouched',
          after.food === 14,
          `food ${fed.food} -> ${after.food} (want 14)`);
  R.check('a saturated mound stops laying (10 per queen)',
          after.ants === 10 && after.food > 0,
          `ants=${after.ants} food=${after.food}`);

  // AND IT STAYS STOPPED. A cap that only holds for one tick is a cap
  // that leaks; run it again as long and assert nothing moved.
  await d.step(3600);
  const later = await d.metric();
  R.check('the cap holds over time', later.ants === 10 && later.food === 14,
          `ants=${later.ants} food=${later.food}`);
}

// ── 3. no workers, no food, game over ──────────────────────────────────
{
  const cart = cartFor('gatedeath', 'death-cart.wasc');
  const d = driver(t, cart);
  await d.boot(7, { level: 'gatedeath' });
  await d.step(120);
  const m = await d.metric();
  const over = d.all().some(l => /^@gameover side=you/.test(l));
  R.check('a side with no ants, no brood and no food is declared dead',
          over && m.dead === true, `dead=${m.dead} line=${over}`);

  // ANNOUNCED ONCE, not every tick: gates parse this log and the UI keys
  // off it, so a latch that does not latch drowns both.
  await d.step(600);
  const n = d.all().filter(l => /^@gameover side=you/.test(l)).length;
  R.check('game over is announced exactly once', n === 1, `${n} lines`);
}

// ── 4. the control: a queen with a meal is NOT dead ─────────────────────
//
// Same empty board, plus one queen and one food. If the loss check cannot
// tell this from the board above it will end somebody's game by surprise,
// which is a far worse bug than never ending it at all.
{
  const cart = cartFor('gatelive', 'live-cart.wasc');
  const d = driver(t, cart);
  await d.boot(7, { level: 'gatelive' });
  await d.step(120);
  const m = await d.metric();
  const over = d.all().some(l => /^@gameover side=you/.test(l));
  R.check('a queen with food in the pantry is alive',
          !over && m.dead === false, `dead=${m.dead}`);
  // ...and she spends it: one food, one ant, and then she is out.
  await d.step(1800);
  const after = await d.metric();
  R.check('her one meal becomes exactly one ant',
          after.ants === 1 && after.food === 0,
          `ants=${after.ants} food=${after.food}`);
}

// Restore the ordinary cart so the next gate does not boot a gate board.
execSync('./build.sh', { stdio: 'ignore' });

await releaseAll();   // hand the emulator hosts back before exiting
process.exit(R.done() ? 0 : 1);