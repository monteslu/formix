// drive.mjs - the harness. Every romdev call is CHECKED: an error result
// throws rather than being silently ignored. This exists because a harness
// that sent input({port,buttons}) instead of input({ports}) errored on
// every call, the errors were never read, and it reported passes for a
// game that was receiving no input at all.
const U = 'http://127.0.0.1:7331';

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
    async inspect() {
      await t('input', { op: 'press', button: 'select', frames: 6 });
      await t('frame', { op: 'step', frames: 40 });
      const lines = await drain();
      await t('input', { op: 'press', button: 'select', frames: 6 });
      await t('frame', { op: 'step', frames: 20 });
      await drain();
      const pos = {}, mound = {};
      for (const l of lines) {
        let m = l.match(/^@node (\w+) (-?\d+) (-?\d+)/);
        if (m) pos[m[1]] = [ +m[2], +m[3] ];
        // `fg` (the HOLDER's garrison) is optional so this still parses a
        // cart built before it existed -- a gate that silently matched
        // nothing would report every mound as missing rather than fail.
        // `held` and `obs` are optional for the same reason `fg` is: an
        // older cart does not print them, and a gate that silently
        // matched nothing would report every mound as missing.
        m = l.match(/^@mound (\w+) (\S+) g=(\d+) gi=(\d+) (?:fg=(\d+) )?q=(\d+)\/(\d+) energy=(\d+) reach=(\d+) seen=(\w+) brood=(\d+)(?: held=(\w+))?(?: obs=(\w+))?/);
        if (m) mound[m[1]] = { owner: m[2] === 'nil' ? null : m[2], g: +m[3], gi: +m[4],
                               fg: m[5] === undefined ? +m[3] : +m[5],
                               queens: +m[6], maxQueens: +m[7], energy: +m[8],
                               reach: +m[9], seen: m[10] === 'true', brood: +m[11],
                               held: m[12] === 'true', observed: m[13] === 'true' };
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
      return { pos, mound, cam, ui };
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
