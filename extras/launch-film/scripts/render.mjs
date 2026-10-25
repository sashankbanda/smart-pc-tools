// Renders the film with Remotion.
//   node scripts/render.mjs                    both cuts -> out/, plus subtitles and audio
//   node scripts/render.mjs --stills [16x9|9x16]  key moments as PNGs in build/stills, to check quickly
//   node scripts/render.mjs --only 16x9        one cut
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { cpus } from 'node:os';
import { join } from 'node:path';
import { bundle } from '@remotion/bundler';
import { renderMedia, renderStill, selectComposition } from '@remotion/renderer';
import { FPS, VOICE } from '../src/timeline.ts';

const ROOT = join(import.meta.dirname, '..');
const OUT = join(ROOT, 'out');
const CUTS = { '16x9': 'Film', '9x16': 'FilmVertical' };
const arg = (name) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : undefined; };

const STILLS = [0.8, 3.2, 4.9, 6.6, 8.3, 9.6, 12.0, 13.8, 15.9, 17.3, 19.8, 21.6, 23.8, 26.6, 29.6, 31.2, 33.0, 34.6, 36.2, 38.0, 40.0, 41.6, 43.6, 45.6, 47.6, 48.8, 50.3, 52.6, 55.2, 57.6];

function srtTime(s) {
  const ms = Math.round(s * 1000), h = Math.floor(ms / 3600000), m = Math.floor(ms / 60000) % 60, sec = Math.floor(ms / 1000) % 60;
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')},${String(ms % 1000).padStart(3, '0')}`;
}

// Subtitles from the voice lines; lines that continue a sentence ("...") are joined into one cue.
function writeSrt() {
  const manifest = JSON.parse(readFileSync(join(ROOT, 'public', 'audio', 'voice', 'voice.json'), 'utf8'));
  const cues = [];
  for (const line of VOICE) {
    const end = line.at + manifest.lines[line.id].seconds;
    const prev = cues[cues.length - 1];
    if (prev && prev.text.endsWith('...') && line.at - prev.end < 1.2) { prev.text = `${prev.text} ${line.text}`; prev.end = end; }
    else cues.push({ start: line.at, end, text: line.text });
  }
  const srt = cues.map((c, i) => `${i + 1}\n${srtTime(c.start)} --> ${srtTime(c.end + 0.25)}\n${c.text}\n`).join('\n');
  writeFileSync(join(OUT, 'smart-pc-tools-launch.srt'), srt);
  return cues.length;
}

async function main() {
  if (!existsSync(join(ROOT, 'public', 'audio', 'mix.wav'))) throw new Error('No soundtrack yet: run npm run voice and npm run audio first.');
  if (!existsSync(join(ROOT, 'public', 'screens', 'transfer-copying.png'))) throw new Error('No app screens yet: run npm run capture first.');
  console.log('Bundling...');
  const serveUrl = await bundle({ entryPoint: join(ROOT, 'src', 'index.ts'), publicDir: join(ROOT, 'public') });

  if (process.argv.includes('--stills')) {
    const cut = arg('--stills') && CUTS[arg('--stills')] ? arg('--stills') : '16x9';
    const composition = await selectComposition({ serveUrl, id: CUTS[cut] });
    const dir = join(ROOT, 'build', 'stills', cut);
    mkdirSync(dir, { recursive: true });
    const times = arg('--at') ? arg('--at').split(',').map(Number) : STILLS;
    for (const t of times) {
      await renderStill({ serveUrl, composition, frame: Math.round(t * FPS), output: join(dir, `${t.toFixed(1).padStart(4, '0')}.png`) });
      process.stdout.write('.');
    }
    console.log(`\n${times.length} stills in ${dir}`);
    return;
  }

  mkdirSync(OUT, { recursive: true });
  const only = arg('--only');
  for (const [cut, id] of Object.entries(CUTS)) {
    if (only && only !== cut) continue;
    const composition = await selectComposition({ serveUrl, id });
    const outputLocation = join(OUT, `smart-pc-tools-launch-${cut}.mp4`);
    const t0 = Date.now();
    let last = -1;
    await renderMedia({
      serveUrl, composition, outputLocation,
      codec: 'h264', crf: 16, pixelFormat: 'yuv420p', audioCodec: 'aac', audioBitrate: '320k',
      concurrency: Math.max(2, Math.floor(cpus().length / 2)),
      onProgress: ({ progress }) => { const p = Math.floor(progress * 20); if (p !== last) { last = p; process.stdout.write(`\r${cut}: ${Math.round(progress * 100)}%  `); } },
    });
    console.log(`\r${cut}: ${outputLocation} (${((Date.now() - t0) / 60000).toFixed(1)} min)`);
  }
  const n = writeSrt();
  copyFileSync(join(ROOT, 'public', 'audio', 'mix.wav'), join(OUT, 'smart-pc-tools-launch-mix.wav'));
  console.log(`Subtitles: ${n} cues in out/smart-pc-tools-launch.srt; final mix in out/smart-pc-tools-launch-mix.wav`);
}

main().catch((e) => { console.error(e); process.exit(1); });
