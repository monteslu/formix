// TWO SOUND CONTROLS, AND THEY ARE ACTUALLY SEPARATE.
//
// The requirement (Luis, 2026-08-20): "sound control should be separate
// with music and sound effects. and sound effects should be louder than
// current default." There was one `masterVolume` and everything
// multiplied through it, so this gate exists to prove the split is real
// rather than cosmetic -- two rows in the menu that both move the same
// number would look identical to a screenshot and identical to a player
// until they turned one off.
//
// THE WHOLE FEATURE IS INDEPENDENCE, so the whole gate is the pair:
// music off with effects audible, then effects off with music audible.
// Either direction alone can pass on a build where the two rows are
// wired together (turn "music" down on a shared control and the shots go
// quiet too -- but so does the music, and a one-sided check only looks at
// the music).
//
// WHAT IS ASSERTED ON. `@audio` is the cart reporting its own mixer
// state, printed every half second by debug/probe.lua. It has to be the
// evidence because romdev's audioDebug({op:'record'}) captures SILENCE
// for every wasmcart cart on this server -- including a shipped,
// human-verified control -- so no WAV can prove this cart makes noise.
// See internal-romdev/feedback/2026-08-15_audiodebug-silent-for-wasmcart.md.
//
// The gains in that line are EFFECTIVE gains (fade x slider), which is
// load-bearing: the raw fade gains do not move when a slider does --
// mute the music and `musicGain.calm` still reads 0.42 while the source
// is silent -- so a gate reading those would go green on a build where
// the slider was connected to nothing. audio/init.lua's `effective()`
// carries the long version of this note.
//
// Written to FAIL: phase 4 is a deliberate control that must go red if
// the two sliders are ever merged back into one.
import { api, driver, makeReport, releaseAll } from './drive.mjs';

const t = api('formix-audio-suite');
const d = driver(t, process.cwd() + '/formix.wasc');
const R = makeReport();

// ── reading the mixer ─────────────────────────────────────────────────
//
// The LAST @audio line in the log, parsed. Taking the last rather than
// the first matters: the line is printed twice a second, and a fade in
// progress means an early sample is mid-crossfade rather than settled.
function readAudio(lines) {
  const line = lines.filter(l => l.startsWith('@audio ') &&
                                 l.includes('vol:music=')).pop();
  if (!line) return null;
  const num = (re) => { const m = line.match(re); return m ? +m[1] : null; };
  const music = {};
  for (const m of line.matchAll(/music:(\w+)=([\d.]+)/g)) music[m[1]] = +m[2];
  const beds = {};
  for (const m of line.matchAll(/bed:(\w+)=([\d.]+)/g)) beds[m[1]] = +m[2];
  return {
    line,
    music,
    beds,
    // The loudest music track, which is the one a player is hearing.
    musicPeak: Math.max(0, ...Object.values(music)),
    bedPeak: Math.max(0, ...Object.values(beds)),
    volMusic: num(/vol:music=([\d.]+)/),
    volSfx: num(/sfx=([\d.]+)/),
    shots: num(/shots=(\d+)/),
    lastGain: num(/last=\w+@([\d.]+)/),
    lastName: (line.match(/last=(\w+)@/) || [])[1] || null,
  };
}

// Settle, then read. The music crossfade is MUSIC_FADE=4.0 seconds, so a
// read taken immediately after a slider move is measuring the fade rather
// than the setting -- and the bed's is 3.0. 300 frames at 60fps is five
// seconds, past both.
async function settle(frames = 300) {
  await d.step(frames);
  return readAudio(d.all());
}

// ── driving the menu ──────────────────────────────────────────────────
//
// Through the REAL pause menu, not a debug instrument. The menu is the
// feature -- two rows a player can reach -- so a gate that set the mixer
// numbers directly would prove the mixer works and say nothing about
// whether anyone can get at it. There is no free SELECT+button
// combination left for an audio instrument anyway (every face button,
// shoulder and d-pad direction under the modifier is spoken for).
const ROW = { levels: 1, music: 2, sfx: 3, palette: 4, hints: 5, resume: 6 };

async function openMenu() {
  await d.press('start', 6);
  await d.step(20);
  const r = await d.inspect();
  return r.ui;
}

// Move to a row by pressing down the required number of times. `index`
// starts at 1 on open.
async function toRow(target) {
  let r = await d.inspect();
  let guard = 0;
  while (r.ui && r.ui.row !== target && guard++ < 12) {
    await d.press('down', 6);
    await d.step(10);
    r = await d.inspect();
  }
  return r.ui;
}

// LEFT steps a slider down, RIGHT steps it up; both clamp on the pad
// (only touch wraps). Four presses from any position therefore lands on
// an end, whatever the starting value -- which is what makes this
// robust to the default moving.
async function slideTo(edge, presses = 5) {
  for (let i = 0; i < presses; i++) {
    await d.press(edge === 'min' ? 'left' : 'right', 6);
    await d.step(8);
  }
}

