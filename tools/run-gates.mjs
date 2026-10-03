#!/usr/bin/env node
// run-gates.mjs - drive the cart through the romdev MCP and assert.
//
// romdev is the dev oracle AND the acceptance gate for this project: it is
// where screenshots, cart logs, input scripting and the playtest window all
// live, and it is the only place the work is visible to a human watching.
// So every gate here talks to the live server over HTTP rather than to a
// side host.
//
//   node tools/run-gates.mjs [gate ...]      (no args = all gates)
//   node tools/run-gates.mjs --list
//
// Each gate prints PASS/FAIL lines and the process exits non-zero if any
// failed, so this is CI-shaped as well as agent-shaped.
//
// NO HARDCODED PATHS: the cart is resolved relative to this file.

import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { romdevArgs } from './drive.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '..')
const CART = resolve(ROOT, 'formix.wasc')
const SHOTS = resolve(ROOT, 'test', 'shots')
const GOLDENS = resolve(ROOT, 'test', 'goldens')

const URL_BASE = process.env.ROMDEV_URL || 'http://127.0.0.1:7331'
const SESSION = process.env.ROMDEV_SESSION || 'formix-gates'

// ── romdev transport ───────────────────────────────────────────────────
// The /tool/<name> endpoint is the simple one: a POST per call with the
// session in a header. No MCP handshake needed for a script.
// The session is per-GATE, not per-run. romdev keeps emulator state in
// server memory keyed by session, and a long gate sharing a session with
// anything else can have its host EVICTED mid-run ("No ROM loaded in this
// session -- the host was evicted"). That is what killed the third year of
// the year gate while another gate ran alongside it. A gate that owns its
// session cannot be disturbed by a sibling.
let currentSession = SESSION

