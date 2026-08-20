// EVERY BOARD MUST BE SURVIVABLE FROM ITS FIRST FRAME.
//
// This gate replaces test-relief and test-relief2, which asserted the old
// promise that a run could never become unwinnable. Food revokes that
// promise on purpose -- starvation is a real loss now -- so the question
// changes rather than disappears: a player can lose, but never because the
// board they were handed was already dead.
//
// THE BOOTSTRAP INVARIANT. Production needs a fed queen, so from the
// opening position a side must be able to reach one:
//
//   * with a queen already standing, ONE worker is enough -- it can walk
//     out, pick something up and bring it back
//   * with no queen at all, ELEVEN -- ten to raise her, and one left over
//     to fetch her first meal
//
// Ten-and-no-queen is the trap this exists to catch: it looks generous,
// buys the queen, and leaves nobody to feed her. The colony then sits at
// zero food with a queen who will never lay, which is a dead board that
// took ten minutes of play to discover.
import { api, driver, makeReport, releaseAll } from './drive.mjs';
import { execSync } from 'child_process';
import { writeFileSync, unlinkSync, existsSync, copyFileSync } from 'fs';

const t = api('formix-bootstrap-suite');
const R = makeReport();

// The campaign proper. `open` is generated and gets its own guarantee
// (a grain patch inside home's reach) once locations land.
const LEVELS = ['gather', 'settle', 'discover', 'war'];

for (const level of LEVELS) {
  const cart = process.cwd() + `/test/boot-${level}.wasc`;
  writeFileSync('app/startlevel', level);
  try {
    execSync('./build.sh', { stdio: 'ignore' });
    copyFileSync(process.cwd() + '/formix.wasc', cart);
  } finally {
    if (existsSync('app/startlevel')) unlinkSync('app/startlevel');
  }

  const d = driver(t, cart);
  await d.boot(7, { level });
  const line = d.all().find(l => l.startsWith('@boot')) || '';
  const num = (k) => {
    const m = line.match(new RegExp(k + '=(-?\\d+)'));
    return m ? +m[1] : null;
  };
  const ants = num('mine'), queens = num('queens'), food = num('food');

  R.check(`${level}: boot reports its opening hand`,
          ants !== null && queens !== null && food !== null, line);

  const need = queens > 0 ? 1 : 11;
  R.check(`${level}: can reach a fed queen from the opening (${ants} ants, ` +
          `${queens} queens, needs ${need})`,
          ants >= need,
          `ants=${ants} queens=${queens} food=${food} need=${need}`);

  // AND IT MUST NOT ALREADY BE OVER. A board that declares game over in
  // its first seconds is the failure this gate is named for.
  await d.step(180);
  const over = d.all().some(l => /^@gameover side=you/.test(l));
  R.check(`${level}: not dead on arrival`, !over, over ? 'gameover at boot' : '');
}

// ── the generated field ────────────────────────────────────────────────
//
// The campaign boards are hand-placed and can be checked by reading
// them. The open field cannot: it is different every seed, so the
// anti-starvation promise there is a GENERATED guarantee -- there is
// always a grain patch inside home's reach -- and a guarantee nobody
// asserts is a coin toss. Grain rather than aphids because grain comes
// back: the promise has to survive the player spending it badly once.
{
  const cart = process.cwd() + '/test/boot-open.wasc';
  execSync('./build.sh --open', { stdio: 'ignore' });
  copyFileSync(process.cwd() + '/formix.wasc', cart);
  execSync('./build.sh', { stdio: 'ignore' });

  // Several seeds, because "it worked on seed 7" is how a generator
  // guarantee gets shipped broken.
  for (const seed of [7, 21, 99, 1234]) {
    const d = driver(t, cart);
    await d.boot(seed, { level: 'open' });
    await d.press('select', 6);       // overlay: dumps @loc lines
    await d.step(40);

    const locs = d.all().filter(l => l.startsWith('@loc ')).map(l => {
      const m = l.match(/@loc (\S+) (\S+) \S+ items=(\d+)\/\d+ .* observed=(\w+).* homedist=(-?\d+) homereach=(-?\d+)/);
      return m && { id: m[1], kind: m[2], items: +m[3], observed: m[4] === 'true',
                    dist: +m[5], reach: +m[6] };
    }).filter(Boolean);

    // THE GUARANTEE IS ABOUT THE BOARD, NOT ABOUT WHAT THE PLAYER KNOWS.
    //
    // This used to assert an OBSERVED grain patch at boot, on the reading
    // that a queened colony watches its neighbours -- so "observed grain"
    // stood in for "grain within reach". Plan 04 deleted that adjacency
    // observation: nothing is observed at boot any more except the ground
    // your ants are standing on, and an anonymous clump beside home is
    // exactly what the player is now supposed to see.
    //
    // The map-generation guarantee itself is unchanged and still worth
    // gating, so assert it directly from sim truth (kind and distance,
    // which the @loc dump reports regardless of fog) rather than through
    // the player's knowledge of it.
    const nearGrain = locs.filter(l => l.kind === 'grain' &&
                                       l.dist >= 0 && l.dist <= l.reach);
    R.check(`open(seed ${seed}): grain within reach of home at boot`,
            nearGrain.length > 0,
            `locs=${locs.length} grain=${locs.filter(l => l.kind === 'grain')
              .map(l => `${l.id}@${l.dist}/${l.reach}`).join(',') || 'none'}`);
    R.check(`open(seed ${seed}): CONTROL: and the player cannot see it yet`,
            !locs.some(l => l.observed),
            `observed=${locs.filter(l => l.observed).map(l => l.kind)
              .join(',') || 'none'}`);
    R.check(`open(seed ${seed}): and there is something in it`,
            nearGrain.some(l => l.items > 0),
            nearGrain.map(l => `${l.id}:${l.items}`).join(' '));
  }
}

// Restore the ordinary cart so the next gate does not boot a gate board.
execSync('./build.sh', { stdio: 'ignore' });

await releaseAll();   // hand the emulator hosts back before exiting
process.exit(R.done() ? 0 : 1);