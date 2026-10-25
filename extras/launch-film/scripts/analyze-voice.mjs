// Measures voice files, since a script cannot listen: pitch (and how much it moves - a flat,
// robotic read moves little), the share of time spent speaking, peaks and clipping.
//   node scripts/analyze-voice.mjs file.wav [more.wav ...]
import { basename } from 'node:path';
import { readWav } from './wav.mjs';

function pitchTrack(x, rate) {
  const frame = Math.round(rate * 0.04), hop = Math.round(rate * 0.01);
  const minLag = Math.floor(rate / 400), maxLag = Math.ceil(rate / 70);
  const f0 = [];
  for (let s = 0; s + frame + maxLag < x.length; s += hop) {
    let energy = 0; for (let i = 0; i < frame; i++) energy += x[s + i] * x[s + i];
    if (Math.sqrt(energy / frame) < 0.02) continue;
    // YIN difference function, cumulative-mean normalised.
    const d = new Float64Array(maxLag + 1);
    for (let lag = 1; lag <= maxLag; lag++) { let sum = 0; for (let i = 0; i < frame; i++) { const v = x[s + i] - x[s + i + lag]; sum += v * v; } d[lag] = sum; }
    let run = 0, best = -1;
    for (let lag = 1; lag <= maxLag; lag++) { run += d[lag]; const n = d[lag] * lag / (run || 1); if (lag >= minLag && n < 0.15) { best = lag; while (best + 1 <= maxLag && d[best + 1] < d[best]) best++; break; } }
    if (best > 0) f0.push(rate / best);
  }
  return f0;
}

for (const path of process.argv.slice(2)) {
  const { channels, rate } = readWav(path);
  const x = channels[0];
  let peak = 0, clipped = 0, voiced = 0;
  for (const v of x) { const a = Math.abs(v); if (a > peak) peak = a; if (a > 0.999) clipped++; }
  const win = Math.round(rate * 0.02);
  for (let s = 0; s + win < x.length; s += win) { let e = 0; for (let i = 0; i < win; i++) e += x[s + i] ** 2; if (Math.sqrt(e / win) > 0.02) voiced++; }
  const f0 = pitchTrack(x, rate).sort((a, b) => a - b);
  const med = f0[Math.floor(f0.length / 2)] || 0;
  const semis = f0.map((f) => 12 * Math.log2(f / med));
  const mean = semis.reduce((a, b) => a + b, 0) / (semis.length || 1);
  const sd = Math.sqrt(semis.reduce((a, b) => a + (b - mean) ** 2, 0) / (semis.length || 1));
  const p10 = semis[Math.floor(semis.length * 0.1)] ?? 0, p90 = semis[Math.floor(semis.length * 0.9)] ?? 0;
  console.log(`${basename(path).padEnd(16)} ${(x.length / rate).toFixed(2)} s  speaking ${(100 * voiced * win / x.length).toFixed(0)}%  pitch ${med.toFixed(0)} Hz, moves ${sd.toFixed(1)} st (range ${(p90 - p10).toFixed(1)} st)  peak ${(20 * Math.log10(peak)).toFixed(1)} dBFS  clipped ${clipped}`);
}
