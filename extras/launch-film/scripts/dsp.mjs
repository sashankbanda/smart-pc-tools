// Small audio building blocks: filters, oscillators, reverb, loudness. 48 kHz throughout.
export const SR = 48000;

export const midiHz = (m) => 440 * 2 ** ((m - 69) / 12);
export const dB = (g) => 10 ** (g / 20);

// Seeded random numbers, so every render sounds the same.
export function rng(seed = 1) {
  let s = seed >>> 0;
  return () => { s = (s + 0x6d2b79f5) >>> 0; let t = s; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}

// RBJ cookbook biquad. type: lowpass, highpass, bandpass, peak, highshelf, lowshelf.
export function biquad(type, freq, q = 0.707, gainDb = 0) {
  const w = 2 * Math.PI * freq / SR, cos = Math.cos(w), sin = Math.sin(w), alpha = sin / (2 * q), A = 10 ** (gainDb / 40);
  let b0, b1, b2, a0, a1, a2;
  switch (type) {
    case 'lowpass': b0 = (1 - cos) / 2; b1 = 1 - cos; b2 = b0; a0 = 1 + alpha; a1 = -2 * cos; a2 = 1 - alpha; break;
    case 'highpass': b0 = (1 + cos) / 2; b1 = -(1 + cos); b2 = b0; a0 = 1 + alpha; a1 = -2 * cos; a2 = 1 - alpha; break;
    case 'bandpass': b0 = alpha; b1 = 0; b2 = -alpha; a0 = 1 + alpha; a1 = -2 * cos; a2 = 1 - alpha; break;
    case 'peak': b0 = 1 + alpha * A; b1 = -2 * cos; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * cos; a2 = 1 - alpha / A; break;
    case 'highshelf': { const s = 2 * Math.sqrt(A) * alpha; b0 = A * ((A + 1) + (A - 1) * cos + s); b1 = -2 * A * ((A - 1) + (A + 1) * cos); b2 = A * ((A + 1) + (A - 1) * cos - s); a0 = (A + 1) - (A - 1) * cos + s; a1 = 2 * ((A - 1) - (A + 1) * cos); a2 = (A + 1) - (A - 1) * cos - s; break; }
    case 'lowshelf': { const s = 2 * Math.sqrt(A) * alpha; b0 = A * ((A + 1) - (A - 1) * cos + s); b1 = 2 * A * ((A - 1) - (A + 1) * cos); b2 = A * ((A + 1) - (A - 1) * cos - s); a0 = (A + 1) + (A - 1) * cos + s; a1 = -2 * ((A - 1) + (A + 1) * cos); a2 = (A + 1) + (A - 1) * cos - s; break; }
    default: throw new Error(type);
  }
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  const k = [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0];
  return (x) => { const y = k[0] * x + k[1] * x1 + k[2] * x2 - k[3] * y1 - k[4] * y2; x2 = x1; x1 = x; y2 = y1; y1 = y; return y; };
}

export function filterInPlace(buf, ...filters) {
  for (let i = 0; i < buf.length; i++) { let v = buf[i]; for (const f of filters) v = f(v); buf[i] = v; }
  return buf;
}

// Zero-delay-feedback state-variable filter whose cutoff can move every sample.
export function svf() {
  let ic1 = 0, ic2 = 0;
  return (x, cutoff, res = 0.2) => {
    const g = Math.tan(Math.PI * Math.min(cutoff, SR * 0.45) / SR), k = 2 - 2 * res;
    const a1 = 1 / (1 + g * (g + k)), a2 = g * a1, a3 = g * a2;
    const v3 = x - ic2, v1 = a1 * ic1 + a2 * v3, v2 = ic2 + a2 * ic1 + a3 * v3;
    ic1 = 2 * v1 - ic1; ic2 = 2 * v2 - ic2;
    return v2;   // low-pass output
  };
}

// Band-limited sawtooth (polyBLEP), phase in 0..1.
export function sawBlep(phase, dt) {
  let v = 2 * phase - 1;
  if (phase < dt) { const t = phase / dt; v -= t + t - t * t - 1; }
  else if (phase > 1 - dt) { const t = (phase - 1) / dt; v -= t * t + t + t + 1; }
  return v;
}

// Freeverb (Jezar's public-domain design), stereo.
export function freeverb({ room = 0.84, damp = 0.3, width = 1 } = {}) {
  const scale = SR / 44100, spread = 23;
  const combT = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617], apT = [556, 441, 341, 225];
  const mkComb = (n) => { const b = new Float32Array(Math.round(n * scale)); let i = 0, store = 0; return (x) => { const out = b[i]; store = out * (1 - damp) + store * damp; b[i] = x + store * room; if (++i >= b.length) i = 0; return out; }; };
  const mkAp = (n) => { const b = new Float32Array(Math.round(n * scale)); let i = 0; return (x) => { const bo = b[i]; const out = -x + bo; b[i] = x + bo * 0.5; if (++i >= b.length) i = 0; return out; }; };
  const cl = combT.map((n) => mkComb(n)), cr = combT.map((n) => mkComb(n + spread));
  const al = apT.map((n) => mkAp(n)), ar = apT.map((n) => mkAp(n + spread));
  const w1 = width / 2 + 0.5, w2 = (1 - width) / 2;
  return (inL, inR) => {
    const x = (inL + inR) * 0.015;
    let l = 0, r = 0;
    for (const c of cl) l += c(x);
    for (const c of cr) r += c(x);
    for (const a of al) l = a(l);
    for (const a of ar) r = a(r);
    return [l * w1 + r * w2, r * w1 + l * w2];
  };
}

