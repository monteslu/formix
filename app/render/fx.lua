-- fx.lua - the post chain: bloom, grade, vignette.
--
-- The scene renders into an rgba16f canvas so the trail glow can go above
-- 1.0 and actually BLOOM rather than clipping to a flat bright stripe. Then:
--
--   scene(16f) -> bright-pass+downsample -> blur H -> blur V -> composite
--
-- Two small canvases at quarter resolution carry the blur, which is the
-- standard trick and the reason this costs about a millisecond instead of
-- ten. The composite also does the day/night grade and the vignette, so the
-- whole mood of a year is three uniforms on one full-screen pass.
--
-- GRACEFUL DEGRADATION IS DELIBERATE: if float canvases are not available
-- (a host without EXT_color_buffer_float), fx.available goes false and
-- render/init draws straight to the screen. The game must never REFUSE to
-- run because it cannot be pretty -- but it also must not silently pretend,
-- so the state is logged once and readable by a gate.

local M = {}

M.available = false
M.reason = "not initialised"

local sceneC, brightC, blurC
local brightS, blurS, compositeS
local W, H, BW, BH

-- Bright-pass + downsample in one: sampling the full-res scene into a
-- quarter-res target with a threshold. Doing them separately would cost an
-- extra full-resolution pass for nothing.
local BRIGHT_FRAG = [[
  uniform float u_threshold;
  uniform float u_knee;
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec3 c = Texel(tex, tc).rgb;
    float l = max(c.r, max(c.g, c.b));
    // Soft knee: a hard cutoff makes the bloom pop in and out as a value
    // crosses the threshold, which reads as flicker on a moving trail.
    float k = clamp((l - u_threshold) / max(1e-4, u_knee), 0.0, 1.0);
    return vec4(c * k * k, 1.0);
  }
]]

-- Separable gaussian, 9 taps. Direction is a uniform so ONE shader serves
-- both passes.
local BLUR_FRAG = [[
  uniform vec2 u_dir;         // texel-sized step, in one axis
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec3 sum = Texel(tex, tc).rgb * 0.2270270270;
    sum += Texel(tex, tc + u_dir * 1.3846153846).rgb * 0.3162162162;
    sum += Texel(tex, tc - u_dir * 1.3846153846).rgb * 0.3162162162;
    sum += Texel(tex, tc + u_dir * 3.2307692308).rgb * 0.0702702703;
    sum += Texel(tex, tc - u_dir * 3.2307692308).rgb * 0.0702702703;
    return vec4(sum, 1.0);
  }
]]

-- The composite: scene + bloom, tonemapped, graded by season and time of
-- day, vignetted. One pass, and the only place the final colour is decided.
local COMPOSITE_FRAG = [[
  uniform Image u_bloom;
  uniform float u_bloomAmount;
  uniform vec3  u_grade;      // per-channel multiplier (the season's cast)
  uniform float u_night;
  uniform float u_vignette;
  uniform vec2  u_res;

  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec3 c = Texel(tex, tc).rgb;
    vec3 b = Texel(u_bloom, tc).rgb;
    c += b * u_bloomAmount;

    // Reinhard-ish tonemap: the scene is HDR now, so something has to bring
    // it back into range, and a plain clamp would flatten every glow into
    // the same white.
    //
    // The rolloff is GENTLE (0.28, not 0.55). A strong one compresses the
    // midtones too -- the soil and the flora, which are already in range --
    // and the whole picture goes flat and grey while the glow it was meant
    // to tame barely changes. Only the top end needs bending.
    c = c / (1.0 + c * 0.28);

    c *= u_grade;

    // Night is a blue-shifted crush, never a black fade -- the colony has
    // to stay readable at 3am in game time.
    vec3 nightC = c * vec3(0.55, 0.66, 0.95);
    nightC = mix(nightC, vec3(dot(nightC, vec3(0.3, 0.59, 0.11))), 0.35);
    c = mix(c, nightC, u_night);

    vec2 d = (sc / u_res) - 0.5;
    c *= 1.0 - dot(d, d) * u_vignette;

    return vec4(c, 1.0);
  }
]]

