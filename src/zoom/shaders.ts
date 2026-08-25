// GLSL for the escape-time relief renderer.
//
// Two passes:
//   FIELD  — one Mandelbrot/Julia evaluation per texel into an RGBA16F tile. Re-runs only
//            when the complex window moves, so a still view costs nothing per frame.
//   RELIEF — per eye, ray-march that tile as a height field inside a slab. Cheap texture
//            fetches, so both eyes get true parallax instead of a flat poster.

// ---- field pass (raw fullscreen, GLSL ES 3.00) -----------------------------
export const FIELD_FRAG = /* glsl */ `
precision highp float;
precision highp int;

uniform vec2  uCenterHi;     // complex-plane centre, float32 head
uniform vec2  uCenterLo;     // ...and the double-precision tail we can still salvage
uniform float uScale;        // half-width of the window, in complex units
uniform float uRes;          // field texture resolution (square)
uniform int   uMaxIter;
uniform vec2  uJuliaC;
uniform float uJulia;        // 1 = Julia (c fixed, z0 = pixel), 0 = Mandelbrot
uniform float uRidge;        // 0 = terraces from iteration count, 1 = ridges from distance
uniform float uTerraceGamma;
uniform float uRidgeWidth;   // ridge falloff, measured in field texels (zoom-invariant)
uniform float uColorCycles;
uniform float uColorShift;
uniform int   uSamples;      // sub-texel grid per side: 1 while moving, 3 once settled
uniform float uTexOn;        // 1 = accumulate the orbit texture, 0 = skip it entirely
uniform float uInvert;       // 0 = set stands proud, 1 = set is the pit and the filigree incises

out vec4 outField;

const float ESC2 = 65536.0;        // escape radius squared (256²) — large radius, smooth count
const float LOG_ESC = 5.5451774;   // log(256)

vec2 cmul(vec2 a, vec2 b){ return vec2(a.x*b.x - a.y*b.y, a.x*b.y + a.y*b.x); }

// The escape-time core, deliberately isolated: swapping in perturbation (CPU reference orbit
// + fp32 delta iteration) for unlimited zoom depth replaces this function and nothing else.
//
// Returns (smoothIter, distanceEstimate, insideFlag, triangleInequalityAverage).
//
// The fourth channel is the texture. Iteration count is near-constant across the big smooth
// regions, which is exactly why they look dead: there is no signal there to colour or shade.
// But the ORBIT still moves, and the triangle inequality average measures where each step
// lands between the bounds |z²|-|c| and |z²|+|c| that the triangle inequality allows. It
// varies richly precisely where the escape count does not — so it puts marbled structure into
// the flats without touching the boundary detail.
vec4 escape(vec2 c, vec2 z0){
  vec2 z = z0;
  vec2 dz = vec2(1.0, 0.0);                              // dz/dc — feeds the distance estimate
  vec2 addC = (uJulia > 0.5) ? vec2(0.0) : vec2(1.0, 0.0);
  float ac = length((uJulia > 0.5) ? uJuliaC : c);       // |c|, the width of the allowed band
  float m2 = dot(z, z);
  float sum = 0.0;   // running TIA up to n
  float sumPrev = 0.0; // ...and up to n-1, so the result can be interpolated smoothly
  float count = 0.0;
  float minR2 = 1e30; // closest the orbit ever comes to the origin — the interior's texture
  int n = 0;
  for(int i = 0; i < uMaxIter; i++){
    vec2 zp = z;
    dz = 2.0 * cmul(z, dz) + addC;
    z  = cmul(z, z) + c;
    m2 = dot(z, z);
    minR2 = min(minR2, m2);
    n = i + 1;
    // Roughly doubles the cost of the inner loop (a sqrt plus a handful of ops on a body of
    // about fifteen), so it is gated on a uniform — uniform control flow, no divergence, and
    // turning the texture off gets the original speed back exactly.
    // Skip the first couple of steps too: they are dominated by the seed and only add noise.
    if(uTexOn > 0.5 && i > 1){
      float azp2 = dot(zp, zp);                          // |zp²| = |zp|²
      float lo = abs(azp2 - ac);
      float hi = azp2 + ac;
      float t = (sqrt(m2) - lo) / max(1e-12, hi - lo);
      sumPrev = sum;
      sum += clamp(t, 0.0, 1.0);
      count += 1.0;
    }
    if(m2 > ESC2) break;
  }
  float avg1 = count > 0.0 ? sum / count : 0.0;
  float avg0 = count > 1.0 ? sumPrev / (count - 1.0) : avg1;

  // Inside the set, TIA barely varies — the orbit is bounded and the average washes out, which
  // is why the interior stays a dead flat plate. The classic orbit trap works there instead:
  // how close the orbit ever came to the origin. Nominally 0..1, same band as TIA, so the two
  // share one normalisation.
  if(m2 <= ESC2) return vec4(float(uMaxIter), 0.0, 1.0, clamp(sqrt(minR2), 0.0, 1.0));
  float lm = log(m2) * 0.5;                              // log|z|
  float s  = float(n) - log2(lm / LOG_ESC);              // fractional iteration count
  float de = sqrt(m2) * lm / max(1e-20, length(dz));     // Milnor/Koebe distance to the set
  // interpolate between the two running averages by the fractional escape, or the texture
  // bands as hard as the raw iteration count does
  float tia = mix(avg0, avg1, clamp(s - floor(s), 0.0, 1.0));
  return vec4(s, de, 0.0, tia);
}

void main(){
  float pixel = 2.0 * uScale / uRes;      // complex units per field texel

  // Supersample. Near the boundary the escape count changes faster than one texel, so a
  // single sample per texel is pure aliasing — it is what puts salt-and-pepper across the
  // filigree. Averaging s and the distance estimate (not the derived height/colour, which
  // are non-linear and hue-wrapping) is what actually resolves it.
  float sumS = 0.0, sumDE = 0.0, sumIn = 0.0, sumTia = 0.0;
  float inv = 1.0 / float(uSamples);
  for(int sy = 0; sy < 3; sy++){
    if(sy >= uSamples) break;
    for(int sx = 0; sx < 3; sx++){
      if(sx >= uSamples) break;
      vec2 jit = (vec2(float(sx), float(sy)) + 0.5) * inv - 0.5;
      vec2 uv  = (gl_FragCoord.xy + jit) / uRes;
      vec2 d   = (uv * 2.0 - 1.0) * uScale;
      // add the tail before the head: the small terms survive the round into the head's
      // exponent, which stops the grid drifting as you pan. It buys no extra zoom depth.
      vec2 p   = (d + uCenterLo) + uCenterHi;
      vec4 e   = escape((uJulia > 0.5) ? uJuliaC : p, (uJulia > 0.5) ? p : vec2(0.0));
      sumS  += e.x;
      sumDE += e.y;
      sumIn += e.z;
      sumTia += e.w;
    }
  }
  float w  = inv * inv;
  float s  = sumS * w;
  float de = sumDE * w;
  float ins = sumIn * w;                  // fractional — gives the set an antialiased edge
  float tia = sumTia * w;

  float t     = pow(clamp(s / float(uMaxIter), 0.0, 1.0), uTerraceGamma);
  float ridge = exp(-(de / pixel) / max(0.001, uRidgeWidth));
  float h     = clamp(mix(t, ridge, uRidge), 0.0, 1.0);
  h = mix(h, 1.0 - h, uInvert);           // flip the relief: mesa becomes chasm, ridges become grooves

  // cycle on log(iterations) so the palette keeps moving at every zoom depth
  float ci = fract(uColorShift + uColorCycles * log(1.0 + s) * 0.15);

  outField = vec4(h, ci, ins, clamp(tia, 0.0, 1.0));
}
`

