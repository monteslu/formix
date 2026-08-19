// drive.mjs - the harness. Every romdev call is CHECKED: an error result
// throws rather than being silently ignored. This exists because a harness
// that sent input({port,buttons}) instead of input({ports}) errored on
// every call, the errors were never read, and it reported passes for a
// game that was receiving no input at all.
const U = 'http://127.0.0.1:7331';

import { existsSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

export function api(session) {
  // RETRY ON TRANSPORT FAILURE ONLY. The server drops a connection now and
  // then when suites run back to back (ECONNRESET); that is a harness
  // problem and must not be reported as a game failure. A tool-level
  // `error` in the RESPONSE is a real failure and still throws.
  const call = async (name, args = {}) => {
    let lastErr;
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        const r = await fetch(`${U}/tool/${name}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'x-romdev-session': session },
          body: JSON.stringify(args),
        });
        const txt = await r.text();
        let out; try { out = JSON.parse(txt); } catch { out = txt; }
        if (out && out.error) {
          throw new Error(`${name}(${JSON.stringify(args).slice(0,120)}) -> ${out.error}`);
        }
        return out;
      } catch (e) {
        if (!/fetch failed|ECONNRESET|socket hang up/i.test(String(e))) throw e;
        lastErr = e;
        await new Promise(r => setTimeout(r, 250 * (attempt + 1)));
      }
    }
    throw lastErr;
  };
  return call;
}

// A 4096-byte run of zeros -- the cart's whole save region, empty.
// GENERATED rather than committed: it is 4096 zeros, it can never drift,
// and a binary blob in the tree invites someone to wonder what is in it.
// Written once per process into the OS temp dir, not beside the cart --
// a file next to a tracked fixture is exactly the trap that broke
// romdev's own suite when SRAM persistence first shipped to disk.
const BLANK_SRAM = (() => {
  const p = join(tmpdir(), 'formix-blank-sram.sav');
  if (!existsSync(p)) writeFileSync(p, Buffer.alloc(4096));
  return p;
})();

export function driver(t, cartPath) {
  let banked = [];
  const drain = async () => {
    const e = await t('wasm', { op: 'events' });
    const lines = (e.log || []).map(l => l.text);
    banked.push(...lines);
    return lines;
  };
  const d = {
    all: () => banked,
    // `level` asserts which campaign level the CART booted into. Default
    // "gather", because that is the opening board nearly every gate
    // assumes. A cart packed with an app/startlevel marker opens somewhere
    // else, and the gates then fail on assertions about ant counts and
    // ownership that look like real regressions -- which cost a full suite
    // run once. Pass level:null to accept whatever boots.
    async boot(seed = 7, opts = {}) {
      banked = [];
      await t('loadMedia', { platform: 'wasmcart', path: cartPath, deterministicSeed: seed });
      // START FROM AN EMPTY SAVE, ALWAYS.
      //
      // romdev 0.120.0 made wasmcart SRAM PERSIST across loadMedia (an
      // in-process cache keyed by cart path). That is the fix this game
      // asked for -- plan 06's progress record is unprovable without it,
      // and a player reloading a cart should keep their colony. But it
      // silently changed what boot() MEANS for a gate: every reload used
      // to hand back a pristine Gather, and now it hands back whatever
      // the previous gate (or the previous SESSION) left behind.
      //
      // Measured when it first bit: a suite run where test-gameplay's
      // sends were refused (`ok=false n=1`), test-longrun's ant
      // conservation reported 12 ants against 6+7 garrisons, test-strand
      // booted `ants=1 queens=0`, and test-campaign failed every
      // assertion -- all of them inheriting one stale `v 6` colony blob
      // with 330 seconds on its clock. None of it was a game bug, and
      // every failure pointed somewhere other than the save.
      //
      // So the gates declare what they need instead of inheriting it: a
      // gate asserts on a FRESH campaign, and the one thing that must
      // survive a reload (the progress record) is proved by writing it
      // and reloading DELIBERATELY, not by whatever happened to be in
      // the cache. Pass `keepSave:true` to opt into the persistence --
      // that is the flag a reload assertion uses.
      if (!opts.keepSave) {
        await t('state', { op: 'importSram', path: BLANK_SRAM });
        // The cart reads its save at init, so the wipe has to be in place
        // BEFORE the boot it should affect -- reload after importing.
        await t('loadMedia', { platform: 'wasmcart', path: cartPath, deterministicSeed: seed });
      }
      await t('frame', { op: 'step', frames: 60 });
      await drain();
      const want = opts.level === undefined ? 'gather' : opts.level;
      if (want !== null) {
        const line = banked.find(l => l.startsWith('@boot'));
        const got = line && (line.match(/level=(\S+)/) || [])[1];
        // An older cart has no level= field; do not fail on its absence.
        if (got && got !== want) {
          throw new Error(
            `cart booted level "${got}", this gate expects "${want}". ` +
            `Remove app/startlevel and rebuild, or pass {level:"${got}"}.`);
        }
      }
      return d;
    },
    async step(frames) { await t('frame', { op: 'step', frames }); await drain(); return d; },
    async press(button, frames = 6) {
      await t('input', { op: 'press', button, frames });
      await t('frame', { op: 'step', frames: 14 });
      return drain();
    },
    async hold(buttons, frames = 8) {
      const p0 = {}; for (const b of buttons) p0[b] = true;
      await t('input', { op: 'set', ports: [p0] });
      await t('frame', { op: 'step', frames });
      await t('input', { op: 'set', ports: [{}] });
      await t('frame', { op: 'step', frames: 16 });
      return drain();
    },
    async tap(x, y) {
      await t('input', { op: 'pointer', x, y, left: true, active: true });
      await t('frame', { op: 'step', frames: 8 });
      await t('input', { op: 'pointer', x, y, left: false, active: true });
      await t('frame', { op: 'step', frames: 18 });
      return drain();
    },
    // SEND ANTS THE WAY A PLAYER DOES: drag from source to target.
    //
    // Gates used to do this as tap(source) + tap(target), because tap-tap
    // sent. It no longer does -- a tap only selects, so that an
    // irreversible move is never one stray tap away while looking around --
    // and every gate that gathered ants silently stopped moving any,
    // reporting "12 gathered -- g=4". Naming the operation here means the
    // next input change is one edit rather than nine.
    async send(from, to) {
      await d.drag(from[0], from[1], to[0], to[1]);
      return drain();
    },
    // PLAN 05, 6c: the GESTURE is identical to a send -- drag from source
    // to target -- the sim itself decides "send" vs "withdraw" by whether
    // the source is a live spider fight (see input/intents.lua's note).
    // Named separately here only so a gate reads "withdraw" where it
    // means withdrawal, not because the wire protocol differs.
    async withdraw(from, to) {
      await d.drag(from[0], from[1], to[0], to[1]);
      return drain();
    },
    async drag(x0, y0, x1, y1, steps = 5) {
      await t('input', { op: 'pointer', x: x0, y: y0, left: true, active: true });
      await t('frame', { op: 'step', frames: 6 });
      for (let i = 1; i <= steps; i++) {
        const x = Math.round(x0 + (x1 - x0) * i / steps);
        const y = Math.round(y0 + (y1 - y0) * i / steps);
        await t('input', { op: 'pointer', x, y, left: true, active: true });
        await t('frame', { op: 'step', frames: 4 });
      }
      await t('input', { op: 'pointer', x: x1, y: y1, left: false, active: true });
      await t('frame', { op: 'step', frames: 20 });
      return drain();
    },
    // The overlay dump: node screen positions + per-mound state.
    // TOGGLE ON, READ, TOGGLE OFF. This assumes the overlay is DOWN on
    // entry, which is the contract every gate follows: a gate that raises
    // the overlay for a SELECT+button instrument lowers it again before
    // inspecting.
    //
    // An earlier plan-06 attempt made this "parity-independent" by
    // toggling until a dump arrived. That broke MORE than it fixed: the
    // number of SELECT presses inspect() issues is itself load-bearing
    // for any gate that brackets it with its own overlay presses, and
    // test-queen's SELECT+Y food grant started being refused because the
    // overlay ended up down when the grant fired. Predictable parity
    // beats clever recovery here.
    async inspect() {
      await t('input', { op: 'press', button: 'select', frames: 6 });
      await t('frame', { op: 'step', frames: 40 });
      const lines = await drain();
      await t('input', { op: 'press', button: 'select', frames: 6 });
      await t('frame', { op: 'step', frames: 20 });
      await drain();
      const pos = {}, mound = {}, loc = {}, corpses = [], spider = {};
      for (const l of lines) {
        let m = l.match(/^@node (\w+) (-?\d+) (-?\d+)/);
        if (m) pos[m[1]] = [ +m[2], +m[3] ];
        m = l.match(/^@corpse (\d+) (-?\d+) (-?\d+)/);
        if (m) corpses[+m[1] - 1] = [ +m[2], +m[3] ];
        // PLAN 05's own line: her hp, kill clock and how many of the 8
        // legs are held right now -- everything M.fightSpider decides
        // that the generic `@loc` line (below) does not carry, since
        // leg occupancy is per-instance state rather than a location
        // field.
        m = l.match(/^@spider (\S+) hp=(-?\d+) killT=(-?[\d.]+) held=(\d+) subdued=(\w+)/);
        if (m) spider[m[1]] = { hp: +m[2], killT: +m[3], held: +m[4],
                                subdued: m[5] === 'true' };
        // `fg` (the HOLDER's garrison) is optional so this still parses a
        // cart built before it existed -- a gate that silently matched
        // nothing would report every mound as missing rather than fail.
        // `held` and `obs` are optional for the same reason `fg` is: an
        // older cart does not print them, and a gate that silently
        // matched nothing would report every mound as missing.
        // spinYou/spinFoe (plan 05): the battle-spin sign M.fight assigned
        // each side while a mound is mixed, 0 when no battle is running.
        // Optional for the same reason `fg`/`held`/etc are: an older cart
        // does not print them.
        // qhp/corpses/corpseValue (2026-08-19): her hp mid-siege and
        // whether a fallen body is still waiting to be carried home.
        // Optional for the same older-cart-compatibility reason.
        m = l.match(/^@mound (\w+) (\S+) g=(\d+) gi=(\d+) (?:fg=(\d+) )?q=(\d+)\/(\d+) energy=(\d+) reach=(\d+) seen=(\w+) brood=(\d+)(?: held=(\w+))?(?: obs=(\w+))?(?: contested=(\w+))?(?: visited=(\w+))?(?: spinYou=(-?\d+))?(?: spinFoe=(-?\d+))?(?: qhp=(-?\d+))?(?: corpses=(\d+))?(?: corpseValue=(\d+))?/);
        if (m) mound[m[1]] = { owner: m[2] === 'nil' ? null : m[2], g: +m[3], gi: +m[4],
                               fg: m[5] === undefined ? +m[3] : +m[5],
                               queens: +m[6], maxQueens: +m[7], energy: +m[8],
                               reach: +m[9], seen: m[10] === 'true', brood: +m[11],
                               held: m[12] === 'true', observed: m[13] === 'true',
                               contested: m[14] === 'true', visited: m[15] === 'true',
                               spinYou: m[16] === undefined ? 0 : +m[16],
                               spinFoe: m[17] === undefined ? 0 : +m[17],
                               qhp: m[18] === undefined ? -1 : +m[18],
                               corpses: m[19] === undefined ? 0 : +m[19],
                               corpseValue: m[20] === undefined ? 0 : +m[20] };
        // LOCATIONS TOO, and the fog gate needs them: `visited` and
        // `lastSeenItems` are the two fields that say what the player has
        // LEARNED about a patch, as opposed to what is in it now, and
        // there is no pixel that distinguishes "remembered six grain"
        // from "there are six grain there right now". Trailing fields are
        // optional for the same reason the mound line's are: an older
        // cart does not print them, and a regex that silently matched
        // nothing would report every location as missing.
        m = l.match(/^@loc (\S+) (\S+) (\S+) items=(\d+)\/(\d+) value=(\d+) guard=(\d+) observed=(\w+) held=(\w+)(?: visited=(\w+))?(?: lastseen=(-?\d+))?(?: homedist=(-?\d+))?(?: homereach=(-?\d+))?(?: contested=(\w+))?/);
        if (m) loc[m[1]] = { kind: m[2], owner: m[3] === 'nil' ? null : m[3],
                             items: +m[4], cap: +m[5], value: +m[6], guard: +m[7],
                             observed: m[8] === 'true', held: m[9] === 'true',
                             visited: m[10] === 'true',
                             lastSeen: m[11] === undefined ? -1 : +m[11],
                             homedist: m[12] === undefined ? -1 : +m[12],
                             homereach: m[13] === undefined ? -1 : +m[13],
                             contested: m[14] === undefined ? false : m[14] === 'true' };
      }
      // The camera, for the pan/zoom gate. Parsed from the same overlay
      // dump: there is no pixel that says "the view moved 300 units".
      let cam = null;
      for (const l of lines) {
        const m = l.match(/^@cam x=(-?[\d.]+) y=(-?[\d.]+) zoom=([\d.]+)/);
        if (m) cam = { x: +m[1], y: +m[2], zoom: +m[3] };
      }
      // The UI line too: `frac` is the composed order's quantity, and it is
      // ONLY printed while the developer overlay is up -- so reading it from
      // the banked log without a fresh inspect gives a stale value from the
      // previous toggle, which is a silent wrong answer rather than a
      // missing one.
      let ui = null;
      for (const l of lines) {
        const m = l.match(/^@ui menu=(\w+) row=(\d+) cursor=(\S+) selected=(\S+) frac=([\d.]+)/);
        if (m) ui = { menu: m[1] === 'true', row: +m[2],
                      cursor: m[3] === 'nil' ? null : m[3],
                      selected: m[4] === 'nil' ? null : m[4], frac: +m[5] };
      }
      // PLAN 06: the level select and the win dialog, plus the select's
      // row list. `rows` decodes as id:<C|->{B|-}{L|-} -- continue,
      // beaten, locked -- which is the state no screenshot can report.
      let ui2 = null;
      for (const l of lines) {
        const m = l.match(/^@ui2 select=(\w+) selrow=(\d+) celebrate=(\w+) celrow=(\d+) rows=(.*)$/);
        if (m) {
          const rows = [];
          if (m[5] && m[5] !== 'none') {
            for (const tok of m[5].trim().split(/\s+/)) {
              const q = tok.match(/^(\S+):(.)(.)(.)$/);
              if (q) rows.push({ id: q[1], continue: q[2] === 'C',
                                 beaten: q[3] === 'B', locked: q[4] === 'L' });
            }
          }
          ui2 = { select: m[1] === 'true', selrow: +m[2],
                  celebrate: m[3] === 'true', celrow: +m[4], rows };
        }
      }
      return { pos, mound, loc, cam, ui, ui2, corpses, spider };
    },
    async metric() {
      await t('frame', { op: 'step', frames: 32 });
      const lines = await drain();
      const m = lines.filter(x => x.startsWith('@m ')).pop();
      return m ? JSON.parse(m.slice(3)) : null;
    },
    async shot(path) { await t('frame', { op: 'screenshot', path }); return path; },
    intents: () => banked.filter(x => x.startsWith('@i ')),
    lastIntent: () => banked.filter(x => x.startsWith('@i ')).pop() || null,
    errors: () => banked.filter(x => /error|attempt to index|attempt to call|stack traceback/i.test(x)),
  };
  return d;
}

export function makeReport() {
  const results = [];
  return {
    check(name, pass, detail = '') {
      results.push({ name, pass: !!pass, detail });
      console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? '  -- ' + detail : ''}`);
      return !!pass;
    },
    done() {
      const bad = results.filter(r => !r.pass);
      console.log(`\n${results.length - bad.length}/${results.length} passed`);
      if (bad.length) { console.log('FAILURES:'); bad.forEach(b => console.log('  - ' + b.name + '  ' + b.detail)); }
      return bad.length === 0;
    },
  };
}
