// THE CAMERA: pan and zoom, on every input, without breaking the send.
//
// None of this is visible to a pixel assertion -- a view that panned across
// open ground and one that did not look identical in a screenshot -- so
// everything here reads the cart's own @cam line.
//
// The rules under test, and why each is a rule:
//
//   1. A drag from EMPTY GROUND pans. This is the fix for a camera that
//      only ever nudged toward the cursor, the documented weak point of
//      console RTS cameras.
//   2. A drag from a MOUND still sends and does NOT pan. The send gesture's
//      priority is the whole safety story of this input scheme.
//   3. PINCH zooms, ANCHORED: the world point under the pinch centroid is
//      still under it afterwards. Zooming about the screen centre while
//      pinching a corner is the classic wrong version.
//   4. A SECOND FINGER landing mid-drag CANCELS the send. A palm brush must
//      never fling a garrison somewhere irreversible.
//   5. The shoulders are quantity WHILE COMPOSING and zoom otherwise --
//      both directions asserted, because a mode split that leaks in either
//      direction is worse than no split.
//   6. R3 resets the view.
//   7. The camera is CLAMPED: it cannot be flung into featureless dark.
import { api, driver, makeReport } from './drive.mjs';

const t = api('formix-camera-suite');
const R = makeReport();
const d = driver(t, process.cwd() + '/formix.wasc');

// A patch of screen with no mound under it. The board is known (Gather at
// zoom 0.42), so this is checked rather than assumed: if a mound ever moves
// under this point the pan tests would silently become send tests.
const EMPTY = [300, 880];
// A finger, in the shape romdev's pointer op wants (x and y are required on
// every call, release included). Slots 1+ are touch contacts; slot 0 is the
// mouse, so a pinch has to use 1 and 2 -- which is also the multi-slot path
// a phone actually delivers and the one carts most often ignore.
const finger = {
  async down(id, x, y) {
    await t('input', { op: 'pointer', id, x, y, left: true, active: true });
  },
  async move(id, x, y) {
    await t('input', { op: 'pointer', id, x, y, left: true, active: true });
  },
  async up(id, x, y) {
    await t('input', { op: 'pointer', id, x, y, left: false, active: false });
  },
};

await d.boot(7);
let r = await d.inspect();
{
  const near = Object.entries(r.pos).filter(([, p]) =>
    Math.hypot(p[0] - EMPTY[0], p[1] - EMPTY[1]) < 200);
  R.check('the chosen empty point really is empty', near.length === 0,
          near.map(([id]) => id).join(',') || 'nothing within 200px');
}

// ── 1. drag empty ground pans ──────────────────────────────────────────
{
  const before = r.cam;
  await d.drag(EMPTY[0], EMPTY[1], EMPTY[0] + 420, EMPTY[1] - 260);
  r = await d.inspect();
  const moved = Math.hypot(r.cam.x - before.x, r.cam.y - before.y);
  R.check('a drag from empty ground pans the camera', moved > 100,
          `cam ${before.x.toFixed(0)},${before.y.toFixed(0)} -> ` +
          `${r.cam.x.toFixed(0)},${r.cam.y.toFixed(0)} (moved ${moved.toFixed(0)})`);
  // THE GROUND FOLLOWS THE FINGER: dragging right must move the camera
  // LEFT in world space, or the map feels like it is being pushed away.
  R.check('the ground follows the finger (drag right -> camera left)',
          r.cam.x < before.x,
          `dx=${(r.cam.x - before.x).toFixed(0)} for a rightward drag`);
  R.check('panning selected nothing', d.all().every(l => !/@i send/.test(l)),
          'a pan must not emit a send');
}

// ── 2. a drag from a mound sends, and does not pan ─────────────────────
{
  await d.boot(7);
  r = await d.inspect();
  const before = r.cam;
  const from = 'n2', to = 'n1';
  await d.send(r.pos[from], r.pos[to]);
  r = await d.inspect();
  const moved = Math.hypot(r.cam.x - before.x, r.cam.y - before.y);
  const sent = d.intents().some(l => /send ok=true/.test(l));
  R.check('a drag from a mound still sends', sent,
          d.lastIntent() || 'no intent');
  // The auto-nudge may move the view a little when the cursor lands near an
  // edge, which is a different mechanism; a PAN would be hundreds of units.
  R.check('and does not pan the camera', moved < 100,
          `camera moved ${moved.toFixed(0)} units during a send`);
}

