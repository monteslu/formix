// FOOD IS A DESTINATION, NEVER A BRIDGE OR A WATCHTOWER.
//
// Two rules that are easy to break by accident and invisible when broken,
// because both failures look like generosity:
//
//   1. HOLDING A LOCATION DOES NOT EXTEND THE NETWORK. You may send to a
//      patch of grain inside your reach, but you may never relay THROUGH
//      it to the ground beyond. The orbit rule is the whole puzzle of the
//      map, and food that widened it would quietly dissolve the puzzle --
//      every far mound suddenly one grain patch away.
//
//   2. HOLDING A LOCATION DOES NOT EXTEND VISION. Ants standing on food
//      see the food they are standing on. A mound's garrison scouts its
//      horizon; a patch of grain does not, or a lucky patch out in the
//      dark would scout a whole corner of the map for free.
//
// The board: two mounds 1900 apart -- well outside a plain mound's 1150
// reach -- with grain exactly halfway, in reach of both. If either rule
// leaks, the far mound becomes reachable or observed the moment the grain
// is taken. Written to FAIL: let path() relay through a location and rule
// 1 goes red; let a location scout its neighbours and rule 2 goes red.
import { api, driver, makeReport } from './drive.mjs';
import { execSync } from 'child_process';
import { writeFileSync, unlinkSync, existsSync, copyFileSync } from 'fs';

const t = api('formix-locrules-suite');
const R = makeReport();

const CART = process.cwd() + '/test/bridge-cart.wasc';
writeFileSync('app/startlevel', 'gatebridge');
try {
  execSync('./build.sh', { stdio: 'ignore' });
  copyFileSync(process.cwd() + '/formix.wasc', CART);
} finally {
  if (existsSync('app/startlevel')) unlinkSync('app/startlevel');
}

const d = driver(t, CART);
await d.boot(7, { level: 'gatebridge' });

let r = await d.inspect();
const far = r.mound.n2;
R.check('the far mound starts unreachable and unknown',
        far && far.owner === null && far.seen === true,
        `owner=${far && far.owner}`);

// Take the grain in the middle.
await d.send(r.pos.n1, r.pos.L3);
await d.step(1200);
r = await d.inspect();
const locLine = d.all().filter(l => l.startsWith('@loc L3')).pop() || '';
R.check('the grain in the middle is ours', /you/.test(locLine), locLine);

// ── rule 1: no relaying through it ──
//
// Try to send from home straight past the grain to the far mound. The
// order must be REFUSED -- the sim drops a send with no path, and the
// intent log says so.
await d.send(r.pos.n1, r.pos.n2);
await d.step(600);
const attempt = d.intents().filter(l => /to=n2/.test(l)).pop() || '';
R.check('a send THROUGH the grain to the far mound is refused',
        /ok=false/.test(attempt), attempt || 'no send intent was emitted');

r = await d.inspect();
R.check('and the far mound is still nobody\'s',
        r.mound.n2.owner === null, `owner=${r.mound.n2.owner}`);

// ── rule 2: no seeing from it ──
//
// Standing on the grain must not reveal the far mound. `held` is the
// strict fact the renderer greys on, and it must still be false there.
R.check('standing on the grain does not reveal the far mound',
        r.mound.n2.held === false, `held=${r.mound.n2.held}`);

// ── and the thing that DOES work ──
//
// The rules above must not have broken the ordinary case: the grain is
// in reach, so ants got there and came home with food.
const m = await d.metric();
R.check('the grain itself was reachable and harvested',
        m.picked > 0 && (m.food + m.eaten) > 0,
        `picked=${m.picked} food=${m.food} eaten=${m.eaten}`);
R.check('no lua errors', d.errors().length === 0, d.errors()[0] || '');

execSync('./build.sh', { stdio: 'ignore' });
process.exit(R.done() ? 0 : 1);
