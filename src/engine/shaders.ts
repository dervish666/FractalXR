// All GLSL is GLSL ES 3.00 (WebGL2). Used with RawShaderMaterial({ glslVersion: GLSL3 }),
// so three.js prepends `#version 300 es` — we must NOT add it, but must declare precision
// and any built-in uniforms/attributes we use (modelViewMatrix, projectionMatrix, position).

const PCG = /* glsl */ `
uint hash(inout uint s){ s = s*747796405u + 2891336453u; uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u; return (w >> 22u) ^ w; }
float rnd(inout uint s){ return float(hash(s)) * (1.0 / 4294967296.0); }
// uniform random point in a ball of radius R (spherically symmetric — no boxy artifact)
vec3 randBall(inout uint s, float R){
  float u = rnd(s) * 2.0 - 1.0;
  float phi = rnd(s) * 6.2831853;
  float r = pow(rnd(s), 0.3333333) * R;
  float st = sqrt(max(0.0, 1.0 - u * u));
  return r * vec3(st * cos(phi), st * sin(phi), u);
}
`

// ---- fullscreen passthrough (raw) -----------------------------------------
export const RAW_VERT = /* glsl */ `
precision highp float;
in vec3 position;
void main(){ gl_Position = vec4(position, 1.0); }
`

// ---- seed: scatter every particle to a fresh point ------------------------
export const SEED_FRAG = /* glsl */ `
precision highp float;
precision highp int;
uniform float uTexSize;
out vec4 outState;
${PCG}
void main(){
  ivec2 ip = ivec2(gl_FragCoord.xy);
  uint seed = uint(ip.y) * uint(uTexSize) + uint(ip.x);
  seed = seed * 747796405u + 101u;
  vec3 p = randBall(seed, 0.5);
  outState = vec4(p, rnd(seed));
}
`

// ---- update: K chaos-game iterations per particle -------------------------
export const UPDATE_FRAG = /* glsl */ `
precision highp float;
precision highp int;
#define MAXT 8
#define NVAR 5
uniform sampler2D uState;
uniform float uTexSize;
uniform float uFrame;
uniform int uNumT;
uniform int uIters;
uniform float uReseedProb;
uniform vec3 uArow0[MAXT];
uniform vec3 uArow1[MAXT];
uniform vec3 uArow2[MAXT];
uniform vec3 uB[MAXT];
uniform float uCdf[MAXT];
uniform float uColor[MAXT];
uniform float uVar[MAXT * NVAR];
out vec4 outState;
${PCG}

vec3 vSpherical(vec3 p){ float r2 = dot(p, p) + 1e-9; return p / r2; }
vec3 vSwirl(vec3 p){ float r2 = p.x*p.x + p.y*p.y; float s = sin(r2), c = cos(r2); return vec3(p.x*s - p.y*c, p.x*c + p.y*s, p.z); }
vec3 vSinusoidal(vec3 p){ return sin(p); }
vec3 vBubble(vec3 p){ float r2 = dot(p, p); float f = 4.0 / (r2 + 4.0); return p * f; }

vec3 applyVars(int j, vec3 p){
  vec3 v = vec3(0.0);
  float w;
  w = uVar[j*NVAR + 0]; if(w != 0.0) v += w * p;
  w = uVar[j*NVAR + 1]; if(w != 0.0) v += w * vSpherical(p);
  w = uVar[j*NVAR + 2]; if(w != 0.0) v += w * vSwirl(p);
  w = uVar[j*NVAR + 3]; if(w != 0.0) v += w * vSinusoidal(p);
  w = uVar[j*NVAR + 4]; if(w != 0.0) v += w * vBubble(p);
  return v;
}

void main(){
  ivec2 ip = ivec2(gl_FragCoord.xy);
  vec2 uv = (vec2(ip) + 0.5) / uTexSize;
  vec4 s = texture(uState, uv);
  vec3 pos = s.xyz;
  float col = s.w;

  uint seed = uint(ip.y) * uint(uTexSize) + uint(ip.x);
  seed = seed * 747796405u + uint(uFrame) * 2654435761u + 1u;

  for(int it = 0; it < 8; it++){
    if(it >= uIters) break;
    bool bad = !(pos.x == pos.x) || !(pos.y == pos.y) || !(pos.z == pos.z) || dot(pos, pos) > 36.0;
    if(bad || rnd(seed) < uReseedProb){
      pos = randBall(seed, 0.5);
      col = rnd(seed);
      continue;
    }
    float t = rnd(seed);
    int j = uNumT - 1;
    for(int k = 0; k < MAXT; k++){ if(k >= uNumT) break; if(t < uCdf[k]){ j = k; break; } }
    vec3 p = vec3(dot(uArow0[j], pos), dot(uArow1[j], pos), dot(uArow2[j], pos)) + uB[j];
    pos = applyVars(j, p);
    col = col * 0.4 + uColor[j] * 0.6; // higher colour-speed → colour tracks the recent transform = distinct colour regions
  }
  outState = vec4(pos, col);
}
`

