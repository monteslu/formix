import { api, driver, makeReport } from './drive.mjs';
const t = api('formix-relief2');
const d = driver(t, process.cwd() + '/formix.wasc');
const R = makeReport();

// Reach the stranded state honestly: raise a queen (12->2), then the queen
// is the only producer. To get "no queen AND <10" we need the queen gone,
// which cannot happen on this level -- so drive the OTHER campaign level
// or verify via a mound with fewer ants and no queen anywhere.
// The `settle` level starts with 12 ants and ONE queen. `crowd` too.
// Gather has 12 and no queen. Spend below 10 with no queen requires a sink.
// The only sinks are queen(10) and upgrade(8, now blocked without a queen).
// => On the shipped levels the stranded state is UNREACHABLE. Assert that.
await d.boot(7);
let { pos, mound } = await d.inspect();
const sinks = [];
await d.tap(...pos.n1);
await d.press('x');
if (/upgrade ok=true/.test(d.lastIntent()||'')) sinks.push('upgrade');
await d.press('y');
if (/queen ok=true/.test(d.lastIntent()||'')) sinks.push('queen');
console.log('  affordable sinks with 4 ants:', sinks.length? sinks.join(','):'none');
R.check('with 4 ants nothing can be spent', sinks.length === 0, sinks.join(','));

// And the invariant that matters: after ANY sequence, either you have >=10
// ants or you have a queen. Fuzz it.
await d.boot(7);
({ pos, mound } = await d.inspect());
const ids = Object.keys(pos);
for (let i = 0; i < 24; i++) {
  const a = ids[i % ids.length], b = ids[(i*3+1) % ids.length];
  await d.send(pos[a], pos[b]);
  if (i % 4 === 3) { await d.press('y'); }
  if (i % 5 === 4) { await d.press('x'); }
  await d.step(240);
}
await d.step(1200);
const m = await d.metric();
({ mound } = await d.inspect());
const queens = Object.values(mound).reduce((a,x)=>a+x.queens,0);
console.log(`  after fuzz: ants=${m.ants} queens=${queens}`);
R.check('INVARIANT: always >=10 ants OR a queen exists',
        m.ants >= 10 || queens > 0, `ants=${m.ants} queens=${queens}`);
R.check('no lua errors during fuzz', d.errors().length===0, d.errors().slice(0,3).join(' | '));
process.exit(R.done() ? 0 : 1);
