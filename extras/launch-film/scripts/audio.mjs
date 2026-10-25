// The soundtrack: music composed for this film, sound effects, the voice-over, and the final mix.
// Everything is synthesized here from src/timeline.ts, so it is original and free to use.
//   node scripts/audio.mjs   ->  public/audio/mix.wav, build/stems/*.wav, build/audio-report.json
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { DURATION, MUSIC, SCENES, SFX, VOICE } from '../src/timeline.ts';
import { SR, biquad, dB, filterInPlace, limit, loudness, midiHz, processReverb, resample, rng, sawBlep, svf, truePeak } from './dsp.mjs';
import { readWav, writeWav } from './wav.mjs';

const ROOT = join(import.meta.dirname, '..');
const N = Math.ceil(DURATION * SR);
const bus = () => [new Float32Array(N), new Float32Array(N)];
const at = (t) => Math.round(t * SR);
const partAt = (p) => MUSIC.find((m) => m.part === p).at;
const random = rng(2026);
const MUSIC_GAIN = -4.5, SFX_GAIN = -1;   // dB, relative to the voice

// ---------------------------------------------------------------------------
// music
// ---------------------------------------------------------------------------
// D major, 92.3 BPM: the eight bars of the demo section fill it exactly (2.6 s a bar).
const BAR = 2.6, BEAT = BAR / 4;
const music = bus(), musicSend = bus();

// A pad chord: three detuned band-limited saws per note, through a soft low-pass whose
// cutoff follows cutoff(t). Slow attack and release, so chords melt into each other.
function pad(t0, t1, notes, { gain = -24, attack = 1.2, release = 1.8, cutoff = () => 900, send = 0.5 } = {}) {
  const a = at(t0), b = Math.min(N, at(t1 + release));
  for (const m of notes) {
    const f = midiHz(m), voices = [-9, 0, 8].map((c) => f * 2 ** (c / 1200));
    const phases = voices.map(() => random()), filters = [svf(), svf()];
    const g = dB(gain) / Math.sqrt(notes.length);
    for (let i = a; i < b; i++) {
      const t = (i - a) / SR, abs = i / SR;
      const env = Math.min(1, t / attack) * (abs < t1 ? 1 : Math.max(0, 1 - (abs - t1) / release));
      if (env <= 0) continue;
      let l = 0, r = 0;
      for (let v = 0; v < 3; v++) {
        const dt = voices[v] / SR;
        phases[v] += dt; if (phases[v] >= 1) phases[v] -= 1;
        const s = sawBlep(phases[v], dt);
        if (v === 0) l += s; else if (v === 2) r += s; else { l += s * 0.7; r += s * 0.7; }
      }
      const c = cutoff(abs);
      const yl = filters[0](l, c, 0.1) * g * env, yr = filters[1](r, c, 0.1) * g * env;
      music[0][i] += yl; music[1][i] += yr; musicSend[0][i] += yl * send; musicSend[1][i] += yr * send;
    }
  }
}

// Warm sub-bass: a sine with a touch of its octave, gently saturated so laptops can hint at it.
function sub(t0, t1, m, gain = -20, attack = 0.4, release = 0.8) {
  const f = midiHz(m), a = at(t0), b = Math.min(N, at(t1 + release)), g = dB(gain);
  for (let i = a; i < b; i++) {
    const t = (i - a) / SR, abs = i / SR;
    const env = Math.min(1, t / attack) * (abs < t1 ? 1 : Math.max(0, 1 - (abs - t1) / release));
    const ph = 2 * Math.PI * f * t;
    const v = Math.tanh(1.4 * (Math.sin(ph) + 0.25 * Math.sin(2 * ph))) * g * env;
    music[0][i] += v; music[1][i] += v;
  }
}

// FM pluck (harmonic) and bell (inharmonic). pan -1..1.
function fm(t, m, { gain = -26, ratio = 1, index = 2.2, indexDecay = 0.18, decay = 0.7, pan = 0, send = 0.4, out = music, outSend = musicSend } = {}) {
  const f = midiHz(m), a = at(t), len = Math.round(decay * 5 * SR), g = dB(gain);
  const gl = g * Math.sqrt((1 - pan) / 2), gr = g * Math.sqrt((1 + pan) / 2);
  for (let k = 0; k < len && a + k < N; k++) {
    const tt = k / SR;
    const env = Math.min(1, tt / 0.004) * Math.exp(-tt / decay);
    const mod = index * Math.exp(-tt / indexDecay) * Math.sin(2 * Math.PI * f * ratio * tt);
    const v = Math.sin(2 * Math.PI * f * tt + mod) * env;
    out[0][a + k] += v * gl; out[1][a + k] += v * gr;
    outSend[0][a + k] += v * gl * send; outSend[1][a + k] += v * gr * send;
  }
}

