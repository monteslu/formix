// A mound is GREY STONE until one of your ants is standing on it, and warms
// to earth the moment one arrives. Colour is presence.
//
// This asserts on PIXELS, because the whole point is what the player sees:
// the sim flag being right while the mound renders brown would pass any
// state-only check and still be the bug.
import { api, driver, makeReport } from './drive.mjs';
import { execSync } from 'child_process';
const t = api('formix-grey-suite');
const d = driver(t, process.cwd() + '/formix.wasc');
const R = makeReport();

// A PIXEL TEST CANNOT RUN AGAINST A PRESENTED WINDOW: screenshots then read
// the window surface rather than this session's framebuffer, which shows up
// as zeros and looks exactly like a render bug. Fail loudly instead.
const st = await t('catalog', { op: 'status' });
if (st && st.playtestWindowOpen) {
  console.log('SKIP  grey pixel tests: playtest window is open (close it first)');
  process.exit(0);
}

// Mean per-channel spread over the mound body. Measuring SATURATION rather
// than brightness is deliberate: stone and earth are matched in VALUE (~51
// vs ~50) so that neither dominates the frame, which means a luminance test
// would see no difference at all. They separate by HUE.
//
// STONE IS COOL, NOT NEUTRAL. The grey is mixed as its own blue-leaning
// colour rather than as desaturated earth, so it carries a real channel
// spread of ~11 -- earth sits at 38-45. The boundary is therefore 20, not
// the near-zero a flat grey would allow. Written as a named constant so
// the next palette change moves one number instead of five literals.
const STONE_MAX = 20;
const EARTH_MIN = 25;

function spread(png, cx, cy) {
  const py = `
from PIL import Image
im=Image.open("${png}").convert('RGB'); px=im.load()
tot=0;n=0
for dy in range(-26,26,2):
  for dx in range(-26,26,2):
    if dx*dx+dy*dy > 676: continue
    r,g,b=px[${cx}+dx,${cy}+dy]
    tot += max(r,g,b)-min(r,g,b); n+=1
print(round(tot/n,2))`;
  return parseFloat(execSync(`python3 -c '${py.replace(/'/g, "'\\''")}'`).toString().trim());
}

await d.boot(7);
const { pos, mound } = await d.inspect();
const before = process.cwd() + '/test/shots/grey-before.png';
await d.shot(before);

// At boot: n1..n4 hold ants, n5/n6 are empty. Both states in ONE frame, so
// no lighting or timing difference can explain the gap between them.
const withAnts = Object.keys(mound).filter(id => mound[id].g > 0);
const without  = Object.keys(mound).filter(id => mound[id].g === 0);
R.check('the board has both occupied and empty mounds to compare',
        withAnts.length > 0 && without.length > 0,
        `occupied=${withAnts.join(',')} empty=${without.join(',')}`);

for (const id of withAnts) {
  const s = spread(before, ...pos[id]);
  R.check(`${id} has ants, so it is EARTH`, s > EARTH_MIN, `spread=${s} (ants=${mound[id].g})`);
}
for (const id of without) {
  const s = spread(before, ...pos[id]);
  R.check(`${id} has no ants, so it is GREY`, s < STONE_MAX, `spread=${s}`);
}

// THE TRANSITION IS THE FEATURE. A static frame only proves two mounds were
// drawn differently; it does not prove a mound RESPONDS. Send ants to an
// empty one and watch it warm.
const target = without[0];
await d.send(pos.n1, pos[target]);
await d.step(1200);
const after = process.cwd() + '/test/shots/grey-after.png';
await d.shot(after);
const m2 = (await d.inspect()).mound;

const sAfter = spread(after, ...pos[target]);
R.check(`${target} turns EARTH once your ants arrive`, sAfter > EARTH_MIN,
        `spread ${spread(before, ...pos[target])} -> ${sAfter} (ants=${m2[target].g})`);

