// BEATING A LEVEL HAS TO BE REMEMBERED, AND THE PLAYER HAS TO BE ABLE TO
// PICK WHERE TO GO NEXT.
//
// Plan 06, Luis 2026-08-19: "when a level is cleared, after a restart you
// should be able to pick that level or start an uncompleted level. we
// don't necessarily need to save the game state, but at least know which
// levels we already beaten so we can go onto the next level."
//
// PERSISTENCE IS PROVED TWO WAYS, and the second one only became possible
// after the host was fixed.
//
// 1. THE ROUND TRIP THROUGH THE BLOB, which is the part Formix owns: the
//    set is written, the in-memory copy is dropped, and it is read back
//    out of the written bytes (`fromblob=` on the @dbg line). If the
//    write, the format, or the co-tenancy with the colony's own lines
//    were broken, that comes back empty.
//
// 2. AN ACTUAL RELOAD. This gate originally could NOT do this: romdev did
//    not carry a wasmcart's SRAM across `loadMedia` (every load started
//    zeroed) and `state({op:'exportSram'})` could not even see the
//    region, reporting "no battery save RAM, size 0" against 4096 live
//    bytes. That was written up in
//    internal-romdev/feedback/2026-08-19_wasmcart-sram-invisible-to-state-tool-and-lost-on-reload.md
//    and FIXED in romdev 0.120.0. So the thing Luis actually asked for --
//    "after a restart you should be able to pick that level" -- is now
//    asserted against a real restart instead of being taken on trust.
//
// NOTE FOR ANYONE ADDING A GATE HERE: `boot()` WIPES SRAM by default,
// precisely because that persistence is now real (see tools/drive.mjs).
// A gate that wants the save to survive a reload must ask for it with
// `boot(seed, {keepSave:true})` -- which is exactly what section 2b does.
import { api, driver, makeReport, releaseAll } from './drive.mjs';
import { execSync } from 'child_process';
import { writeFileSync, unlinkSync, existsSync, copyFileSync } from 'fs';
import { readPNG } from './png.mjs';

const R = makeReport();

function buildCart(fname, markers) {
  const CART = process.cwd() + '/test/' + fname;
  for (const [f, v] of Object.entries(markers)) writeFileSync('app/' + f, v);
  try {
    execSync('./build.sh', { stdio: 'ignore' });
    copyFileSync(process.cwd() + '/formix.wasc', CART);
  } finally {
    // RESTORE THE CART IN A FINALLY, per DEVLOOP.md: a rebuilding gate
    // that leaves the cart wrong poisons every gate after it.
    for (const f of Object.keys(markers)) {
      if (existsSync('app/' + f)) unlinkSync('app/' + f);
    }
    execSync('./build.sh', { stdio: 'ignore' });
  }
  return CART;
}

const PLAIN = process.cwd() + '/formix.wasc';

// Open the pause menu and pick "Choose a level" (row 1).
//
// ORDER MATTERS, AND IT COST THIS GATE A SUITE RUN. On a level that is
// already FINISHED, START does not open the pause menu at all -- it means
// "next field" (intents.lua's `M.levelDone` branch, which predates plan
// 06 and is what the HUD prompt has always promised). So a gate that
// beats a level and then presses START to reach the select silently
// advances the campaign instead, and every assertion after it reads a
// fresh Gather with nothing beaten.
//
// The fix is to open the select BEFORE recording anything, or from a
// level that is not done. `beatLevel` below therefore takes the select
// route first and records afterwards where a test needs both.
async function openSelect(d) {
  await d.press('start', 6);
  await d.step(20);
  await d.press('a', 6);
  await d.step(30);
}

// Record the current level as beaten (overlay on, SELECT+START, overlay
// off). Leaves `levelDone` set, so anything needing the pause menu after
// this must account for the START behaviour described above.
async function beatLevel(d) {
  await d.press('select', 6);
  await d.step(15);
  await d.hold(['select', 'start'], 8);
  await d.step(15);
  await d.press('select', 6);
  await d.step(15);
}

// ── 1. FIRST BOOT: no select screen in the way ─────────────────────────
{
  const t = api('formix-progress-firstboot');
  const d = driver(t, PLAIN);
  await d.boot(7, { level: 'gather' });
  const ins = await d.inspect();
  R.check('a fresh player boots straight into gather, with no level select',
          ins.ui2 && ins.ui2.select === false,
          ins.ui2 ? `select=${ins.ui2.select}` : 'no @ui2 line');
  R.check('...and nothing is recorded as beaten yet',
          d.all().some(l => /@progress loaded beaten=0/.test(l)),
          d.all().filter(l => l.startsWith('@progress')).join(' | '));
  R.check('no lua errors on the first-boot path',
          d.errors().length === 0, d.errors().slice(0, 2).join(' | '));
}