// Soft kick: a sine that drops in pitch, with a little click.
function kick(t, gain = -16) {
  const a = at(t), len = Math.round(0.6 * SR), g = dB(gain);
  let ph = 0;
  for (let k = 0; k < len && a + k < N; k++) {
    const tt = k / SR, f = 46 + 70 * Math.exp(-tt / 0.045);
    ph += 2 * Math.PI * f / SR;
    const v = (Math.sin(ph) * Math.exp(-tt / 0.22) + (random() - 0.5) * 0.3 * Math.exp(-tt / 0.003)) * g;
    music[0][a + k] += v; music[1][a + k] += v;
  }
}

// Shaker: short, high, quiet noise.
const shakerHp = [biquad('highpass', 6500, 0.7), biquad('highpass', 6500, 0.7)];
function shaker(t, gain = -34, pan = 0.3) {
  const a = at(t), len = Math.round(0.09 * SR), g = dB(gain);
  for (let k = 0; k < len && a + k < N; k++) {
    const tt = k / SR, env = Math.min(1, tt / 0.004) * Math.exp(-tt / 0.03);
    const n = (random() * 2 - 1) * env * g;
    music[0][a + k] += shakerHp[0](n) * (1 - pan); music[1][a + k] += shakerHp[1](n) * (1 + pan);
  }
}

const ramp = (t, t0, t1, v0, v1) => (t <= t0 ? v0 : t >= t1 ? v1 : v0 + (v1 - v0) * (t - t0) / (t1 - t0));

