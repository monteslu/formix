-- ground.lua - the soil.
--
-- One full-screen quad through a fragment shader that sums a few octaves of
-- value noise. No texture, no asset, no upload: the whole floor of the world
-- costs one draw call and scales to any resolution for free. The day/night
-- tint and the season palette ride on uniforms, so the same shader carries
-- the entire mood arc of a year.

local M = {}

local shader, mesh
local t = 0

-- Palette per season, as (low, high) soil colours the shader mixes between.
-- Kept here rather than in the shader so the season transition can be
-- interpolated in Lua and sent as two colours.
local SEASON = {
  spring = { { 0.09, 0.13, 0.09 }, { 0.20, 0.28, 0.16 } },
  summer = { { 0.11, 0.12, 0.07 }, { 0.26, 0.27, 0.14 } },
  autumn = { { 0.13, 0.10, 0.07 }, { 0.28, 0.20, 0.11 } },
  winter = { { 0.09, 0.10, 0.13 }, { 0.19, 0.21, 0.26 } },
}

local FRAG = [[
  uniform vec2  u_cam;        // world-space camera centre
  uniform float u_scale;      // world units per pixel
  uniform vec2  u_res;
  uniform vec3  u_low;
  uniform vec3  u_high;
  uniform float u_night;      // 0 = day, 1 = night
  uniform float u_wet;        // 0 = dry, 1 = raining

  // Value noise. A hash of the integer lattice, smoothstep-interpolated.
  // Cheap, stable, and with three octaves it reads as soil rather than TV
  // static -- which one octave does.
  float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
  }
  float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
               mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
  }
  float fbm(vec2 p) {
    float v = 0.0, a = 0.5;
    for (int k = 0; k < 4; k++) {
      v += a * vnoise(p);
      p *= 2.03;      // not exactly 2: an exact double aligns the octaves
      a *= 0.5;       // into a visible grid
    }
    return v;
  }

  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    // Screen -> world, so the ground scrolls with the camera instead of
    // sticking to the screen (which reads as a moving background, the
    // single most obvious tell of a fake world).
    vec2 w = (sc - u_res * 0.5) / u_scale + u_cam;

    float n  = fbm(w * 0.0032);
    float n2 = fbm(w * 0.021 + 17.0);
    float g = clamp(n * 0.75 + n2 * 0.25, 0.0, 1.0);

    vec3 col = mix(u_low, u_high, g);

    // GRAIN AND LITTER FROM ONE LOOKUP. Both want high-frequency noise, and
    // this shader runs per pixel over the whole screen -- the first version
    // spent three extra vnoise() calls here (~6M a frame at 1080p) and cost
    // 9fps for detail that is deliberately subtle. One sample feeds both:
    // its value drives the grain, and its top decile is the litter. They
    // correlate, which is invisible at this contrast and free.
    float fine = vnoise(w * 0.42);
    col *= 0.94 + fine * 0.12;
    float litter = smoothstep(0.90, 0.99, fine);
    col = mix(col, col * vec3(0.62, 0.66, 0.55), litter * 0.55);

    // Damp patches where the noise pools, stronger in rain.
    float damp = smoothstep(0.62, 0.95, n) * (0.25 + u_wet * 0.75);
    col = mix(col, col * vec3(0.72, 0.80, 0.92), damp);

    // NIGHT AND VIGNETTE ARE NOT APPLIED HERE. Both belong to the post
    // composite (render/fx.lua), which sees the whole scene -- if the
    // ground darkened itself and the composite darkened everything again,
    // dusk would fall twice as fast on the soil as on the ants standing on
    // it. u_night stays as a uniform because the damp-patch look does
    // legitimately change at night; it just must not dim.
    col = mix(col, col * vec3(0.88, 0.92, 1.04), u_night * 0.5);

    return vec4(col, 1.0);
  }
]]

function M.init(vp)
  shader = love.graphics.newShader(FRAG)
end

-- ONE PALETTE, no seasons. Seasons belonged to the terrarium game this
-- stopped being; more importantly the ground must be DARK and quiet so
-- that the units and the mounds are the only bright things on screen. A
-- lit green lawn competes with everything drawn on top of it.
--
-- BUT DARK IS NOT BLACK, and the first pass at this overshot badly: at
-- 4.5%-11.5% luminance the soil was RGB 12-30, which has structure but no
-- COLOUR -- the noise was visible and the earth was not. The fog sheet
-- then takes another third out of it, so unlit ground was reading as a
-- black screen with mounds floating on it.
--
-- The band below is roughly double, which is still far under the mounds
-- (0.36-0.52) and the ants (amber, ~0.85), so nothing competes: the soil
-- reads as damp earth with a green cast, and the bright things on top of
-- it are still the only bright things.
local SOIL_LO = { 0.085, 0.098, 0.070 }
local SOIL_HI = { 0.215, 0.235, 0.165 }

function M.draw(snap, vp)
  local lo, hi = SOIL_LO, SOIL_HI
  local night = 0

  love.graphics.setShader(shader)
  shader:send("u_cam", { vp.cam.x, vp.cam.y })
  shader:send("u_scale", vp.worldScale())
  shader:send("u_res", { vp.w, vp.h })
  shader:send("u_low", lo)
  shader:send("u_high", hi)
  shader:send("u_night", night)
  shader:send("u_wet", 0)   -- no weather in this game (yet)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, vp.w, vp.h)
  love.graphics.setShader()

  M.night = night

  -- On a host with no float canvas the post composite never runs, so
  -- nothing else would ever apply the night grade. Do it here as a plain
  -- overlay: dimmer than the HDR version and without the blue shift, but
  -- the alternative is a world where the sun never sets.
  if not require("render.fx").available and night > 0.01 then
    love.graphics.setColor(0.04, 0.06, 0.14, night * 0.45)
    love.graphics.rectangle("fill", 0, 0, vp.w, vp.h)
    love.graphics.setColor(1, 1, 1, 1)
  end
end

return M