// ---- bulb update: relax particles onto a Mandelbulb/Juliabulb surface ------
// Same texel layout as UPDATE_FRAG (pos.xyz + colorIndex) so FlamePoints/Compositor
// are untouched — only the iterator differs. Each particle Newton-projects onto the
// DE=0 isosurface (the Green-function distance estimate never overshoots), then wanders
// tangentially so the shell fills and shimmers instead of freezing.
export const BULB_UPDATE_FRAG = /* glsl */ `
precision highp float;
precision highp int;
uniform sampler2D uState;
uniform float uTexSize;
uniform float uFrame;
uniform float uReseedProb;
uniform float uPower;      // polynomial power (8 = classic Mandelbulb)
uniform vec3 uJuliaC;      // Julia constant (used when uMandelbulb < 0.5)
uniform float uMandelbulb; // 1 = c = p (Mandelbulb/box), 0 = Julia (c = uJuliaC)
uniform float uFormula;    // 0 = Mandelbulb, 1 = Mandelbox
uniform float uScale;      // Mandelbox scale (negative gives the "architectural" look)
uniform float uMinR;       // Mandelbox sphere-fold min radius
uniform float uFixedR;     // Mandelbox sphere-fold fixed radius
uniform float uBound;      // seed / reseed ball radius (per formula)
uniform float uProjSteps;  // Newton projection steps toward the surface
uniform float uJitter;     // tangential wander amount
out vec4 outState;
${PCG}

// Mandelbulb / Juliabulb distance estimate (trig form, IQ/Hvidtfeldt).
// Returns (distance, orbitTrapR, orbitTrapY) — the traps drive colour.
vec4 mandelbulbDE(vec3 p){
  vec3 z = p;
  vec3 c = (uMandelbulb > 0.5) ? p : uJuliaC;
  float dr = 1.0;
  float r = length(z);
  float trapR = 1e10, trapY = 1e10;
  float esc = 0.0;
  for(int i = 0; i < 8; i++){
    r = length(z);
    if(r > 2.0){ esc = 1.0; break; }
    float rr = max(r, 1e-9);
    float theta = acos(clamp(z.z / rr, -1.0, 1.0));
    float phi = atan(z.y, z.x);
    dr = pow(rr, uPower - 1.0) * uPower * dr + 1.0;
    float zr = pow(rr, uPower);
    theta *= uPower; phi *= uPower;
    z = zr * vec3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta)) + c;
    trapR = min(trapR, length(z));
    trapY = min(trapY, abs(z.y));
  }
  float d = 0.5 * log(max(r, 1e-9)) * r / max(dr, 1e-6);
  return vec4(d, trapR, trapY, esc);
}

// Mandelbox distance estimate: box fold + sphere fold + scale (linear DE).
// Negative uScale gives the classic "architectural / branching" look.
vec4 mandelboxDE(vec3 p){
  vec3 offset = (uMandelbulb > 0.5) ? p : uJuliaC;
  vec3 z = p;
  float dr = 1.0;
  float trapR = 1e10, trapY = 1e10;
  float minR2 = uMinR * uMinR;
  float fixedR2 = uFixedR * uFixedR;
  float esc = 0.0;
  for(int i = 0; i < 10; i++){
    z = clamp(z, -1.0, 1.0) * 2.0 - z;             // box fold
    float r2 = dot(z, z);
    if(r2 < minR2){ float t = fixedR2 / minR2; z *= t; dr *= t; }       // sphere fold (inner)
    else if(r2 < fixedR2){ float t = fixedR2 / r2; z *= t; dr *= t; }   // sphere fold (shell)
    z = uScale * z + offset;
    dr = dr * abs(uScale) + 1.0;
    if(dot(z, z) > 36.0){ esc = 1.0; break; }      // orbit escaped → outside the set
    trapR = min(trapR, length(z));
    trapY = min(trapY, abs(z.y));
  }
  return vec4(length(z) / max(abs(dr), 1e-6), trapR, trapY, esc);
}

// dispatch on the selected formula. .x=distance, .yz=orbit traps, .w=escaped (1/0)
vec4 de(vec3 p){
  return (uFormula > 0.5) ? mandelboxDE(p) : mandelbulbDE(p);
}

vec3 deGrad(vec3 p, float e){
  vec2 k = vec2(1.0, -1.0);
  return normalize(
    k.xyy * de(p + k.xyy * e).x +
    k.yyx * de(p + k.yyx * e).x +
    k.yxy * de(p + k.yxy * e).x +
    k.xxx * de(p + k.xxx * e).x);
}

void main(){
  ivec2 ip = ivec2(gl_FragCoord.xy);
  vec2 uv = (vec2(ip) + 0.5) / uTexSize;
  vec4 s = texture(uState, uv);
  vec3 pos = s.xyz;
  float col = s.w;

  uint seed = uint(ip.y) * uint(uTexSize) + uint(ip.x);
  seed = seed * 747796405u + uint(uFrame) * 2654435761u + 1u;

  float bsq = uBound * uBound * 4.0; // generous escape bound (scales with the object)
  float e = 0.0012 * uBound;         // gradient epsilon scales with object size

  bool bad = !(pos.x == pos.x) || !(pos.y == pos.y) || !(pos.z == pos.z) || dot(pos, pos) > bsq;
  if(bad || rnd(seed) < uReseedProb){
    pos = randBall(seed, uBound); // scatter into the bounding ball
  }

  // Newton-project toward the surface. For the box, aim a thin shellEps OUTSIDE the
  // surface (DE>0) — this repels the spurious interior zeros (the core blob) instead of
  // collapsing onto them. For the bulb shellEps=0 (project straight onto the shell).
  float shellEps = (uFormula > 0.5) ? 0.012 * uBound : 0.0;
  vec4 d = de(pos);
  for(int i = 0; i < 6; i++){
    if(float(i) >= uProjSteps) break;
    d = de(pos);
    pos -= deGrad(pos, e) * (d.x - shellEps);
  }

  // wander tangentially so the shell fills uniformly and shimmers (stays alive)
  vec3 n = deGrad(pos, e);
  vec3 t1 = normalize(cross(n, vec3(0.0, 0.0, 1.0) + vec3(1e-3)));
  vec3 t2 = cross(n, t1);
  pos += (t1 * (rnd(seed) * 2.0 - 1.0) + t2 * (rnd(seed) * 2.0 - 1.0)) * uJitter * uBound;

  col = clamp(d.y * 0.7 + d.z * 0.5, 0.0, 1.0); // orbit-trap banding

  // Mandelbox: recycle interior points (orbit never escaped) so they don't pile on the core
  if(uFormula > 0.5 && d.w < 0.5) pos = randBall(seed, uBound);
  if(dot(pos, pos) > bsq) pos = randBall(seed, uBound);
  outState = vec4(pos, col);
}
`

