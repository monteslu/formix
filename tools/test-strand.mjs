import { api, driver, makeReport } from './drive.mjs';
const t = api('formix-strand-suite');
const d = driver(t, process.cwd() + '/formix.wasc');
const R = makeReport();

// Can a player strand themselves below 10 with no queen, by ordinary play?
// Throw the whole colony at the most expensive neutral mound repeatedly.
await d.boot(7);
let { pos, mound } = await d.inspect();
const start = (await d.metric()).ants;

let rounds = 0;
while (rounds++ < 10) {
  ({ mound } = await d.inspect());
  const neutral = Object.entries(mound)
    .filter(([,m]) => m.owner !== 'you')
    .sort((a,b) => b[1].energy - a[1].energy)[0];
  const src = Object.entries(mound)
    .filter(([,m]) => m.owner === 'you' && m.g > 0)
    .sort((a,b) => b[1].g - a[1].g)[0];
  if (!neutral || !src) break;
  await d.send(pos[src[0]], pos[neutral[0]]);
  await d.step(1500);
}
const end = (await d.metric()).ants;
({ mound } = await d.inspect());
const queens = Object.values(mound).reduce((a,m)=>a+m.queens,0);
console.log(`  ants ${start} -> ${end}, queens=${queens}`);
R.check('ordinary aggressive play cannot strand you below a queen',
        end >= 10 || queens > 0,
        `ants=${end} queens=${queens} -- UNWINNABLE if both low`);

R.check('no lua errors', d.errors().length === 0, d.errors().slice(0,2).join(' | '));
process.exit(R.done() ? 0 : 1);
