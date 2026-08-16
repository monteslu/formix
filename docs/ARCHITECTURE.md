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
pan / zoom / debug
```

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

**Fog is presence, not a layer.** There is no dark sheet over the map. A
mound renders as grey stone until one of your ants is standing on it (or a
queen lives there), and only then does it show its garrison, its owner
colour and its true kind. That single flag — `held` — drives the mound
colour, the rim, the enemy bodies, the larvae, the panel and the minimap.
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