// ── 2. THE RECORD, AND ITS ROUND TRIP THROUGH THE BLOB ─────────────────
//
// `beatlevel` (SELECT+START, overlay-gated) writes the same record a real
// win writes, through progress.markBeaten -- test-campaign is what proves
// campaign.complete fires on a played level; this is about the record.
{
  const t = api('formix-progress-record');
  const d = driver(t, PLAIN);
  await d.boot(7, { level: 'gather' });

  await d.press('select', 6);
  await d.step(20);
  await d.hold(['select', 'start'], 8);
  await d.step(20);
  const line = d.all().filter(l => l.startsWith('@dbg beatlevel')).pop();
  R.check('beating a level records it', !!line && /beaten=gather/.test(line),
          line || 'no @dbg beatlevel line');
  R.check('and it survives a round trip through the save blob',
          !!line && /fromblob=gather/.test(line),
          line || 'no @dbg beatlevel line');

  // CO-TENANCY: the colony's own writer must not erase the progress
  // lines. SELECT+A round-trips the colony through serialize/deserialize
  // and writes the blob; the progress record has to still be there after.
  await d.hold(['select', 'a'], 8);
  await d.step(30);
  await d.hold(['select', 'start'], 8);
  await d.step(20);
  const after = d.all().filter(l => l.startsWith('@dbg beatlevel')).pop();
  R.check('CONTROL: a colony save does not wipe the beaten set',
          !!after && /fromblob=gather/.test(after),
          after || 'no @dbg beatlevel line');
  R.check('no lua errors across the record path',
          d.errors().length === 0, d.errors().slice(0, 2).join(' | '));
}

// ── 2b. THE RESTART. What Luis actually asked for. ────────────────────
//
// "After a restart you should be able to pick that level." Sections 1-2
// prove the bytes are written and readable; this proves they SURVIVE the
// cart being reloaded, which is the player-visible promise and the one
// thing that was untestable until romdev 0.120.0.
//
// The shape matters: beat a level on a WIPED cart, reload with
// keepSave:true, and read the set back out of the freshly-booted cart.
// The control runs the SAME sequence through the default (wiping) boot
// and asserts the earlier level is FORGOTTEN -- without it this would
// pass just as happily against a host that never wiped anything.
{
  const t = api('formix-progress-restart');
  const d = driver(t, PLAIN);

  await d.boot(7, { level: 'gather' });
  await d.press('select', 6);
  await d.step(20);
  await d.hold(['select', 'start'], 8);   // beat `gather`, writes the blob
  await d.step(30);
  const wrote = d.all().filter(l => l.startsWith('@dbg beatlevel')).pop();
  R.check('preamble: the level was recorded before the restart',
          !!wrote && /beaten=gather/.test(wrote), wrote || 'no @dbg line');

  // THE RESTART ITSELF: reload the cart, keeping the save region.
  await d.boot(7, { level: null, keepSave: true });
  await d.press('select', 6);
  await d.step(20);
  await d.hold(['select', 'start'], 8);
  await d.step(20);
  const back = d.all().filter(l => l.startsWith('@dbg beatlevel')).pop();
  R.check('THE RESTART: the beaten set survives a cart reload',
          !!back && /fromblob=[^ ]*gather/.test(back),
          back || 'no @dbg beatlevel line after reload');

  // CONTROL THAT MUST FAIL: the same restart WITHOUT keeping the save
  // must come back with the OLD level forgotten. This is what proves the
  // assertion above reads persisted bytes rather than a set the cart
  // rebuilds on its own -- and that the suite's default wipe genuinely
  // wipes, which every other gate now depends on.
  //
  // THE SECOND LEVEL IS LOAD-BEARING. `beatlevel` marks the CURRENT
  // level, and `fromblob` is a set, so beating `gather` twice reads
  // `gather` either way and a control built on it would pass vacuously.
  // So: beat `settle` first, restart, then beat `gather`. With the save
  // kept the set reads both; with it wiped it reads only `gather`, and
  // the disappearance of `settle` is the fact being asserted.
  const restartCtl = async (keepSave) => {
    const tc = api(`formix-progress-restart-${keepSave ? 'keep' : 'wipe'}`);
    const dc = driver(tc, PLAIN);
    await dc.boot(7, { level: 'gather' });
    await dc.press('select', 6);
    await dc.step(20);
    // Reach `settle` and record it, so there is a PRIOR entry to lose.
    // `beatlevel` records the win and raises the celebration card; the
    // card's "Next level" row is A, exactly as a player advances (see
    // test-celebrate section 3). SELECT+START alone would only ever
    // re-record `gather`, which is what made the first cut of this
    // control read `fromblob=gather` on both sides and prove nothing.
    await dc.hold(['select', 'start'], 8);   // beat gather, card opens
    await dc.step(20);
    await dc.press('a', 6);                  // "Next level" -> settle
    await dc.step(90);
    await dc.hold(['select', 'start'], 8);   // beat settle
    await dc.step(30);
    const before = dc.all().filter(l => l.startsWith('@dbg beatlevel')).pop();
    await dc.boot(7, { level: null, keepSave });
    await dc.press('select', 6);
    await dc.step(20);
    await dc.hold(['select', 'start'], 8);
    await dc.step(20);
    const after = dc.all().filter(l => l.startsWith('@dbg beatlevel')).pop();
    return { before, after };
  };

  const kept = await restartCtl(true);
  const wiped = await restartCtl(false);
  const setOf = l => ((l || '').match(/fromblob=(\S*)/) || [, ''])[1];
  R.check('preamble: two levels were recorded before the restart',
          /settle/.test(setOf(kept.before)) && /gather/.test(setOf(kept.before)),
          kept.before || 'no @dbg line');
  R.check('a KEPT save still remembers the earlier level after a restart',
          /settle/.test(setOf(kept.after)), kept.after || 'no @dbg line');
  R.check('CONTROL: a WIPED restart has forgotten it',
          !/settle/.test(setOf(wiped.after)), wiped.after || 'no @dbg line');

  R.check('no lua errors across the restart path',
          d.errors().length === 0, d.errors().slice(0, 2).join(' | '));
}