// ---- points: sample state texture, splat additive HDR ---------------------
export const POINTS_VERT = /* glsl */ `
precision highp float;
uniform mat4 modelViewMatrix;
uniform mat4 projectionMatrix;
in vec3 position;        // dummy attribute (gives the draw a vertex count)
in vec2 ref;             // texel coord of this particle in the state texture
uniform sampler2D uState;
uniform sampler2D uPalette;
uniform float uPointSize;
uniform float uBrightness;
out vec3 vColor;
void main(){
  vec4 s = texture(uState, ref);
  vec3 p = s.xyz;
  bool nan = !(p.x == p.x) || !(p.y == p.y) || !(p.z == p.z);
  vec4 mv = modelViewMatrix * vec4(p, 1.0);
  gl_Position = projectionMatrix * mv;
  // fixed tiny screen-space size: stays small, never grows when you fly in;
  // merges into a smooth glow where dense, unobtrusive specks where sparse
  gl_PointSize = clamp(uPointSize, 1.0, 6.0);
  vColor = texture(uPalette, vec2(clamp(s.w, 0.0, 1.0), 0.5)).rgb * uBrightness;
  if(nan){ gl_Position = vec4(2.0, 2.0, 2.0, 1.0); gl_PointSize = 0.0; }
  gl_Position += vec4(position * 0.0, 0.0); // keep the position attribute live
}
`