// ── PHASE 0: the report carries what the gate needs ───────────────────
await d.boot(7);
const base = await settle(200);

R.check('the cart reports its mixer state with both sliders',
        base !== null && base.volMusic !== null && base.volSfx !== null,
        base ? base.line.slice(0, 150) : 'no @audio line with vol:');

if (!base) {
  console.log('\nno @audio report -- nothing further can be asserted');
  R.done();
  await releaseAll();
  process.exit(1);
}

// SFX ARE LOUDER THAN MUSIC AT THE DEFAULT SETTING. This is the "louder
// than current default" half of the request, stated as the relationship
// that has to hold rather than as a literal: the sfx slider runs to full
// scale while the music keeps its headroom, so at the same slider
// position a shot is louder than a track. Asserting the RELATION rather
// than 1.0-vs-0.85 means re-tuning either default by ear does not
// falsely redden this.
R.check('at the default setting, effects are louder than music',
        base.volSfx > base.volMusic,
        `sfx=${base.volSfx} music=${base.volMusic}`);

// And louder than they were: the old chain was 0.8 (call site) x 0.85
// (the single master) = 0.68 of full scale for a shot at default. The
// new default has to beat that or "louder" did not happen.
const OLD_DEFAULT_SHOT = 0.8 * 0.85;
R.check('a shot at the default setting is louder than the old master could make it',
        base.volSfx * 0.8 > OLD_DEFAULT_SHOT,
        `now=${(base.volSfx * 0.8).toFixed(3)} was=${OLD_DEFAULT_SHOT.toFixed(3)}`);

R.check('music is playing to begin with, so muting it can be seen',
        base.musicPeak > 0.05,
        `musicPeak=${base.musicPeak} tracks=${JSON.stringify(base.music)}`);

// ── PHASE 1: MUSIC OFF, EFFECTS STILL AUDIBLE ─────────────────────────
//
// The first half of the pair. A player who turns music off wants a quiet
// garden -- so the BED and the wind go with it (they are atmosphere, not
// effects; audio/init.lua carries the reasoning) -- while a clank still
// lands at full strength.
await openMenu();
await toRow(ROW.music);
await slideTo('min');
await d.press('b', 6);            // close the menu (cancel)
await d.step(20);

const muted = await settle();
R.check('the music slider reads zero after turning it all the way down',
        muted && muted.volMusic === 0,
        muted ? `vol:music=${muted.volMusic}` : 'no report');

R.check('MUSIC IS SILENT with the music slider at zero',
        muted && muted.musicPeak <= 0.001,
        muted ? `musicPeak=${muted.musicPeak} tracks=${JSON.stringify(muted.music)}` : 'no report');

// THE BED FOLLOWS THE MUSIC SLIDER. This is the one genuinely ambiguous
// case in the split and it was decided deliberately: "music off" has to
// mean a quiet garden, not a quiet garden that still hums.
R.check('the ambient bed follows the music slider, so the garden goes quiet',
        muted && muted.bedPeak <= 0.001,
        muted ? `bedPeak=${muted.bedPeak} beds=${JSON.stringify(muted.beds)}` : 'no report');

// THE OTHER HALF: effects are untouched. Asserted on the SETTING (the
// slider did not move) and then on a real one-shot below.
R.check('the effects slider did NOT move when music was turned down',
        muted && muted.volSfx === base.volSfx,
        muted ? `sfx=${muted.volSfx} (was ${base.volSfx})` : 'no report');

// A REAL ONE-SHOT, DRIVEN THROUGH THE GAME.
//
// A SEND is the reliable provocation. audio.onIntent only speaks for
// link/reinforce/danger/abandon/caste -- pressing A emits `select`, which
// deliberately makes no sound at all (rule 1: nothing is a
// notification), so an earlier version of this helper tapped a foreign
// mound, watched `shots` stay at 0, and was measuring a sound the game
// does not have rather than a broken slider.
//
// A drag from an owned mound to a neighbour emits `link`, which plays.
// Alternating the direction each call means the second send is not
// refused as a no-op repeat of the first.
let sendFlip = false;
async function provokeShot() {
  const before = readAudio(d.all());
  const r = await d.inspect();
  const mine = Object.keys(r.mound).filter(id => r.mound[id].owner === 'you' &&
                                                 r.mound[id].g > 0 && r.pos[id]);
  const others = Object.keys(r.mound).filter(id => r.pos[id] && !mine.includes(id));
  const pool = others.length ? others : mine;
  if (mine.length && pool.length) {
    sendFlip = !sendFlip;
    const from = mine[sendFlip ? 0 : mine.length - 1];
    const to = pool.find(id => id !== from) || pool[0];
    await d.send(r.pos[from], r.pos[to]);
    await d.step(30);
  }
  const after = await settle(120);
  return { before, after, fired: after && before &&
           (after.shots || 0) > (before.shots || 0) };
}

