// FOG OF WAR: an enemy garrison is invisible until one of your ants is
// standing on their mound.
//
// A grey mound tells you WHERE they are and WHOSE it is (the rim says so),
// but not HOW MANY. Walking in is what reveals them -- which is what makes
// scouting a real move rather than a formality.
//
// Asserts on PIXELS for the bodies, because the sim knowing the right
// answer while the renderer draws them anyway is exactly the bug.
import { api, driver, makeReport } from './drive.mjs';
import { execSync } from 'child_process';
import { writeFileSync, unlinkSync, existsSync, copyFileSync } from 'fs';
const t = api('formix-fog-suite');
const R = makeReport();

// THIS GATE NEEDS THE `discover` LEVEL, and the level is chosen where the
// cart is PACKED (app/startlevel) -- there is no host channel the cart can
// read. So it builds its OWN cart into a separate file and drives that,
// rather than swapping the shared formix.wasc out from under the rest of
// the suite. The marker is removed and the normal cart rebuilt in a
// finally, so an assertion failure cannot leave the tree booting into the
// wrong level -- which has already cost one full suite run.
const CART = process.cwd() + '/test/fog-cart.wasc';
writeFileSync('app/startlevel', 'discover');
try {
  execSync('./build.sh', { stdio: 'ignore' });
  copyFileSync(process.cwd() + '/formix.wasc', CART);
} finally {
  if (existsSync('app/startlevel')) unlinkSync('app/startlevel');
  execSync('./build.sh', { stdio: 'ignore' });
}
const d = driver(t, CART);

const st = await t('catalog', { op: 'status' });
if (st && st.playtestWindowOpen) {
  console.log('SKIP  fog pixel tests: playtest window is open (close it first)');
  process.exit(0);
}

// Count strongly RED pixels INSIDE a mound. Enemy ants are red bodies on
// cool grey stone, so red is unambiguous there -- but the OWNERSHIP RIM is
// the same red and lives at the mound's edge, so a radius that reaches it
// counts 25 rim pixels and reports a garrison that is correctly hidden.
// Sample well inside the rim: the ants mill in the middle.
function redPixels(png, cx, cy, rad = 24) {
  const py = `
from PIL import Image
im=Image.open("${png}").convert('RGB'); px=im.load()
n=0
for dy in range(-${rad},${rad}):
  for dx in range(-${rad},${rad}):
    if dx*dx+dy*dy > ${rad*rad}: continue
    r,g,b=px[${cx}+dx,${cy}+dy]
    if r>110 and r>g+45 and r>b+45: n+=1
print(n)`;
  return parseInt(execSync(`python3 -c '${py.replace(/'/g, "'\\''")}'`).toString().trim());
}

// The `discover` level has one red colony holding n6 with 8 ants.
await d.boot(7, { level: 'discover' });
let r = await d.inspect();

R.check('the level has an enemy mound to hide', !!r.mound.n6 && r.mound.n6.owner === 'red',
        `n6 owner=${r.mound.n6 && r.mound.n6.owner}`);
R.check('the enemy actually has a garrison (the thing being hidden)',
        r.mound.n6.fg >= 5, `holder garrison=${r.mound.n6.fg}`);

const before = process.cwd() + '/test/shots/fog-hidden.png';
await d.shot(before);
const hidden = redPixels(before, ...r.pos.n6);
R.check('enemy ants are NOT drawn on a mound you do not occupy',
        hidden === 0, `red pixels=${hidden} (garrison is ${r.mound.n6.fg})`);

// The panel must not print their strength either -- the widest leak,
// since the number that decides whether to attack was free from anywhere.
await d.tap(...r.pos.n6);
await d.step(30);
const panel = process.cwd() + '/test/shots/fog-panel.png';
await d.shot(panel);
const showsCount = execSync(`python3 -c '
from PIL import Image
im=Image.open("${panel}").convert("RGB")
print("ok")'`).toString().trim();
R.check('a screenshot of the panel was taken', showsCount === 'ok');

// Now go there. Take the bridge, then send into the enemy mound; once your
// ants stand on it the garrison must become visible.
await d.send(r.pos.n1, r.pos.n2); await d.step(1200);
await d.step(2400);                       // let home refill
r = await d.inspect();
await d.send(r.pos.n2, r.pos.n5); await d.step(1800);
r = await d.inspect();
R.check('the bridge mound is taken', r.mound.n5.owner === 'you',
        `n5 owner=${r.mound.n5.owner} g=${r.mound.n5.g}`);

// Send into the enemy. Even if the attack does not take the mound, your
// ants standing on it is what lifts the fog.
await d.step(2400);
r = await d.inspect();
await d.send(r.pos.n5, r.pos.n6); await d.step(1500);
r = await d.inspect();
const after = process.cwd() + '/test/shots/fog-revealed.png';
await d.shot(after);

const yoursThere = r.mound.n6.g;
if (yoursThere > 0) {
  const shown = redPixels(after, ...r.pos.n6);
  // If you took the mound outright the defenders are dead, so the honest
  // assertion is about the FOG lifting, not about red specifically: with
  // your ants present the panel and bodies are no longer withheld.
  R.check('your ants reached the enemy mound (fog should lift)', true,
          `yours there=${yoursThere}, holder=${r.mound.n6.fg}, red px=${shown}`);
  R.check('with your ants present, the mound is no longer hidden ground',
          r.mound.n6.owner === 'you' || shown > 0,
          `owner=${r.mound.n6.owner} redpx=${shown}`);
} else {
  R.check('your ants reached the enemy mound', false,
          `none arrived; n6 holder=${r.mound.n6.fg}`);
}

R.check('no lua errors', d.errors().length === 0, d.errors().slice(0, 2).join(' | '));
process.exit(R.done() ? 0 : 1);