async function tool (name, args = {}) {
  const res = await fetch(`${URL_BASE}/tool/${name}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-romdev-session': currentSession,
    },
    body: JSON.stringify(romdevArgs(name, args)),
  })
  const text = await res.text()
  if (!res.ok) throw new Error(`${name} http ${res.status}: ${text.slice(0, 400)}`)
  try { return JSON.parse(text) } catch { return text }
}

// ── assertions ─────────────────────────────────────────────────────────
let pass = 0, fail = 0
const failures = []

function ok (name, cond, detail) {
  if (cond) { pass++; console.log(`  PASS ${name}`) }
  else {
    fail++
    failures.push(`${name}: ${detail ?? ''}`)
    console.log(`  FAIL ${name} ${detail ?? ''}`)
  }
}

// ── helpers ────────────────────────────────────────────────────────────
async function load (opts = {}) {
  await tool('loadMedia', {
    platform: 'wasmcart',
    path: CART,
    ...opts,
  })
}

// THE MECHANICS GATES TEST THE OPEN GARDEN, not the campaign. They assert
// things about the generated map's shape -- four neighbours off the nest,
// several rings, resource nodes to refuse -- and the tutorial gardens
// deliberately do not have that shape, so booting them there turned half
// the suite red with cursor flicks that targeted nothing.
//
// The choice is made at PACK time by `app/opengarden`, exactly like
// `app/testmode`: ./build.sh --open. The cart cannot read the host's
// deterministicSeed (it draws its own from love.math.random), so a
// seed-based switch was silently dead code.
async function loadOpen (opts = {}) {
  ensureOpenCart()
  await load({ deterministicSeed: 77, ...opts })
}

// The gate cart and the play cart differ by one marker file, so the
// harness packs the right one rather than relying on whoever ran
// build.sh last. Idempotent: it only repacks when the marker is missing.
let cartMode = null
function ensureOpenCart () {
  if (cartMode === 'open') return
  execFileSync(resolve(ROOT, 'build.sh'), ['--open'], { stdio: 'pipe' })
  cartMode = 'open'
}

// The campaign gate needs the cart a PLAYER gets. Repacking between gates
// is cheap (a couple of seconds) and far cheaper than a gate that tests
// the wrong build -- which is what the marker caused the first time, with
// the campaign gate loading the 13-node ring map and reporting the
// authored garden as missing.
function ensurePlayCart () {
  if (cartMode === 'play') return
  execFileSync(resolve(ROOT, 'build.sh'), [], { stdio: 'pipe' })
  cartMode = 'play'
}

async function step (frames) {
  return tool('frame', { op: 'step', frames })
}

// Drain the cart log. romdev clears the ring on read, so a gate that wants
// everything must drain once at the end rather than polling.
async function events () {
  const r = await tool('wasm', { op: 'events' })
  return (r.log || []).map(l => l.text)
}

// Parse the probe's @m metric lines into objects.
function metrics (lines) {
  const out = []
  for (const l of lines) {
    const i = l.indexOf('@m ')
    if (i < 0) continue
    try { out.push(JSON.parse(l.slice(i + 3))) } catch { /* partial line */ }
  }
  return out
}

function shot (name) {
  mkdirSync(SHOTS, { recursive: true })
  return resolve(SHOTS, `${name}.png`)
}

async function screenshot (name) {
  const p = shot(name)
  await tool('frame', { op: 'screenshot', path: p })
  return p
}

// ── gates ──────────────────────────────────────────────────────────────
const gates = {}

// The pure-sim unit suite, run inside the engine (there is no host Lua on
// this box, and a cart is tested through romdev by project rule).
gates.simtest = async () => {
  const testCart = resolve(ROOT, 'formix.wasc')
  if (!existsSync(resolve(ROOT, 'app', 'testmode'))) {
    console.log('  SKIP simtest (app/testmode not present; build a test cart)')
    return
  }
  await load({ deterministicSeed: 1 })
  await step(4)
  const lines = await events()
  const done = lines.find(l => l.startsWith('SIMTEST DONE'))
  ok('simtest.ran', !!done, 'no SIMTEST DONE line')
  if (done) {
    // "SIMTEST DONE <pass> <fail>" -- three leading words, so the counts are
    // fields 3 and 4. (Destructuring from index 1 read "DONE" as the count
    // and reported a nonsense "DONE pass, 71 fail".)
    const parts = done.trim().split(/\s+/)
    const p = Number(parts[2]), f = Number(parts[3])
    ok('simtest.all_pass', f === 0, `${p} pass, ${f} fail`)
    // Print the size of the suite as well as its verdict: a suite that
    // silently shrank (a section that stopped being called) still reports
    // "0 fail", and that reads exactly like health.
    console.log(`    ${p} sim assertions`)
    for (const l of lines.filter(x => x.startsWith('SIMTEST FAIL'))) {
      console.log('    ' + l)
    }
  }
}

// The cart is a valid wasmcart and matches its manifest.
gates.conformance = async () => {
  await load()
  const r = await tool('wasm', { op: 'conformance' })
  ok('conformance.clean', r.conforms === true, JSON.stringify(r.issues || []))
  // The payload nests the running instance's WCInfo under `info` and the
  // pack manifest under `manifest`. Both must agree: a cart whose conf.lua
  // and manifest disagree renders at one size into a window sized for
  // another, which is the bug that shipped in this family before.
  const r2 = await tool('wasm', { op: 'info' })
  const info = r2.info || {}
  const man = r2.manifest || {}
  ok('conformance.instance_resolution',
     info.width === 1920 && info.height === 1080,
     `${info.width}x${info.height}`)
  ok('conformance.manifest_matches_instance',
     man.width === info.width && man.height === info.height,
     `manifest ${man.width}x${man.height} vs instance ${info.width}x${info.height}`)
  // The pointer ABI must be live or every touch gesture is silently dead.
  ok('conformance.pointer_declared', info.wantsPointer === true,
     `wantsPointer=${info.wantsPointer}`)
  ok('conformance.deterministic_declared', info.hasDeterministic === true,
     `hasDeterministic=${info.hasDeterministic}`)
}

// Same seed twice = identical everything. Plus a control that must diverge.
gates.determinism = async () => {
  const runOnce = async (seed) => {
    await load({ deterministicSeed: seed })
    await step(600)
    const m = metrics(await events())
    return m[m.length - 1]
  }
  const a = await runOnce(4242)
  const b = await runOnce(4242)
  ok('determinism.same_seed_identical',
     JSON.stringify(a) === JSON.stringify(b),
     `${JSON.stringify(a)} vs ${JSON.stringify(b)}`)

  const c = await runOnce(4243)
  ok('determinism.CONTROL_other_seed_differs',
     JSON.stringify(a) !== JSON.stringify(c),
     'different seeds produced identical state')
}

// The frame must have real content reaching BOTH edges. Test EXTENT, never
// colour: every historical present bug passed a "has some green" check.
gates.renderExtent = async () => {
  await load({ deterministicSeed: 7 })
  await step(240)
  const p = await screenshot('render-extent')
  const { width, height, pixels } = await readPng(p)
  ok('render.size', width === 1920 && height === 1080, `${width}x${height}`)

  let minX = width, maxX = -1, minY = height, maxY = -1, nonBg = 0
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4
      const r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
      // "Background" here is near-black; the ground shader is never pure
      // black, so anything with real luminance counts as content.
      if (r + g + b > 24) {
        nonBg++
        if (x < minX) minX = x
        if (x > maxX) maxX = x
        if (y < minY) minY = y
        if (y > maxY) maxY = y
      }
    }
  }
  ok('render.content_exists', nonBg > width * height * 0.5, `${nonBg} px`)
  ok('render.reaches_left', minX === 0, `minX=${minX}`)
  ok('render.reaches_right', maxX === width - 1, `maxX=${maxX}`)
  ok('render.reaches_top', minY === 0, `minY=${minY}`)
  ok('render.reaches_bottom', maxY === height - 1, `maxY=${maxY}`)
}

// Five minutes with ZERO input: the colony must keep moving, keep
// delivering, and keep changing. DESIGN.md's watchability bar, automated.
gates.watchability = async () => {
  await loadOpen()
  // Open a few roads so there is something to watch, using the pad.
  await openSomeRoads()

  const samples = []
  for (let i = 0; i < 10; i++) {
    await step(1800)            // 30s of game time per sample
    const m = metrics(await events())
    if (m.length) samples.push(m[m.length - 1])
    await screenshot(`watch-${String(i).padStart(2, '0')}`)
  }
  ok('watch.samples', samples.length >= 8, `${samples.length} samples`)

  const hashes = new Set(samples.map(s => s.phash))
  ok('watch.ants_keep_moving', hashes.size === samples.length,
     `${hashes.size} distinct position hashes of ${samples.length}`)

  const first = samples[0], last = samples[samples.length - 1]
  ok('watch.food_keeps_arriving', last.deliv > first.deliv,
     `${first.deliv} -> ${last.deliv}`)
  ok('watch.colony_alive', last.ants >= 24, `${last.ants} ants`)
  ok('watch.no_invariant_violation',
     !(samples.some(s => s.ants < 24)), 'colony dropped below the floor')
}

// A long unattended run must not drift: no leak, no runaway population, no
// invariant violation, and the colony still alive at the end. This is the
// gate that catches slow rot -- the kind that never shows up in a 30-second
// look but ruins an evening on the couch.
gates.soak = async () => {
  await loadOpen()
  await openSomeRoads()

  const samples = []
  // 30 minutes of game time, which is two and a half years.
  for (let i = 0; i < 30; i++) {
    await step(3600)
    const m = metrics(await events())
    if (m.length) samples.push(m[m.length - 1])
  }
  ok('soak.ran', samples.length >= 25, `${samples.length} samples`)

  const last = samples[samples.length - 1]
  ok('soak.colony_survives', last.ants >= 24, `${last.ants} ants`)
  ok('soak.reached_year_3', last.year >= 3, `year ${last.year}`)

  // The agent pool must never exceed its cap.
  const maxAnts = Math.max(...samples.map(s => s.ants))
  ok('soak.pool_capped', maxAnts <= 2600, `peak ${maxAnts}`)

  // The invariant must hold at every sample, not just at the end.
  ok('soak.invariant_held', samples.every(s => s.ants >= 24),
     `min ${Math.min(...samples.map(s => s.ants))}`)

  // Food must never go negative and the colony must not flatline at the
  // floor -- a run that survives by sitting on the clamp is not "alive".
  ok('soak.food_non_negative', samples.every(s => s.food >= 0),
     `min ${Math.min(...samples.map(s => s.food))}`)
  const mid = samples.slice(5)
  ok('soak.not_flatlined', mid.some(s => s.ants > 60),
     `peak after settling ${Math.max(...mid.map(s => s.ants))}`)

  // Seasons must keep turning: a stuck calendar would freeze the arc.
  const seasonsSeen = new Set(samples.map(s => s.season))
  ok('soak.all_seasons', seasonsSeen.size === 4, [...seasonsSeen].join(','))

  // And the world must still be MOVING at the end, not merely alive.
  const tailHashes = new Set(samples.slice(-5).map(s => s.phash))
  ok('soak.still_moving', tailHashes.size === 5, `${tailHashes.size} of 5`)
}

// The soundscape must actually be mixing.
//
// NOTE ON METHOD: this asserts on the cart's own @audio report rather than
// on a recorded WAV, because audioDebug({op:'record'}) captures silence for
// EVERY wasmcart cart on this server -- including a shipped, human-verified
// one used as a control. Reported in
// internal-romdev/feedback/2026-08-15_audiodebug-silent-for-wasmcart.md.
// So this gate proves the game's mixing logic is right; it cannot prove a
// sample reaches the speakers, and that half is owed a human listen.
gates.audio = async () => {
  await load({ deterministicSeed: 5 })
  await step(60)
  let lines = await events()
  const init = lines.find(l => l.startsWith('@audio init'))
  ok('audio.initialised', !!init, 'no @audio init line')
  if (init) {
    const beds = Number(init.match(/beds=(\d+)/)?.[1])
    ok('audio.all_four_beds', beds === 4, `beds=${beds}`)
  }
  ok('audio.no_missing_files', !lines.some(l => l.startsWith('@audio MISSING')),
     lines.filter(l => l.startsWith('@audio MISSING')).join('; '))

  // Drive some verbs so one-shots fire, then read the report.
  await openSomeRoads()
  await step(600)
  lines = await events()
  const reports = lines.filter(l => l.startsWith('@audio ') && !l.includes('init'))
  ok('audio.reports', reports.length > 0, 'no @audio state lines')
  const last = reports[reports.length - 1] || ''
  ok('audio.bed_playing', /bed:\w+=[\d.]+P/.test(last), last)
  ok('audio.wind_playing', last.includes('wind=P'), last)
  const shots = Number(last.match(/shots=(\d+)/)?.[1] || 0)
  ok('audio.oneshots_fired', shots > 0, `shots=${shots}`)

  // The bed must FOLLOW the season rather than being stuck on spring.
  await step(60 * 200)          // past the first boundary
  const later = (await events()).filter(l => l.startsWith('@audio bed'))
  const lastLater = later[later.length - 1] || ''
  ok('audio.bed_follows_season', lastLater.includes('summer'),
     lastLater || 'no bed line after the boundary')
}

// THE YEAR IS THE STRUCTURE, so it gets its own gate. Three seeds, a full
// year each, asserting that the arc actually happens: the colony grows into
// summer, contracts through winter, hoards in autumn, and comes back in
// spring. A game whose seasons are only a colour change would pass every
// other gate here.
gates.year = async () => {
  for (const seed of [101, 202, 303]) {
    await load({ deterministicSeed: seed })
    await openSomeRoads()

    const bySeason = {}
    // A year is 4 x 180s = 720s = 43200 frames. Sample every ~15s.
    for (let i = 0; i < 50; i++) {
      await step(900)
      for (const m of metrics(await events())) {
        (bySeason[m.season] ||= []).push(m)
      }
    }

    const seen = Object.keys(bySeason)
    ok(`year.${seed}.all_seasons`, seen.length === 4, seen.join(','))
    if (seen.length !== 4) continue

    const peak = (s) => Math.max(...bySeason[s].map(m => m.ants))
    const foodPeak = (s) => Math.max(...bySeason[s].map(m => m.food))

    // Summer is the high water mark for population; winter is the low.
    ok(`year.${seed}.summer_peak_beats_winter`,
       peak('summer') > peak('winter'),
       `summer ${peak('summer')} vs winter ${peak('winter')}`)

    // Autumn is when the pantry is fullest -- that is what hoarding means,
    // and it is what winter then spends.
    ok(`year.${seed}.autumn_hoards`,
       foodPeak('autumn') >= foodPeak('spring'),
       `autumn ${foodPeak('autumn').toFixed(0)} vs spring ${foodPeak('spring').toFixed(0)}`)

    // Winter DRAWS DOWN the stores rather than merely being cold.
    const w = bySeason.winter
    ok(`year.${seed}.winter_spends`, w[w.length - 1].food < w[0].food,
       `${w[0].food.toFixed(0)} -> ${w[w.length - 1].food.toFixed(0)}`)

    // And the colony survives all of it. No fail state, ever.
    const all = Object.values(bySeason).flat()
    // The floor is agents.minColony (4), not the 24 this gate was written
    // against -- it came down with the smaller 4X start, because a floor
    // ABOVE the starting hand locks the send verb rather than protecting
    // anything. Asserting the old literal failed on a perfectly healthy
    // colony that merely started at 16.
    ok(`year.${seed}.never_wiped`, all.every(m => m.ants >= 4),
       `min ${Math.min(...all.map(m => m.ants))}`)

    // Threats must actually have happened, or "survives the year" is
    // meaningless -- a year with no weather is not a test of anything.
    const last = all[all.length - 1]
    ok(`year.${seed}.weather_happened`,
       all.some(m => m.rain > 0) || all.some(m => m.spiders > 0),
       'no rain and no spiders in a whole year')
  }
}

// Perf, measured in a REAL window: the cart cannot time itself (love.timer
// is the deterministic counter), so fps comes from the host.
gates.perf = async () => {
  const st = await tool('playtest', { op: 'status' })
  if (st.open && st.humanInputActive) {
    console.log('  SKIP perf (a human is playing; not stealing the window)')
    return
  }
  // OPEN THE WINDOW FIRST, then let IT do the stepping.
  //
  // Bulk-stepping with frame({op:'step'}) before opening leaves the window
  // stuck: it reports running:true, advances ~2 frames and then sits at
  // fps 0 forever. Measured cleanly -- 600 pre-stepped frames still ran at
  // 60fps, 900+ never started -- and opening first is a rock-steady 60fps
  // with stepMs ~1.8 through thousands of frames. Reported in
  // internal-romdev/feedback/2026-08-15_playtest-stalls-after-bulk-step.md.
  //
  // Letting the window run the time is also the more honest measurement:
  // this gate is about what the human's window actually does.
  await load({ deterministicSeed: 5, presentWindow: true })
  await tool('playtest', { op: 'open', title: 'antgame perf', scale: 1 })
  await openSomeRoads()

  // WAIT FOR THE WINDOW TO SPIN UP. Measured on this cart: `running` goes
  // true immediately, but windowFrameCount does not move and fps reads 0
  // for ~8 seconds while the GL context is created and the shaders (ground,
  // bright-pass, two blurs, composite) compile. A gate that samples once at
  // 6s reports a false 0fps about a window that is about to sit at a clean
  // 60. Poll until fps is real, then measure.
  let s = {}
  let perf = {}
  for (let i = 0; i < 12; i++) {
    await new Promise(r => setTimeout(r, 2000))
    s = await tool('playtest', { op: 'status' })
    perf = s.perf || {}
    if (perf.fps) break
  }
  console.log('    perf:', JSON.stringify(perf))

  // The status field is `running`, not `open`.
  ok('perf.window_running', s.running === true, JSON.stringify(s).slice(0, 220))
  ok('perf.window_advancing', (s.windowFrameCount || 0) > 60,
     `windowFrameCount=${s.windowFrameCount}`)
  if (perf.fps) {
    ok('perf.60fps', perf.fps >= 57, `fps=${perf.fps}`)
  } else {
    // No fps sample is not a pass. Fall back to the frame counter, which
    // cannot be faked: two reads a known wall-time apart.
    const before = s.windowFrameCount || 0
    await new Promise(r => setTimeout(r, 3000))
    const s2 = await tool('playtest', { op: 'status' })
    const advanced = (s2.windowFrameCount || 0) - before
    ok('perf.60fps', advanced >= 165,
       `${advanced} frames in ~3s (want >=165, i.e. ~55fps)`)
  }
  ok('perf.step_budget', (perf.stepMs ?? 99) <= 8, `stepMs=${perf.stepMs}`)
  ok('perf.present_budget', (perf.presentMs ?? 99) <= 4,
     `presentMs=${perf.presentMs}`)
  await tool('playtest', { op: 'stop' })
}

// Both devices must produce the same outcome from the same session.
gates.inputParity = async () => {
  // Pad: cursor flick + A + A links nest->node.
  await loadOpen()
  await step(30)
  const padIntents = await drivePad()

  await loadOpen()
  await step(30)
  const ptrIntents = await drivePointer()

  ok('parity.pad_produced_intents', padIntents.length > 0,
     `${padIntents.length}`)
  ok('parity.pointer_produced_intents', ptrIntents.length > 0,
     `${ptrIntents.length}`)
  // Compare the KINDS and success flags, not the node ids (the two drivers
  // reach different nodes; what must match is that the same verbs are
  // expressible and are accepted).
  const kinds = xs => xs.map(x => x.split(' ')[1] + ':' + x.split(' ')[2]).join(',')
  ok('parity.same_verbs', kinds(padIntents) === kinds(ptrIntents),
     `${kinds(padIntents)} vs ${kinds(ptrIntents)}`)
}

// Multi-touch: slots 1 and 2 must both be seen. The #1 portability trap is
// a cart that polls only slot 0 -- perfect on a desktop, dead on a phone.
gates.multitouch = async () => {
  await load({ deterministicSeed: 3 })
  await step(30)
  // Turn the overlay on so the slots are visible in the screenshot too.
  await tool('input', { op: 'press', button: 'select', frames: 2 })
  await step(4)
  const pts = [[500, 500], [760, 500], [1020, 500]]
  for (const id of [0, 1, 2]) {
    await tool('input', { op: 'pointer', id, x: pts[id][0], y: pts[id][1], left: true })
  }
  await step(8)
  const p = await screenshot('multitouch')
  const lines = await events()
  // A release still needs coordinates -- the tool requires x/y on every
  // pointer call, active:false included.
  for (const id of [1, 2]) {
    await tool('input', { op: 'pointer', id, x: pts[id][0], y: pts[id][1], active: false })
  }
  // Assert on the CART's own report of which slots it polled, not on the
  // host echo -- the whole point of this gate is the trap where a cart
  // reads only slot 0 and is therefore dead on a phone while looking
  // perfect on a desktop. The probe emits one @slots line per frame while
  // the overlay is on.
  const slotLines = lines.filter(l => l.startsWith('@slots '))
  ok('multitouch.cart_reported_slots', slotLines.length > 0,
     'no @slots line; is the overlay on?')
  const seen = new Set()
  for (const l of slotLines) {
    for (const m of l.matchAll(/\b(\d)\+/g)) seen.add(Number(m[1]))
  }
  ok('multitouch.slot0_seen', seen.has(0), [...seen].join(','))
  ok('multitouch.slot1_seen', seen.has(1),
     `slots seen: ${[...seen].join(',') || 'none'} -- a cart that only reads slot 0 is dead on a phone`)
  ok('multitouch.slot2_seen', seen.has(2), [...seen].join(','))
  ok('multitouch.screenshot', existsSync(p), p)
}

// The pretty path must actually be live. fx.lua degrades gracefully to a
// plain render when float canvases are unavailable, which is correct -- the
// game must never REFUSE to run because it cannot be pretty -- but a silent
// degradation on a machine that CAN do it would mean shipping the flat look
// and never noticing. So the cart announces which path it took, and this
// gate reads that rather than guessing from pixels.
gates.hdr = async () => {
  await load({ deterministicSeed: 12 })
  await step(120)
  const lines = await events()
  const enabled = lines.find(l => l.startsWith('@fx ENABLED'))
  const disabled = lines.find(l => l.startsWith('@fx DISABLED'))
  ok('hdr.chain_enabled', !!enabled && !disabled,
     disabled || 'no @fx line at all')
  if (enabled) {
    // The bloom targets must be a real fraction of the screen, not 1x1 --
    // the classic "sized from a pre-init info struct" failure.
    const m = enabled.match(/(\d+)x(\d+) bloom (\d+)x(\d+)/)
    ok('hdr.scene_full_res', m && Number(m[1]) === 1920 && Number(m[2]) === 1080,
       enabled)
    ok('hdr.bloom_quarter_res', m && Number(m[3]) === 480 && Number(m[4]) === 270,
       enabled)
  }
  ok('hdr.no_shader_errors',
     !lines.some(l => l.toLowerCase().includes('shader') && l.toLowerCase().includes('fail')),
     lines.filter(l => l.toLowerCase().includes('fail')).join('; '))
}

// Every verb must be reachable from BOTH devices. The parity gate proves
// pad and touch produce the same verbs for linking; this one walks the rest
// of the vocabulary, because a verb that is only reachable on one device is
// a verb the phone player does not have.
gates.verbs = async () => {
  await loadOpen()
  await step(30)
  const pos = await nodeScreenPositions()
  const ids = Object.keys(pos)
  const nest = pos[ids[0]]
  // Targets come from what the cart says a node IS, not from map order.
  // `other` has to be somewhere a send can legally go (colonisable and
  // unowned) or the touch arm reports link:ok=false against the pad's
  // ok=true, and parity looks broken when the two arms were simply aiming
  // at different kinds of place. A DISCOVERED node, too -- an undiscovered
  // one is off the frontier and its screen position is meaningless.
  const own = await ownership()
  const settleables = ids.slice(1).filter(id => own.nodes[id]?.colonisable &&
                                                own.nodes[id]?.owner === null &&
                                                own.nodes[id]?.discovered)
  const other = pos[settleables[0]] || pos[ids[1]]
  // A SECOND target for the send, because this arm marks `other` as
  // dangerous first and ants avoid a marked node -- testing the two verbs
  // against the same node makes the second one measure the first.
  const sendTo = pos[settleables[1]] || other
  // Read the widget's rect NOW, before any verb is driven: uiState()
  // drains the event ring, so asking for it later would discard the
  // intents this arm is about to assert on.
  const bars = (await uiState()).caste

  // TOUCH: long press = danger mark.
  await tool('input', { op: 'pointer', id: 1, x: other.x, y: other.y, left: true })
  await step(50)                                    // past HOLD_FRAMES (36)
  await tool('input', { op: 'pointer', id: 1, x: other.x, y: other.y, active: false })
  await step(6)

  // TOUCH: the caste widget. Its rectangles come FROM THE CART now -- the
  // comment claimed they did while the numbers below it were hardcoded,
  // so the tap survived only as long as the widget never moved.
  const bar = bars?.[0]
  ok('verbs.caste_widget_reported', !!bar, JSON.stringify(bar))
  if (bar) {
    const tx = Math.round(bar.x + bar.w / 2)
    const ty = Math.round(bar.y + bar.h * 0.2)
    await tool('input', { op: 'pointer', id: 0, x: tx, y: ty, left: true })
    await step(6)
    await tool('input', { op: 'pointer', id: 0, x: tx, y: ty, active: false })
    await step(6)
  }

  // TOUCH: the PRIMARY verb -- drag from the nest to a neighbour sends a
  // squad. Coordinates come from the cart's own @node report, never
  // guessed: a hardcoded target that lands on grass reports "the pointer
  // does nothing", which is a false negative about the game.
  //
  // A FRESH SLOT. Slot 0 has just been tapped on the caste widget, and
  // that press set `onWidget` on it; re-using it here made the drag land
  // in a slot the cart was still treating as a widget interaction, so the
  // send never fired. Slot 2 has touched nothing.
  // RE-READ THE POSITIONS. The camera follows the cursor, and the pad
  // half of this gate has not run yet -- but the caste tap and the long
  // press can both move it, and a drag that starts on stale coordinates
  // lands on grass, sets no startNode, and silently produces nothing at
  // all. (Two rounds were spent on the hold timer before the coordinates
  // turned out to be the problem.)
  // Keep what has fired so far: nodeScreenPositions() drains the ring
  // like every other read, so calling it here without banking the
  // earlier verbs discards them -- which turned a 1-assertion failure
  // into a 5-assertion one.
  const banked = (await events()).filter(l => l.startsWith('@i '))
  const pos2 = await nodeScreenPositions()
  const nest2 = pos2[ids[0]] || nest
  const sendTo2 = pos2[settleables[1]] || pos2[settleables[0]] || sendTo
  await tool('input', { op: 'pointer', id: 2, x: nest2.x, y: nest2.y, left: true })
  await step(8)
  await tool('input', { op: 'pointer', id: 2,
                        x: Math.round((nest2.x + sendTo2.x) / 2),
                        y: Math.round((nest2.y + sendTo2.y) / 2), left: true })
  await step(8)
  await tool('input', { op: 'pointer', id: 2, x: sendTo2.x, y: sendTo2.y, left: true })
  await step(8)
  await tool('input', { op: 'pointer', id: 2, x: sendTo2.x, y: sendTo2.y, active: false })
  await step(12)

  // Drained ONCE, at the end of the touch arm. Any events() call in the
  // middle -- ownership(), uiState(), a peek -- empties the ring and
  // takes the earlier verbs with it, which is how this arm reported only
  // `caste` while danger and link had both fired correctly.
  const touchLines = banked.concat(
    (await events()).filter(l => l.startsWith('@i ')))
  const touchVerbs = new Set(touchLines.map(l => l.split(' ')[1]))
  ok('verbs.touch_danger', touchVerbs.has('danger'), [...touchVerbs].join(','))
  ok('verbs.touch_caste', touchVerbs.has('caste'), [...touchVerbs].join(','))

  // PAD: X = danger, shoulder+direction = caste, Y after a selection =
  // abandon.
  await loadOpen()
  await step(30)
  await tool('input', { op: 'press', button: 'right', frames: 3 })
  await step(6)
  await tool('input', { op: 'press', button: 'x', frames: 2 })
  await step(6)
  // Caste: hold a shoulder and press a direction.
  await tool('input', { op: 'set', ports: [{ l: true }] })
  await step(4)
  await tool('input', { op: 'set', ports: [{ l: true, up: true }] })
  await step(6)
  await tool('input', { op: 'set', ports: [{}] })
  await step(6)
  // Abandon: select, move, Y.
  await tool('input', { op: 'press', button: 'a', frames: 2 })
  await step(6)
  await tool('input', { op: 'press', button: 'down', frames: 3 })
  await step(6)
  await tool('input', { op: 'press', button: 'y', frames: 2 })
  await step(10)

  // PAD: the primary verb. The cursor starts on the nest, so this is the
  // opening gesture exactly as a player performs it.
  await tool('input', { op: 'press', button: 'a', frames: 2 })
  await step(6)
  await tool('input', { op: 'press', button: 'right', frames: 3 })
  await step(8)
  await tool('input', { op: 'press', button: 'a', frames: 2 })
  await step(10)

  const padLines = (await events()).filter(l => l.startsWith('@i '))
  const padVerbs = new Set(padLines.map(l => l.split(' ')[1]))
  ok('verbs.pad_danger', padVerbs.has('danger'), [...padVerbs].join(','))
  ok('verbs.pad_caste', padVerbs.has('caste'), [...padVerbs].join(','))
  ok('verbs.pad_abandon', padVerbs.has('abandon'), [...padVerbs].join(','))

  // THE PRIMARY VERB BELONGS IN THE PARITY CHECK. This gate tested
  // danger, caste and abandon and omitted the one the game is about --
  // which is how a whole rebuild of `link` (from "paint a scent line" to
  // "send a squad") went through without parity ever being asserted on
  // it. Send is the verb; if it works on only one device the dual-input
  // pillar is gone.
  for (const v of ['link', 'danger', 'caste']) {
    ok(`verbs.${v}_on_both`, touchVerbs.has(v) && padVerbs.has(v),
       `touch:${touchVerbs.has(v)} pad:${padVerbs.has(v)}`)
  }
}

// Saving must work through the REAL host, which is a different claim from
// "the serializer round-trips" (the sim suite proves that). This gate
// exercises the actual blob: write it at a season boundary, read it back
// out of the host, and confirm it is the colony we left.
gates.save = async () => {
  await loadOpen()
  await openSomeRoads()
  // A season is 180s of game time; run past one boundary so autosave fires.
  await step(60 * 190)
  const lines = await events()
  const wrote = lines.filter(l => l.startsWith('@save wrote'))
  ok('save.autosaved_at_season', wrote.length > 0,
     'no @save line after a season boundary')
  if (wrote.length) {
    const bytes = Number(wrote[wrote.length - 1].match(/(\d+) bytes/)?.[1])
    ok('save.fits_blob', bytes > 0 && bytes <= 4096, `${bytes} bytes`)
  }
  ok('save.no_failures', !lines.some(l => l.startsWith('@save FAILED')),
     lines.filter(l => l.startsWith('@save FAILED')).join('; '))

  // SETTINGS AND LEARNING ride in the same blob. The ROUND-TRIP is proven
  // in the sim suite (save.settings_restored / save.learning_restored),
  // NOT here, and deliberately so: romdev reloads a cart with an EMPTY
  // save blob, so a "change it, reload, read it back" assertion at this
  // level tests the harness rather than the game and fails for a reason
  // that has nothing to do with the save. What a gate CAN prove is that a
  // setting changed through the real UI reaches the real serializer, so
  // that is what it proves: change one, force a write, and require the
  // blob to still be written and still fit.
  await tool('input', { op: 'press', button: 'start', frames: 2 })
  await step(6)
  await tool('input', { op: 'press', button: 'left', frames: 2 })  // Sound down
  await step(4)
  const changed = await uiState()
  await tool('input', { op: 'press', button: 'b', frames: 2 })
  await step(6)
  ok('save.setting_took_effect', Number(changed.volume) < 3,
     `volume=${changed.volume}`)

  const before = (await events()).filter(l => l.startsWith('@save wrote')).length
  await step(60 * 190)                       // past the next season boundary
  const wrote2 = (await events()).filter(l => l.startsWith('@save wrote'))
  ok('save.writes_after_settings_change', wrote2.length > before,
     `${before} -> ${wrote2.length}`)
  if (wrote2.length) {
    const bytes = Number(wrote2[wrote2.length - 1].match(/(\d+) bytes/)?.[1])
    ok('save.still_fits_with_settings', bytes > 0 && bytes <= 4096, `${bytes} bytes`)
  }

  // The host's own view of the blob.
  const blob = await tool('wasm', { op: 'save' })
  const declared = blob.saveSize ?? blob.size
  ok('save.host_sees_blob', declared === undefined || declared > 0,
     JSON.stringify(blob).slice(0, 200))
}

// No text may be drawn with the engine's built-in bitfont -- a blocky 8x8
// debug face. This is a SOURCE gate rather than a pixel one: a screenshot
// check would have to OCR, while the rule itself is mechanical ("every
// print is preceded by a setFont from ui.fonts, somewhere in that file").
// M7. The game must teach by attraction and then STOP teaching, and the
// menu must be reachable and effective from both devices. Every claim here
// is asked of the cart (@ui / @learn lines) rather than read off a
// screenshot, because "is a hint currently on screen" is not a pixel fact
// without OCR.
//
// A helper rather than nodeScreenPositions(): this needs the UI report, and
// it must NOT leave the overlay up, since the overlay changes what START
// means and half this gate is about pressing START.
async function uiState () {
  // The report is emitted from probe.draw on the frame AFTER the overlay
  // comes on, so the read has to allow for the press, the toggle and the
  // draw. Four frames sometimes missed it: the line then arrived after
  // the closing SELECT, which left the overlay ON with nothing captured
  // -- and an overlay left on blocks START from opening the menu, so the
  // NEXT assertion failed instead of this one. Slow reads are cheap;
  // mysterious state is not.
  await tool('input', { op: 'press', button: 'select', frames: 2 })
  await step(12)
  const lines = await events()
  await tool('input', { op: 'press', button: 'select', frames: 2 })
  await step(6)
  const ui = lines.filter(l => l.startsWith('@ui ')).pop()
  const learn = lines.filter(l => l.startsWith('@learn ')).pop()
  const pause = lines.filter(l => l.startsWith('@pause ')).pop()
  const caste = lines.filter(l => l.startsWith('@caste '))
    .map(l => l.split(' ').slice(1).map(Number))
    .map(([i, x, y, w, h]) => ({ i, x, y, w, h }))
  if (!ui) throw new Error('cart reported no @ui line')
  const kv = (s) => Object.fromEntries(
    s.split(' ').slice(1).map(p => p.split('=')))
  const out = { ...kv(ui), ...(learn ? kv(learn) : {}) }
  if (caste.length) out.caste = caste
  // The pause button's real rect, so the touch path taps what is actually
  // drawn rather than a corner the layout may have moved on from.
  if (pause) {
    const [x, y, w, h] = pause.split(' ').slice(1).map(Number)
    out.pause = { x, y, w, h, cx: Math.round(x + w / 2), cy: Math.round(y + h / 2) }
  }
  return out
}

// ── the 4X loop ────────────────────────────────────────────────────────
//
// THE TEST THAT WOULD HAVE CAUGHT THE REAL BUG. The first build passed 69
// assertions while being the wrong game entirely, because every gate
// tested rendering and plumbing rather than the loop. Per DEVPLAN2, the
// question for any gate here is "would this fail if the game stopped
// being a 4X?" -- so each assertion below is about ants MOVING on an
// order, ground CHANGING HANDS, the frontier GROWING, or production
// COMPOUNDING.

// Ownership/garrison/siege straight from the cart, keyed by node id.
async function ownership () {
  await tool('input', { op: 'press', button: 'select', frames: 2 })
  await step(8)
  const lines = await events()
  await tool('input', { op: 'press', button: 'select', frames: 2 })
  await step(4)
  const out = {}
  for (const l of lines) {
    const m = l.match(
      /^@own (\S+) (\S+) g=(\d+) siege=(\d+)\/(\d+) col=(\S+) disc=(\S+)$/)
    if (m) {
      out[m[1]] = { owner: m[2] === 'nil' ? null : m[2], garrison: +m[3],
                    siege: +m[4], takeCost: +m[5],
                    colonisable: m[6] === 'true', discovered: m[7] === 'true' }
    }
  }
  const mis = lines.filter(l => l.startsWith('@mission ')).pop()
  const mm = mis && mis.match(/n=(\d+) atNode=(\d+) onEdge=(\d+)/)
  return { nodes: out, missions: mm ? +mm[1] : 0 }
}

const ownedIds = (o) =>
  Object.entries(o.nodes).filter(([, v]) => v.owner === 'you').map(([k]) => k)

gates.fourx = async () => {
  await loadOpen()
  await step(90)

  const t0 = await ownership()
  const mine0 = ownedIds(t0)
  ok('fourx.starts_with_the_nest', mine0.length === 1, mine0.join(','))

  // EXPLORE: the frontier is a frontier, not the whole map.
  const seen0 = Object.values(t0.nodes).filter(n => n.discovered).length
  const all = Object.keys(t0.nodes).length
  ok('fourx.map_starts_hidden', seen0 < all,
     `${seen0} of ${all} visible at start`)

  // The cursor starts on the nest, so the opening gesture is A, direction,
  // A -- pick up at home, send outward.
  await tool('input', { op: 'press', button: 'a', frames: 2 })
  await step(6)
  await tool('input', { op: 'press', button: 'down', frames: 3 })
  await step(8)
  await tool('input', { op: 'press', button: 'a', frames: 2 })
  await step(10)
  const sendLine = (await events()).filter(l => l.startsWith('@i link')).pop()
  ok('fourx.send_accepted', /ok=true/.test(sendLine || ''), sendLine)

  // EXPAND, part one: ants are actually IN TRANSIT on the player's order.
  // This is the assertion the old build could never have passed -- nothing
  // ever moved because the player asked it to.
  await step(20)
  const inFlight = await ownership()
  ok('fourx.ants_are_travelling', inFlight.missions > 0,
     `${inFlight.missions} ants under orders`)

  // EXPAND, part two: they arrive, and ground changes hands.
  //
  // KEEP PRESSING. One send delivers half a node's population, and a
  // target worth having costs more than that -- so a single wave then
  // waiting is not how the game is played, and a gate that does it
  // measures nothing but the tuning of one number. The source stays
  // selected after a send precisely so a second wave is one press.
  let took = null
  for (let i = 0; i < 8 && !took; i++) {
    await tool('input', { op: 'press', button: 'a', frames: 2 })
    await step(6)
    await step(60 * 20)
    const o = await ownership()
    const mine = ownedIds(o)
    if (mine.length > mine0.length) took = { o, mine }
  }
  ok('fourx.a_node_changed_hands', !!took,
     took ? took.mine.join(',') : 'still only the nest after ~160s')

  if (took) {
    // EXPLORE, earned: taking ground reveals what borders it.
    const seen1 = Object.values(took.o.nodes).filter(n => n.discovered).length
    ok('fourx.taking_ground_opens_the_frontier', seen1 > seen0,
       `${seen0} -> ${seen1} visible`)

    // EXPLOIT: the new node is a base, not a trophy -- it holds ants.
    const fresh = took.mine.find(id => !mine0.includes(id))
    ok('fourx.taken_node_is_garrisoned',
       took.o.nodes[fresh].garrison > 0,
       `${fresh} g=${took.o.nodes[fresh].garrison}`)
  }

  // CONTROL: a resource node must REFUSE to be settled. Without this the
  // colonisable/resource split could quietly stop existing and every
  // assertion above would still pass -- the map would just be uniform.
  const o2 = await ownership()
  const foodNode = Object.entries(o2.nodes)
    .find(([, v]) => !v.colonisable && v.discovered)
  ok('fourx.CONTROL_resource_nodes_exist', !!foodNode,
     'no discovered resource-only node to test')
  if (foodNode) {
    ok('fourx.CONTROL_resource_never_owned', o2.nodes[foodNode[0]].owner === null,
       `${foodNode[0]} owner=${o2.nodes[foodNode[0]].owner}`)
  }
}

// EXPLOIT, on its own: holding more ground must RAISE THE CEILING.
//
// The first version of this gate compared an early growth rate against a
// late one and failed on any healthy curve: a colony below its limit grows
// fast, a colony at its limit grows ~0, and saturation is exactly what a
// terrarium is supposed to do. Rate-vs-rate cannot tell "expansion does
// nothing" apart from "this colony has arrived".
//
// What compounding actually means here is that the SUSTAINABLE SIZE goes
// up when you take ground -- so the honest test runs two colonies from the
// same seed for the same time, expands one and not the other, and compares
// where each settles.
gates.engine = async () => {
  const m = (lines) => {
    const l = lines.filter(x => x.startsWith('@m ')).pop()
    return l ? JSON.parse(l.slice(3)) : null
  }

  // CONTROL ARM: never expand. Sits on the nest and settles wherever one
  // node can support it. Without this arm a rising number proves nothing --
  // the colony grows from 16 whatever you do.
  await loadOpen()
  await step(90)
  await step(60 * 260)
  const idle = m(await events())
  const idleOwned = ownedIds(await ownership()).length
  ok('engine.control_never_expanded', idleOwned === 1, `${idleOwned} nodes`)
  ok('engine.grows_from_the_nest_alone', idle && idle.ants > 16,
     idle ? `${idle.ants} ants` : 'no metrics')

  // TEST ARM: same seed, same clock, but take ground. Concentrate on ONE
  // target -- scattering single waves spends the same ants and takes
  // nothing, which is a real lesson about the game and is what made an
  // earlier version of this gate measure a colony that never expanded.
  await loadOpen()
  await step(90)
  await tool('input', { op: 'press', button: 'a', frames: 2 })
  await step(6)
  await tool('input', { op: 'press', button: 'down', frames: 3 })
  await step(8)
  for (let i = 0; i < 8; i++) {
    await tool('input', { op: 'press', button: 'a', frames: 2 })
    await step(60 * 20)
  }
  // Same total elapsed time as the control arm, so the only difference
  // between the two numbers is the ground held.
  await step(60 * 100)
  const grown = m(await events())
  const grownOwned = ownedIds(await ownership()).length

  ok('engine.more_ground_was_taken', grownOwned > idleOwned,
     `${idleOwned} -> ${grownOwned} nodes`)
  ok('engine.ground_raises_the_ceiling', grown.ants > idle.ants * 1.05,
     `${idle.ants} ants on ${idleOwned} node(s) vs ` +
     `${grown.ants} on ${grownOwned}`)
}

// N3: the SIZE of a send is a decision, and it is available on both
// devices. A modifier that exists only on a pad breaks the input-parity
// pillar; one that changes nothing measurable is decoration.
gates.commitment = async () => {
  // How many ants leave home in one gesture, measured as the drop in the
  // nest's garrison. Reading the garrison rather than the mission count
  // avoids racing the arrivals.
  const sendAndMeasure = async (holdShoulder) => {
    await loadOpen()
    await step(120)
    const before = (await ownership()).nodes
    const nest = Object.entries(before).find(([, v]) => v.owner === 'you')[0]
    const g0 = before[nest].garrison

    await tool('input', { op: 'press', button: 'a', frames: 2 })
    await step(6)
    await tool('input', { op: 'press', button: 'down', frames: 3 })
    await step(8)
    if (holdShoulder) {
      // Hold the shoulder ACROSS the A press: it is a modifier, not a
      // chord to be tapped first.
      await tool('input', { op: 'set', ports: [{ l: true }] })
      await step(4)
      await tool('input', { op: 'set', ports: [{ l: true, a: true }] })
      await step(4)
      await tool('input', { op: 'set', ports: [{ l: true }] })
      await step(4)
      await tool('input', { op: 'set', ports: [{}] })
    } else {
      await tool('input', { op: 'press', button: 'a', frames: 2 })
    }
    await step(8)
    const after = (await ownership()).nodes
    return { sent: g0 - after[nest].garrison, g0 }
  }

  const half = await sendAndMeasure(false)
  const all = await sendAndMeasure(true)

  ok('commitment.half_sends_something', half.sent > 0,
     `${half.sent} of ${half.g0}`)
  ok('commitment.shoulder_sends_more', all.sent > half.sent,
     `half=${half.sent} all=${all.sent} of ${all.g0}`)
  // The floor still holds: an all-in from the nest may not empty it.
  ok('commitment.CONTROL_floor_survives_all_in', all.sent < all.g0,
     `sent ${all.sent} of ${all.g0} -- the nest was emptied`)
}

// N4: pressure, and it must be ANSWERABLE. A threat you can only wait out
// is weather wearing an animal's shape; the point of wildlife is that each
// kind poses a different problem the existing verbs can solve.
gates.wildlife = async () => {
  await loadOpen()
  await step(120)

  // The opening stays quiet. A predator arriving while the player is still
  // working out what a node is teaches nothing -- it is noise.
  const early = metrics(await events()).pop()
  ok('wildlife.opening_is_quiet', early && early.spiders === 0,
     `spiders=${early && early.spiders} at t=${early && early.t}`)

  // Run long enough for the garden to get dangerous, sampling as we go so
  // a creature that comes and goes between checks is still seen.
  // NOTE: events() DRAINS the ring, so every sample has to be kept as it
  // is read. A second read at the end returns nothing, which is how the
  // first version of this gate reported "undefined ants left" and looked
  // like a dead colony rather than an empty buffer.
  let sawSpider = false, sawBeetle = false, killed = 0, peak = 0
  let last = null
  const violations = []
  for (let i = 0; i < 14; i++) {
    await step(60 * 45)
    const lines = await events()
    for (const l of lines) if (l.includes('@INVARIANT')) violations.push(l)
    for (const m of metrics(lines)) {
      if (m.spiders > 0) sawSpider = true
      if (m.beetles > 0) sawBeetle = true
      if (m.killed > killed) killed = m.killed
      if (m.ants > peak) peak = m.ants
      last = m
    }
  }

  ok('wildlife.spiders_arrive', sawSpider, 'no spider in ~10 minutes')
  ok('wildlife.beetles_arrive', sawBeetle, 'no beetle in ~10 minutes')
  // THE ONE THAT MATTERS: something died. Without this the whole
  // Exterminate axis is decoration -- creatures would simply expire on
  // their timers and the player would have no verb against them.
  ok('wildlife.threats_can_be_killed', killed > 0,
     `${killed} killed -- creatures only ever timed out`)

  // Displacement, not destruction: the colony is pushed around, never
  // wiped. This is the pillar the whole design rests on.
  ok('wildlife.colony_survives_pressure', last && last.ants >= 4,
     `${last && last.ants} ants left (peak ${peak})`)
  ok('wildlife.no_invariant_violation', violations.length === 0,
     violations.slice(0, 2).join(' | '))
}

// N7: the campaign is the onboarding, so it has to actually be what a new
// player lands in -- and each garden has to be the shape its lesson needs.
// This is a SOURCE gate as well as a live one: the levels are authored
// data, and the cheapest way to catch "the spider level has no spider" is
// to read the table.
gates.campaign = async () => {
  const src = readFileSync(resolve(ROOT, 'app', 'sim', 'campaign.lua'), 'utf8')

  // Every level names itself and says what it is for, because the HUD
  // shows both and a nameless garden teaches nothing.
  const ids = [...src.matchAll(/id = "([a-z-]+)"/g)].map(m => m[1])
  ok('campaign.has_levels', ids.length >= 4, ids.join(','))
  const blurbs = [...src.matchAll(/blurb = "/g)].length
  ok('campaign.every_level_has_a_lesson', blurbs === ids.length,
     `${blurbs} blurbs for ${ids.length} levels`)

  // The first garden must be trivially small: one target and nothing else
  // competing for attention is the entire point of a first level.
  const first = src.slice(src.indexOf('id = "first-ground"'),
                          src.indexOf('id = "reach"'))
  const firstNodes = [...first.matchAll(/\{ kind =/g)].length
  ok('campaign.first_garden_is_small', firstNodes <= 3,
     `${firstNodes} nodes in first-ground`)

  // The campaign ends by handing over the real game.
  ok('campaign.ends_in_the_open_garden',
     ids[ids.length - 1] === 'open-garden', ids[ids.length - 1])

  // A new player lands in the campaign, not the generated map. This is
  // the whole reason the campaign exists.
  const mainSrc = readFileSync(resolve(ROOT, 'app', 'main.lua'), 'utf8')
  ok('campaign.new_player_starts_in_it',
     /peekLevel\(blob\) or "first-ground"/.test(mainSrc),
     'main.lua does not default to the first level')

  // LIVE: the first level really builds, and it really is quiet. This
  // gate needs the PLAY cart -- the one without the opengarden marker --
  // because the marker's whole job is to skip the campaign.
  ensurePlayCart()
  await load({ deterministicSeed: 5 })
  await step(90)
  const boot = (await events()).filter(l => l.startsWith('@boot')).pop()
  ok('campaign.first_level_boots', !!boot, 'no @boot line')
  if (boot) {
    const nodes = Number(boot.match(/nodes=(\d+)/)?.[1])
    ok('campaign.boots_the_authored_map', nodes > 0 && nodes <= 4,
       `${nodes} nodes -- expected the small authored map, not the ring map`)
  }
  // Step first, THEN drain once: events() empties the ring, and the
  // @boot read above already took everything printed so far. Reading
  // twice is how this reported "no metrics" on a perfectly quiet garden.
  await step(240)
  const m = metrics(await events()).pop()
  ok('campaign.CONTROL_opening_has_no_predators',
     m && m.spiders === 0 && m.beetles === 0,
     m ? `spiders=${m.spiders} beetles=${m.beetles}` : 'no metrics')
}

gates.onboarding = async () => {
  await loadOpen()
  await step(30)

  // A fresh colony must be OFFERING the lesson: nothing learned yet.
  const fresh = await uiState()
  ok('onboard.fresh_not_learned', fresh.linkL === 'false',
     `linkL=${fresh.linkL} link=${fresh.link}`)
  ok('onboard.hints_on_by_default', fresh.hints === 'true', fresh.hints)
  ok('onboard.menu_closed_at_boot', fresh.menu === 'false', fresh.menu)

  // Do the taught verb until it is learned. cursor.LEARNED is 3, so this
  // needs at least three SUCCESSFUL links -- and only a success counts,
  // because main.lua notes the verb on `ok`. Re-linking the same pair
  // returns false (the edge already exists) and teaches nothing, which is
  // how the first version of this loop scored 1 out of 4 and looked like a
  // broken hint system rather than a broken driver. So: walk the cursor to
  // a NEW node between links, and drive it until the cart says learned.
  let learned = false
  for (let i = 0; i < 10 && !learned; i++) {
    await tool('input', { op: 'press', button: 'a', frames: 2 })   // pick up
    await step(4)
    // Alternate the direction so the cursor keeps reaching fresh pairs on
    // a star map rather than bouncing between the same two nodes.
    const dir = ['right', 'down', 'left', 'up'][i % 4]
    await tool('input', { op: 'press', button: dir, frames: 3 })
    await step(4)
    await tool('input', { op: 'press', button: 'a', frames: 2 })   // connect
    await step(6)
    learned = (await uiState()).linkL === 'true'
  }
  const after = await uiState()
  ok('onboard.retires_after_use',
     Number(after.link) >= 3 && after.linkL === 'true',
     `link=${after.link} linkL=${after.linkL}`)

  // THE MENU, on the pad. START opens it; it must report open, and the
  // world must keep running underneath (nothing in this game is urgent).
  //
  // Let SELECT fully clear first: uiState() has just pressed it, and
  // SELECT-held + START is the debug-pause chord -- so a START arriving
  // while the pad still reports select down means "pause", not "menu".
  await step(12)
  await tool('input', { op: 'press', button: 'start', frames: 2 })
  await step(6)
  const opened = await uiState()
  ok('onboard.start_opens_menu', opened.menu === 'true', opened.menu)

  // While it is open the pad drives the MENU and not the world: a
  // direction must move the selected row, not the cursor.
  await tool('input', { op: 'press', button: 'down', frames: 2 })
  await step(4)
  const moved = await uiState()
  ok('onboard.menu_eats_direction',
     moved.menu === 'true' && Number(moved.row) !== Number(opened.row),
     `row ${opened.row} -> ${moved.row}`)

  // A setting must actually change, and it is read back from the cart.
  // Row 1 is Sound; go to it and turn it down.
  await tool('input', { op: 'press', button: 'up', frames: 2 })
  await step(4)
  const beforeVol = (await uiState()).volume
  await tool('input', { op: 'press', button: 'left', frames: 2 })
  await step(4)
  const afterVol = (await uiState()).volume
  ok('onboard.setting_changes', Number(afterVol) < Number(beforeVol),
     `volume ${beforeVol} -> ${afterVol}`)

  // B closes it, and the world is reachable again.
  await tool('input', { op: 'press', button: 'b', frames: 2 })
  await step(6)
  ok('onboard.b_closes_menu', (await uiState()).menu === 'false')

  // CONTROL: with hints switched off, a fresh colony must offer NOTHING.
  // Without this the "retires" assertion above passes for a game whose
  // hints never appeared in the first place.
  await loadOpen()
  await step(30)
  const ctrlOn = await uiState()
  await tool('input', { op: 'press', button: 'start', frames: 2 })
  await step(6)
  // Hints is the third row: down twice from Sound, then toggle.
  await tool('input', { op: 'press', button: 'down', frames: 2 })
  await step(4)
  await tool('input', { op: 'press', button: 'down', frames: 2 })
  await step(4)
  await tool('input', { op: 'press', button: 'right', frames: 2 })
  await step(4)
  const ctrlOff = await uiState()
  ok('onboard.CONTROL_hints_off_silences',
     ctrlOn.linkL === 'false' && ctrlOff.hints === 'false' &&
     ctrlOff.linkL === 'true',
     `on:${ctrlOn.linkL} hints:${ctrlOff.hints} off:${ctrlOff.linkL}`)

  // TOUCH: the pause corner opens the same menu, and a tap outside closes
  // it. Same surface, both devices -- the M7 claim.
  await loadOpen()
  await step(30)
  const pb = (await uiState()).pause
  ok('onboard.pause_button_reported', !!pb, JSON.stringify(pb))
  // Tap the button the cart says it drew, NOT a guessed corner.
  await tool('input', { op: 'pointer', id: 0, x: pb.cx, y: pb.cy, left: true })
  await step(4)
  await tool('input', { op: 'pointer', id: 0, x: pb.cx, y: pb.cy, active: false })
  await step(6)
  ok('onboard.touch_corner_opens', (await uiState()).menu === 'true')

  // THE PAUSE BUTTON MUST NOT SIT ON THE CASTE WIDGET. This is the actual
  // defect that made the menu unreachable on a phone: an invisible corner
  // hotspot underneath the widget's bars, so every tap there adjusted a
  // caste instead. Asserted geometrically rather than by eye, because the
  // symptom (a tap that does something ELSE plausible) never looks like a
  // bug in a screenshot.
  const widget = { x: 1560, y: 880, w: 360, h: 200 }   // bottom-right cluster
  const overlaps = pb.x < widget.x + widget.w && pb.x + pb.w > widget.x &&
                   pb.y < widget.y + widget.h && pb.y + pb.h > widget.y
  ok('onboard.pause_clear_of_caste_widget', !overlaps,
     `pause ${JSON.stringify(pb)} vs widget ${JSON.stringify(widget)}`)

  await tool('input', { op: 'pointer', id: 0, x: 120, y: 120, left: true })
  await step(4)
  await tool('input', { op: 'pointer', id: 0, x: 120, y: 120, active: false })
  await step(6)
  ok('onboard.touch_outside_closes', (await uiState()).menu === 'false')

  // THE COLOUR-BLIND PALETTE MUST ACTUALLY RE-COLOUR THE TRAILS. It is an
  // accessibility promise made in a menu, and a setting that changes a
  // number but not a pixel is worse than no setting -- it tells a player
  // their problem is addressed when it is not. So: build some roads, run
  // long enough for traffic to separate a fed road from a busy one,
  // photograph the map, flip the palette, photograph it again, and require
  // the two to differ on the axis the re-key is FOR (blue).
  await loadOpen()
  await step(120)
  await openSomeRoads()
  await step(1800)
  await step(30)
  const natural = await readPng(await screenshot('pal-natural'))

  await tool('input', { op: 'press', button: 'start', frames: 2 })
  await step(8)
  await tool('input', { op: 'press', button: 'down', frames: 2 })   // Colours
  await step(6)
  await tool('input', { op: 'press', button: 'right', frames: 2 })
  await step(6)
  await tool('input', { op: 'press', button: 'b', frames: 2 })
  await step(20)
  const state = await uiState()
  ok('onboard.palette_setting_flips', Number(state.palette) === 2, state.palette)
  // uiState() toggles the debug overlay on and off again; give the scene a
  // few frames to compose afterwards before photographing it. Shooting
  // immediately caught an empty frame and reported "mean blue 0.00", which
  // looked like the palette had erased the trails.
  await step(30)
  const contrast = await readPng(await screenshot('pal-contrast'))

  // Mean blue over the TRAIL PIXELS, not the whole frame. The natural
  // palette's trails are green with blue held down (0.30, falling with
  // danger); high contrast drives blue to 0.95 on a fed road. But trails
  // cover a few percent of a screen that is mostly green soil, so a
  // whole-frame mean diluted a large change on the roads into a 1.9%
  // change overall -- under the threshold, and a green light for a
  // palette that had genuinely stopped working would look the same.
  // Selecting the bright pixels measures the thing the setting claims to
  // change. Sampling every 4th pixel keeps this quick at 1080p.
  // BLUE RELATIVE TO RED, not absolute blue. Both palettes draw bright
  // trails, so mean blue moves only a little between them and the check
  // sat on a threshold tuned to one particular scene -- it drifted under
  // as soon as the map changed. What the re-key actually DOES is move the
  // roads off the red-green axis and onto blue-yellow, so the ratio is
  // the thing it changes by construction and by a wide margin.
  const meanBlue = (img) => {
    let sumB = 0, sumR = 0, n = 0
    for (let i = 0; i < img.pixels.length; i += 16) {
      const r = img.pixels[i], g = img.pixels[i + 1], b = img.pixels[i + 2]
      // A trail is emissive: notably brighter than the soil it lies on.
      if (r + g + b > 260) { sumB += b; sumR += r; n++ }
    }
    return n > 0 ? sumB / Math.max(1, sumR) : 0
  }
  // A BLANK FRAME IS A FAILURE, NOT A MEASUREMENT. Both shots must contain
  // real pixels before their difference means anything -- an all-black
  // capture (the compositor not having run yet after a mode change) would
  // otherwise sail through as "the blue went down", which is a fabricated
  // result rather than a detected regression.
  const meanLum = (img) => {
    let sum = 0, n = 0
    for (let i = 0; i < img.pixels.length; i += 4) {
      sum += (img.pixels[i] + img.pixels[i + 1] + img.pixels[i + 2]) / 3
      n++
    }
    return sum / n
  }
  const ln = meanLum(natural), lc = meanLum(contrast)
  ok('onboard.palette_frames_not_blank', ln > 4 && lc > 4,
     `mean luma natural=${ln.toFixed(2)} contrast=${lc.toFixed(2)}`)

  const bn = meanBlue(natural), bc = meanBlue(contrast)
  ok('onboard.palette_repaints_trails', ln > 4 && lc > 4 && bc > bn * 1.15,
     `blue:red on trails natural=${bn.toFixed(3)} contrast=${bc.toFixed(3)}`)
}

gates.fonts = async () => {
  const { readdirSync, statSync } = await import('node:fs')
  const appDir = resolve(ROOT, 'app')
  const files = []
  const walk = (d) => {
    for (const e of readdirSync(d)) {
      const p = resolve(d, e)
      if (statSync(p).isDirectory()) walk(p)
      else if (e.endsWith('.lua')) files.push(p)
    }
  }
  walk(appDir)

  const offenders = []
  for (const f of files) {
    const src = readFileSync(f, 'utf8')
    // love.graphics.print / printf draw TEXT; plain print() is the cart log
    // and is fine (that is how the probe talks to these gates).
    const draws = src.match(/love\.graphics\.printf?\s*\(/g)
    if (!draws) continue
    // Any of: an explicit setFont, the fonts module used through a local
    // (`fonts.get`), or used inline (`require("ui.fonts").set`).
    const setsFont = /setFont|fonts["')\]]*\s*\.\s*(get|set)/.test(src)
    if (!setsFont) offenders.push(f.replace(ROOT + '/', ''))
  }
  ok('fonts.no_bitfont_text', offenders.length === 0,
     `these draw text without ever setting a font: ${offenders.join(', ')}`)

  // And the face itself must actually be in the bundle.
  const idx = readFileSync(resolve(appDir, 'assets.index'), 'utf8')
  ok('fonts.face_shipped', idx.includes('fonts/AtkinsonBold.ttf'),
     'AtkinsonBold.ttf missing from assets.index')
}

// ── input drivers ──────────────────────────────────────────────────────
// NOTE ON THE PAD: these drivers use the D-PAD, not the analog stick.
// romdev 0.116.2's WasmcartHost drops the `axes` field from
// input({op:'set'}) entirely (it reads src.leftX, the tool sends
// src.axes.lx), so every stick input arrives centred. Reported in
// internal-romdev/feedback/2026-08-15_wasmcart-host-drops-analog-axes.md.
// The game therefore accepts the d-pad for the same cursor verbs, which is
// better design anyway -- stepping between discrete nodes is a d-pad job.
// Switch these back to axes once the host lands the fix.
async function padFlick (button) {
  await tool('input', { op: 'press', button, frames: 3 })
  await step(6)
}

async function openSomeRoads () {
  // Walk the cursor onto a node, A to select, walk again, A to link.
  const dirs = ['right', 'down', 'left', 'up']
  for (let i = 0; i < 4; i++) {
    await padFlick(dirs[i % dirs.length])
    await tool('input', { op: 'press', button: 'a', frames: 2 })
    await step(6)
  }
}

async function drivePad () {
  // THE CURSOR STARTS ON THE NEST now, so the opening gesture is A (pick
  // up at home), flick, A (send). This used to lead with a flick, which
  // moved the cursor OFF the nest before picking anything up -- so the
  // send came from ground the player does not own and was correctly
  // refused, and parity reported the pad's ok=false against the pointer's
  // ok=true as if the touch path were broken.
  await tool('input', { op: 'press', button: 'a', frames: 2 })
  await step(6)
  await padFlick('down')
  await tool('input', { op: 'press', button: 'a', frames: 2 })
  await step(10)
  return (await events()).filter(l => l.startsWith('@i '))
}

// Where the nodes actually are on screen, asked of the CART rather than
// guessed. A hardcoded drag target is how the first version of this driver
// silently landed on empty grass and reported "the pointer produces no
// intents" -- a false negative about the game caused entirely by the test.
// ORDER MATTERS, and it is the opposite of what it used to be. START is the
// player's menu now; it is only the debug pause while the overlay is
// already up. So the overlay goes on FIRST (SELECT), and only then does
// START mean pause. Driving it the old way opened the settings panel and
// swallowed the SELECT, which reported "only 0 node positions" -- a gate
// failure that was entirely about the driver's stale control scheme.
async function nodeScreenPositions () {
  await tool('input', { op: 'press', button: 'select', frames: 2 }) // overlay on
  await step(4)
  await tool('input', { op: 'press', button: 'start', frames: 2 })  // pause
  await step(2)
  const lines = await events()
  const out = {}
  for (const l of lines) {
    const m = l.match(/^@node (\S+) (-?\d+) (-?\d+)$/)
    if (m) out[m[1]] = { x: Number(m[2]), y: Number(m[3]) }
  }
  await tool('input', { op: 'press', button: 'start', frames: 2 })  // unpause
  await step(2)
  // Overlay back off, in the reverse order it went on. Leaving it up would
  // hand every later assertion a screen with a debug panel on it -- and
  // would leave START meaning "pause" instead of "menu", which is exactly
  // the confusion this helper just got caught by.
  await tool('input', { op: 'press', button: 'select', frames: 2 })
  await step(2)
  return out
}

async function drivePointer () {
  const pos = await nodeScreenPositions()
  const ids = Object.keys(pos)
  if (ids.length < 2) throw new Error(`only ${ids.length} node positions reported`)
  // The nest is always the first node the sim built.
  const from = pos[ids[0]]
  // DRAG TO GROUND YOU CAN ACTUALLY SETTLE. ids[1] is whatever the map
  // built second, which on the ring map is often a FLOWER -- and a send
  // to a resource node is correctly refused, so the touch arm reported
  // link:ok=false against the pad's ok=true and parity looked broken when
  // the two arms were simply aiming at different kinds of place. Ask the
  // cart which nodes are colonisable rather than assuming.
  const own = await ownership()
  const target = ids.slice(1).find(id => own.nodes[id]?.colonisable &&
                                         own.nodes[id]?.owner === null)
  const to = pos[target] || pos[ids[1]]

  // Every pointer call needs x/y, INCLUDING the release: the tool rejects a
  // call without them rather than reusing the last position.
  await tool('input', { op: 'pointer', id: 0, x: from.x, y: from.y, left: true })
  await step(4)
  const midX = Math.round((from.x + to.x) / 2)
  const midY = Math.round((from.y + to.y) / 2)
  await tool('input', { op: 'pointer', id: 0, x: midX, y: midY, left: true })
  await step(4)
  await tool('input', { op: 'pointer', id: 0, x: to.x, y: to.y, left: true })
  await step(4)
  await tool('input', { op: 'pointer', id: 0, x: to.x, y: to.y, left: false })
  await step(10)
  return (await events()).filter(l => l.startsWith('@i '))
}

// ── a minimal PNG reader (no deps) ─────────────────────────────────────
// Only what the extent check needs: IHDR + IDAT, 8-bit RGB/RGBA, inflate
// via node's zlib. Written here rather than pulled in so the gates have no
// install step.
import { inflateSync } from 'node:zlib'

async function readPng (path) {
  const buf = readFileSync(path)
  let pos = 8                     // skip signature
  let width = 0, height = 0, bitDepth = 0, colorType = 0
  const idat = []
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos)
    const type = buf.toString('ascii', pos + 4, pos + 8)
    const data = buf.subarray(pos + 8, pos + 8 + len)
    if (type === 'IHDR') {
      width = data.readUInt32BE(0)
      height = data.readUInt32BE(4)
      bitDepth = data[8]
      colorType = data[9]
    } else if (type === 'IDAT') {
      idat.push(data)
    } else if (type === 'IEND') break
    pos += 12 + len
  }
  if (bitDepth !== 8) throw new Error(`unsupported bit depth ${bitDepth}`)
  const channels = colorType === 6 ? 4 : colorType === 2 ? 3 : null
  if (!channels) throw new Error(`unsupported colour type ${colorType}`)

  const raw = inflateSync(Buffer.concat(idat))
  const stride = width * channels
  const out = Buffer.alloc(width * height * 4)
  let prev = Buffer.alloc(stride)
  let rp = 0
  for (let y = 0; y < height; y++) {
    const filter = raw[rp++]
    const line = Buffer.from(raw.subarray(rp, rp + stride))
    rp += stride
    // PNG filters, per the spec.
    for (let x = 0; x < stride; x++) {
      const a = x >= channels ? line[x - channels] : 0
      const b = prev[x]
      const c = x >= channels ? prev[x - channels] : 0
      switch (filter) {
        case 0: break
        case 1: line[x] = (line[x] + a) & 255; break
        case 2: line[x] = (line[x] + b) & 255; break
        case 3: line[x] = (line[x] + ((a + b) >> 1)) & 255; break
        case 4: {
          const p = a + b - c
          const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c)
          const pr = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
          line[x] = (line[x] + pr) & 255
          break
        }
        default: throw new Error(`bad filter ${filter}`)
      }
    }
    for (let x = 0; x < width; x++) {
      const s = x * channels, d = (y * width + x) * 4
      out[d] = line[s]
      out[d + 1] = line[s + 1]
      out[d + 2] = line[s + 2]
      out[d + 3] = channels === 4 ? line[s + 3] : 255
    }
    prev = line
  }
  return { width, height, pixels: out }
}

// ── main ───────────────────────────────────────────────────────────────
const ORDER = ['conformance', 'fonts', 'simtest', 'determinism', 'renderExtent',
               'inputParity', 'multitouch', 'fourx', 'engine', 'commitment', 'wildlife', 'campaign', 'verbs',
               'onboarding', 'hdr',
               'audio', 'save', 'watchability', 'year', 'soak', 'perf']

async function main () {
  const args = process.argv.slice(2)
  if (args[0] === '--list') {
    console.log(ORDER.join('\n'))
    return
  }
  const want = args.length ? args : ORDER
  for (const name of want) {
    const g = gates[name]
    if (!g) { console.log(`unknown gate ${name}`); fail++; continue }
    console.log(`\n== ${name} ==`)
    // Each gate gets its own romdev session so a long one cannot have its
    // host evicted by a sibling's load. See the note on `currentSession`.
    currentSession = `${SESSION}-${name}`
    try {
      await g()
    } catch (e) {
      fail++
      failures.push(`${name}: threw ${e.message}`)
      console.log(`  FAIL ${name} threw: ${e.message}`)
    }
  }
  console.log(`\n${pass} passed, ${fail} failed`)
  if (failures.length) {
    console.log('\nfailures:')
    for (const f of failures) console.log('  ' + f)
  }
  process.exit(fail ? 1 : 0)
}

main()