export const POINTS_FRAG = /* glsl */ `
precision highp float;
in vec3 vColor;
out vec4 fragColor;
void main(){
  vec2 d = gl_PointCoord - vec2(0.5);
  float r2 = dot(d, d);
  if(r2 > 0.25) discard;
  float fall = exp(-r2 * 7.0);
  fragColor = vec4(vColor * fall, fall);
}
`

// ---- tone map: flam3 log-density, fullscreen, per eye ---------------------
export const TONEMAP_FRAG = /* glsl */ `
precision highp float;
uniform sampler2D uHdr;
uniform vec2 uFbSize;
uniform float uExposure;
uniform float uGamma;
uniform float uK2;
uniform float uHiDesat; // 0 = keep colour in bright cores, 1 = desaturate highlights to white
uniform float uPassthrough; // 0 = opaque void (VR), 1 = premultiplied alpha over passthrough (AR/MR)
out vec4 fragColor;
void main(){
  vec2 uv = gl_FragCoord.xy / uFbSize;
  vec3 c = texture(uHdr, uv).rgb;
  // flam3 log-density: scale by luminance so hue is preserved through the curve
  float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
  float ls = lum > 1e-6 ? (uExposure * log(1.0 + lum * uK2) / lum) : 0.0;
  vec3 col = c * ls;
  // highlight handling: instead of clipping each channel to flat white, hold the
  // hue and only roll toward white as controlled by uHiDesat (vibrancy).
  float m = max(col.r, max(col.g, col.b));
  if(m > 1.0){
    vec3 hue = col / m;
    col = mix(hue, vec3(1.0), (1.0 - 1.0 / m) * uHiDesat);
  }
  vec3 mapped = pow(clamp(col, 0.0, 1.0), vec3(1.0 / uGamma));

  // AR/MR passthrough: derive alpha from glow brightness so dark gaps reveal the
  // real room and bright cores read strongly, then output PREMULTIPLIED colour —
  // the WebXR compositor always treats the eye buffer as premultiplied (spec PR #840).
  // uPassthrough == 0 reproduces the opaque VR void EXACTLY: outA forced to 1 so
  // fragColor == vec4(mapped, 1.0), the prior behaviour bit-for-bit.
  float a = max(mapped.r, max(mapped.g, mapped.b));
  a = smoothstep(0.015, 0.9, a); // floor kills passthrough camera-noise haze tinting the room
  a = pow(a, 0.85);              // lift mid-glow so faint filaments stay visible
  float outA = mix(1.0, a, uPassthrough);
  fragColor = vec4(mapped * outA, outA); // premultiplied; void path (outA==1) is a no-op
}
`
