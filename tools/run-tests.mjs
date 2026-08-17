// The suite. Every test drives the real cart through romdev and asserts on
// what the SIM reports or what the PIXELS show -- never on a claim.
import { execSync } from 'child_process';
import { existsSync, readFileSync } from 'fs';

// REFUSE TO RUN AGAINST AN OVERRIDDEN CART. `app/startlevel` boots the
// game into a named level, which is exactly what most of these gates do
// NOT want: they assume Gather's opening board. A stale marker left from
// debugging silently made test-deadend and test-relief play the wrong
// level and report failures that had nothing to do with the code. A wrong
// answer is worse than no answer, so stop instead.
if (existsSync('app/startlevel')) {
  const want = readFileSync('app/startlevel', 'utf8').trim();
  console.error(`REFUSING TO RUN: app/startlevel is set to "${want}".`);
  console.error('The suite assumes the campaign opens on Gather. Remove the');
  console.error('marker and rebuild:  rm app/startlevel && ./build.sh');
  process.exit(2);
}
const suites = ['test-reachable', 'test-queen', 'test-grey', 'test-gameplay',
                'test-longrun', 'test-deadend', 'test-strand',
                'test-campaign', 'test-render', 'test-camera',
                // THE CART-REBUILDING GATES GO LAST, all of them. test-war
                // was the first, for the reason below; test-food and
                // test-bootstrap pack their own boards the same way and
                // belong in the same quarantine. Running them before
                // test-render is exactly the mistake the note describes.
                'test-war', 'test-food', 'test-forage', 'test-locrules',
                'test-bootstrap'];
// LAST, ON PURPOSE: test-war rebuilds the cart twice (it needs its own
// level) and the pixel gate that followed it came back with a completely
// black frame on two separate runs, then passed 4/4 in isolation. Putting
// the rebuilding gate at the end keeps it away from anything that reads
// pixels.
const pause = ms => new Promise(r => setTimeout(r, ms));
let bad = 0;
for (const s of suites) {
  console.log(`\n=== ${s} ===`);
  try { execSync(`node tools/${s}.mjs`, { stdio: 'inherit' }); }
  catch { bad++; }
  await pause(1500);   // let the server settle between suites
}
console.log(bad ? `\n${bad} SUITE(S) FAILED` : '\nALL SUITES GREEN');
process.exit(bad ? 1 : 0);