function compose() {
  const tension = partAt('tension'), lift = partAt('lift'), drive = partAt('drive'), peak = partAt('peak'), resolve = partAt('resolve');

  // air: an open Dsus2, almost nothing, the filter barely open.
  pad(0, tension + 0.4, [50, 57, 64, 69], { gain: -26, attack: 2.5, cutoff: (t) => ramp(t, 0, 5, 450, 900) });
  sub(1.6, tension + 0.2, 38, -26, 2.0);

  // tension: Bm(add9) - Gmaj7 - Em7 - F#7sus4 - F#7, with a slow heartbeat that stops when the copy stalls.
  const tc = [
    [tension, tension + 2.6, [47, 54, 61, 62], 35],
    [tension + 2.6, tension + 5.2, [43, 50, 54, 59], 31],
    [tension + 5.2, tension + 7.6, [40, 50, 55, 59], 40],
    [tension + 7.6, tension + 9.0, [42, 49, 52, 59], 42],
    [tension + 9.0, lift, [42, 49, 52, 58], 42],
  ];
  for (const [a, b, notes, root] of tc) { pad(a, b, notes, { gain: -25, attack: 0.9, cutoff: (t) => ramp(t, tension, lift, 800, 1500) }); sub(a, b, root, -22); }
  for (const t of [5.3, 6.6, 7.9]) kick(t, -22);
  for (const t of [10.6, 11.8, 12.9, 13.8, 14.5]) kick(t, -23 + (t - 10) * 0.8);
  // a lone high note that sags in pitch as the copy stalls
  fm(8.9, 78, { gain: -30, ratio: 2, index: 0.6, decay: 1.4, pan: -0.2 });

  // lift: the reveal opens on D, bright and wide.
  const lc = [
    [lift, lift + 2.8, [50, 57, 62, 64, 66], 38],
    [lift + 2.8, lift + 5.0, [49, 57, 61, 64, 69], 37],
    [lift + 5.0, drive, [47, 54, 62, 66, 69], 35],
  ];
  for (const [a, b, notes, root] of lc) { pad(a, b, notes, { gain: -23, attack: 0.25, cutoff: (t) => ramp(t, lift, lift + 2, 1200, 2400) }); sub(a, b, root, -20, 0.05); }
  [74, 78, 81, 85, 81, 78].forEach((m, k) => fm(lift + 3.0 + k * BEAT, m, { gain: -31, ratio: 3.5, index: 1.4, decay: 1.2, pan: k % 2 ? 0.35 : -0.35, send: 0.6 }));

  // drive: G - D/F# - Asus2 - Bm7, twice. Eighth-note plucks, a soft kick on 1 and 3,
  // a shaker from the second bar.
  const prog = [
    { pad: [43, 50, 57, 59, 62], root: 31, arp: [67, 74, 79, 81, 79, 74, 83, 74] },
    { pad: [42, 50, 57, 62, 66], root: 30, arp: [66, 74, 78, 81, 78, 74, 81, 74] },
    { pad: [45, 52, 57, 59, 64], root: 33, arp: [69, 76, 81, 83, 81, 76, 83, 76] },
    { pad: [47, 54, 57, 62, 66], root: 35, arp: [71, 74, 78, 81, 78, 74, 83, 74] },
  ];
  for (let bar = 0; bar < 8; bar++) {
    const t = drive + bar * BAR, c = prog[bar % 4];
    pad(t, t + BAR, c.pad, { gain: -25, attack: 0.15, release: 0.9, cutoff: () => 1600 + bar * 80, send: 0.35 });
    sub(t, t + BAR - 0.05, c.root, -19, 0.03, 0.2);
    for (let k = 0; k < 8; k++) fm(t + k * BEAT / 2, c.arp[k], { gain: k % 2 ? -31 : -29, ratio: 1, index: 1.6, decay: 0.32, pan: k % 2 ? 0.3 : -0.3, send: 0.3 });
    kick(t, -17); kick(t + 2 * BEAT, -19);
    if (bar >= 1) for (let k = 0; k < 8; k++) shaker(t + k * BEAT / 2, k % 2 ? -33 : -37, k % 2 ? 0.4 : -0.4);
  }

  // peak: three brighter bars with a high octave and a bell counter-melody, then a breath on Asus4.
  const peakProg = [prog[0], prog[1], prog[2]];
  const melody = [[83, 81, 78, 81], [81, 78, 74, 78], [76, 78, 81, 85]];
  peakProg.forEach((c, bar) => {
    const t = peak + bar * BAR;
    pad(t, t + BAR, [...c.pad, c.pad[2] + 12, c.pad[3] + 12], { gain: -23, attack: 0.1, release: 0.9, cutoff: () => 3000, send: 0.45 });
    sub(t, t + BAR - 0.05, c.root, -18, 0.03, 0.2);
    for (let k = 0; k < 8; k++) fm(t + k * BEAT / 2, c.arp[k] + (k === 6 ? 12 : 0), { gain: k % 2 ? -30 : -28, ratio: 1, index: 1.8, decay: 0.34, pan: k % 2 ? 0.35 : -0.35, send: 0.35 });
    melody[bar].forEach((m, k) => fm(t + k * BEAT, m, { gain: -29, ratio: 3.5, index: 1.2, decay: 1.4, pan: 0.1, send: 0.7 }));
    for (let k = 0; k < 4; k++) kick(t + k * BEAT, k % 2 ? -21 : -17);
    for (let k = 0; k < 8; k++) shaker(t + k * BEAT / 2, k % 2 ? -32 : -36, k % 2 ? 0.4 : -0.4);
  });
  const breath = peak + 3 * BAR;
  pad(breath, resolve, [45, 52, 57, 62, 64], { gain: -25, attack: 0.08, release: 0.8, cutoff: (t) => ramp(t, breath, resolve, 2600, 1500) });
  sub(breath, resolve, 33, -21, 0.05);

  // resolve: Dmaj9, held, the logo's chord, fading to silence.
  const end = DURATION - 0.6;
  pad(resolve, end - 2.5, [38, 50, 57, 61, 64, 66], { gain: -23, attack: 0.05, release: 3.5, cutoff: (t) => ramp(t, resolve, end, 2600, 700), send: 0.7 });
  sub(resolve, end - 3.5, 38, -19, 0.03, 2.5);
  kick(resolve, -15);
  [74, 78, 81, 85].forEach((m, k) => fm(resolve + 0.6 + k * 0.7, m, { gain: -31, ratio: 3.5, index: 1.1, decay: 1.8, pan: (k - 1.5) * 0.25, send: 0.8 }));
}

// ---------------------------------------------------------------------------
// sound effects
// ---------------------------------------------------------------------------
const sfx = bus(), sfxSend = bus();

