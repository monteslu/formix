// THE CAMPAIGN HAS AN ENDING.
//
// `open` was a placeholder -- `{ id = "open", campaign = true, generated
// = true }` and nothing else: no nodes, no locations, no lesson. It was
// the last row of the level select ("The open field -- Everything, all at
// once") and `campaign.complete` refuses every generated level on its
// first line, so it could not be beaten by anybody. The final level of
// the campaign was permanently unwinnable and the game had no ending.
//
// This gate asserts the three things that were wrong:
//
//   1. THE BOARD EXISTS. Authored nodes and locations, not a scatter.
//   2. THERE ARE TWO ENEMIES (Luis, 2026-08-20: "the following level can
//      have multiple enemies"). War was cut to a single rival because two
//      awake colonies straight after discover's one dormant one was a
//      cliff; this is where that fight went.
//   3. IT CAN BE WON, AND WINNING ENDS THE CAMPAIGN rather than
//      advancing into the gate fixtures. `campaign.next` used to walk the
//      array unconditionally, so the level after `open` is `gatefood` --
//      a one-mound gate board that would have been offered to the player
//      as "the next garden" the moment `open` became winnable.
//
// Point 3 is the one that needs care: playing this level to a real
// conclusion would take longer than the whole suite, so the WIN
// TRANSITION is driven with the SELECT+START progress instrument (the
// same one test-progress uses) and the win CONDITION is asserted
// separately against the live board. Between them they cover what a real
// win does without spending twenty minutes doing it.
import { api, driver, makeReport, releaseAll } from './drive.mjs';
import { execSync } from 'child_process';
import { writeFileSync, unlinkSync, existsSync, copyFileSync } from 'fs';

const t = api('formix-open-suite');
const R = makeReport();

// Its own cart, restored in a finally so a failure cannot leave the tree
// booting into the wrong level.
const CART = process.cwd() + '/test/open-cart.wasc';
writeFileSync('app/startlevel', 'open');
try {
  execSync('./build.sh', { stdio: 'ignore' });
  copyFileSync(process.cwd() + '/formix.wasc', CART);
} finally {
  if (existsSync('app/startlevel')) unlinkSync('app/startlevel');
  execSync('./build.sh', { stdio: 'ignore' });
}
const d = driver(t, CART);

await d.boot(7, { level: 'open' });
let r = await d.inspect();

// ── 1: THE BOARD IS AUTHORED ──────────────────────────────────────────
//
// A generated map would still produce mounds, so "there are mounds" is
// not the assertion. What separates authored from generated here is the
// COUNT: buildMap scatters 22 by default, this level authors 12. A board
// that comes back with twenty-odd is the generated field, which is the
// state this gate exists to catch.
const total = Object.keys(r.mound).length;
R.check('the open field is an AUTHORED board, not the generated scatter',
        total >= 8 && total <= 16,
        `${total} mounds (authored 12; the generated field is ~22)`);

R.check('it has locations to fight over',
        Object.keys(r.loc).length >= 6,
        `${Object.keys(r.loc).length} locations`);

// ── 2: TWO ENEMIES, AND THEY ARE REAL COLONIES ────────────────────────
const sides = new Set(Object.values(r.mound)
  .filter(m => m.owner && m.owner !== 'you').map(m => m.owner));
R.check('EXACTLY TWO enemy colonies -- this is the multi-enemy level',
        sides.size === 2,
        `sides=${[...sides].sort().join(',')}`);

// Each has a capital with a queen, or it is a garrison rather than a
// colony -- the distinction discover's notes are written about, and the
// one that decides whether an enemy regrows behind its front.
for (const side of [...sides].sort()) {
  const theirs = Object.entries(r.mound).filter(([, m]) => m.owner === side);
  const queens = theirs.reduce((n, [, m]) => n + (m.queens || 0), 0);
  R.check(`${side} is a colony with a queen, not a fixed garrison`,
          queens > 0 && theirs.length >= 2,
          `${theirs.length} mounds, ${queens} queens`);
}

