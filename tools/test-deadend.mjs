import { api, driver, makeReport } from './drive.mjs';
const t = api('formix-dead-suite');
const d = driver(t, process.cwd() + '/formix.wasc');
const R = makeReport();

// Reproduce the reported end state: ants spent, no queen, nothing left.
await d.boot(7);
let { pos, mound } = await d.inspect();
// Gather 12 to home, then blow 10 on a queen -> 2 left, but a queen exists
// so production recovers. The BAD case is spending on anything that does
// NOT produce. X is now blocked, so try: can ants be lost any other way?
for (const [id,m] of Object.entries(mound)) {
  if (id==='n1' || m.owner!=='you' || m.g===0) continue;
  await d.send(pos[id], pos.n1); await d.step(900);
}
({ mound } = await d.inspect());
R.check('12 gathered', mound.n1.g === 12, `g=${mound.n1.g}`);

// Attack a neutral mound with too few ants: do the attackers die for nothing?
const neutral = Object.entries(mound).find(([,m]) => m.owner===null);
const [nid, nm] = neutral;
const beforeAnts = (await d.metric()).ants;
await d.send(pos.n1, pos[nid]);
await d.step(1800);
const afterAnts = (await d.metric()).ants;
({ mound } = await d.inspect());
R.check('attacking neutral ground does not annihilate the army',
        afterAnts >= beforeAnts - nm.energy - 1,
        `ants ${beforeAnts} -> ${afterAnts}, target energy was ${nm.energy}`);
R.check('the attack actually took the mound',
        mound[nid].owner === 'you', `owner=${mound[nid].owner}`);

// After taking it, is a queen still reachable somewhere?
const total = (await d.metric()).ants;
R.check('a queen is still reachable after expanding', total >= 10, `ants=${total}`);

// THE REAL DEAD END: no queen, fewer than 10 ants, no production.
// Prove production is the ONLY way ants appear, and that with a queen it works.
await d.boot(7);
({ pos, mound } = await d.inspect());
const a0 = (await d.metric()).ants;
await d.step(60*60*3);
const a1 = (await d.metric()).ants;
R.check('without a queen the colony NEVER grows (so <10 ants is terminal)',
        a1 === a0, `${a0} -> ${a1}`);

R.check('no lua errors', d.errors().length === 0, d.errors().slice(0,2).join(' | '));
process.exit(R.done() ? 0 : 1);