// ── 3. pinch zooms, anchored at the centroid ───────────────────────────
{
  await d.boot(7);
  r = await d.inspect();
  const z0 = r.cam.zoom;

  // Two fingers, spreading apart around a centroid that stays put. Slots
  // 1 and 2 are touch contacts (slot 0 is the mouse), which is also the
  // only way to exercise the multi-slot path a phone actually uses.
  const cx = 700, cy = 400;
  const spread = async (half) => {
    await finger.move(1, cx - half, cy);
    await finger.move(2, cx + half, cy);
    await t('frame', { op: 'step', frames: 4 });
  };
  await spread(80);
  for (const h of [110, 150, 200, 260]) await spread(h);
  await finger.up(1, cx - 260, cy);
  await finger.up(2, cx + 260, cy);
  await t('frame', { op: 'step', frames: 10 });
  r = await d.inspect();

  R.check('spreading two fingers zooms IN', r.cam.zoom > z0 * 1.4,
          `zoom ${z0.toFixed(3)} -> ${r.cam.zoom.toFixed(3)}`);

  // THE ANCHOR. Work out which world point sits under the centroid now and
  // compare with where it was before the pinch. worldToScreen is
  //   (w - cam) * s + half   =>   world = (screen - half)/s + cam
  const S0 = 1080 / 1080 * z0, S1 = 1080 / 1080 * r.cam.zoom;
  const w0 = (cx - 1920 / 2) / S0 + 0;             // cam.x was 0 at boot
  const w1 = (cx - 1920 / 2) / S1 + r.cam.x;
  R.check('the world under the pinch centroid stays put (anchored zoom)',
          Math.abs(w1 - w0) < 60,
          `world x under centroid ${w0.toFixed(0)} -> ${w1.toFixed(0)}`);
}

// ── 4. a second finger cancels a send ──────────────────────────────────
//
// Asserted on the SELECTION, not only on the absence of a send. "No send
// happened" is too weak on its own: a pinch moves the view, so the release
// can miss its target and the send vanishes for an incidental reason -- the
// assertion then passes even with the cancel ripped out (verified: it did).
// The selection dropping is the direct expression of "that gesture was
// abandoned", and nothing else in this sequence produces it.
//
// The overlay is turned on for the whole gesture so @ui prints every frame;
// otherwise there is no way to see the state mid-drag.
{
  await d.boot(7);
  r = await d.inspect();
  const src = r.pos.n2, dst = r.pos.n1;

  await d.press('select', 6);          // overlay ON: @ui every frame
  await d.step(10);
  const selOf = () => {
    const l = d.all().filter(x => x.startsWith('@ui ')).pop() || '';
    const m = l.match(/selected=(\S+)/);
    return m ? (m[1] === 'nil' ? null : m[1]) : undefined;
  };

  await finger.down(1, src[0], src[1]);
  await t('frame', { op: 'step', frames: 6 });
  await finger.move(1, Math.round((src[0] + dst[0]) / 2),
                       Math.round((src[1] + dst[1]) / 2));
  await t('frame', { op: 'step', frames: 6 });
  await d.step(2);
  const during = selOf();
  R.check('a one-finger drag from a mound has it picked up',
          during === 'n2', `selected=${during}`);

  // ...then a second finger lands: this is a pinch now, not a send.
  await finger.down(2, 1500, 800);
  await t('frame', { op: 'step', frames: 8 });
  await d.step(2);
  const afterSecond = selOf();
  R.check('a second finger CANCELS the drag (selection dropped)',
          afterSecond === null, `selected=${afterSecond}`);

  // Finish where the send would have completed, and lift.
  await finger.move(1, dst[0], dst[1]);
  await t('frame', { op: 'step', frames: 4 });
  await finger.up(1, dst[0], dst[1]);
  await finger.up(2, 1500, 800);
  await t('frame', { op: 'step', frames: 20 });
  await d.step(30);

  const sends = d.intents().filter(l => /send ok=true/.test(l));
  R.check('and no send is emitted', sends.length === 0,
          sends[0] || 'no send emitted, as required');
  await d.press('select', 6);          // overlay OFF
  await d.step(10);
}