// ── 3. THE SELECT'S RULES: beaten, frontier, locked ────────────────────
{
  const t = api('formix-progress-rules');
  const d = driver(t, PLAIN);
  await d.boot(7, { level: 'gather' });
  // ORDER: BEAT, DISMISS THE CARD, SPEND THE ONE-SHOT START, THEN MENU.
  //
  // Recording a win sets `levelDone`, and on a finished level the FIRST
  // START means "next field" rather than "open the menu" -- the promise
  // the HUD has always made. Plan 06 made that a one-shot
  // (`intents.startConsumed`) so the pause menu is not lost forever after
  // a win, but the promise still has to be spent before START goes back
  // to being the pause button.
  //
  // So: B clears the celebration card, the first START spends the
  // next-field promise (which starts settle), and from there START opens
  // the menu normally. The select is then read on settle -- which is
  // FINE, and is in fact the more honest board to read it on: gather is
  // beaten, settle is the frontier the player is now standing in.
  await beatLevel(d);
  await d.press('b', 6);            // dismiss the celebration card
  await d.step(20);
  await d.press('start', 6);        // spend the one-shot "next field"
  await d.step(120);
  await openSelect(d);

  const ins = await d.inspect();
  R.check('the level select opens from the pause menu',
          ins.ui2 && ins.ui2.select === true,
          ins.ui2 ? `select=${ins.ui2.select}` : 'no @ui2 line');
  const rows = (ins.ui2 && ins.ui2.rows) || [];
  const byId = Object.fromEntries(rows.map(r => [r.id, r]));
  R.check('gather is marked beaten', !!byId.gather && byId.gather.beaten,
          JSON.stringify(rows));
  R.check('settle is the frontier: unbeaten but NOT locked',
          !!byId.settle && !byId.settle.beaten && !byId.settle.locked,
          JSON.stringify(byId.settle));
  R.check('CONTROL: levels past the frontier stay LOCKED',
          !!byId.discover && byId.discover.locked && !!byId.war && byId.war.locked,
          `discover=${JSON.stringify(byId.discover)} war=${JSON.stringify(byId.war)}`);
  R.check('CONTROL: no gate fixture ever appears in a player level list',
          rows.length > 0 && rows.every(r => !/^gate/.test(r.id)),
          rows.map(r => r.id).join(','));

  // PIXELS: the screen is actually drawn, not just flagged open.
  const shot = process.cwd() + '/test/shots/progress-select.png';
  await d.shot(shot);
  const im = readPNG(shot);
  let panel = 0;
  for (let y = 300; y < 800; y += 2) {
    for (let x = 500; x < 1420; x += 2) {
      const [rr, gg, bb] = im.at(x, y);
      // The card is a dark panel with a green rim over a 0.92 scrim; the
      // ordinary board underneath is brown earth and green grass at much
      // higher brightness.
      if (rr < 40 && gg < 50 && bb < 45) panel++;
    }
  }
  R.check('the select screen is actually on the glass (dark card pixels)',
          panel > 2000, `dark panel px=${panel}`);
  R.check('no lua errors with the select open',
          d.errors().length === 0, d.errors().slice(0, 2).join(' | '));
}

