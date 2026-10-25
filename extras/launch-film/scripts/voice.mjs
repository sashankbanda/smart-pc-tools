// Voice-over: one WAV per line of src/timeline.ts, spoken by Kokoro (Apache-2.0, runs locally).
//   node scripts/voice.mjs                 every line (unchanged lines are reused)
//   node scripts/voice.mjs --voice bf_emma another voice
//   node scripts/voice.mjs --samples       the first lines in several voices, to compare by ear
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { KokoroTTS } from 'kokoro-js';
import { VOICE } from '../src/timeline.ts';
import { writeWav } from './wav.mjs';

const ROOT = join(import.meta.dirname, '..');
const OUT = join(ROOT, 'public', 'audio', 'voice');
const MODEL = 'onnx-community/Kokoro-82M-v1.0-ONNX';
const arg = (name, fallback) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : fallback; };
const VOICE_NAME = arg('--voice', 'af_heart');   // the highest-rated Kokoro voice: warm, clear, US English

// Kokoro reads "PC" well, but not every product word: spell them the way they should sound.
const say = (text) => text.replace(/\bPC\b/g, 'P.C.');

// Cut the quiet before and after the words, keeping a short natural breath of room.
function trim(samples, rate) {
  const win = Math.round(rate * 0.01), floor = 0.006;
  const loud = (i) => { let s = 0; for (let k = i; k < i + win && k < samples.length; k++) s += samples[k] * samples[k]; return Math.sqrt(s / win) > floor; };
  let a = 0; while (a < samples.length - win && !loud(a)) a += win;
  let b = samples.length - win; while (b > a && !loud(b)) b -= win;
  a = Math.max(0, a - Math.round(rate * 0.03)); b = Math.min(samples.length, b + win + Math.round(rate * 0.12));
  const out = samples.slice(a, b);
  const fade = Math.round(rate * 0.008);
  for (let i = 0; i < fade && i < out.length; i++) { out[i] *= i / fade; out[out.length - 1 - i] *= i / fade; }
  return out;
}

async function main() {
  mkdirSync(OUT, { recursive: true });
  console.log(`Loading Kokoro (${MODEL}, first run downloads about 330 MB)...`);
  const tts = await KokoroTTS.from_pretrained(MODEL, { dtype: 'fp32', device: 'cpu' });

  if (process.argv.includes('--samples')) {
    const dir = join(ROOT, 'build', 'voice-samples');
    mkdirSync(dir, { recursive: true });
    const text = `${VOICE[0].text} ${VOICE[1].text} ${VOICE[6].text} ${VOICE[7].text}`;
    for (const v of ['af_heart', 'af_bella', 'bf_emma', 'am_michael', 'am_fenrir', 'bm_george']) {
      const audio = await tts.generate(say(text), { voice: v, speed: 0.92 });
      writeWav(join(dir, `${v}.wav`), [audio.audio], audio.sampling_rate);
      console.log(`  ${v}.wav`);
    }
    return;
  }

  const manifestPath = join(OUT, 'voice.json');
  const old = existsSync(manifestPath) ? JSON.parse(readFileSync(manifestPath, 'utf8')) : {};
  const manifest = { voice: VOICE_NAME, lines: {} };
  for (const line of VOICE) {
    const speed = line.speed ?? 1;
    const key = createHash('sha1').update(`${VOICE_NAME}|${speed}|${line.text}`).digest('hex').slice(0, 12);
    const file = `${line.id}.wav`;
    const prev = old.lines?.[line.id];
    if (prev?.key === key && existsSync(join(OUT, file))) { manifest.lines[line.id] = prev; continue; }
    const audio = await tts.generate(say(line.text), { voice: VOICE_NAME, speed });
    const samples = trim(audio.audio, audio.sampling_rate);
    writeWav(join(OUT, file), [samples], audio.sampling_rate);
    manifest.lines[line.id] = { key, file, seconds: +(samples.length / audio.sampling_rate).toFixed(3) };
    console.log(`  ${line.id.padEnd(11)} ${manifest.lines[line.id].seconds.toFixed(2)} s  "${line.text}"`);
  }
  writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));

  // Does every line finish before the next one starts?
  let ok = true;
  VOICE.forEach((line, i) => {
    const end = line.at + manifest.lines[line.id].seconds;
    const next = VOICE[i + 1];
    if (next && end > next.at - 0.15) { ok = false; console.log(`  ! ${line.id} ends at ${end.toFixed(2)} s, too close to ${next.id} at ${next.at} s`); }
  });
  console.log(ok ? 'Voice: every line fits its slot.' : 'Voice: move the lines above in src/timeline.ts.');
}

main().catch((e) => { console.error(e); process.exit(1); });