function M.init(vp)
  W, H = math.floor(vp.w), math.floor(vp.h)
  BW, BH = math.floor(W / 4), math.floor(H / 4)

  -- Probe rather than assume: float renderability is an extension on
  -- WebGL2, and asking is cheap.
  local okScene, scene = pcall(love.graphics.newCanvas, W, H,
                               { format = "rgba16f" })
  if not okScene or not scene then
    M.available = false
    M.reason = "no rgba16f canvas (" .. tostring(scene) .. ")"
    print("@fx DISABLED " .. M.reason)
    return false
  end

  local okB, bright = pcall(love.graphics.newCanvas, BW, BH,
                            { format = "rgba16f" })
  local okBl, blur = pcall(love.graphics.newCanvas, BW, BH,
                           { format = "rgba16f" })
  if not (okB and okBl and bright and blur) then
    M.available = false
    M.reason = "no half-res float canvases"
    print("@fx DISABLED " .. M.reason)
    return false
  end

  local okS, err = pcall(function()
    brightS = love.graphics.newShader(BRIGHT_FRAG)
    blurS = love.graphics.newShader(BLUR_FRAG)
    compositeS = love.graphics.newShader(COMPOSITE_FRAG)
  end)
  if not okS then
    M.available = false
    M.reason = "shader compile failed: " .. tostring(err)
    print("@fx DISABLED " .. M.reason)
    return false
  end

  sceneC, brightC, blurC = scene, bright, blur
  M.available = true
  M.reason = "ok"
  print(string.format("@fx ENABLED %dx%d bloom %dx%d", W, H, BW, BH))
  return true
end

-- Begin drawing the scene into the HDR target.
function M.beginScene()
  if not M.available then return false end
  love.graphics.setCanvas(sceneC)
  -- A freshly bound target's contents are undefined; clear or the previous
  -- frame smears.
  love.graphics.clear(0, 0, 0, 1)
  return true
end

-- Resolve: bright-pass, blur, composite to the screen.
--   grade   {r,g,b} season cast
--   night   0..1
--   amount  bloom strength
function M.finish(grade, night, amount, vignette)
  if not M.available then return false end
  local g = love.graphics

  -- 1. bright pass, downsampling to quarter res
  g.setCanvas(brightC)
  g.clear(0, 0, 0, 1)
  g.setShader(brightS)
  -- The threshold sits just under 1.0 so ordinary in-range scenery (soil,
  -- petals, ant bodies) contributes nothing and only the deliberately
  -- over-bright emissive passes bloom. A lower threshold blooms the whole
  -- picture, which is the "everything is foggy" look, not a glow.
  brightS:send("u_threshold", 0.85)
  brightS:send("u_knee", 0.5)
  g.setColor(1, 1, 1, 1)
  g.draw(sceneC, 0, 0, 0, BW / W, BH / H)
  g.setShader()

  -- 2. blur H, then V, ping-ponging between the two small targets
  g.setCanvas(blurC)
  g.clear(0, 0, 0, 1)
  g.setShader(blurS)
  blurS:send("u_dir", { 1 / BW, 0 })
  g.draw(brightC, 0, 0)

  g.setCanvas(brightC)
  g.clear(0, 0, 0, 1)
  blurS:send("u_dir", { 0, 1 / BH })
  g.draw(blurC, 0, 0)
  g.setShader()

  -- 3. composite to the screen. setCanvas() with no argument returns to it.
  g.setCanvas()
  g.setShader(compositeS)
  compositeS:send("u_bloom", brightC)
  compositeS:send("u_bloomAmount", amount or 1.0)
  compositeS:send("u_grade", grade or { 1, 1, 1 })
  compositeS:send("u_night", night or 0)
  compositeS:send("u_vignette", vignette or 0.45)
  compositeS:send("u_res", { W, H })
  g.setColor(1, 1, 1, 1)
  -- FLIPPED BACK. A canvas has its origin at the BOTTOM-left in GL, and
  -- this engine does not compensate on the way out, so everything drawn
  -- into the scene target came out vertically mirrored: the world was
  -- upside down relative to the HUD, which is drawn after the composite
  -- and was therefore fine.
  --
  -- That is what made the d-pad feel inverted, and it is why it survived
  -- so many "fixes": pressing UP correctly picked the mound with the
  -- smaller world y, and the renderer then drew that mound at the BOTTOM
  -- of the screen. Every test that asked the sim where the cursor went
  -- agreed with itself and disagreed with the screen. Measured with a
  -- marker drawn at y=60..120 inside the pass, which appeared at y=990 on
  -- a 1080-tall screen -- an exact mirror about the centre.
  --
  -- FLIP THE FINISHED TARGET. A canvas has its origin at the bottom-left
  -- in GL, so the scene lands upside down; drawing it with a -1 y-scale
  -- from the bottom edge puts it back.
  --
  -- This CANNOT be done by flipping the transform in beginScene instead:
  -- the ground, bright-pass and composite are full-screen shader passes
  -- drawn in raw screen space, and a pushed flip breaks all three (the
  -- soil vanishes and stray geometry smears across the frame). The flip
  -- belongs to the blit, not to the drawing.
  --
  -- The consequence is that a screen position RECORDED during the scene
  -- pass is in flipped space. Anything painted after the composite from
  -- such a position must mirror it back -- see vp.unflip.
  g.draw(sceneC, 0, H, 0, 1, -1)
  g.setShader()
  return true
end

return M