// ---- height-range reduction (raw fullscreen, 4x4 per pass) -----------------
export const REDUCE_FRAG = /* glsl */ `
precision highp float;
uniform sampler2D uSrc;
uniform int uFirst;          // 1 = reading the field, 0 = reading a partial reduction
uniform int uChannel;        // which field channel to measure: 0 = height, 3 = orbit texture
out vec4 outRange;
// (min, max, sum, sum of squares). Min and max describe the extremes; the sums give a mean and
// a standard deviation, and those two are AVERAGES — so unlike the extremes they do not drift
// as the tile resolution changes. That is what keeps apparent relief height the same when you
// step the resolution up.
void main(){
  ivec2 o = ivec2(gl_FragCoord.xy) * 4;
  float lo =  1e30;
  float hi = -1e30;
  float sum = 0.0;
  float sq  = 0.0;
  for(int y = 0; y < 4; y++){
    for(int x = 0; x < 4; x++){
      vec4 s = texelFetch(uSrc, o + ivec2(x, y), 0);
      if(uFirst == 1){
        float v = s[uChannel];
        lo = min(lo, v);
        hi = max(hi, v);
        sum += v;
        sq  += v * v;
      } else {
        lo = min(lo, s.r);
        hi = max(hi, s.g);
        sum += s.b;
        sq  += s.a;
      }
    }
  }
  outRange = vec4(lo, hi, sum, sq);
}
`