function noiseSweep(t, len, { from, to, q = 1.2, gain, envelope, pan = () => 0, send = 0.4 }) {
  const a = at(t), n = Math.round(len * SR), g = dB(gain);
  const hp = biquad('highpass', 120);
  let ic1 = 0, ic2 = 0;
  for (let k = 0; k < n && a + k < N; k++) {
    const x = k / n, freq = from * (to / from) ** x;
    // a band-pass state-variable filter sweeping through white noise (unity gain at its centre)
    const w = random() * 2 - 1;
    const gg = Math.tan(Math.PI * Math.min(freq, SR * 0.45) / SR), kk = 1 / q;
    const a1 = 1 / (1 + gg * (gg + kk)), a2 = gg * a1, a3 = gg * a2;
    const v3 = w - ic2, v1 = a1 * ic1 + a2 * v3, v2 = ic2 + a2 * ic1 + a3 * v3;
    ic1 = 2 * v1 - ic1; ic2 = 2 * v2 - ic2;
    const v = hp(kk * v1) * envelope(x) * g;
    const p = pan(x), gl = Math.sqrt((1 - p) / 2), gr = Math.sqrt((1 + p) / 2);
    sfx[0][a + k] += v * gl; sfx[1][a + k] += v * gr;
    sfxSend[0][a + k] += v * gl * send; sfxSend[1][a + k] += v * gr * send;
  }
}

function tone(t, len, { f0, f1 = f0, gain, decay = 0.1, attack = 0.002, harmonics = [1], pan = 0, send = 0.3 }) {
  const a = at(t), n = Math.round(len * SR), g = dB(gain);
  const gl = g * Math.sqrt((1 - pan) / 2), gr = g * Math.sqrt((1 + pan) / 2);
  let ph = 0;
  for (let k = 0; k < n && a + k < N; k++) {
    const tt = k / SR, f = f0 * (f1 / f0) ** (k / n);
    ph += 2 * Math.PI * f / SR;
    let v = 0; harmonics.forEach((h, j) => { v += h * Math.sin(ph * (j + 1)); });
    v *= Math.min(1, tt / attack) * Math.exp(-tt / decay);
    sfx[0][a + k] += v * gl; sfx[1][a + k] += v * gr;
    sfxSend[0][a + k] += v * gl * send; sfxSend[1][a + k] += v * gr * send;
  }
}

const SOUNDS = {
  bell: (t, g) => fm(t, 81, { gain: g, ratio: 3.5, index: 2.4, indexDecay: 0.4, decay: 2.2, send: 0.8, out: sfx, outSend: sfxSend }),
  swell: (t, g) => noiseSweep(t, 3.2, { from: 180, to: 900, gain: g, envelope: (x) => Math.sin(Math.PI * Math.min(1, x * 1.25)) ** 2, send: 0.8 }),
  tick: (t, g) => { for (let k = 0; k < 6; k++) tone(t + k * 0.42 * (1 + k * 0.12), 0.05, { f0: 2400, gain: g - k * 1.5, decay: 0.012, send: 0.2 }); },
  stall: (t, g) => { tone(t, 0.9, { f0: 330, f1: 70, gain: g, decay: 0.35, attack: 0.01, harmonics: [1, 0.4, 0.2], send: 0.4 }); noiseSweep(t, 0.4, { from: 900, to: 150, gain: g - 6, envelope: (x) => 1 - x }); },
  whoosh: (t, g) => noiseSweep(t - 0.35, 0.8, { from: 300, to: 2600, gain: g, envelope: (x) => Math.sin(Math.PI * x) ** 1.5, pan: (x) => -0.6 + 1.2 * x, send: 0.5 }),
  impact: (t, g) => { tone(t, 2.4, { f0: 95, f1: 32, gain: g, decay: 0.7, attack: 0.003, harmonics: [1, 0.3], send: 0.6 }); noiseSweep(t, 0.5, { from: 2000, to: 200, gain: g - 8, envelope: (x) => Math.exp(-x * 6), send: 0.9 }); },
  riser: (t, g) => noiseSweep(t, 1.3, { from: 250, to: 7000, gain: g, envelope: (x) => x ** 2.2, pan: (x) => Math.sin(x * 9) * 0.3, send: 0.6 }),
  tap: (t, g) => { tone(t, 0.12, { f0: 1350, f1: 1100, gain: g, decay: 0.025, harmonics: [1, 0.25], send: 0.15 }); tone(t, 0.1, { f0: 520, gain: g - 6, decay: 0.03, send: 0.1 }); },
  glide: (t, g) => tone(t, 0.7, { f0: 880, f1: 440, gain: g, decay: 0.3, attack: 0.03, harmonics: [1, 0.15], send: 0.5 }),
  shimmer: (t, g) => [86, 90, 93, 97, 98].forEach((m, k) => fm(t + k * 0.09 + random() * 0.03, m, { gain: g - k, ratio: 3.5, index: 0.8, decay: 1.1, pan: (k - 2) * 0.3, send: 0.9, out: sfx, outSend: sfxSend })),
  chime: (t, g) => [74, 81, 90].forEach((m, k) => fm(t + k * 0.04, m, { gain: g - k * 2, ratio: 3.5, index: 1.8, indexDecay: 0.6, decay: 3.4, pan: (k - 1) * 0.3, send: 0.9, out: sfx, outSend: sfxSend })),
};