// ── 4. BOTH DEVICES DRIVE IT ───────────────────────────────────────────
//
// "both mouse and gamepad need to be able to advance to next level or
// select previous" -- so this is two assertions, not one.
{
  // 4a. THE PAD.
  const t = api('formix-progress-pad');
  const d = driver(t, PLAIN);
  await d.boot(7, { level: 'gather' });
  await beatLevel(d);
  await d.press('b', 6); await d.step(20);      // dismiss the celebration
  await d.press('start', 6); await d.step(120); // spend the one-shot START
  await openSelect(d);

  let ins = await d.inspect();
  R.check('the select is up for the pad test',
          ins.ui2 && ins.ui2.select, `select=${ins.ui2 && ins.ui2.select}`);
  const row0 = ins.ui2 && ins.ui2.selrow;
  await d.press('down', 6);
  await d.step(15);
  ins = await d.inspect();
  R.check('the PAD moves the focused row',
          ins.ui2 && ins.ui2.selrow !== row0,
          `row ${row0} -> ${ins.ui2 && ins.ui2.selrow}`);

  await d.press('a', 6);
  await d.step(90);
  // ASSERT ON THE LEVEL STARTING, NOT ON `select` GOING FALSE. Confirming
  // a row rebuilds the world, which re-inits the probe with the overlay
  // OFF -- so `@ui2` stops printing entirely and `select` reads null
  // rather than false. The null is the world being rebuilt, which is the
  // very thing being tested; `@level started` is the honest signal.
  const started = d.all().filter(l => l.startsWith('@level started')).pop();
  R.check('the PAD confirms a row and the level actually starts',
          !!started, started || 'no @level started line');
  R.check('no lua errors on the pad path',
          d.errors().length === 0, d.errors().slice(0, 2).join(' | '));
}
{
  // 4b. THE MOUSE, on the same screen.
  const t = api('formix-progress-mouse');
  const d = driver(t, PLAIN);
  await d.boot(7, { level: 'gather' });
  await beatLevel(d);
  await d.press('b', 6); await d.step(20);      // dismiss the celebration
  await d.press('start', 6); await d.step(120); // spend the one-shot START
  await openSelect(d);

  let ins = await d.inspect();
  R.check('the select is up for the mouse test',
          ins.ui2 && ins.ui2.select, `select=${ins.ui2 && ins.ui2.select}`);

  // Row geometry from ui/levelselect.lua layout(): rows are vp.u(96)
  // tall, centred, with a +30 offset. vp.u is 1:1 at 1080p.
  const nRows = (ins.ui2 && ins.ui2.rows.length) || 5;
  const rowH = 96;
  const y0 = Math.round((1080 - rowH * nRows) / 2 + 30);
  await d.tap(960, y0 + Math.floor(rowH / 2));
  await d.step(90);
  // Same reasoning as the pad assertion above: the rebuild takes the
  // overlay down with it, so the level-started line is the signal.
  const started = d.all().filter(l => l.startsWith('@level started')).pop();
  R.check('a MOUSE click picks a row and the level starts',
          !!started, started || 'no @level started line');
  R.check('no lua errors on the mouse path',
          d.errors().length === 0, d.errors().slice(0, 2).join(' | '));
}

// ── 5. LOCKED ROWS REFUSE ──────────────────────────────────────────────
{
  const t = api('formix-progress-locked');
  const d = driver(t, PLAIN);
  await d.boot(7, { level: 'gather' });
  await openSelect(d);
  let ins = await d.inspect();
  // With NOTHING beaten this cart's select still opens from the menu, and
  // every level past the frontier is locked. Clicking one must do nothing.
  const rows = (ins.ui2 && ins.ui2.rows) || [];
  const lockedIdx = rows.findIndex(r => r.locked);
  R.check('there is a locked row to try', lockedIdx >= 0,
          rows.map(r => `${r.id}${r.locked ? '(locked)' : ''}`).join(','));
  if (lockedIdx >= 0) {
    const rowH = 96;
    const y0 = Math.round((1080 - rowH * rows.length) / 2 + 30);
    await d.tap(960, y0 + lockedIdx * rowH + Math.floor(rowH / 2));
    await d.step(60);
    ins = await d.inspect();
    R.check('CONTROL: clicking a LOCKED row does not start it',
            ins.ui2 && ins.ui2.select === true,
            `select=${ins.ui2 && ins.ui2.select} (should stay open)`);
  }
  R.check('no lua errors on the locked-row path',
          d.errors().length === 0, d.errors().slice(0, 2).join(' | '));
}

await releaseAll();   // hand the emulator hosts back before exiting
process.exit(R.done() ? 0 : 1);