// ---- relief pass (ShaderMaterial + GLSL3; three declares the built-in uniforms) ----
export const RELIEF_VERT = /* glsl */ `
out vec3 vLocal;
out vec3 vEyeLocal;
void main(){
  vLocal = position;
  // cameraPosition is set per sub-camera, so each eye marches from its own origin
  vEyeLocal = (inverse(modelMatrix) * vec4(cameraPosition, 1.0)).xyz;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
}
`

export const RELIEF_FRAG = /* glsl */ `
precision highp float;

in vec3 vLocal;
in vec3 vEyeLocal;

uniform sampler2D uField;
uniform sampler2D uPalette;
uniform vec3  uHalf;         // slab half-extents, metres
uniform float uRes;          // field resolution
uniform int   uSteps;        // march steps through the slab
uniform vec3  uLightDir;
uniform float uNormalWidth;  // gradient baseline, in texels
uniform float uShadow;
uniform float uSpecular;
uniform float uAmbient;
uniform float uExposure;
uniform vec3  uInsideColor;
uniform float uHeightLo;     // measured range of the tile, stretched across the full slab
uniform float uHeightHi;
uniform float uHeightCurve;  // 0 = linear, up to 2 = hard S-curve
uniform float uTexAmt;       // orbit-trap texture: colour modulation, 0..1
uniform float uTexBump;      // ...and how much it perturbs the surface normal
uniform float uTexLo;        // measured range of the orbit texture across the tile
uniform float uTexHi;

// re-declared here so the hit point can be written to the depth buffer; three sets both
// per object and per (sub-)camera, so they are correct for each eye.
uniform mat4 projectionMatrix;
uniform mat4 modelViewMatrix;

out vec4 outColor;

vec2  uvOf(vec3 p){ return p.xy / (2.0 * uHalf.xy) + 0.5; }
// Raw TIA clusters in a narrow band, so unnormalised it is a faint wash. Stretching it over
// the range actually present in the tile is what turns it from a tint into a texture.
float tiaAt(vec2 uv){
  float t = texture(uField, clamp(uv, 0.0, 1.0)).a;
  return clamp((t - uTexLo) / max(1e-4, uTexHi - uTexLo), 0.0, 1.0);
}

float heightAt(vec2 uv){
  float h = texture(uField, clamp(uv, 0.0, 1.0)).r;
  float t = clamp((h - uHeightLo) / max(1e-4, uHeightHi - uHeightLo), 0.0, 1.0);
  // An S-curve steepens the MIDDLE of the range and flattens both ends. The set interior sits
  // at one end and the far exterior at the other, both of them large and smooth; the filigree
  // is the band between. So this spends the slab on the fractal instead of on its two
  // plateaus, which is what stops the interesting part getting lost.
  float s1 = t * t * (3.0 - 2.0 * t);
  t = mix(t, s1, min(uHeightCurve, 1.0));
  if(uHeightCurve > 1.0){
    float s2 = t * t * (3.0 - 2.0 * t);
    t = mix(t, s2, uHeightCurve - 1.0);
  }
  return t;
}
// Lift the base a hair off the slab floor. At height exactly 0 the surface sits ON the bottom
// face, where the march's below-surface test never fires, and the region renders as a hole
// straight through the panel. An inverted set (interior height 0) does exactly that.
float surfZ(vec2 uv){ return -uHalf.z + (0.006 + 0.994 * heightAt(uv)) * 2.0 * uHalf.z; }

// ray/AABB slab test, guarded against axis-parallel rays
vec2 slab(vec3 ro, vec3 rd){
  vec3 s = vec3(rd.x < 0.0 ? -1.0 : 1.0, rd.y < 0.0 ? -1.0 : 1.0, rd.z < 0.0 ? -1.0 : 1.0);
  vec3 inv = s / max(abs(rd), vec3(1e-6));
  vec3 a = (-uHalf - ro) * inv;
  vec3 b = ( uHalf - ro) * inv;
  vec3 lo = min(a, b), hi = max(a, b);
  return vec2(max(max(lo.x, lo.y), lo.z), min(min(hi.x, hi.y), hi.z));
}

void main(){
  vec3 ro = vEyeLocal;
  vec3 rd = normalize(vLocal - vEyeLocal);

  vec2 tt = slab(ro, rd);
  float tN = max(tt.x, 0.0);
  float tF = tt.y;
  if(tF <= tN) discard;

  // Linear march down to the first sample below the surface, then bisect. The step divisor
  // is uSteps-1 so the LAST sample lands exactly on the exit point: a surface sitting near
  // the slab floor is otherwise stepped straight over, and the panel shows a hole.
  float dt = (tF - tN) / float(uSteps - 1);
  float t = tN, tPrev = tN;
  bool hit = false;
  for(int i = 0; i < uSteps; i++){
    vec3 p = ro + rd * t;
    if(p.z - surfZ(uvOf(p)) < 0.0){ hit = true; break; }
    tPrev = t;
    t += dt;
  }
  if(!hit) discard;                    // ray passed clean over the relief — see through it

  float lo = tPrev, hi = t;            // (collapses to tN for a grazing entry through a cliff)
  for(int i = 0; i < 6; i++){
    float m = 0.5 * (lo + hi);
    vec3 p = ro + rd * m;
    if(p.z - surfZ(uvOf(p)) < 0.0) hi = m; else lo = m;
  }
  vec3 hitP = ro + rd * hi;
  vec2 uv = uvOf(hitP);

  // normal from a wide finite difference: the extra baseline keeps the half-float height
  // quantisation out of the shading, and softens the relief in a way that flatters it
  float e = uNormalWidth / uRes;
  float hL = heightAt(uv - vec2(e, 0.0)), hR = heightAt(uv + vec2(e, 0.0));
  float hD = heightAt(uv - vec2(0.0, e)), hU = heightAt(uv + vec2(0.0, e));
  float dzdx = (hR - hL) * uHalf.z / (2.0 * e * uHalf.x);
  float dzdy = (hU - hD) * uHalf.z / (2.0 * e * uHalf.y);
  vec3 n = normalize(vec3(-dzdx, -dzdy, 1.0));

  vec4 f = texture(uField, uv);

  // The orbit-trap texture. It carries structure through the big smooth regions, where the
  // escape count is flat and there is otherwise nothing for the light to catch. Two effects:
  // a small palette shift plus a luminance modulation, and a fine bump on the surface normal.
  // The bump is the one that matters — a flat region with a constant normal is lit uniformly,
  // which is precisely what makes it read as dead.
  float tex = clamp((f.a - uTexLo) / max(1e-4, uTexHi - uTexLo), 0.0, 1.0);
  if(uTexBump > 0.0){
    float tL = tiaAt(uv - vec2(e, 0.0)), tR = tiaAt(uv + vec2(e, 0.0));
    float tD = tiaAt(uv - vec2(0.0, e)), tU = tiaAt(uv + vec2(0.0, e));
    vec2 g = vec2(tR - tL, tU - tD) / (2.0 * e);
    n = normalize(n - vec3(g, 0.0) * uTexBump);
  }

  float idx = fract(f.g + uTexAmt * 0.10 * (tex - 0.5));
  vec3 base = mix(texture(uPalette, vec2(idx, 0.5)).rgb, uInsideColor, clamp(f.b, 0.0, 1.0));
  base *= mix(1.0, 0.45 + 1.15 * tex, uTexAmt);

  vec3 L = normalize(uLightDir);
  vec3 V = normalize(ro - hitP);
  vec3 H = normalize(L + V);
  float ndl  = max(dot(n, L), 0.0);
  float wrap = ndl * 0.75 + 0.25;                              // half-lambert keeps colour in shadow
  float spec = pow(max(dot(n, H), 0.0), 48.0) * uSpecular;
  float rim  = pow(1.0 - max(dot(n, V), 0.0), 3.0);

  float sh = 1.0;
  if(uShadow > 0.0){
    vec3 sp = hitP + n * (uHalf.z * 0.02);
    float sdt = (uHalf.x * 0.6) / 16.0;
    for(int i = 1; i <= 16; i++){
      vec3 q = sp + L * (sdt * float(i));
      if(q.z > uHalf.z || abs(q.x) > uHalf.x || abs(q.y) > uHalf.y) break;
      if(q.z < surfZ(uvOf(q))){ sh = 1.0 - uShadow; break; }
    }
  }

  // cheap cavity term: sit lower than your wider neighbourhood and you go darker
  float wide = 6.0 * e;
  float hAvg = 0.25 * (heightAt(uv + vec2(wide, 0.0)) + heightAt(uv - vec2(wide, 0.0))
                     + heightAt(uv + vec2(0.0, wide)) + heightAt(uv - vec2(0.0, wide)));
  float ao = clamp(1.0 - 1.7 * max(0.0, hAvg - f.r), 0.22, 1.0);

  vec3 col = base * (uAmbient + wrap * sh * 1.15) * ao
           + vec3(spec * sh)
           + base * rim * 0.35;
  col *= uExposure;
  col = col / (1.0 + col);                    // soft rolloff so highlights don't clip flat
  outColor = vec4(pow(col, vec3(1.0 / 2.2)), 1.0);

  vec4 clip = projectionMatrix * modelViewMatrix * vec4(hitP, 1.0);
  gl_FragDepth = 0.5 + 0.5 * (clip.z / clip.w);
}
`
