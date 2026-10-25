// Checks the rendered films, decoding them with the ffmpeg that comes with Remotion:
// format, length, loudness and true peak of the delivered audio, picture/sound sync against
// the mix, black or frozen stretches, and a contact sheet of frames from the actual file.
//   node scripts/check.mjs   ->  build/check/report.json and build/check/<cut>-sheet.png
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import sharp from 'sharp';
import { loudness, truePeak } from './dsp.mjs';
import { readWav } from './wav.mjs';
import { DURATION } from '../src/timeline.ts';

const ROOT = join(import.meta.dirname, '..');
const OUT = join(ROOT, 'out'), DIR = join(ROOT, 'build', 'check');
const CUTS = ['16x9', '9x16'];
const tool = (name, args) => execFileSync('npx', ['remotion', name, ...args], { cwd: ROOT, shell: true, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 1 << 26 });

// The delay between two signals, in samples (positive: b is late), by cross-correlation.
function lag(a, b, at, rate) {
  const s = Math.round(at * rate), n = Math.round(2 * rate), max = Math.round(0.08 * rate);
  let best = 0, bestV = -Infinity;
  for (let d = -max; d <= max; d++) {
    let v = 0;
    for (let i = 0; i < n; i += 2) v += a[s + i] * (b[s + i + d] ?? 0);
    if (v > bestV) { bestV = v; best = d; }
  }
  return best;
}

async function checkCut(cut) {
  const file = join(OUT, `smart-pc-tools-launch-${cut}.mp4`);
  if (!existsSync(file)) return { cut, error: `missing ${file}` };
  const probe = JSON.parse(tool('ffprobe', ['-v', 'error', '-show_entries', 'stream=codec_type,codec_name,width,height,r_frame_rate,sample_rate,channels,duration:format=duration,size,bit_rate', '-of', 'json', `"${file}"`]));
  const video = probe.streams.find((s) => s.codec_type === 'video'), audio = probe.streams.find((s) => s.codec_type === 'audio');

  // sound as delivered
  const wav = join(DIR, `${cut}.wav`);
  tool('ffmpeg', ['-v', 'error', '-y', '-i', `"${file}"`, '-vn', '-c:a', 'pcm_s16le', '-ar', '48000', `"${wav}"`]);
  const got = readWav(wav), mix = readWav(join(ROOT, 'public', 'audio', 'mix.wav'));
  const [L, R] = got.channels;
  const lags = [5.5, 16.5, 30, 45.2, 53].map((t) => +(1000 * lag(mix.channels[0], L, t, 48000) / 48000).toFixed(1));

  // pictures: 2 per second, small, for black/frozen detection and the contact sheet
  const frames = join(DIR, cut);
  rmSync(frames, { recursive: true, force: true }); mkdirSync(frames, { recursive: true });
  tool('ffmpeg', ['-v', 'error', '-y', '-i', `"${file}"`, '-vf', 'scale=240:-2', '-r', '2', `"${join(frames, '%04d.png')}"`]);
  const files = readdirSync(frames).filter((f) => f.endsWith('.png')).sort();
  const luma = [], diffs = [];
  let prev = null;
  for (const f of files) {
    const { data } = await sharp(join(frames, f)).resize(48, 48, { fit: 'fill' }).greyscale().raw().toBuffer({ resolveWithObject: true });
    let s = 0; for (const v of data) s += v; luma.push(s / data.length);
    if (prev) { let d = 0; for (let i = 0; i < data.length; i++) d += Math.abs(data[i] - prev[i]); diffs.push(d / data.length); }
    prev = data;
  }
  const time = (i) => (i + 0.5) / 2;
  // Black is expected only in the first half second (the hook opens on black) and the last fade.
  const black = luma.map((v, i) => ({ t: time(i), v })).filter((x) => x.v < 4 && x.t > 0.6 && x.t < DURATION - 0.8).map((x) => x.t);
  let run = 0, longest = 0, longestAt = 0;
  diffs.forEach((d, i) => { if (d < 0.25) { run++; if (run > longest) { longest = run; longestAt = time(i + 1) - run / 2; } } else run = 0; });

  return {
    cut, file: `out/smart-pc-tools-launch-${cut}.mp4`,
    megabytes: +(probe.format.size / 1e6).toFixed(1),
    video: `${video.codec_name} ${video.width}x${video.height} @ ${video.r_frame_rate} fps`,
    audio: `${audio.codec_name} ${audio.sample_rate} Hz, ${audio.channels} ch`,
    seconds: +(+probe.format.duration).toFixed(2),
    integratedLufs: +loudness(L, R).toFixed(2),
    truePeakDbtp: +truePeak(L, R).toFixed(2),
    syncMsAgainstMix: lags,
    blackFramesAt: black,
    longestStillSeconds: +(longest / 2).toFixed(1), longestStillAround: +longestAt.toFixed(1),
    framesForSheet: frames,
  };
}

const results = [];
mkdirSync(DIR, { recursive: true });
for (const cut of CUTS) {
  const r = await checkCut(cut);
  results.push(r);
  if (r.error) { console.log(`${cut}: ${r.error}`); continue; }
  console.log(`${cut}: ${r.video}, ${r.audio}, ${r.seconds} s, ${r.megabytes} MB`);
  console.log(`      ${r.integratedLufs} LUFS, true peak ${r.truePeakDbtp} dBTP, audio offset vs mix ${r.syncMsAgainstMix.join(' / ')} ms`);
  console.log(`      black frames: ${r.blackFramesAt.length ? r.blackFramesAt.join(', ') + ' s' : 'none'}; longest still stretch ${r.longestStillSeconds} s (around ${r.longestStillAround} s)`);
  execFileSync('powershell', ['-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', join(ROOT, 'scripts', 'contact-sheet.ps1'), '-Dir', r.framesForSheet, '-Output', join(DIR, `${cut}-sheet.png`), '-Cols', cut === '16x9' ? '12' : '20', '-ThumbW', cut === '16x9' ? '160' : '96'], { stdio: 'ignore' });
}
writeFileSync(join(DIR, 'report.json'), JSON.stringify(results, null, 2));
const bad = results.filter((r) => r.error || r.blackFramesAt?.length || r.truePeakDbtp > -1 || Math.abs(r.integratedLufs + 14) > 1 || r.syncMsAgainstMix?.some((v) => Math.abs(v) > 25));
console.log(bad.length ? `Check: ${bad.length} cut(s) need a look - see build/check/report.json` : 'Check: both cuts pass.');
