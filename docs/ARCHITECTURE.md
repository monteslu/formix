# Architecture

About 8,300 lines of Lua in four layers, with one hard rule between them:
**the simulation never draws, and the renderer never decides anything.**

```
  input/          reads devices, produces INTENTS
     |
     v
  sim/            the whole game state; the only mutation door is sim.apply
     |
     | snapshot (read-only)
     v
  render/ ui/     draws the snapshot; owns no state that matters
```

The cart runs on [wasmcart-lua](https://github.com/monteslu/wasmcart), a
LÖVE-shaped API compiled to WebAssembly. `main.lua` is the entry point and
the only file that wires the layers together.

## The layers

### `sim/` — the game

Nothing here calls `love.graphics` or reads a clock. The only entropy is an
injected RNG, which makes determinism structural rather than aspirational:
the same seed and the same intents always produce the same game.

| file | what it owns |
|---|---|
| `init.lua` | the whole simulation behind one door: `new`, `update`, `apply`, `snapshot` |
| `world.lua` | the map — mounds, their stats, and the reach rule that defines the network |
| `agents.lua` | the ants: units, currency and builders all at once |
| `campaign.lua` | the four hand-built levels and their completion rules |
| `rival.lua` | one enemy brain per side; queens, expands, reinforces, attacks |
| `save.lua` | serialisation, as a diffable text format |
| `castes.lua` `economy.lua` `scent.lua` `seasons.lua` `threats.lua` | the systems layered on top |

**`sim.apply` is the only mutation door.** Every player action arrives as an
intent and returns true or false, which is what the UI uses for its refusal
feedback. Nothing else may write to the world.

### `input/intents.lua` — the only file that reads a device

Both a gamepad and a touchscreen produce the *same* intent stream, so
everything downstream is device-blind:

```
send    {from, to, count}
queen   {node}
upgrade {node, stat}
select  {node}            -- cursor moved; UI only
pan     {dx, dy}          -- world units; touch drag, mouse drag, right stick
zoom    {f, sx, sy}       -- continuous + anchor: pinch, wheel
        {step}            -- one rung of render/viewport ZOOM_STEPS: shoulders
        {reset}           -- default zoom, centred on the cursor: R3
debug
```

THE CAMERA IS NOT THE CURSOR, and they are only loosely coupled: panning
never moves the cursor, and moving the cursor recalls the view for a short
window afterwards. Both directions matter -- a nudge that ran continuously
undid every manual pan the instant the player let go, which is a camera you
cannot aim. Every zoom path goes through one intent so the anchor and the
world-bounds clamp cannot be forgotten by whichever input is added next.

The core gesture is drag-from-a-mound, and the drag distance chooses how
many ants go. A tap only ever selects — an irreversible move should never
be one stray tap away, because looking around is the most common thing a
player does.

### `render/` — draws a snapshot

Takes `sim.snapshot(s)` and draws it. Holds caches (generated mound
geometry, fonts, canvases) but no state that would change the game if it
were thrown away.

`render/init.lua` sets the frame's shape: an HDR scene pass, bloom, then the
composite that decides the final colour. `fx.lua` owns that chain.

### `ui/` — panels, menu, minimap, HUD

Drawn *outside* the bloom composite, because bloomed type is unreadable.
`nodepanel.lua` is the one interactive piece: it records button rectangles
each frame so `input/intents.lua` can hit-test them.

## Three ideas the code keeps coming back to

**Reach is the network.** A mound can throw a certain distance; you may only
send inside the reach of a place you already hold. Edges are computed from
positions rather than stored, so the ring drawn on screen *is* the rule, and
a mound whose range stat grows really does reach further.

**Ants are the only currency.** There is nothing to gather and nothing to
shuttle. An ant is your army, your money and your builder, so every price is
a number of bodies you give up — which is what makes spending feel like it.

**Fog is presence, not a layer.** There is no dark sheet over the map.
Instead every site — mound and food location alike — is in exactly one of
three states, and each has a hard ceiling on what it is allowed to draw:

| state | when | may show |
|---|---|---|
| **present** | your ants stand here, your assault is inbound (`contested`), or a queen of yours lives here | everything: owner, garrison, enemies, live item counts |
| **discovered** | you have stood here before, nobody friendly is here now | the *identity* only — kind and real size — rendered grey. No owner, no enemies, no live counts |
| **unknown** | never visited | one medium-grey circle, the SAME circle for every site. Position only |

Three flags carry it. `observed` means **presence** and nothing else: your
ants are physically here, or a fight you are paying for is inbound. `held`
is the tighter "one of yours is standing on it", and warms the ground from
stone to earth. `visited` is the one that never clears — set the first time
one of your ants arrives, kept through leaving, losing the ground and a save
round trip — and it buys *identity*, never live state.

Two rules are load-bearing, both learned by breaking them:

- **Adjacency observes nothing.** A queened colony spreads `lit` (the ground
  comes out of the fog, which is what makes raising a queen the moment the
  map opens up) but does NOT spread `observed`. It used to, and the board
  handed over neighbouring kinds, item counts, owners and enemy bodies for
  free, forever, for the price of a queen you were raising anyway. There was
  very nearly nothing left to learn by walking somewhere.
- **An unknown site is one shared circle.** `render/unknownsite.lua` is the
  only way state 3 is ever drawn, mound or location, at one uniform radius
  and with no per-site variation at all. Drawing each kind at its own radius
  labelled every circle on the board by size — and made the spider, the one
  thing the fog most needs to hide, the biggest thing out there. Seeded
  wobble was tried and cut for the same reason: any per-site variation is a
  channel.

`visited` is NOT the "found" latch that was tried and reverted. That one kept
ground *warm* — colour, owner, the lot — which `test-grey` rightly killed,
because in this game the coloured ground IS the ground you hold. This one
remembers only what kind of place it is; the ground still goes back to grey
stone the moment your ants leave.

See `docs/ENGINE-NOTES.md` for why the layer approach was abandoned.

## Testing

Two layers, both driving the real cart through the
[romdev](https://www.npmjs.com/package/romdevtools) MCP server.

```sh
node tools/run-tests.mjs      # the full suite
node tools/test-war.mjs       # or any single gate
```

`tools/drive.mjs` is the harness. **Every romdev call is checked**: a
tool-level error throws rather than being silently ignored. That exists
because a harness that sent malformed input once reported passes for a game
receiving no input at all.

The suite asserts on what the SIM reports or what the PIXELS show, never on
a claim. Some gates worth knowing about:

| gate | what it protects |
|---|---|
| `test-reachable` | pure geometry: every mound on every level is reachable and connected. Shipped once with an unwinnable level because nothing asked. |
| `test-grey` | the fog rule, in pixels — including that a mound goes *back* to stone when its ants leave |
| `test-war` | that the war map actually produces a war: mounds captured from another colony, not merely ownership changing |
| `test-gameplay` | the input contract, including that tap-tap does *not* send |
| `test-campaign` | that a level transition really rebuilds the world |
| `test-camera` | pan/zoom on all three inputs: empty-ground drag pans, a mound drag still sends, pinch zooms ANCHORED (the world under the centroid stays put), a second finger cancels a send, the shoulder mode split holds in both directions, and the camera cannot be flung out of the world |
| `test-food` | queens eat: an empty pantry lays nothing, N food buys exactly N ants, the 10-per-queen cap holds, and no-workers-no-food is game over |
| `test-forage` | the food ledger closes -- ground + carried + pool + eaten always equals what was taken -- and ants deliver and STAY rather than re-foraging |
| `test-locrules` | food is a destination, never a bridge or a watchtower |
| `test-bootstrap` | every board can reach a fed queen from its opening position |
| `test-fog3` | the three fog states, and that nothing leaks across them: the `visited` latch survives leaving and a save round trip, and every unvisited site on the board measures the same size and brightness whether it is a spider or a small mound. Runs on its own `gatefog` fixture -- it used to walk `discover`'s red colony and wait for the board to hand over a discovered-but-enemy-held mound, so a difficulty tuning pass reddened a gate that tests RENDERING |
| `test-audio` | that the music and effects sliders are genuinely separate: music off with effects still audible, then the reverse, plus both orderings of the opposed-slider control. Asserts on EFFECTIVE gains (fade x slider), because the raw fade gain does not move when a slider does -- reading that would pass on a build where the slider was wired to nothing |
| `test-open` | that the campaign has an ending. `open` was a four-field placeholder and `campaign.complete` refuses generated levels, so the last row could not be beaten by anybody. Also that beating it does not advance into the gate fixtures -- `campaign.next` walked the array unconditionally, and the entry after `open` is `gatefood` |

**Gates are written to fail.** Several were rewritten after passing a
deliberately sabotaged build — the war gate first passed with the enemy AI
disabled, which made it worse than nothing. If a gate cannot be made to fail
by breaking the thing it tests, it is not testing that thing.

## Building

```sh
./build.sh                     # pack the cart
python3 tools/make-audio.py    # regenerate the soundscape
python3 tools/make-icon.py     # regenerate the launcher icon
```

`build.sh` resolves the engine and packer from the environment
(`WASMCART_LUA`, `ENGINE`, `WASMCART_PACK`) and contains no absolute paths.

Build-time marker files in `app/` change what the packed cart does, and none
are committed:

| marker | effect |
|---|---|
| `app/testmode` | boots the pure-Lua unit suite instead of the game |
| `app/startlevel` | boots straight into a named level, for gates |
| `app/opengarden` | boots the generated field instead of the campaign |

A marker is the mechanism because the cart cannot read host values — the
choice has to be made where the cart is packed. Before writing any
conditional on a host value, print it from inside the cart and check it is
what you think it is.