// ---------------------------------------------------------------------------
// voice
// ---------------------------------------------------------------------------
const voice = new Float32Array(N), voiceSendBus = bus();
function placeVoice() {
  const manifest = JSON.parse(readFileSync(join(ROOT, 'public', 'audio', 'voice', 'voice.json'), 'utf8'));
  for (const line of VOICE) {
    const info = manifest.lines[line.id];
    if (!info) throw new Error(`No voice for ${line.id}: run npm run voice first.`);
    const { channels, rate } = readWav(join(ROOT, 'public', 'audio', 'voice', info.file));
    const x = resample(channels[0], rate, SR);
    // Clean-up: no rumble, a little warmth and presence, softer "s" sounds.
    filterInPlace(x, biquad('highpass', 85, 0.7), biquad('lowshelf', 220, 0.7, 1.5), biquad('peak', 3200, 1.0, 2), biquad('highshelf', 8500, 0.7, -2.5));
    // Every line to the same speaking level (RMS of the voiced part).
    let s = 0, c = 0; for (const v of x) if (Math.abs(v) > 0.02) { s += v * v; c++; }
    const g = dB(-20) / Math.sqrt(s / Math.max(1, c));
    // Gentle compression: 2.5:1 above -24 dBFS, 5 ms attack, 120 ms release.
    let env = 0; const atk = Math.exp(-1 / (0.005 * SR)), rel = Math.exp(-1 / (0.12 * SR));
    const a = at(line.at);
    for (let i = 0; i < x.length && a + i < N; i++) {
      const v = x[i] * g, lvl = Math.abs(v);
      env = lvl > env ? lvl + (env - lvl) * atk : lvl + (env - lvl) * rel;
      const over = 20 * Math.log10(Math.max(env, 1e-6)) + 24;
      const red = over > 0 ? dB(-over * (1 - 1 / 2.5)) : 1;
      voice[a + i] += v * red * dB(3);
    }
  }
  for (let i = 0; i < N; i++) { voiceSendBus[0][i] = voice[i] * 0.12; voiceSendBus[1][i] = voice[i] * 0.12; }
}

// Music ducks under the voice: about 7 dB, easing in over 60 ms and out over 450 ms.
function duckGain() {
  const g = new Float32Array(N), atk = Math.exp(-1 / (0.06 * SR)), rel = Math.exp(-1 / (0.45 * SR));
  let env = 0;
  const look = at(0.08);
  for (let i = 0; i < N; i++) {
    const v = Math.abs(voice[Math.min(N - 1, i + look)]);
    const target = v > 0.01 ? 1 : 0;
    env = target > env ? target + (env - target) * atk : target + (env - target) * rel;
    g[i] = dB(-7 * env);
  }
  return g;
}

