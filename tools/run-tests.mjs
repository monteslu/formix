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
const suites = ['test-reachable', 'test-overlap', 'test-queen', 'test-grey', 'test-gameplay',
                'test-longrun', 'test-deadend', 'test-strand',
                'test-campaign', 'test-render', 'test-camera',
                // PLAN 06's two UI gates. Neither packs its own board --
                // both drive the ordinary cart through the pause menu and
                // the overlay-gated progress instruments -- so they sit
                // with the cheap gates rather than in the rebuild
                // quarantine below.
                'test-progress', 'test-celebrate',
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
                'test-siege', 'test-queencarry'];
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
async function serverAlive() {
  try {
    const res = await fetch('http://127.0.0.1:7331/tool/catalog', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-romdev-session': 'suite-health' },
      body: JSON.stringify({ op: 'status' }),
      signal: AbortSignal.timeout(5000),
    });
    return res.ok;
  } catch { return false; }
}

if (!await serverAlive()) {
  console.error('REFUSING TO RUN: the romdev server on :7331 is not answering.');
  console.error('Every gate drives the cart through it, so all 21 would fail');
  console.error('with ECONNREFUSED and none of it would mean anything.');
  console.error('Start it, then re-run:');
  console.error('  cd ~/code/cliemu/romdev/packages/romdevtools && \\');
  console.error('    setsid nohup node src/mcp/server.js > /tmp/rom-dev-mcp.log 2>&1 < /dev/null &');
  process.exit(3);
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
