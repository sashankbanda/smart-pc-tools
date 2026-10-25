# Smart PC Tools: launch film

A 60-second product film, in a 16:9 and a 9:16 cut, rebuilt from code. It contains:

- **Picture:** real app screens, rendered by [Remotion](https://www.remotion.dev).
- **Voice-over:** a local neural voice, Kokoro.
- **Music and sound effects:** composed and synthesized here.

The plan, storyboard and script are in [PLAN.md](PLAN.md).

## Make it

You need Windows 10 or 11 and [Node.js](https://nodejs.org) 23.6 or newer (the scripts import `src/timeline.ts` directly).

```powershell
cd extras\launch-film
npm install        # once: Remotion, Kokoro, Inter (about 400 MB, all inside node_modules)
npm run capture    # the real app screens, taken by the apps themselves with demo data
npm run film       # voice -> soundtrack -> both cuts -> checks
```

The first `npm run film` also downloads the Kokoro voice model (about 330 MB) and Remotion's headless Chrome (about 120 MB).

| Step | Command | Makes |
| --- | --- | --- |
| Screens | `npm run capture` | `public/screens/*.png`: 10 real screens at 2x, and the 3 app icons |
| Voice | `npm run voice` | `public/audio/voice/*.wav`, one per line. Unchanged lines are reused |
| Soundtrack | `npm run audio` | `public/audio/mix.wav`, plus stems in `build/stems/` and a level report |
| Picture | `npm run render` | `out/smart-pc-tools-launch-16x9.mp4`, `-9x16.mp4`, `.srt` and `-mix.wav` |
| Checks | `npm run check` | `build/check/report.json`, plus a contact sheet of each finished file |
| Preview | `npm run studio` | Remotion Studio in the browser: scrub, and change things live |

To check a few moments quickly without rendering the whole film:

```powershell
node scripts/render.mjs --stills 16x9 --at 15.9,26.6,47.6
```

## Change it

Everything time-based lives in **`src/timeline.ts`**: scenes, voice lines (words, start time, pace), on-screen words, sound cues and music sections.

- **Change a voice line:** edit it in `VOICE`, then run `npm run voice`. It regenerates only that line and warns if a line runs into the next one.
- **Try another voice:** `node scripts/voice.mjs --samples` writes a few voices to `build/voice-samples/`. Then use `node scripts/voice.mjs --voice bf_emma`. The voice list is on the [Kokoro model card](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md).
- **Move a sound or change its level:** edit `SFX`, then run `npm run audio`.
- **Picture:**
  - `src/story.tsx` has the scenes.
  - `src/product.tsx` has the app panel, its camera moves and the highlight rings, in the window's own pixel coordinates (1164 x 761).
  - `src/kit.tsx` has the shared look.

The voice-over is generated, so it never needs re-recording. Kokoro takes only words and pace, so the delivery is steered by the punctuation, the pauses between lines and the `speed` of each line.

## What is in here

| Path | What it is |
| --- | --- |
| `PLAN.md` | Concept, storyboard, script, shot list, music and sound cue sheet |
| `src/timeline.ts` | The single source of timings |
| `src/Root.tsx`, `src/Film.tsx` | The two compositions (1920x1080 and 1080x1920, 30 fps), and how the layers stack |
| `src/kit.tsx`, `src/story.tsx`, `src/product.tsx` | The look, the scenes, the app panel |
| `scripts/capture.ps1` | Runs the apps on autopilot through `../video-tools/make-promo.ps1 -CaptureOnly` |
| `scripts/voice.mjs` | Kokoro voice-over, line by line |
| `scripts/audio.mjs`, `scripts/dsp.mjs` | Music, sound effects, voice processing, the mix, loudness |
| `scripts/render.mjs` | Renders both cuts, stills and the subtitles |
| `scripts/check.mjs`, `scripts/analyze-voice.mjs`, `scripts/contact-sheet.ps1` | Verification |

`public/screens`, `public/audio`, `build/` and `out/` are generated and git-ignored.

## Sound targets

- **Mix:** -14 LUFS integrated (ITU-R BS.1770-4), true peak at or below -1 dBTP (limited at -1.5).
- **Music:** ducks about 7 dB under the voice.
- **Voice:** each line is levelled to the same speaking loudness, then lightly EQ'd and compressed.

`npm run audio` prints the per-scene balance, and `npm run check` measures the delivered MP4s again.

## Licences

| Part | Licence |
| --- | --- |
| App screens and icons | Smart PC Tools' own interface, captured with demo data (no real files or apps) |
| Music and sound effects | Original, synthesized by `scripts/audio.mjs` for this film |
| Photo thumbnails | Generated gradients (`tileBackground` in `src/kit.tsx`), not real photos |
| Voice | [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) (Apache-2.0) via [kokoro-js](https://www.npmjs.com/package/kokoro-js) (Apache-2.0) |
| Font | [Inter](https://rsms.me/inter/), SIL Open Font License 1.1 |
| Renderer | [Remotion](https://www.remotion.dev/license): free for individuals and companies of up to 3 people; larger companies need a company licence |