const s1 = await provokeShot();
R.check('a one-shot still FIRES with the music muted',
        s1.fired,
        `shots ${s1.before?.shots} -> ${s1.after?.shots}`);

R.check('and it is AUDIBLE -- effects survive a muted music slider',
        s1.after && s1.after.lastGain > 0.05,
        s1.after ? `last=${s1.after.lastName}@${s1.after.lastGain}` : 'no report');

// ── PHASE 2: EFFECTS OFF, MUSIC BACK UP ───────────────────────────────
//
// The reverse. Together with phase 1 this is what proves independence:
// each control silences its own layer and leaves the other alone, so no
// single shared number can satisfy both.
await openMenu();
await toRow(ROW.music);
await slideTo('max');             // music back on
await toRow(ROW.sfx);
await slideTo('min');             // effects off
await d.press('b', 6);
await d.step(20);

const sfxOff = await settle();
R.check('the effects slider reads zero after turning it all the way down',
        sfxOff && sfxOff.volSfx === 0,
        sfxOff ? `vol:sfx=${sfxOff.volSfx}` : 'no report');

R.check('MUSIC IS AUDIBLE AGAIN with the music slider back up',
        sfxOff && sfxOff.musicPeak > 0.05,
        sfxOff ? `musicPeak=${sfxOff.musicPeak} vol:music=${sfxOff.volMusic}` : 'no report');

const s2 = await provokeShot();
R.check('a one-shot still fires with effects muted (it is silenced, not skipped)',
        s2.fired,
        `shots ${s2.before?.shots} -> ${s2.after?.shots}`);

R.check('but it is SILENT -- the effects slider actually silences it',
        s2.after && s2.after.lastGain <= 0.001,
        s2.after ? `last=${s2.after.lastName}@${s2.after.lastGain}` : 'no report');

// ── PHASE 3: the settings survive a save round trip ───────────────────
//
// A slider that resets every session is not a setting. The colony save
// carries them now (a `set` line); before this work ui/menu.lua had a
// serialize/deserialize pair that NOTHING EVER CALLED, so every sound,
// colour and hints choice was silently lost on exit.
//
// Driven through SELECT+A, the in-place serialize/deserialize instrument:
// romdev hands every loadMedia a fresh save sandbox, so a reload cannot
// see this and an assertion built on one would be testing the harness.
const beforeTrip = readAudio(d.all());
await d.press('select', 6);       // overlay up: the instrument is gated on it
await d.step(20);
await d.hold(['select', 'a'], 8);
await d.step(30);
await d.press('select', 6);       // overlay down
await d.step(20);

const afterTrip = await settle(150);
R.check('the two volume settings survive a save round trip',
        afterTrip && beforeTrip &&
        afterTrip.volMusic === beforeTrip.volMusic &&
        afterTrip.volSfx === beforeTrip.volSfx,
        afterTrip ? `music ${beforeTrip?.volMusic}->${afterTrip.volMusic} ` +
                    `sfx ${beforeTrip?.volSfx}->${afterTrip.volSfx}` : 'no report');

// ── PHASE 4: THE CONTROL THAT MUST FAIL if the sliders are merged ─────
//
// Set the two to OPPOSITE ENDS and require them to differ. On a build
// where both rows drive one number this lands them equal and goes red --
// which is the only assertion here that a shared-control regression
// cannot slip past, because every check above looks at one layer at a
// time and a merged control still silences the layer being looked at.
await openMenu();
await toRow(ROW.music);
await slideTo('max');
await toRow(ROW.sfx);
await slideTo('min');
await d.press('b', 6);
await d.step(20);

const opposed = await settle(150);
R.check('CONTROL: music at max and effects at min are DIFFERENT numbers',
        opposed && opposed.volMusic > 0 && opposed.volSfx === 0,
        opposed ? `music=${opposed.volMusic} sfx=${opposed.volSfx}` : 'no report');

// And the mirror of it, so neither ordering can be the one that happens
// to work.
await openMenu();
await toRow(ROW.music);
await slideTo('min');
await toRow(ROW.sfx);
await slideTo('max');
await d.press('b', 6);
await d.step(20);

const opposed2 = await settle(150);
R.check('CONTROL: and the other way round -- music at min, effects at max',
        opposed2 && opposed2.volMusic === 0 && opposed2.volSfx > 0,
        opposed2 ? `music=${opposed2.volMusic} sfx=${opposed2.volSfx}` : 'no report');

R.check('no lua errors in the audio run', d.errors().length === 0,
        d.errors().slice(0, 3).join(' | '));

const ok = R.done();
await releaseAll();
process.exit(ok ? 0 : 1);