export function processReverb(sendL, sendR, outL, outR, opts, wet = 1) {
  const verb = freeverb(opts);
  for (let i = 0; i < sendL.length; i++) { const [l, r] = verb(sendL[i], sendR[i]); outL[i] += l * wet; outR[i] += r * wet; }
}

// ITU-R BS.1770-4 integrated loudness (LUFS) of a 48 kHz stereo signal.
export function loudness(L, R) {
  const kw = () => { const a = biquad('highshelf', 1681.97, 0.7072, 3.9998), b = biquad('highpass', 38.135, 0.5003); return (x) => b(a(x)); };
  const fl = kw(), fr = kw();
  const block = Math.round(0.4 * SR), hop = Math.round(0.1 * SR);
  const sq = new Float64Array(L.length);
  for (let i = 0; i < L.length; i++) { const l = fl(L[i]), r = fr(R[i]); sq[i] = l * l + r * r; }
  const cum = new Float64Array(L.length + 1);
  for (let i = 0; i < L.length; i++) cum[i + 1] = cum[i] + sq[i];
  const blocks = [];
  for (let s = 0; s + block <= L.length; s += hop) blocks.push((cum[s + block] - cum[s]) / block);
  const lk = (z) => -0.691 + 10 * Math.log10(z);
  const abs = blocks.filter((z) => lk(z) > -70);
  if (!abs.length) return -Infinity;
  const rel = lk(abs.reduce((a, b) => a + b, 0) / abs.length) - 10;
  const gated = abs.filter((z) => lk(z) > rel);
  return lk(gated.reduce((a, b) => a + b, 0) / gated.length);
}

// The highest peak between samples too (4x oversampled with a windowed-sinc interpolator), in dBTP.
const TAPS = 16;
const PHASES = [0.25, 0.5, 0.75].map((f) => {
  const k = [];
  for (let j = -TAPS / 2 + 1; j <= TAPS / 2; j++) { const x = j - f; const sinc = x === 0 ? 1 : Math.sin(Math.PI * x) / (Math.PI * x); const w = 0.5 + 0.5 * Math.cos(Math.PI * x / (TAPS / 2)); k.push(sinc * w); }
  return k;
});
export function truePeakAt(x, i) {
  let p = Math.abs(x[i]);
  for (const k of PHASES) {
    let v = 0;
    for (let j = 0; j < k.length; j++) { const n = i + j - TAPS / 2 + 1; if (n >= 0 && n < x.length) v += x[n] * k[j]; }
    if (Math.abs(v) > p) p = Math.abs(v);
  }
  return p;
}
export function truePeak(L, R) {
  let p = 0;
  for (const x of [L, R]) for (let i = 0; i < x.length; i++) { if (Math.abs(x[i]) * 1.6 < p) continue; const v = truePeakAt(x, i); if (v > p) p = v; }
  return 20 * Math.log10(p || 1e-9);
}

// Look-ahead limiter on true peaks: gain rides down smoothly before a peak, never above ceiling.
export function limit(L, R, ceilingDb = -1.5, lookMs = 5, releaseMs = 120) {
  const ceil = dB(ceilingDb), n = L.length, look = Math.round(lookMs * SR / 1000);
  const need = new Float32Array(n);
  for (let i = 0; i < n; i++) { const p = Math.max(truePeakAt(L, i), truePeakAt(R, i)); need[i] = p > ceil ? ceil / p : 1; }
  // m: the lowest gain needed within `look` samples either side. Its moving average over half
  // that width still reaches the needed gain exactly at each peak, but ramps there smoothly.
  const m = new Float32Array(n), dq = [];
  for (let i = 0; i < n + look; i++) {
    if (i < n) { while (dq.length && need[dq[dq.length - 1]] >= need[i]) dq.pop(); dq.push(i); }
    const t = i - look;
    if (t >= 0) { while (dq[0] < t - look) dq.shift(); m[t] = need[dq[0]]; }
  }
  const half = Math.max(1, Math.floor(look / 2)), cum = new Float64Array(n + 1);
  for (let i = 0; i < n; i++) cum[i + 1] = cum[i] + m[i];
  const rel = Math.exp(-1 / (releaseMs * SR / 1000));
  let cur = 1;
  for (let i = 0; i < n; i++) {
    const a = Math.max(0, i - half), b = Math.min(n, i + half + 1);
    const s = (cum[b] - cum[a]) / (b - a);
    cur = s < cur ? s : s + (cur - s) * rel;
    L[i] *= cur; R[i] *= cur;
  }
}

// Cubic (Catmull-Rom) resampling, good enough for speech at 24 to 48 kHz.
export function resample(x, from, to) {
  if (from === to) return x;
  const n = Math.floor(x.length * to / from), out = new Float32Array(n), r = from / to;
  for (let i = 0; i < n; i++) {
    const t = i * r, k = Math.floor(t), f = t - k;
    const y0 = x[k - 1] ?? x[k], y1 = x[k], y2 = x[k + 1] ?? y1, y3 = x[k + 2] ?? y2;
    out[i] = y1 + 0.5 * f * (y2 - y0 + f * (2 * y0 - 5 * y1 + 4 * y2 - y3 + f * (3 * (y1 - y2) + y3 - y0)));
  }
  return out;
}
