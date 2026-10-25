# Smart PC Tools - launch film plan

**60 s · 1920x1080 and 1080x1920 · 30 fps.** Every time below comes from `src/timeline.ts`, which is the single source of timings.

## 1. Concept: "Room to breathe"

A phone holds a lifetime of photos, and it is always full. Moving them is slow, fragile and uncertain. Smart PC Tools makes it calm: copy, check every file, then free up space - one simple question at a time.

**Look**

- **Setting:** a deep indigo night, with negative space throughout.
- **Light:** one horizon of light (indigo to cyan, the README's colours) rises at the reveal and returns for the logo.
- **Motif:** a single photo tile that becomes a library, and a green tick that confirms each one.
- **Product:** the real app screens float on a glass panel with a gentle 3D tilt.
- **Finish:** fine animated film grain and a vignette.
- **Type:** Inter, with words that sharpen out of a soft blur.

**Reference** (pin.it/68X0Ke2U7, a 20 s vertical SaaS motion piece, studied frame by frame from 40 extracted frames):

- **Borrowed:** the glowing planet-horizon arc, tilted glass UI cards in a fan, very sparse type, and the end card on the arc.
- **Changed:** our own palette instead of purple, and the product's real screens instead of mock UI.

## 2. Storyboard and shot list

| # | Time (s) | Picture | On screen | Voice-over (mood) |
| --- | --- | --- | --- | --- |
| 1 Hook | 0-5 | Black. One photo tile glows (0.25). The camera pulls back from 4.4x: tiles light up outward from the centre until a whole library fills the frame, tilting away. | - | "Every photo you've ever taken... lives on one small phone." *(intimate)* |
| 2 Problem | 5-15.2 | The library compresses into a phone whose storage bar is red (6). Phone left, laptop right, a cable draws in and data pulses along it (7-8.9). **8.9:** the plug drops out, the bar goes red: *Copy interrupted*. **11:** the bar rewinds, *Starting over...*. **12.6:** the laptop shows a photo folder with gaps and a pulsing "?". **14.3:** everything sinks into the dark. | "Storage full." then "Start again?" | "Moving it all to your PC takes hours. One interruption, and you start over. And when it finally finishes... did everything really make it?" *(grounded)* |
| 3 Reveal | 15.2-21.9 | **Impact:** the horizon rises. The three app icons, then the wordmark, sharpen in (15.55). **18.1:** the logo lifts and the three real apps rise from the horizon as a fan of glass cards, labelled. **21:** the side cards part and the centre card (Smart Transfer) glides right. | **Smart PC Tools** | "Meet Smart PC Tools. Three simple helpers, for your Windows PC." *(assured, discovery)* |
| 4a Transfer | 21.9-32.2 | Real screens: *From* (push toward the iPhone), then *Copying, 41%* with a ring on **Pause** (25.45), then *All 234 files are safely copied* with a push-in and a burst on the tick (29.2). | SMART TRANSFER · "iPhone, Android, any drive." · "Pause any time." · "Every file checked." | "Smart Transfer copies your photos and videos. Need your phone? Pause, and carry on later. Then it checks every single file, before anything is removed." *(clear, conversational)* |
| 4b Cleanup | 32.2-37.2 | The panel slides to *You can free up 385.1 MB*: a ring on *Duplicate files* (33.7), then on **Clean up 385.1 MB** (35.35). | SMART CLEANUP · "Free up space, safely." | "Smart Cleanup finds duplicates and junk, and frees up space, safely." |
| 4c Memory | 37.2-42.7 | *Your memory is nearly full* (92 %), then the app list (Google Chrome, VS Code, CapCut, Brave) with a ring on **Close 4 apps** (39.75), then *Closed 4 apps* with a burst on the tick. | SMART MEMORY · "A faster PC, your choice." | "And Smart Memory closes the apps you don't need, so a slow PC can breathe again." |
| 5 Outcome | 42.7-51.6 | **Impact:** the panel falls away; the phone returns, its storage drains from red to green (*Plenty of space*). **46.2:** the camera dives into the phone, the library returns, and a band of light sweeps across it, ticking every tile. It then dims and softens behind the line. | "Everything copied." · "Everything checked." · **"Room to breathe."** | "Every file copied. Every file checked. Your phone has room again... and you never have to wonder." *(composed, then uplifting)* |
| 6 Close | 51.6-60 | The horizon rises again; the logo sharpens in (51.7), the lines follow, quiet hold, fade to black (59.3). | Logo · "Free for Windows 10 and 11" · "One simple question at a time." · github.com/sashankbanda/smart-pc-tools | "Smart PC Tools. Free, for Windows. One simple question at a time." *(warm, direct)* |

**Facts the film relies on (all real):**

- Copying from an iPhone, an Android phone or any folder or drive.
- Pause and carry on later.
- Every file is checked before anything is removed.
- Cleanup finds duplicates and junk, and removes them to the Recycle Bin.
- Memory closes only the apps you tick.
- Free, for Windows 10 and 11.

The numbers on screen (41 %, 234 files, 385.1 MB, 92 %, 1.3 GB) are what the apps really showed on the demo data. There are no invented statistics, testimonials or speed claims.

## 3. Music cue sheet

All of it is composed in `scripts/audio.mjs`: D major, 92.3 BPM, so the eight bars of the demo section land exactly on 2.6 s each.

| Time (s) | Section | What plays |
| --- | --- | --- |
| 0-5 | air | An open Dsus2 pad, almost closed filter; a D sub swells in at 1.6 |
| 5-15.2 | tension | Bm(add9), Gmaj7, Em7, F#7sus4, F#7; a slow heartbeat kick that stops at the stall (8.9) and returns, quickening, toward the reveal; a lone high note at the stall |
| 15.2-21.9 | lift | Opens on Dadd9, then A/C# and Bm7, bright; a bell arpeggio from 18.2 |
| 21.9-42.7 | drive | G - D/F# - Asus2 - Bm7, played twice: eighth-note FM plucks, a soft kick on 1 and 3, a shaker from bar 2 |
| 42.7-50.5 | peak | Three brighter bars with a high octave, four-on-the-floor kick and a bell counter-melody |
| 50.5-51.6 | breath | Asus4, the drums stop |
| 51.6-60 | resolve | Dmaj9 held under the logo, a slow bell arpeggio, fading to silence |

## 4. Sound-effect cue sheet

| Time (s) | Sound | Purpose |
| --- | --- | --- |
| 0.4 | bell | The first photo |
| 1.6 | swell | The pull-back |
| 5.0 | whoosh | Into the phone |
| 6.4 | ticks, slowing | Copying takes hours |
| 8.9 | stall | The plug drops out |
| 13.9 to 15.2 | riser, then impact | Into the reveal |
| 21.9, 32.2, 37.2 | whoosh | Each tool arrives |
| 25.6, 35.3, 39.9 | tap | Pause, Clean up, Close 4 apps |
| 29.2 | shimmer | All files verified |
| 40.6 | glide | Memory freed |
| 42.7 | impact | The outcome |
| 47.0 | shimmer | The wave of ticks |
| 51.0 to 51.6 | riser, then chime | The logo |

## 5. How it is made

- **Rendering:** Remotion (React to MP4, with its own headless Chrome and ffmpeg). It needs no install beyond `npm install`.
- **Voice:** Kokoro-82M, voice `af_heart` (the highest-rated Kokoro voice), run locally.
- **What was not available:** no paid voice service was configured, and the Windows voices (David, Zira, Mark) were not good enough.

See [README.md](README.md) for the commands, the files and the licences.
