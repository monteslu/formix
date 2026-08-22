# Notes: things found the hard way

Running log of gotchas hit while building this. Each one cost real time, so
each one is written down with the symptom first -- that is what you will be
looking at when it happens again.

## Engine (wasmcart-lua)

**A filled polygon must be CONVEX, or the GPU 2D path dies for the run.**
Symptom: a later `setShader()` errors with "this run is on the software
rasterizer", and the cart log has `GPU 2D path DISABLED for the rest of the
run -- this is a BUG, not a fallback` followed by a truncated reason. The
engine fans a filled polygon on the GPU and refuses a concave one; the
refusal is deliberately loud rather than a silent slow fallback. Bit twice
here: trail ribbons traced up one side and back down the other, and the
classic waisted ant silhouette. Fix: draw ribbons as a run of quads, and
build an ant from three overlapping convex ovals rather than one outline.

**Pad button names are the ABI's, and a wrong one CRASHES.** The table is
`a b x y l r start select up down left right l3 r3`. SDL-style names
(`dpup`, `leftshoulder`, `back`) are not in it, and `love.pad.isDown`
indexes without a nil check, so a typo raises "attempt to perform bitwise
operation on a nil value" from inside the prelude -- a full-screen LUA
ERROR, not a dead button. `input/intents.lua` wraps the poll in a pcall so
a future typo degrades to "that button does nothing".

**`Source:play()` captures the CURRENT volume.** `setVolume` before there is
a channel only records the number for later; `play()` hands whatever
`self.vol` is at that moment to the host when it allocates the channel. So
starting a fading-in loop while its gain is still 0 plays it at volume zero
AND makes `isPlaying()` true forever, meaning it is never restarted and the
game is silent for the whole session. Set the gain first, start only above
zero.

**A `goto` cannot leave the block its label is in, and the engine only
tells you at LOAD time.** Symptom: the cart never starts and the host log
ends with `lua error in main.lua: error loading module 'input.intents':
no visible label 'continue_slot' for <goto>`. A `goto continue_slot`
written inside an `if` branch, aiming at a label at the end of the
enclosing `for`, does not compile -- Lua labels are visible only in their
own block and its nested ones, never from a sibling branch outward. It
cost a whole session because the failure is a LOAD error: every gate went
red at once with `fetch failed` and nothing rendered, which reads like a
dead server rather than one bad statement. There is no host `lua`/`luac`
on this box, so nothing catches it before the engine does. The fix is
structural, not a label: express the short-circuit as an `if/elseif/else`
chain. If a gate suite goes red all at once, read the cart log FIRST.

**Never allocate a GPU resource mid-frame.** `love.graphics.newFont()`
called during the HDR pass corrupted the engine's declared-format
composite blit mesh -- `Mesh:setVertices: the update failed. A
declared-format mesh's buffer is allocated at newMesh and cannot grow
past 6 vertices` -- which raised a Lua error EVERY frame and dropped the
whole run to the software rasterizer. The trigger was one new font size
(30) that only a newly-added panel asked for; every other size had been
allocated at init and so had never shown the problem. Warm every size (or
canvas, or mesh) before the first frame.

The lesson underneath it is about DIAGNOSIS, not fonts. The visible
symptom was three layers away and looked like gameplay: the erroring
frame never processed input, so START stopped opening the menu and a gate
reported "cart reported no @ui line". Several rounds went into the
overlay toggle and the START guard while the cart log had been saying
`lua error in frame` the entire time. Read the cart log FIRST -- this
file already said so, and it would have saved the detour twice in one
session.

**`love.mouse.isDown(1)` IS ALSO TRUE WHEN PAD R IS HELD.** The prelude
mirrors the pad's R button onto mouse button 1 as a convenience for
pad-only hosts (`mouse.isDown` has an explicit fallback: "gamepad
fallback: R trigger is fire, mirroring button 1"). Harmless while R did
nothing spatial -- and poison the moment R became zoom-out. Symptom:
pressing R to zoom silently PICKED UP whichever mound the mouse cursor
happened to be resting over, so the next A press -- which the player meant
as "select this" -- was read as "put it back down" and appeared to do
nothing. On a desktop it would also pan the view on every zoom press, since
a click on open ground is now a camera drag. It cost an hour, because the
visible failure was two buttons away from the cause and the pad and the
mouse look like separate worlds.

Read the RAW pointer (`wc.pointer(0)` returns x, y, buttons, active) in any
cart that reads the pad itself; the mirror is only for carts that do not.
`input/intents.lua` does exactly that now.

**Warm fonts BEFORE anything caches a font object.** hud.lua and
caste_widget.lua both keep the font they are handed at init, so warming
afterwards left them drawing at whatever they had already stored --
visible as run-together labels in the corner.

**`circle("fill")` is unreliable after a render-target pass.** The engine
evaluates a filled circle per fragment from `gl_FragCoord`, which is
viewport-relative. Use a polygon fan (`flora.disc`). Inherited from the
eightball cart; not re-hit here because the fan was in from the start.

**Matrices are row-major.** Not hit in this game (no 3D), but the trap that
costs the most elsewhere: `glUniformMatrix4fv` needs transpose=TRUE, and an
untransposed matrix rasterizes NOTHING with no error at all.

## Rendering

**Emissive must exceed 1.0 to bloom, but on a NORMALISED colour.** Drawn at
LDR values the bright pass has nothing to find and the whole map reads flat.
Multiplied too hard (2.6) a busy trail saturates all three channels: it
blooms beautifully and comes out white, losing the colour that was carrying
the meaning. Normalise the hue, then scale.

**A strong tonemap greys the whole picture.** Rolloff 0.55 compressed the
midtones -- soil and flora, already in range -- while barely touching the
glow it was meant to tame. 0.28 bends only the top end.

**Only one layer may own the night grade.** The ground shader dimmed itself
AND the post composite dimmed everything, so dusk fell twice as fast on the
soil as on the ants standing on it. The composite owns it; the ground keeps
a plain overlay for the no-float-canvas path only.

**Fading a colour toward a dark ground DESATURATES it.** Undiscovered
nodes are drawn at ~0.3 alpha, and every one of them came out grey-white
-- which reads as dead, the exact opposite of the "there is something
over there, send someone" that is this game's whole onboarding. The first
fix (multiply the colour up) made it worse: these petals are pale by
design, so scaling clipped all three channels and produced white flowers.
The right correction is to push each channel AWAY from its own mean --
saturate, do not brighten -- and to stop the pollen core blooming while
the node is unknown, since an emissive bead over 1.0 swamps the petals
behind it.

**An additive halo the size of a fog bank draws the eye to a SMEAR.** The
first "come and look at me" glow under an undiscovered node used a 2.1x
radius; the map filled with pale discs and read as weather. A marker has
to say *here*, so the glow barely exceeds the plant and leans on a slow
breath rather than on size.

**A creature reads by the RATIO of body to limb, not by its parts.** The
spider had every anatomical piece right -- eight legs, two body sections,
a knee bend, eye glints -- and still read as a fat tick with whiskers,
because the abdomen was 0.95r against 0.13r legs. Halving the body and
more than doubling the leg width (a heavy femur, a thinner tibia, a blunt
foot so the taper does not fade out) fixed it without adding a single new
element. Body-to-legspan went 0.35 -> 0.21. When a generated creature
looks wrong, check the proportions before adding detail.

**`setLineWidth` is not a way to draw a thick limb.** Raising the spider's
leg width from 0.13r to 0.30r changed nothing on screen: GL caps
`glLineWidth` at 1 on most drivers, so every leg stayed a 2px thread no
matter what the code asked for. The fix is real geometry -- each segment
is a four-point quad (convex, so the fan path accepts it) with a disc at
the joint. If a stroked shape ignores its width, stop tuning the number
and build the shape.

**Check that a generated body is oriented along the axis its limbs
imply.** The spider's abdomen-to-head ran along +X while both leg fans
were centred on +X and -X, so the body lay ALONG the leg axis and the
animal read as rotated 90 degrees from itself -- with the legs merged
into a mass it was invisible until they were separated. Legs come off the
SIDES; the body runs down the clear axis between them. Worth printing the
angles rather than eyeballing it: eight legs at 45-135 and 225-315
degrees against a body at 0 is the arrangement that reads.

**A body drawn the same value as its limbs disappears into them.** Once
the legs became solid geometry, an abdomen at 0.10 against legs at 0.06
vanished -- the spider looked like a starburst with nothing in the
middle. The body now steps UP in value from abdomen to head, which both
separates it from the limbs and gives the creature a facing.

**A full-screen fragment shader is where per-pixel detail gets
expensive.** Adding grain and litter to the soil cost three extra
`vnoise()` calls per pixel -- about 6M evaluations a frame at 1080p --
and dropped the game from 55fps to 47 with a step time up from 4.7ms to
5.9ms, for detail that is deliberately subtle. Folding both effects onto
ONE sample (its value drives the grain, its top decile is the litter)
recovered all of it. They correlate, which is invisible at this contrast
and free.

**Measure the baseline before believing a perf number.** The 47fps
reading looked like an M7 regression until the pre-M7 commit was measured
on the same machine at the same moment and gave 55, not the 58 recorded
earlier -- the box was loaded. Successive runs of the fixed build gave
55, 56 and 65. A single fps sample on a busy machine is not evidence;
step time (4.3ms vs 5.9ms) was the stable signal.

**A world-space overlay drawn AFTER the composite lands in the wrong
place.** The cursor and selection rings were drawn after `fx.finish()`,
i.e. in screen space on top of an already-composited scene, and every one
of them sat ~115px off the node it was circling. Two rounds were wasted
adjusting the RADIUS (which was correct all along) and one on swapping
circle()/arc() for line segments (also not the cause). Anything that
marks a place IN THE WORLD has to be rasterised in the world's pass with
everything it aligns to; only type stays outside, because bloomed text is
unreadable. Symptom to recognise: a constant offset in the same direction
for every instance -- that is a space mismatch, never a maths error.

**When an overlay looks misaligned, measure the offset before touching
the formula.** Reading two ring centres off the screenshot and
subtracting the node positions gave a constant (+42,-120) and (-3,-114)
-- obviously a translation, which immediately rules out per-node radius
and points at the coordinate space. Guessing at the radius three times
cost more than one measurement would have.

**A fixed scatter radius makes a ring.** Resting ants placed at a constant
radius from a node's centre form a perfect circle of bodies that reads as a
UI element. Vary the radius per ant as well as the angle.

## Simulation

**Every kill site needs the floor check.** The displacement invariant broke
because `economy.lua` clamped starvation and age-out while `agents.lua`'s
hazard kill did not, so a long famine on a hazardous road walked the colony
one ant under the floor. The floor now lives in `agents.lua` (which owns
`kill()`) and `economy.cfg.minColony` forwards to it through a metatable, so
there is exactly one value and a test that disarms it really disarms every
path.

**Without regrowth the game is a countdown.** The first build gave the map
~5500 food total and no renewal: the colony boomed to 190 ants by t=190,
ate the world, and starved. Every run ended in a bust however well it was
played. A terrarium has to be able to reach a steady state.

**A road has to be materially better, not just preferred.** On a star map
every source is one hop from the nest, so edge CHOICE alone was worth a
measured 1.1x and trails were decoration. Roads are now faster to walk, and
an ant with no scent to follow dithers before choosing.

**Traffic reinforcement has to beat decay at REAL crossing rates.** The
first value needed ~28 crossings a second to break even; a busy road sees
3-6. Every road therefore faded to invisible no matter how heavily it was
used, and the map rendered dark.

## Game design (the 4X engine)

**A concave payoff makes expansion mathematically a LOSS.** Node output
was `growRate * sqrt(garrison)`, and sqrt is concave -- so splitting a
workforce across two nodes always produces less than concentrating it on
one. The measurement was unambiguous and repeatable: two nodes supported
54 ants where one supported 68. No amount of tuning the rates fixes the
shape; either the frontier node's rate must beat the source's MARGINAL
rate (which falls as the source fills), or something must cap the source.

**If one node can carry the whole colony, there is no reason to expand.**
An uncapped nest reached 82 ants on its own and beat every expanding
colony, over both short and long runs. A 4X needs a per-node CEILING so
that "I want more ants" becomes "I need more places" -- which is also
truer to the fiction, since a nest has finite room. Capacity is the
mechanic that turns expansion from optional into necessary.

**Territory has to buy something a bigger nest cannot.** The first
attempt at making expansion pay drew income from the new node's OWN pile
-- which is the same food its foragers were already carrying home, just
relabelled, and changed nothing. What a forward base actually adds is
REACH: piles too far from the nest to work are now next door to
somebody. Income has to come from the neighbours it unlocks.

**Measure both arms, do not reason about the curve.** Three rounds were
spent on arithmetic about marginal rates that turned out to be nearly
identical between arms (0.2474 vs 0.2487) -- the real gap was the ants
SPENT taking the node, which no amount of rate algebra would have shown.
Running the same seed twice, expanding one arm and not the other, gave
the answer in one measurement.

**A rate-vs-rate gate cannot test a saturating system.** The first
compounding gate compared an early growth rate against a late one and
failed on every healthy curve: a colony below its limit grows fast, one
at its limit grows ~0, and saturating is what a terrarium is supposed to
do. What compounding means here is that the sustainable SIZE rises, so
the honest test is two arms from one seed compared at the same clock.

## Testing

**A PIXEL GATE'S DETECTOR IS A CONSTRAINT ON THE ART.** Symptom: a colour
change that is obviously correct reddens an unrelated gate. `test-queencarry`
finds a live enemy queen by counting red ink (`g < r * 0.45`), and the queen
colour was a hardcoded `(0.96,0.40,0.30)` -> `g/r = 0.417`. Fixing queens to
wear their own side's colour (gold's queens were rendering RED, because the
literal only ever matched red) lightened red's queen to `g/r = 0.480` -- over
the threshold, so the gate could no longer see the thing it measures.

The fix was to retune the render (lighten by 0.20, not 0.28) rather than move
the threshold. 0.20 puts `g/r` back at 0.419, where the old literal sat, and
separates the queen from her own workers slightly BETTER than before (0.224
vs 0.204 RGB distance). Moving the threshold instead would have kept the gate
green while making it mean less: it is measuring a real property -- an enemy
queen is red and visible -- and a bound that moves whenever the art moves is
not a bound.


**A control that cannot fail is not a control.** Two of these silently
defanged themselves when the game changed: a famine test that zeroed
`food` stopped being a famine once sources regrew (it must zero `regrow`
and `cap` too), and a delivery control asserted `delivered == 0` for a
colony that legitimately forages without roads, just slowly.

**Assert relative facts, not literals.** `x1 < 100` for a node bound broke
the moment node radii were tuned. The real claim was "the bound grows when
the far node becomes known".

**A lifted finger is down -> INACTIVE, not down -> up.** The pointer loop
processed a slot only `if p.active`, which meant the release branch never
ran for touch: a finger leaving the glass clears the slot outright. Every
drag that ended by lifting produced NOTHING. A mouse hides this
completely -- slot 0 stays active with the button released -- so the
desktop playtest looked perfect while the primary verb would not have
worked on a phone at all. Any slot that was down last frame has to be
processed one more time.

**A slow drag must not become a long press.** The hold timer fired on
elapsed frames alone, and a finger whose movement had not yet been
REPORTED looked identical to one resting -- so a deliberate drag raised a
danger mark on its start node instead of sending ants. Latch a "has ever
moved" flag rather than testing current displacement.

Both of these were invisible to every desktop test and were found only
once the parity gate's two arms were aiming at the same KIND of target.
That is the argument for input-parity testing existing at all: the bugs
it finds are the ones a developer with a mouse cannot see.

**An invisible affordance loses to a visible one underneath it.** The
touch pause was an unmarked hotspot in the bottom-right corner -- which
is where the caste widget's bars live, so on a phone every tap there
adjusted a caste and the menu was simply unreachable. Nothing looked
broken: the tap did something plausible. Two rules came out of it: draw
the affordance, and derive the hit rect and the drawn rect from ONE
function so they cannot drift. The gate now asserts the pause button does
not overlap the widget, because "a tap that does something else
reasonable" is invisible in a screenshot.

**A whole-frame mean dilutes the thing you are measuring.** The palette
gate compared mean blue across the entire screenshot, but trails cover a
few percent of a frame that is mostly green soil -- so a large change on
the roads showed up as 1.9% overall and tripped a 2% threshold. Selecting
just the emissive pixels (r+g+b over a brightness cut) moved the measured
value from 34 to 104 and made the check both pass honestly and fail
loudly when the feature is disconnected. Measure the pixels the feature
actually owns.

**A blank capture is a FAILURE, not a measurement.** The palette gate
compares mean blue between two screenshots; a shot taken immediately
after a menu closed came back all black, and "blue went from 33.6 to
0.00" passed the *inverse* of the check while looking like a real
regression. Any pixel comparison needs a not-blank assertion on BOTH
frames first, and a few frames of settle after a UI mode change.

**A touch-only control needs every value REACHABLE.** Volume clamped at 4
and touch has no left/right -- a tap is a single "next" -- so once a
phone player raised the sound they could never lower it again. Touch
confirm now wraps; the pad keeps clamping left/right, where clamping is
the familiar behaviour and nothing is unreachable. Any "cycle to the next
value" control has this bug unless it wraps.

**A switch the cart cannot see is dead code that LOOKS like a feature.**
The gates needed to boot the generated map instead of the campaign, and
the first two attempts both silently never fired: a check for
`love.wasmcart.deterministic` (no such flag exists in the engine -- it
was invented) and then a magic seed, on the assumption that romdev's
`deterministicSeed` reaches the cart. It does not: it seeds the HOST rng,
and the cart draws its own seed from `love.math.random`, so the observed
seed was 135168 when the gate asked for 1. Both versions compiled, ran,
and quietly did nothing. The working mechanism is a build-time marker
file (`app/opengarden`, exactly like `app/testmode`) -- the choice is
made where the cart is packed, which is somewhere the harness actually
controls. Before writing a conditional on a host value, PRINT it from
inside the cart and check it is what you think.

**Ask the cart where things are.** A gate that hardcoded a drag target
landed on empty grass and reported "the pointer produces no intents" -- a
false negative about the game caused entirely by the test. The probe now
reports node screen positions and the driver reads them.

## romdev

**A BLACK PLAYTEST WINDOW: do not trust a screenshot.** Symptom: the window
is black, but `playtest({op:'status'})` says `running:true` at a healthy
60fps with the frame counter climbing, and `playtest({op:'framebuffer'})` /
`frame({op:'screenshot'})` come back showing the game rendering perfectly.
Every instrument says fine; the human's screen is black.

Those captures read the CART's own FBO. A GL-direct window presents by a
separate GPU blit. When the two disagree -- which is exactly this class of
bug -- the capture is a picture of a buffer nobody is looking at. Capture
the REAL window instead:

```sh
DISPLAY=:0 xwininfo -root -tree | grep '"<window title>' | grep node
DISPLAY=:0 import -window 0x<id> /tmp/real.png
```

Cost hours twice, and once led to telling the human their window was fine
while they were staring at black. Two distinct causes, both now fixed:

- **Another session tearing down a GL cart** blanked a live window in an
  unrelated session. `makeCurrent` lived only on webgl-node's wrapper
  object, which callers throw away in favour of the bare context, so
  wasmcart's teardown silently failed to switch contexts -- and GL object
  names are plain integers with no context identity, so its deletes
  destroyed another context's identically-numbered textures. Needs
  webgl-node >= 1.5.1 and wasmcart >= 0.24.0.
- **A `loadMedia` while a window is attached** left the window bound to the
  old, destroyed context. Needs romdevtools >= 0.129.0.

If it happens again on current versions, the cart log line to look for is
`@fx DISABLED` -- `render/fx.lua` degrades to the no-bloom path rather than
aborting the frame, so the game stays PLAYABLE and the broken state stays
inspectable instead of taking the window down with it.

Three more bugs found here, all written up in `internal-romdev/feedback/`:

- **`input({op:'set'})` axes are dropped for wasmcart.** The tool validates
  and forwards `{axes:{lx,ly}}`; `WasmcartHost._padFromInput` reads
  `src.leftX`. Every stick input arrives centred. The game accepts the
  d-pad for the same verbs, which is better design anyway.
- **A playtest window never starts if the host was bulk-stepped first.**
  `running:true`, advances ~2 frames, then `fps: 0` forever. Open the
  window BEFORE stepping.
- **`audioDebug({op:'record'})` captures silence for every wasmcart cart**,
  including a shipped human-verified one used as a control. The cart
  self-reports its mixer state instead.

**Never rebuild the cart while a gate suite is running.** Toggling
`app/testmode` and rebuilding to run the sim suite swaps `formix.wasc`
underneath whatever gate is mid-flight; the save gate then failed with
"no @save line" and "cart reported no @ui line", which reads exactly like
a broken save. Same class of problem as a shared romdev session: one
suite at a time, and no `./build.sh` until it finishes.

**Do not restart the shared romdev server from an agent shell.** Every
gate went red with `webgl-node: failed to create EGL context` after a
restart that looked successful -- the process bound the port and answered
`catalog`, but could not load a cart. The cause was in the server log,
not the gate output: `Invalid MIT-MAGIC-COOKIE-1 key`, i.e. the shell had
DISPLAY set but no X authority, so EGL could not initialise. A server
started that way is worse than a dead one: it responds to everything
except the thing you need. CLAUDE.md already says to check for a human
first; the reason it is a hard rule is that the environment a working
server was started in cannot be reproduced from here.

**Symptom split worth remembering:** `fetch failed` = the process is
gone; `EGL context` errors with a live port = it is running without a
display it can draw on. The first is a crash (read the cart log, it is
usually a Lua load error); the second is never the cart's fault.

**Give a long gate its own session.** romdev keeps emulator state per
session and will evict a host when another gate loads into the same one --
which killed the third year of a three-year run.

## Shaders and blending on this engine

**A shader runs on `rectangle`, but nothing composites against the
destination.** Two facts, both measured, that between them decide where any
screen-space effect can live:

- `setBlendMode("alpha")` DISCARDS a shader's alpha channel. A fragment
  returning alpha 0 still paints.
- `setBlendMode("multiply")` REPLACES the destination rather than
  modulating it. Proof: a shader returning a flat 0.5 grey, drawn over soil
  measuring ~20, produced 128 -- not 10.

The consequence is that a full-screen effect drawn as its OWN pass can only
paint over the picture; it can never darken or tint what is already there.
An effect that needs the scene has to live inside a pass that already holds
it -- for this cart, the composite in render/fx.lua, where the scene is a
variable and darkening it is ordinary arithmetic.

**Integer uniforms do not survive `send`.** `uniform int u_count` sent as 4
arrived as 0, so a `for` loop guarded by `if (i >= u_count) break;` exited
on its first iteration and the effect silently did nothing. The neighbouring
`vec3[]` array in the same shader came through perfectly. Use floats for
counts and compare with `float(i)`.

**Probe with a CONSTANT before debugging the maths.** Both of the above hid
behind "the effect renders nothing", which looks identical to bad geometry,
a bad coordinate space, or a bad blend mode -- and several hours went into
guessing between those. The probe that actually resolved it was making the
shader `return` a flat colour unconditionally: that separates "this code
never runs" from "this code runs and computes zero" in a single build.
Painting a suspect uniform into a colour channel narrows it the rest of the
way. Do this FIRST, not tenth.

## Fog of war

**Fog is in the mounds, not over them.** A mound renders as grey stone
until one of your ants is standing on it, and warms to earth when one
arrives -- so the coloured ground IS the ground you hold. `sim.updateVision`
sets `n.held` for exactly that (a friendly ant physically present), which is
narrower than `n.observed`: observed is also true for every neighbour of an
established colony, so it would light mounds nobody has walked on.

**Two signals, two questions.** Colour answers "am I here" and gates on
`held` (any ant of yours). MOVEMENT answers "does this place live" and gates
on `lit` (a queen). A mound with a squad standing on it is warm but still;
it only starts breathing once a colony is founded. Everything else on the
map is motionless, so the wobble reads as the one thing it means rather than
as ambience.

**Stone is mixed as its own colour.** Desaturating the earth tone gave a
dead putty grey; the shipped stone is deliberately COOL (blue-leading,
`~(47,50,58)`) and matched in VALUE to the earth (~51 vs ~50) so neither
dominates the frame -- they separate by hue. An earlier version sat brighter
than the earth and the eye went straight to the ground you do NOT hold,
which is backwards. Consequence for tests: a luminance probe sees no
difference between the two states. Measure SATURATION.

The previous layer-based fog is deleted rather than parked. It drew a dark
sheet and punched holes with a stack of concentric polygon discs, which
could not produce a clean edge at any setting: a 16-step alpha ramp is a
staircase, and the eye manufactures its own bands at every step boundary
(Mach bands), so adding steps made it worse rather than better. The shader
rewrite that would have fixed it could not be composited for the blending
reasons above.

**A sight radius wider than the map hides every fog bug.** Sight was
`W.reach` (~1153 world units) on a board 1856 wide -- one queen revealed
everything, so no fog implementation could ever have looked right. If fog
as a layer is ever revived, check that number FIRST: reach is the rule about
where you may send, which is a different question from how far you can see.

## The campaign

Four hand-built missions, each teaching one thing by the SHAPE of its map:

1. **Gather** -- no mound has ten ants but the board has twelve, so the
   only move that goes anywhere is to pull them together. Teaches that a
   send moves real ants and that ten of them buy production.
2. **Settle** -- ten ants and one queen. Ten buys exactly one queen, so
   spending them at the start leaves nothing to expand with; the level
   forces take -> fill -> queen -> let that one pay for the next. Done at
   four mounds each with a queen of its own.
3. **Neighbours** -- one red colony in the corner, ASLEEP until found.
   Opens exactly like Settle until the frontier touches red ground.
4. **War** -- two rival colonies (red and gold), both awake from the first
   second, both expanding into the neutral middle. They fight each other
   as well as you.

**Three things had to be built for this, and two of them were dead code.**

**The level transition never worked.** `menu.wantNextLevel` was set by the
menu and NOTHING consumed it, so "next field" silently did nothing and
every level after the first was unreachable in normal play. The old
campaign gate passed anyway, because it only asserted "some mounds exist"
and "you own some ground" -- both true of the PREVIOUS level still sitting
there. The gate now asserts the new level's actual shape (Settle starts
from one mound, not Gather's four), which fails against the old behaviour.

**START now means "next field" on a finished level.** The HUD had been
promising exactly that while START opened the pause menu.

**`app/opengarden` was dead too** -- build.sh wrote the marker and nothing
read it, so `--open` packed an ordinary cart. Both it and the new
`app/startlevel` (which boots straight into a named level, so a gate can
test the war map without playing three missions) are now read in main.lua.
Same lesson as the fog switch: a marker the cart cannot see is a feature
that only LOOKS like one -- print it from inside the cart before trusting.

**A sleeping enemy must not compound.** `wakeOnContact` kept the rival
BRAIN dormant, but its queens kept laying: an undiscovered colony went 8 ->
22 ants in forty idle seconds, so exploring carefully was punished with an
unwinnable wall. Sleeping now pauses the whole colony, not just decisions.

**A garrison scouts its own horizon.** Ants standing on a mound now see WHO
is on the mounds next door (`observed`), though the ground there stays dark
until a queen lights it (`lit`). Before this, discovery required settling
the bridge mound and queening it, so a squad could stand next to an enemy
colony and not notice it.

**One brain per side.** `sim.rivals` is a list; a single brain driving two
colonies would coordinate them into one opponent with two bodies. Separate
brains also means they fight each other, since each attacks the weakest
thing in its reach.

**One colour per side.** Red and gold have distinct rims AND ant colours.
Two enemies in the same red makes a three-way war unreadable -- you cannot
tell whose border you are on, or see them eating each other.