// ── 5. the shoulders: quantity while composing, zoom otherwise ─────────
{
  await d.boot(7);
  r = await d.inspect();
  const z0 = r.cam.zoom;

  // Nothing selected -> R zooms.
  await d.press('r', 6);
  await d.step(20);
  r = await d.inspect();
  R.check('with nothing selected, R steps the zoom', r.cam.zoom > z0,
          `zoom ${z0.toFixed(3)} -> ${r.cam.zoom.toFixed(3)}`);

  // Pick a mound up (A on the cursor's mound) -> now R trims quantity and
  // must NOT zoom.
  // Pick a mound up. The state has to be read through a FRESH inspect --
  // @ui is only printed while the overlay is up, so the banked copy is
  // whatever the previous toggle left behind.
  await d.press('a', 6);
  await d.step(20);
  const picked = await d.inspect();
  const zPicked = picked.cam.zoom;
  R.check('A picks a mound up (composing begins)',
          picked.ui && picked.ui.selected !== null,
          `selected=${picked.ui && picked.ui.selected} frac=${picked.ui && picked.ui.frac}`);

  await d.press('l', 6);
  await d.step(20);
  const trimmed = await d.inspect();
  R.check('while composing, L changes the quantity',
          trimmed.ui && trimmed.ui.frac < 1.0,
          `frac ${picked.ui && picked.ui.frac} -> ${trimmed.ui && trimmed.ui.frac}`);
  R.check('and does NOT zoom (the mode split holds)',
          Math.abs(trimmed.cam.zoom - zPicked) < 1e-6,
          `zoom ${zPicked.toFixed(3)} -> ${trimmed.cam.zoom.toFixed(3)}`);
}

// ── 6. R3 resets the view ──────────────────────────────────────────────
{
  await d.boot(7);
  await d.drag(EMPTY[0], EMPTY[1], EMPTY[0] + 500, EMPTY[1] + 300);
  await d.press('r', 6);              // and change the zoom too
  await d.step(20);
  let moved = await d.inspect();
  const drifted = Math.hypot(moved.cam.x, moved.cam.y) > 100 ||
                  Math.abs(moved.cam.zoom - 0.42) > 1e-6;
  R.check('the view is somewhere else before the reset', drifted,
          `cam ${moved.cam.x.toFixed(0)},${moved.cam.y.toFixed(0)} ` +
          `zoom ${moved.cam.zoom.toFixed(3)}`);

  await t('input', { op: 'set', ports: [{ r3: true }] });
  await t('frame', { op: 'step', frames: 8 });
  await t('input', { op: 'set', ports: [{}] });
  await d.step(20);
  const after = await d.inspect();
  R.check('R3 restores the default zoom', Math.abs(after.cam.zoom - 0.42) < 1e-6,
          `zoom=${after.cam.zoom.toFixed(3)}`);
  R.check('R3 centres on the cursor',
          Math.hypot(after.cam.x - 0, after.cam.y - 0) < 200,
          `cam ${after.cam.x.toFixed(0)},${after.cam.y.toFixed(0)} ` +
          `(the cursor starts on home at 0,0)`);
}

// ── 7. the camera is clamped ───────────────────────────────────────────
{
  await d.boot(7);
  // Pan as hard as possible, repeatedly, in one direction.
  //
  // START ON OPEN GROUND, NOT ON A PANEL. (1700, 900) sits INSIDE the
  // minimap's rect (bottom-right, 370x248 at a 28px margin), so this
  // "drag" was a minimap JUMP -- the camera teleports to the tapped
  // world position -- and never exercised the pan clamp it is named
  // for. It passed only because the old minimap geometry happened to
  // map that point under the 12000 threshold; resizing the panel moved
  // the same screen point to a different world position and the number
  // changed, which is how a gate that was measuring the wrong thing
  // finally said so.
  //
  // (1400, 700) is clear of all three UI rects: the node panel
  // (bottom-left), the minimap (bottom-right) and the settings gear
  // (top-right).
  for (let i = 0; i < 6; i++) {
    await d.drag(1400, 700, 200, 120, 3);
  }
  const far = await d.inspect();
  // Gather's mounds span roughly +/-1200 world units. A clamp that works
  // keeps the camera within a screen or so of that; an unclamped camera
  // would be tens of thousands of units out after six full-screen drags.
  const dist = Math.hypot(far.cam.x, far.cam.y);
  R.check('the camera cannot be flung into the void', dist < 12000,
          `camera ended ${dist.toFixed(0)} units from the field`);
  R.check('no lua errors from any camera path', d.errors().length === 0,
          d.errors()[0] || '');
}

process.exit(R.done() ? 0 : 1);