// ---------------------------------------------------------------------------
// mix
// ---------------------------------------------------------------------------
function main() {
  const t0 = Date.now();
  compose();
  for (const cue of SFX) SOUNDS[cue.kind](cue.at, cue.gain ?? -14);
  placeVoice();

  processReverb(musicSend[0], musicSend[1], music[0], music[1], { room: 0.88, damp: 0.35 }, 0.9);
  processReverb(sfxSend[0], sfxSend[1], sfx[0], sfx[1], { room: 0.86, damp: 0.3 }, 0.9);
  const voiceL = Float32Array.from(voice), voiceR = Float32Array.from(voice);
  processReverb(voiceSendBus[0], voiceSendBus[1], voiceL, voiceR, { room: 0.55, damp: 0.5 }, 0.5);

  // A gentle high-pass on music and effects keeps the low end clean under the voice.
  for (const b of [music, sfx]) for (const ch of b) filterInPlace(ch, biquad('highpass', 30, 0.7));

  const duck = duckGain();
  const mixL = new Float32Array(N), mixR = new Float32Array(N);
  const fadeIn = at(0.05), fadeOut = at(0.4);
  for (let i = 0; i < N; i++) {
    const edge = Math.min(1, i / fadeIn, (N - 1 - i) / fadeOut);
    music[0][i] *= duck[i] * dB(MUSIC_GAIN); music[1][i] *= duck[i] * dB(MUSIC_GAIN);
    sfx[0][i] *= dB(SFX_GAIN); sfx[1][i] *= dB(SFX_GAIN);
    mixL[i] = (voiceL[i] + music[0][i] + sfx[0][i]) * edge;
    mixR[i] = (voiceR[i] + music[1][i] + sfx[1][i]) * edge;
  }

  // How far the music sits under the voice, scene by scene (while the voice speaks).
  const balance = SCENES.map((s) => {
    const a = at(s.from), b = at(s.to);
    const v = loudness(voiceL.subarray(a, b), voiceR.subarray(a, b)), m = loudness(music[0].subarray(a, b), music[1].subarray(a, b));
    return { scene: s.id, voice: +v.toFixed(1), music: +m.toFixed(1), gap: +(v - m).toFixed(1) };
  });

  // Loudness to -14 LUFS, true peaks below -1 dBTP (limited at -1.5 for margin).
  const TARGET = -14;
  for (let pass = 0; pass < 3; pass++) {
    const g = dB(TARGET - loudness(mixL, mixR));
    for (let i = 0; i < N; i++) { mixL[i] *= g; mixR[i] *= g; }
    limit(mixL, mixR, -1.5);
  }
  const report = {
    integratedLufs: +loudness(mixL, mixR).toFixed(2),
    truePeakDbtp: +truePeak(mixL, mixR).toFixed(2),
    voiceLufs: +loudness(voiceL, voiceR).toFixed(2),
    musicLufs: +loudness(music[0], music[1]).toFixed(2),
    sfxLufs: +loudness(sfx[0], sfx[1]).toFixed(2),
    balance,
    seconds: DURATION,
  };

  const stems = join(ROOT, 'build', 'stems');
  mkdirSync(stems, { recursive: true });
  writeWav(join(ROOT, 'public', 'audio', 'mix.wav'), [mixL, mixR], SR);
  writeWav(join(stems, 'voice.wav'), [voiceL, voiceR], SR, 32);
  writeWav(join(stems, 'music.wav'), music, SR, 32);
  writeWav(join(stems, 'sfx.wav'), sfx, SR, 32);
  writeFileSync(join(ROOT, 'build', 'audio-report.json'), JSON.stringify(report, null, 2));
  console.log(`Mix: ${report.integratedLufs} LUFS, true peak ${report.truePeakDbtp} dBTP (${((Date.now() - t0) / 1000).toFixed(1)} s)`);
  console.log(`     stems: voice ${report.voiceLufs}, music ${report.musicLufs} (ducked), effects ${report.sfxLufs} LUFS`);
  for (const cue of SFX) {
    const a = at(Math.max(0, cue.at - 0.4)), b = at(Math.min(DURATION, cue.at + 1.6));
    let peak = 0; for (let i = a; i < b; i++) peak = Math.max(peak, Math.abs(sfx[0][i]), Math.abs(sfx[1][i]));
    console.log(`     sfx ${cue.kind.padEnd(8)} at ${String(cue.at).padEnd(5)} ${loudness(sfx[0].subarray(a, b), sfx[1].subarray(a, b)).toFixed(1).padStart(6)} LUFS  peak ${(20 * Math.log10(peak)).toFixed(1)} dBFS`);
  }
  for (const b of balance) console.log(`     ${b.scene.padEnd(9)} voice ${String(b.voice).padStart(6)}  music ${String(b.music).padStart(6)}  music sits ${b.gap} LU under`);
}

main();