// NEITHER ENEMY IS A WALK-OVER ON ITS OWN.
//
// NOT "the enemies outnumber you at t=0", which is what this asserted
// first and was the wrong measure -- it went red on the balance pass
// that made the level winnable at all (the player opens with 24 ants and
// two queens, deliberately, because holding two fronts from one capital's
// output is not arithmetically possible). Starting ant counts are not
// where this board's difficulty lives.
//
// The threat is that TWO colonies grow at once, so what has to be true at
// the start is that each of them is a real opponent rather than scenery:
// comparable to a single one of the player's fronts. A rival fielding
// three ants would satisfy any total-based check as long as its partner
// was large, and would still be a mound the player walks over.
const mine = Object.values(r.mound).filter(m => m.owner === 'you')
  .reduce((n, m) => n + (m.g || 0), 0);
const perSide = {};
for (const [, m] of Object.entries(r.mound)) {
  if (m.owner && m.owner !== 'you') {
    perSide[m.owner] = (perSide[m.owner] || 0) + (m.fg || 0);
  }
}
// NOT ASSERTED AT BOOT, AND THE REASON IS THE FOG.
//
// Two versions of a starting-strength check were written here and both
// were measuring the wrong number. `fg` is the HOLDER's garrison as the
// player can currently see it, and at t=0 both rivals are unobserved --
// so this reads 13 and 8 for colonies authored at 18+5 and 14+4. Any
// threshold tuned against those numbers is a threshold tuned against the
// fog, and it would move the moment the board's sight lines changed
// without either colony getting weaker.
//
// What the gate CAN see honestly is each side's mound-and-queen count
// (asserted above: two mounds and a queen each, so neither is a token),
// and what each side GROWS INTO once the fog lifts, which is what the
// survival run in phase 4 measures. Between them they cover "neither
// enemy is scenery" without any number that depends on visibility.
//
// The authored strengths, for the record, are red 18+5 with a home
// capital and gold 14+4 -- gold deliberately the smaller and slower, so
// that a player who reads the board can take it first and turn on red
// with one flank quiet.
const perSideMounds = {};
for (const [, m] of Object.entries(r.mound)) {
  if (m.owner && m.owner !== 'you') {
    perSideMounds[m.owner] = (perSideMounds[m.owner] || 0) + 1;
  }
}
R.check('neither enemy is a single-mound token',
        Math.min(...Object.values(perSideMounds)) >= 2,
        `mounds per side=${JSON.stringify(perSideMounds)} ` +
        `(visible garrisons ${JSON.stringify(perSide)} are fogged at boot)`);

// THE PLAYER OPENS ABLE TO GARRISON BOTH DIRECTIONS. This is the balance
// fix stated as a property of the board rather than as the numbers that
// produced it: a capital plus a garrisoned mound on each shoulder, and
// more than one queen, because one capital's output cannot hold two
// fronts. The first authored cut had one queen and empty shoulders, and a
// scripted player was eliminated by 200 seconds while the SAME script
// survived War's single rival for a full run.
//
// (The rival pantries are the other half of that fix -- cut from 55/40 to
// 40/30 -- but a gate cannot see a side's food, so the half that is
// observable is asserted here and the survival run below is what actually
// covers the outcome.)
const myMounds = Object.entries(r.mound).filter(([, m]) => m.owner === 'you');
const myQueens = myMounds.reduce((n, [, m]) => n + (m.queens || 0), 0);
R.check('the player opens with enough to garrison two fronts',
        myMounds.length >= 3 && myQueens >= 2,
        `${myMounds.length} mounds, ${myQueens} queens, ${mine} ants`);

// ── 3: TWO FRONTS, GEOMETRICALLY ──────────────────────────────────────
//
// The lesson is "you cannot answer both", which requires the two enemies
// to be in DIFFERENT DIRECTIONS from home. Two colonies stacked on one
// side of the map is one front with extra ants, and it would satisfy
// every count above.
const homeId = Object.keys(r.mound).find(id => r.mound[id].owner === 'you' &&
                                               r.mound[id].queens > 0);
