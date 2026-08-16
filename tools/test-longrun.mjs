import { api, driver, makeReport } from './drive.mjs';
const t = api('formix-long-suite');
const d = driver(t, process.cwd() + '/formix.wasc');
const R = makeReport();

// THE SESSION THAT WENT WRONG: play a long time WITHOUT ever raising a
// queen, which is what a confused player does. The colony must not be
// able to reach an unrecoverable state in silence.
await d.boot(7);
const start = await d.metric();
await d.step(60 * 60 * 4);          // four minutes unattended
const idle = await d.metric();
R.check('idle colony does not lose ants', idle.ants >= start.ants,
        `${start.ants} -> ${idle.ants}`);

// Now the real failure shape: spend everything on sends, never queen.
await d.boot(7);
let { pos, mound } = await d.inspect();
for (let round = 0; round < 6; round++) {
  ({ mound } = await d.inspect());
  const from = Object.entries(mound).find(([,m]) => m.owner==='you' && m.g>0);
  const to   = Object.entries(mound).find(([id,m]) => m.owner!=='you');
  if (!from || !to) break;
  await d.send(pos[from[0]], pos[to[0]]);
  await d.step(1200);
}
const spent = await d.metric();
({ mound } = await d.inspect());
const totalG = Object.values(mound).reduce((a,m)=>a+m.g,0);
R.check('ants are never silently destroyed by sends',
        spent.ants === totalG + spent.moving,
        `metric ants=${spent.ants} garrisons=${totalG} moving=${spent.moving}`);

// Can the player still recover? Somewhere must be able to reach 10.
const best = Math.max(...Object.values(mound).map(m=>m.g));
R.check('colony retains enough ants to ever queen (>=10 total)',
        spent.ants >= 10, `ants=${spent.ants} best mound=${best}`);

R.check('no lua errors over a long run', d.errors().length === 0, d.errors().slice(0,3).join(' | '));
process.exit(R.done() ? 0 : 1);
