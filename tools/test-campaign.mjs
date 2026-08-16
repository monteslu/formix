import { api, driver, makeReport } from './drive.mjs';
const t = api('formix-campaign');
const d = driver(t, process.cwd() + '/formix.wasc');
const R = makeReport();

// Complete Gather the way a player does, then move to the next level and
// prove the new level is playable -- ownership, fog and production all
// re-established rather than carried over broken.
await d.boot(7);
let { pos, mound } = await d.inspect();
for (const [id,m] of Object.entries(mound)) {
  if (id==='n1' || m.owner!=='you' || m.g===0) continue;
  await d.send(pos[id], pos.n1); await d.step(900);
}
await d.tap(...pos.n1); await d.press('y'); await d.step(90);
({ mound } = await d.inspect());
R.check('Gather completed (queen raised)', mound.n1.queens === 1);

const done = d.all().filter(x=>x.startsWith('@level'));
R.check('level reports complete', done.length > 0, done.join(' ') || 'no @level line');

// START advances to the next field.
await d.press('start');
await d.step(240);
const after = await d.inspect();
const ids = Object.keys(after.mound);
R.check('next level loaded', ids.length > 0, `mounds=${ids.length}`);

// THE WORLD MUST ACTUALLY BE REBUILT. This is where the old version of
// this gate passed a broken game: `menu.wantNextLevel` was set and NOTHING
// consumed it, so START did nothing at all and the assertions below --
// "some mounds exist", "you own some ground" -- were satisfied by the
// PREVIOUS level still sitting there. Assert the shape of the new level
// instead: Settle starts with exactly ONE mound held, ten ants and a
// queen, so carrying Gather's four owned mounds over fails it.
const started = d.all().filter(x => x.startsWith('@level started'));
R.check('the cart reports starting the next level', started.length > 0,
        started.join(' ') || 'no @level started line');
const ownedNow = Object.values(after.mound).filter(m => m.owner === 'you').length;
R.check('Settle starts from ONE mound, not Gather\'s four', ownedNow === 1,
        `owned=${ownedNow}`);
const neutral = Object.values(after.mound).filter(m => !m.owner).length;
R.check('the rest of the new field is unclaimed', neutral >= 4, `neutral=${neutral}`);
const home2 = Object.entries(after.mound).find(([,m]) => m.owner === 'you');
R.check('the new home has its starting queen', home2 && home2[1].queens === 1,
        home2 ? `queens=${home2[1].queens}` : 'no owned mound');
const m2 = await d.metric();
R.check('player has ants on the new level', m2.ants > 0, `ants=${m2.ants}`);
R.check('no lua errors across the transition', d.errors().length===0,
        d.errors().slice(0,3).join(' | '));
await d.shot(process.cwd()+'/test/shots/level2.png');
process.exit(R.done() ? 0 : 1);