const [sa, sb] = [...sides].sort();
function bearing(side) {
  const ms = Object.keys(r.mound).filter(id => r.mound[id].owner === side);
  let sx = 0, sy = 0;
  for (const id of ms) { sx += r.pos[id][0]; sy += r.pos[id][1]; }
  return [sx / ms.length - r.pos[homeId][0], sy / ms.length - r.pos[homeId][1]];
}
const [ax, ay] = bearing(sa), [bx, by] = bearing(sb);
// Screen Y grows downward, but the SIGN is all that matters: the two
// enemies must sit on opposite sides of the line through home.
R.check('the two enemies are in DIFFERENT directions from home (two fronts)',
        Math.sign(ay) !== Math.sign(by) && Math.sign(ay) !== 0,
        `${sa} bearing=(${ax.toFixed(0)},${ay.toFixed(0)}) ` +
        `${sb} bearing=(${bx.toFixed(0)},${by.toFixed(0)})`);

// ── 4: THE LEVEL IS ALIVE ─────────────────────────────────────────────
//
// Both rivals awake from the first tick (no wakeOnContact on this board),
// so letting it run has to produce actual play. The war map's whole
// failure mode was two colonies expanding into their own corners and
// then staring at each other, and nothing caught it because nothing
// asserted anyone ever fought.
const ownerLog = {};
for (const id of Object.keys(r.mound)) ownerLog[id] = [r.mound[id].owner || '-'];
for (let i = 0; i < 5; i++) {
  await d.step(3000);
  r = await d.inspect();
  for (const id of Object.keys(r.mound)) {
    (ownerLog[id] = ownerLog[id] || []).push(r.mound[id].owner || '-');
  }
}
// THE RIVALS PLAY THE GAME: they take ground and they grow.
//
// NOT "@rival ... attacks", which is what this asserted first and is the
// wrong instrument on this board. `sim/rival.lua` logs foraging, attacks
// and idling -- but EXPANSION ONTO EMPTY GROUND, which is what a rival
// spends its opening minutes doing, prints nothing at all. The gate
// drives no sends, so the player is not a target worth walking to and
// neither colony has any reason to attack anybody for a long time.
//
// The check went red for 550 seconds on a board where the rivals had in
// fact each taken an extra mound by t=100 and grown from 8 to 48 ants.
// The level was working and the assertion was reading a log line that
// the behaviour it cared about does not emit -- which is the exact shape
// of mistake worth writing down rather than quietly retuning.
//
// So it asserts on the BOARD. Ground taken and garrisons grown are both
// visible in the overlay dump, and together they are what "the colonies
// are alive" actually means: the war map's inert-rival failure (two
// colonies expanding into their own corners and then staring at each
// other) shows up here as growth WITHOUT expansion, and a frozen brain
// shows up as neither.
const grownSides = {};
for (const [, m] of Object.entries(r.mound)) {
  if (m.owner && m.owner !== 'you') {
    grownSides[m.owner] = (grownSides[m.owner] || 0) + (m.fg || 0);
  }
}
const moundsNow = {};
for (const [, m] of Object.entries(r.mound)) {
  if (m.owner && m.owner !== 'you') {
    moundsNow[m.owner] = (moundsNow[m.owner] || 0) + 1;
  }
}
R.check('both rival colonies EXPANDED past the two mounds they started on',
        Object.values(moundsNow).length === 2 &&
        Math.min(...Object.values(moundsNow)) > 2,
        `mounds per side now ${JSON.stringify(moundsNow)} (started 2 each)`);
R.check('both rival colonies GREW (they are laying, not frozen)',
        Object.values(grownSides).length === 2 &&
        Math.min(...Object.values(grownSides)) > 20,
        `visible garrisons ${JSON.stringify(grownSides)}`);

const neutralLeft = Object.values(r.mound).filter(m => !m.owner).length;
R.check('the neutral middle gets claimed', neutralLeft <= 3,
        `neutral mounds left=${neutralLeft}`);

// BOTH ENEMIES SURVIVE THE OPENING. If one quietly dies in the first
// four minutes the board is a one-front fight wearing two colours, which
// is the level this one was written to stop being.
const alive = {};
for (const m of Object.values(r.mound)) {
  if (m.owner && m.owner !== 'you') alive[m.owner] = (alive[m.owner] || 0) + 1;
}
R.check('both enemy colonies are still standing after the opening',
        Object.keys(alive).length === 2,
        JSON.stringify(alive));

