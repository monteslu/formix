import { api, driver, makeReport } from './drive.mjs';
const t = api('formix-queen-suite');
const d = driver(t, process.cwd() + '/formix.wasc');
const R = makeReport();

// ---- gather 12 ants onto home, the way a player does ----
await d.boot(7);
let { pos, mound } = await d.inspect();
const owned = Object.entries(mound).filter(([,m]) => m.owner === 'you');
R.check('starts with 4 owned mounds', owned.length === 4, `got ${owned.length}`);
R.check('starts with no queens', owned.every(([,m]) => m.queens === 0));

const home = 'n1';
for (const [id, m] of owned) {
  if (id === home || m.g === 0) continue;
  await d.send(pos[id], pos[home]);
  await d.step(900);
}
({ mound } = await d.inspect());
R.check('gathered >=10 onto home', mound[home].g >= 10, `home g=${mound[home].g}`);

// ---- Y raises a queen ----
await d.tap(...pos[home]);
await d.press('y');
await d.step(60);
({ mound } = await d.inspect());
R.check('queen exists after Y', mound[home].queens === 1, `queens=${mound[home].queens}`);
R.check('queen cost exactly 10 ants', mound[home].g === 2, `garrison=${mound[home].g}`);

// ---- she lays larvae ----
await d.step(600);
({ mound } = await d.inspect());
const broodSeen = mound[home].brood;
R.check('queen lays brood', broodSeen > 0, `brood=${broodSeen}`);

// ---- larvae hatch into ants ----
const before = (await d.metric()).ants;
await d.step(3600);          // a full minute
const after = (await d.metric()).ants;
R.check('brood hatches into new ants', after > before, `ants ${before} -> ${after}`);

// ---- a second queen is allowed once affordable ----
({ mound } = await d.inspect());
if (mound[home].g >= 10) {
  await d.tap(...pos[home]);
  await d.press('y');
  await d.step(60);
  ({ mound } = await d.inspect());
  R.check('a mound holds more than one queen', mound[home].queens === 2, `queens=${mound[home].queens}`);
} else {
  R.check('a mound holds more than one queen', false, `could not afford: g=${mound[home].g}`);
}

R.check('no lua errors during the run', d.errors().length === 0, d.errors().slice(0,2).join(' | '));
process.exit(R.done() ? 0 : 1);
