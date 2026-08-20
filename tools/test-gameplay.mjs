import { api, driver, makeReport, releaseAll } from './drive.mjs';
const t = api('formix-play-suite');
const d = driver(t, process.cwd() + '/formix.wasc');
const R = makeReport();

await d.boot(7);
let { pos, mound } = await d.inspect();

// --- SENDS ---
// A DRAG SENDS. Tap-tap used to, and no longer does -- see the control
// immediately below, which is the half that actually matters.
await d.send(pos.n3, pos.n1);
R.check('touch drag sends', /send ok=true from=n3 to=n1/.test(d.lastIntent()||''), d.lastIntent());
await d.step(900);

// --- the relay rule ---
({ mound } = await d.inspect());
R.check('n3 emptied by the send', mound.n3.g === 0, `n3 g=${mound.n3.g}`);

// TAP-TAP MUST NOT SEND. Looking at a neighbour is the most common thing
// a player does, and it used to fling the selected mound's whole garrison
// there -- an irreversible move one stray tap away. Tapping a source then
// a target must leave both untouched.
const relayFrom = 'n2', relayTo = 'n4';
const beforeTap = (await d.inspect()).mound[relayFrom].g;
await d.tap(...pos[relayFrom]);
await d.tap(...pos[relayTo]);
await d.step(180);
const afterTap = (await d.inspect()).mound[relayFrom].g;
R.check('tap-tap does NOT send (a tap only selects)', afterTap === beforeTap,
        `${relayFrom} ${beforeTap} -> ${afterTap}`);

// TAP THE MOUND, THEN DRAG FROM IT. The most natural gesture in the game,
// and it did nothing at all: the press handler treated a press on the
// already-selected mound as "put it down", clearing the source before the
// drag could use it. You had to tap somewhere ELSE first, which nobody
// would guess. Deselect now happens on release, once a drag is ruled out.
{
  await d.boot(7);
  const s2 = await d.inspect();
  await d.tap(...s2.pos.n3);
  await d.step(30);
  const g0 = (await d.inspect()).mound.n3.g;
  await d.drag(...s2.pos.n3, ...s2.pos.n1);
  await d.step(300);
  const g1 = (await d.inspect()).mound.n3.g;
  R.check('tap then drag FROM the same mound sends', g1 < g0,
          `n3 ${g0} -> ${g1}`);
}

// AND FROM A DIFFERENT ONE. Putting a finger down on another mound
// re-selects it, so the drag sends from wherever the finger STARTED --
// not from whatever happened to be selected before.
{
  await d.boot(7);
  const s3 = await d.inspect();
  await d.tap(...s3.pos.n2);
  await d.step(30);
  const g0 = (await d.inspect()).mound.n3.g;
  await d.drag(...s3.pos.n3, ...s3.pos.n1);
  await d.step(300);
  const g1 = (await d.inspect()).mound.n3.g;
  R.check('drag from a mound that was NOT selected sends from it', g1 < g0,
          `n3 ${g0} -> ${g1}`);
}

// --- upgrade is refused with no queen (the ten-ant trap) ---
await d.tap(...pos.n1);
await d.press('x');
R.check('X refused with no queen', /upgrade ok=false/.test(d.lastIntent()||''), d.lastIntent());
({ mound } = await d.inspect());
const gBefore = mound.n1.g;
await d.press('x');
({ mound } = await d.inspect());
// NOT EQUALITY: a mound with a queen HATCHES BROOD between the two reads,
// so the count legitimately rises (5 -> 6) and an == assertion fails for a
// refusal that spent nothing. What "spends nothing" means is that ants
// never go DOWN -- an upgrade costs 20, so a real spend is unmistakable.
R.check('X spends nothing when refused', mound.n1.g >= gBefore,
        `${gBefore} -> ${mound.n1.g} (must not DROP)`);

// --- taking neutral ground ---
({ pos, mound } = await d.inspect());
const neutral = Object.entries(mound).find(([,m]) => m.owner === null);
if (neutral) {
  const [nid] = neutral;
  // gather enough to overcome its energy, then send
  for (const [id,m] of Object.entries(mound)) {
    if (id==='n1' || m.owner!=='you' || m.g===0) continue;
    await d.send(pos[id], pos.n1); await d.step(700);
  }
  await d.send(pos.n1, pos[nid]);
  await d.step(1500);
  ({ mound } = await d.inspect());
  R.check('neutral ground can be taken', mound[nid].owner === 'you',
          `${nid} owner=${mound[nid].owner} energy=${mound[nid].energy}`);
} else {
  R.check('neutral ground can be taken', false, 'no neutral mound found');
}

// --- pad parity: the same order via d-pad ---
await d.boot(7);
({ pos } = await d.inspect());
await d.press('a');            // pick up home
await d.press('left');         // aim
await d.press('a');            // send
R.check('pad A-dir-A sends', /send ok=true/.test(d.lastIntent()||''), d.lastIntent());

// --- diagonals ---
await d.boot(7);
const diag = await d.hold(['up','left']);
R.check('diagonal aims', diag.some(x=>/@c select node=n5/.test(x)),
        diag.filter(x=>x.startsWith('@c')).pop() || 'no move');

// --- THE DROP IS AS FORGIVING AS THE AIM ---
//
// A drag that crosses a mound and releases a little past it must still
// send there, and the arrow that was drawn to that mound is the promise
// being kept. The bug this guards against was SILENT: past a tight
// radius the release emitted no intent at all -- no send, no refusal --
// while the arrow was still pointing at the target, so the gesture
// looked like it did nothing and the next attempt worked. It read as
// "sometimes sends take two tries".
//
// The pair matters more than either number. Inside the release radius a
// drop MUST land; well outside it the arrow is gone and the drop MUST
// NOT, or "forgiving" quietly becomes "sends to whatever you last brushed
// past, from anywhere on the map".
for (const [off, want] of [[0, true], [50, true], [90, true], [160, false]]) {
  await d.boot(7);
  const st = await d.inspect();
  const [x1, y1] = st.pos.n1, [x2, y2] = st.pos.n2;
  const dd0 = Math.hypot(x2 - x1, y2 - y1);
  const ux = (x2 - x1) / dd0, uy = (y2 - y1) / dd0;
  // Straight through n2 and out the far side, so the finger genuinely
  // crosses the target before stopping short of / past it.
  const out = await d.drag(x1, y1, Math.round(x2 + ux * off), Math.round(y2 + uy * off));
  const sent = (out || []).filter(l => l.startsWith('@i send')).pop();
  await d.step(40);
  const after = await d.inspect();
  const landed = /send ok=true/.test(sent || '') && after.mound.n2.gi > st.mound.n2.gi;
  R.check(`a drop ${off}px past the mound ${want ? 'SENDS' : 'does not send'}`,
          landed === want,
          `${sent || 'no intent'} | n2 incoming ${st.mound.n2.gi} -> ${after.mound.n2.gi}`);
}

R.check('no lua errors', d.errors().length === 0, d.errors().slice(0,2).join(' | '));
await releaseAll();   // hand the emulator hosts back before exiting
process.exit(R.done() ? 0 : 1);