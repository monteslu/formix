// WINNING SHOULD LOOK LIKE WINNING.
//
// Plan 06, Luis 2026-08-19: "when a level is complete it should be more
// apparent. maybe a cool dialog and confetti." Before this, finishing a
// level swapped one line of small text at the top of the screen -- easy
// to play straight past without noticing you had won.
//
// The dialog and the confetti hang off the `levelJustDone` rising edge in
// sim.update, NOT off any particular level's win condition (test-campaign
// owns those, for real, on played boards). So this gate fires that edge
// with the overlay-gated `beatlevel` instrument and asserts on what the
// player then sees and can do.
//
// Written to FAIL: the confetti assertion counts bright flake pixels in
// the band the burst falls through, and the sabotage (skip the burst)
// takes it to zero -- recorded in 06-levels.md's sabotage table.
import { api, driver, makeReport } from './drive.mjs';
import { readPNG } from './png.mjs';

const R = makeReport();
const CART = process.cwd() + '/formix.wasc';

// Fire a level completion: overlay on, SELECT+START, overlay off.
async function win(d) {
  await d.press('select', 6);
  await d.step(15);
  await d.hold(['select', 'start'], 8);
  return d.step(4);
}

// Bright, saturated flake ink in the band the burst falls through. The
// dimmed garden under a 0.55 scrim does not reach these values, and the
// card itself is near-black with a thin green rim.
function flakeInk(im, y0, y1) {
  let n = 0;
  for (let y = y0; y < y1; y += 2) {
    for (let x = 300; x < 1620; x += 2) {
      const [r, g, b] = im.at(x, y);
      const mx = Math.max(r, g, b);
      if (mx > 150 && (r + g + b) > 330) n++;
    }
  }
  return n;
}

// ── 1. THE DIALOG APPEARS, ONCE, ON COMPLETION ─────────────────────────
{
  const t = api('formix-celebrate-appears');
  const d = driver(t, CART);
  await d.boot(7, { level: 'gather' });

  let ins = await d.inspect();
  R.check('CONTROL: no celebration before the level is finished',
          ins.ui2 && ins.ui2.celebrate === false,
          `celebrate=${ins.ui2 && ins.ui2.celebrate}`);

  await win(d);
  const shot = process.cwd() + '/test/shots/celebrate-open.png';
  await d.shot(shot);
  ins = await d.inspect();
  R.check('finishing a level raises the celebration dialog',
          ins.ui2 && ins.ui2.celebrate === true,
          `celebrate=${ins.ui2 && ins.ui2.celebrate}`);
  R.check('...focused on NEXT LEVEL, the row a winner most likely wants',
          ins.ui2 && ins.ui2.celrow === 1,
          `celrow=${ins.ui2 && ins.ui2.celrow}`);

  const im = readPNG(shot);
  R.check('and confetti is actually falling',
          flakeInk(im, 180, 420) > 60,
          `bright flake px=${flakeInk(im, 180, 420)}`);
  R.check('no lua errors raising the celebration',
          d.errors().length === 0, d.errors().slice(0, 2).join(' | '));
}

// ── 2. THE PAD DRIVES IT ───────────────────────────────────────────────
{
  const t = api('formix-celebrate-pad');
  const d = driver(t, CART);
  await d.boot(7, { level: 'gather' });
  await win(d);
  await d.step(20);

  // DOWN moves to "Keep playing", A dismisses without advancing.
  await d.press('down', 6);
  await d.step(12);
  let ins = await d.inspect();
  R.check('the PAD moves the focused row',
          ins.ui2 && ins.ui2.celrow === 2,
          `celrow=${ins.ui2 && ins.ui2.celrow}`);

  await d.press('a', 6);
  await d.step(30);
  ins = await d.inspect();
  const started = d.all().filter(l => l.startsWith('@level started'));
  R.check('KEEP PLAYING dismisses the dialog',
          ins.ui2 && ins.ui2.celebrate === false,
          `celebrate=${ins.ui2 && ins.ui2.celebrate}`);
  R.check('CONTROL: and does NOT start the next level',
          started.length === 0, started.join(' | ') || 'none, correct');
  R.check('the sim keeps running underneath (never paused)',
          (await d.metric()).t > 0, `t=${(await d.metric()).t}`);
  R.check('no lua errors on the pad path',
          d.errors().length === 0, d.errors().slice(0, 2).join(' | '));
}

// ── 3. NEXT LEVEL ACTUALLY ADVANCES, on both devices ───────────────────
{
  const t = api('formix-celebrate-next-pad');
  const d = driver(t, CART);
  await d.boot(7, { level: 'gather' });
  await win(d);
  await d.step(20);
  await d.press('a', 6);          // row 1 = Next level
  await d.step(90);
  const started = d.all().filter(l => l.startsWith('@level started')).pop();
  R.check('the PAD advances to the next level from the dialog',
          !!started && /settle/.test(started),
          started || 'no @level started line');
  R.check('no lua errors advancing by pad',
          d.errors().length === 0, d.errors().slice(0, 2).join(' | '));
}
{
  const t = api('formix-celebrate-next-mouse');
  const d = driver(t, CART);
  await d.boot(7, { level: 'gather' });
  await win(d);
  await d.step(20);

  // Row geometry from ui/celebrate.lua layout(): the card is vp.u(720) x
  // vp.u(300), centred; its two rows are vp.u(84) tall, sitting
  // vp.u(18) up from the bottom edge. vp.u is 1:1 at 1080p.
  const h = 300, rowH = 84;
  const cardY = Math.round((1080 - h) / 2);
  const ry = cardY + h - rowH * 2 - 18;
  await d.tap(960, ry + Math.floor(rowH / 2));      // row 1: Next level
  await d.step(90);
  const started = d.all().filter(l => l.startsWith('@level started')).pop();
  R.check('a MOUSE click advances to the next level from the dialog',
          !!started && /settle/.test(started),
          started || 'no @level started line');
  R.check('no lua errors advancing by mouse',
          d.errors().length === 0, d.errors().slice(0, 2).join(' | '));
}

// ── 4. THE OLD PATH SURVIVES ───────────────────────────────────────────
//
// START on a finished level advanced to the next field long before this
// plan, and the HUD still promises it once the card is gone. A new dialog
// that silently broke the old prompt would be a regression dressed as a
// feature.
{
  const t = api('formix-celebrate-oldpath');
  const d = driver(t, CART);
  await d.boot(7, { level: 'gather' });
  await win(d);
  await d.step(20);

  // START while the card is up must DISMISS, never advance -- the dialog
  // is asking the question, so the button must not answer it silently.
  await d.press('start', 6);
  await d.step(30);
  let ins = await d.inspect();
  let started = d.all().filter(l => l.startsWith('@level started'));
  R.check('START dismisses the card rather than skipping past it',
          ins.ui2 && ins.ui2.celebrate === false && started.length === 0,
          `celebrate=${ins.ui2 && ins.ui2.celebrate} started=${started.length}`);

  // ...and then, with the card gone, START does what the HUD says.
  await d.press('start', 6);
  await d.step(90);
  started = d.all().filter(l => l.startsWith('@level started')).pop();
  R.check('with the card gone, START still advances (the pre-plan-06 path)',
          !!started && /settle/.test(started),
          started || 'no @level started line');
  R.check('no lua errors on the old path',
          d.errors().length === 0, d.errors().slice(0, 2).join(' | '));
}

process.exit(R.done() ? 0 : 1);
