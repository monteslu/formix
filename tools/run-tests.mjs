// The suite. Every test drives the real cart through romdev and asserts on
// what the SIM reports or what the PIXELS show -- never on a claim.
import { execSync } from 'child_process';
import { existsSync, readFileSync, readdirSync } from 'fs';

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
const suites = ['test-reachable', 'test-overlap', 'test-queen', 'test-grey', 'test-gameplay',
                'test-longrun', 'test-deadend', 'test-strand',
                'test-campaign', 'test-render', 'test-camera',
                // PLAN 06's two UI gates. Neither packs its own board --
                // both drive the ordinary cart through the pause menu and
                // the overlay-gated progress instruments -- so they sit
                // with the cheap gates rather than in the rebuild
                // quarantine below.
                'test-progress', 'test-celebrate',
                // The music/sfx split. Drives the real pause menu (two
                // rows a player can reach) and reads the cart's own
                // @audio report, so it packs no board and sits with the
                // cheap gates.
                'test-audio',
                // THE CART-REBUILDING GATES GO LAST, all of them. test-war
                // was the first, for the reason below; test-food and
                // test-bootstrap pack their own boards the same way and
                // belong in the same quarantine. Running them before
                // test-render is exactly the mistake the note describes.
                'test-war', 'test-food', 'test-forage', 'test-locrules',
                'test-bootstrap', 'test-fog3',
                // test-siege was written during plan 05 and never added to
                // this list -- it packs `gatesiege`, so it belongs in the
                // quarantine, and it has been running only by hand since.
                // test-queencarry (plan 06) packs `gatesiege2` next to it.
                'test-siege', 'test-queencarry',
                // The last campaign level. Packs its own `open` board and
                // rebuilds twice, so it belongs in the quarantine.
                'test-open'];

// NOT IN THE LIST, ON PURPOSE. There are more gate FILES in tools/ than
// there are entries above, which reads as an oversight to anyone who
// counts them, so it is written down rather than left to be rediscovered:
//
//   test-battle, test-spider  heavyweights, run by hand. Both drive long
//                             fights and neither is quick enough to earn
//                             its place in a suite that already takes six
//                             minutes.
//   test-fog                  superseded by test-fog3, which asserts the
//                             same rule on a board that does not depend on
//                             a level's difficulty tuning.
//
// Anything else missing from `suites` is a bug, not a decision.
const UNREGISTERED = ['test-battle', 'test-spider', 'test-fog'];
// LAST, ON PURPOSE: test-war rebuilds the cart twice (it needs its own
// level) and the pixel gate that followed it came back with a completely
// black frame on two separate runs, then passed 4/4 in isolation. Putting
// the rebuilding gate at the end keeps it away from anything that reads
// pixels.
const pause = ms => new Promise(r => setTimeout(r, ms));

// IS THE SERVER ALIVE? Every gate drives the real cart through romdev on
// :7331, so a dead server makes all of them fail with ECONNREFUSED -- which
// on screen is indistinguishable from a red assertion. That is not
// hypothetical: on 2026-08-19 the server was OOM-killed twice mid-suite, and
// the runs came back "2 SUITE(S) FAILED" / "7 SUITE(S) FAILED" with nothing
// saying the host had died. Hours are cheap to lose that way, so the suite
// checks before it starts and again after any failure, and says which kind
// of failure it was.
// Same override run-gates.mjs and drive.mjs honour, so the suite can run on a
// private server instead of the shared :7331.
const ROMDEV_URL = process.env.ROMDEV_URL || 'http://127.0.0.1:7331';

async function serverAlive() {
  try {
    const res = await fetch(`${ROMDEV_URL}/tool/catalog`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-romdev-session': 'suite-health' },
      body: JSON.stringify({ op: 'status' }),
      signal: AbortSignal.timeout(5000),
    });
    return res.ok;
  } catch { return false; }
}

if (!await serverAlive()) {
  console.error(`REFUSING TO RUN: the romdev server at ${ROMDEV_URL} is not answering.`);
  console.error('Every gate drives the cart through it, so all 21 would fail');
  console.error('with ECONNREFUSED and none of it would mean anything.');
  console.error('Start it, then re-run:');
  console.error('  cd ~/code/cliemu/romdev/packages/romdevtools && \\');
  console.error('    setsid nohup node src/mcp/server.js > /tmp/rom-dev-mcp.log 2>&1 < /dev/null &');
  process.exit(3);
}

// A NEW GATE FILE THAT NOBODY REGISTERED IS A GATE THAT NEVER RUNS, and
// it fails silently and permanently -- exactly what happened to
// test-siege, which was written during plan 05 and ran only by hand for
// two plans before anyone noticed. Every tools/test-*.mjs must be either
// in `suites` or in UNREGISTERED above; a file in neither stops the suite
// rather than being quietly skipped.
{
  const onDisk = readdirSync('tools')
    .filter(f => /^test-.*\.mjs$/.test(f))
    .map(f => f.replace(/\.mjs$/, ''));
  const known = new Set([...suites, ...UNREGISTERED]);
  const orphans = onDisk.filter(f => !known.has(f));
  if (orphans.length) {
    console.error(`REFUSING TO RUN: ${orphans.length} gate file(s) are in ` +
                  'neither the suite nor the deliberately-unregistered list:');
    for (const o of orphans) console.error(`  tools/${o}.mjs`);
    console.error('Add each to `suites` (it runs) or to UNREGISTERED (it does');
    console.error('not, and the comment there says why).');
    process.exit(2);
  }
}

let bad = 0;
let infraDown = false;
for (const s of suites) {
  console.log(`\n=== ${s} ===`);
  try { execSync(`node tools/${s}.mjs`, { stdio: 'inherit' }); }
  catch {
    // A failure is only a real result if the server was still there to
    // produce it. Ask before counting it.
    if (!await serverAlive()) { infraDown = true; break; }
    bad++;
  }
  await pause(1500);   // let the server settle between suites
}

if (infraDown) {
  console.error('\nINFRASTRUCTURE FAILURE, NOT A TEST RESULT.');
  console.error('The romdev server stopped answering mid-suite, so every');
  console.error('gate from that point on would have failed for the same');
  console.error('reason. NOTHING here says anything about the game.');
  console.error('Check whether it was OOM-killed:  journalctl -k | grep -i oom');
  console.error('Then restart it and re-run the suite from the top.');
  process.exit(3);
}
console.log(bad ? `\n${bad} SUITE(S) FAILED` : '\nALL SUITES GREEN');
process.exit(bad ? 1 : 0);
