import { api, driver, makeReport } from './drive.mjs';
import { execSync } from 'child_process';
const t = api('formix-render');
const d = driver(t, process.cwd() + '/formix.wasc');
const R = makeReport();

const st = await t('catalog', { op: 'status' });
if (st && st.playtestWindowOpen) {
  console.log('SKIP  render pixel tests: playtest window is open');
  process.exit(0);
}

function py(code) {
  return execSync(`python3 -c '${code.replace(/'/g, "'\\''")}'`).toString().trim();
}
// Where is the "N ready" gauge text, and is it upright? Text drawn inside
// the flipped scene pass lands mirrored about the screen centre, so its
// distance from the mound it labels is the tell. This test exists because
// "6 ready" shipped upside down twice and no assertion noticed.
function textRowsNear(png, cx, cy, radius) {
  return py(`
from PIL import Image
im=Image.open("${png}").convert('RGB'); px=im.load(); w,h=im.size
rows=[]
for y in range(max(0,${cy-radius}), min(h,${cy+radius})):
  n=0
  # A NARROW COLUMN, because the selection ring is the SAME pale green as
  # the gauge text and just as bright -- no colour or count threshold can
  # separate them, which is what made this test measure the ring and report
  # the gauge 3px above its mound. Nor can a radial cut: the ring reaches
  # radius 73 while the text sits at distance 56, so excluding the ring by
  # distance would delete the text too.
  #
  # What DOES separate them is horizontal position. The gauge is printed
  # centred under the mound, so its pixels cluster near cx; the ring at any
  # given row is out at the sides. Sampling a 48px-wide column through the
  # centre sees the text and misses the arcs.
  for x in range(max(0,${cx-24}), min(w,${cx+24})):
    r,g,b=px[x,y]
    # COLOUR, NOT COUNT, separates the gauge text from the other bright
    # things around a selected mound. Two of them get in the way:
    #   * the selection RING, a flat rim green (133,196,130) -- its top arc
    #     lights 38 pixels on one row, more than several real text rows, so
    #     no count threshold can exclude it
    #   * the cursor BRACKET, near-white (249,249,229) corner marks
    # The gauge text is GREEN AND BRIGHT, so require both: bright enough to
    # clear the ring, and green enough to reject the white bracket.
    # Without this the detected span ran 483..603 rather than 591..603,
    # putting its centre above the mound and failing the side assertion for
    # a gauge that was drawn correctly.
    if g>210 and r>150 and b>140 and g-b>30: n+=1
  if n>3: rows.append(y)
print(min(rows) if rows else -1, max(rows) if rows else -1)`);
}

await d.boot(7);
const { pos, mound } = await d.inspect();
// Pick up home so the "N ready" gauge appears.
await d.tap(...pos.n1);
await d.step(30);
const shot = process.cwd() + '/test/shots/render-gauge.png';
await d.shot(shot);

const [lo, hi] = textRowsNear(shot, pos.n1[0], pos.n1[1], 220).split(/\s+/).map(Number);
R.check('the "N ready" gauge is drawn near its mound', lo > 0,
        `text rows ${lo}..${hi} around mound y=${pos.n1[1]}`);
// ASSERT THE SIDE, NOT THE DISTANCE. The first version of this test
// allowed 220px of slack, and the mirrored bug moves the text only ~114px
// -- so the control PASSED with the bug deliberately reintroduced, which
// makes the test worse than nothing. The gauge is positioned BELOW its
// mound; mirrored, it lands above. The side is unambiguous.
const textY = (lo + hi) / 2;
R.check('gauge text is BELOW its mound (mirrored text lands above)',
        lo > 0 && textY > pos.n1[1] + 20,
        `text centre ${textY} vs mound ${pos.n1[1]}`);

// The scene must not be black: the ground shader has to be alive. A pushed
// transform in beginScene once killed it entirely.
const groundLum = parseFloat(py(`
from PIL import Image
im=Image.open("${shot}").convert('RGB'); px=im.load()
tot=n=0
for y in range(140,940,7):
  for x in range(500,1880,7):
    r,g,b=px[x,y]; tot+=r+g+b; n+=1
print(round(tot/n/3,2))`));
R.check('the ground is rendered (scene is not black)', groundLum > 12,
        `mean luminance ${groundLum}`);

R.check('no lua errors', d.errors().length === 0, d.errors().slice(0,2).join(' | '));
process.exit(R.done() ? 0 : 1);