// IT GOES BOTH WAYS. Colour tracks PRESENCE, not history: a mound whose
// ants all leave must go back to stone. Without this, a renderer that
// latched "has been visited" would pass every assertion above while
// quietly showing the player ground they no longer occupy. The send above
// emptied n1 to fill the target, so n1 is the natural subject.
if (m2.n1 && m2.n1.g === 0) {
  const sHome = spread(after, ...pos.n1);
  R.check('a mound whose ants all LEFT goes back to GREY', sHome < STONE_MAX,
          `n1 spread ${spread(before, ...pos.n1)} -> ${sHome} (ants=${m2.n1.g})`);
}

// THE CONTROL THAT MUST NOT MOVE. Without it, a global brightening (a
// season tick, a bloom change) would satisfy the assertion above and the
// test would report a pass for a feature that does nothing.
const ctrl = without[1];
if (ctrl) {
  const cA = spread(after, ...pos[ctrl]);
  R.check(`CONTROL: ${ctrl} got no ants, so it stays GREY`, cA < STONE_MAX,
          `spread=${cA} (ants=${m2[ctrl].g})`);
}

// ── BREATHING MEANS A QUEEN ──
//
// The wobble says a mound is a living COLONY, so it must not run on a
// mound that merely has ants standing on it. That is a motion property: a
// single frame cannot show it, so measure the silhouette across several
// frames and see whether it changes. Body pixels on the centre row is
// enough -- the rings wobble outward, so the width moves.
// THE THRESHOLD MUST CLEAR THE GROUND. The soil sums to ~123 (43,47,33),
// so an r+g+b>108 test lit every pixel in the window and reported a
// constant 140 for every mound -- a probe measuring nothing, which reads
// exactly like "nothing is animating". Mound bodies (earth ~150, stone
// ~155) sit above 135; ground sits below it.
//
// AND THE WINDOW MUST CLEAR THE MOUND. At +/-70 the sample sat entirely
// INSIDE the larger mounds, so every pixel was lit and the width was a
// constant 140 whatever the rings did -- which let a deliberately
// sabotaged build (everything breathing) pass the still-control. +/-140
// reaches past the widest mound on the board, so the silhouette edge is
// actually in frame.
function width(png, cx, cy) {
  const py = `
from PIL import Image
im=Image.open("${png}").convert('RGB'); px=im.load()
n=0
for x in range(${cx}-140, ${cx}+140):
  r,g,b=px[x,${cy}]
  if r+g+b > 135: n+=1
print(n)`;
  return parseInt(execSync(`python3 -c '${py.replace(/'/g, "'\\''")}'`).toString().trim());
}

// Raise a queen, then watch it and an empty mound together. The ants were
// sent to `target` above, so THAT is where the colony can be founded --
// n1 was emptied and cannot afford a queen. Gather the rest onto it first;
// a queen costs 10.
for (const [id, m] of Object.entries(m2)) {
  if (id === target || m.owner !== 'you' || m.g === 0) continue;
  await d.send(pos[id], pos[target]);
  await d.step(900);
}
await d.tap(...pos[target]);
await d.press('y');
await d.step(120);
const m3 = (await d.inspect()).mound;
const shots = [];
for (let i = 0; i < 6; i++) {
  const p = process.cwd() + `/test/shots/grey-breathe${i}.png`;
  await d.step(25);
  await d.shot(p);
  shots.push(p);
}
R.check(`${target} raised a queen for the breathing test`,
        m3[target] && m3[target].queens > 0,
        `queens=${m3[target] && m3[target].queens}`);
if (m3[target] && m3[target].queens > 0) {
  const w = shots.map(p => width(p, ...pos[target]));
  R.check('a mound with a QUEEN breathes', new Set(w).size > 1,
          `widths ${w.join(',')} (queens=${m3[target].queens})`);
}
// The still control. Without it, a camera drift or a resize would make
// every mound's width vary and the assertion above would pass for a game
// that animates everything.
if (ctrl) {
  const w = shots.map(p => width(p, ...pos[ctrl]));
  R.check(`CONTROL: ${ctrl} has no queen, so it does NOT breathe`,
          new Set(w).size === 1, `widths ${w.join(',')}`);
}

R.check('no lua errors', d.errors().length === 0, d.errors().slice(0, 2).join(' | '));
process.exit(R.done() ? 0 : 1);