// THE PLAYER IS STILL ON THE BOARD, and this is the balance assertion
// that has teeth. The gate sends nothing -- it is an IDLE player -- so
// this is the weakest possible showing, and the bar is correspondingly
// low: home must not have fallen in the first four minutes to colonies
// the player has not even engaged.
//
// It is a real bound, not a formality. Measured on War, an idle player is
// eliminated outright by 200 seconds (red takes all nine mounds); the
// first authored cut of THIS board did the same to a player who was
// actively playing. An idle player surviving here is the signal that two
// rivals spend part of their effort on each other rather than all of it
// on the west -- which is the pressure valve the map's shape is for, and
// the thing that stops two opponents from being twice one opponent.
const youLeft = Object.values(r.mound).filter(m => m.owner === 'you').length;
R.check('an idle player is not wiped out in the opening minutes',
        youLeft > 0,
        `you hold ${youLeft} mounds after 250s of not playing`);

// ── 5: THE WIN CONDITION IS "BOTH BROKEN", NOT A TERRITORY FRACTION ───
//
// Asserted from the live board: enemies still hold ground, so the level
// must NOT be complete. The fallback rule in campaign.complete is
// `owned >= 66% of mounds`, which on a 12-mound board a player can reach
// while a rival still holds a corner -- on the level whose lesson is "you
// cannot answer both fronts", that is exactly the state that must not
// count as an answer.
const enemyHeld = Object.values(r.mound).filter(m => m.owner && m.owner !== 'you').length;
const youHeld = Object.values(r.mound).filter(m => m.owner === 'you').length;
const bootLines = d.all().filter(l => l.startsWith('@level complete'));
R.check('with enemies still on the board, the level is NOT complete',
        enemyHeld > 0 && bootLines.length === 0,
        `you=${youHeld} enemy=${enemyHeld} completions=${bootLines.length}`);

// ── 6: WINNING ENDS THE CAMPAIGN ──────────────────────────────────────
//
// THE ASSERTION THIS GATE WAS WRITTEN FOR. `campaign.next` walked
// `M.levels[i + 1]` unconditionally and the entry after `open` is
// `gatefood` -- a one-mound gate fixture. Making `open` winnable without
// fixing that would have offered a gate board to the player as "the next
// garden", with the celebration card advertising it.
//
// Driven with SELECT+START (the progress instrument), which fires the
// same completion transition a real win does: it sets `levelDone`, reads
// `campaign.next`, and writes `nextLevelId`.
await d.press('select', 6);
await d.step(20);
await d.hold(['select', 'start'], 8);
await d.step(60);
await d.press('select', 6);
await d.step(30);

const done = d.all().filter(l => l.startsWith('@level complete')).pop() ||
             d.all().filter(l => l.startsWith('@progress beaten')).pop();
R.check('the last campaign level can be BEATEN at all',
        d.all().some(l => /@progress beaten open/.test(l)),
        done || 'no completion recorded');

// `next=nil` IS THE WHOLE POINT, and it needs its own witness.
//
// An earlier version of this check fell back to reading the celebration
// dialog when no `@level complete` line appeared, and that fallback was
// worthless: a build with the bug still in it reports `celebrate=true`
// exactly like a fixed one, so the assertion passed under deliberate
// sabotage. `nextLevelId` is the only thing that differs between "the
// campaign ended here" and "the campaign advanced into gatefood", which
// is why probe.lua now prints it on the beatlevel line.
const beatLine = d.all().filter(l => l.startsWith('@dbg beatlevel')).pop();
R.check('beating the last level does NOT advance into a gate fixture',
        beatLine !== undefined && /next=nil/.test(beatLine),
        beatLine || 'no @dbg beatlevel line');

R.check('no lua errors on the open field', d.errors().length === 0,
        d.errors().slice(0, 3).join(' | '));

const ok = R.done();
await releaseAll();
process.exit(ok ? 0 : 1);
