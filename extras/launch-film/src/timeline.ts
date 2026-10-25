// The whole film in one place: scenes, voice-over lines, on-screen words and sound cues, all in
// seconds. The voice, music, picture and subtitle scripts all read this file, so changing a time
// here moves everything that belongs to it. Times follow the real length of each voice line
// (public/audio/voice/voice.json) with natural gaps between phrases.

export const FPS = 30;
export const DURATION = 60;

export type SceneId = 'hook' | 'problem' | 'reveal' | 'transfer' | 'cleanup' | 'memory' | 'outcome' | 'close';

export const SCENES: { id: SceneId; from: number; to: number }[] = [
  { id: 'hook', from: 0, to: 5 },
  { id: 'problem', from: 5, to: 15.2 },
  { id: 'reveal', from: 15.2, to: 21.9 },
  { id: 'transfer', from: 21.9, to: 32.2 },
  { id: 'cleanup', from: 32.2, to: 37.2 },
  { id: 'memory', from: 37.2, to: 42.7 },
  { id: 'outcome', from: 42.7, to: 51.6 },
  { id: 'close', from: 51.6, to: DURATION },
];

export const sceneOf = (id: SceneId) => SCENES.find((s) => s.id === id)!;

// One voice file per line. `at` is when it starts; `speed` 1 is Kokoro's normal pace.
// Mood notes are for whoever edits the script: Kokoro itself only takes the words and the speed.
export type VoiceLine = { id: string; at: number; text: string; speed?: number; mood: string };

export const VOICE: VoiceLine[] = [
  { id: 'hook-1', at: 0.7, text: "Every photo you've ever taken...", speed: 0.88, mood: 'intimate' },
  { id: 'hook-2', at: 3.0, text: 'lives on one small phone.', speed: 0.88, mood: 'intimate' },

  { id: 'problem-1', at: 5.4, text: 'Moving it all to your PC takes hours.', speed: 0.92, mood: 'grounded' },
  { id: 'problem-2', at: 8.25, text: 'One interruption, and you start over.', speed: 0.92, mood: 'grounded' },
  { id: 'problem-3', at: 10.95, text: 'And when it finally finishes...', speed: 0.92, mood: 'grounded' },
  { id: 'problem-4', at: 13.0, text: 'did everything really make it?', speed: 0.9, mood: 'grounded, a real question' },

  { id: 'reveal-1', at: 16.2, text: 'Meet Smart PC Tools.', speed: 0.92, mood: 'assured, discovery' },
  { id: 'reveal-2', at: 18.7, text: 'Three simple helpers, for your Windows PC.', speed: 0.95, mood: 'assured' },

  { id: 'transfer-1', at: 22.2, text: 'Smart Transfer copies your photos and videos.', speed: 1.0, mood: 'clear' },
  { id: 'transfer-2', at: 25.3, text: 'Need your phone? Pause, and carry on later.', speed: 0.98, mood: 'conversational' },
  { id: 'transfer-3', at: 28.2, text: 'Then it checks every single file, before anything is removed.', speed: 0.98, mood: 'confident' },

  { id: 'cleanup-1', at: 32.5, text: 'Smart Cleanup finds duplicates and junk, and frees up space, safely.', speed: 1.0, mood: 'clear' },

  { id: 'memory-1', at: 37.5, text: "And Smart Memory closes the apps you don't need, so a slow PC can breathe again.", speed: 1.0, mood: 'clear, light' },

  { id: 'outcome-1', at: 43.4, text: 'Every file copied.', speed: 0.9, mood: 'composed' },
  { id: 'outcome-2', at: 45.1, text: 'Every file checked.', speed: 0.9, mood: 'composed' },
  { id: 'outcome-3', at: 47.0, text: 'Your phone has room again...', speed: 0.9, mood: 'optimistic' },
  { id: 'outcome-4', at: 48.95, text: 'and you never have to wonder.', speed: 0.9, mood: 'warm, uplifting' },

  { id: 'close-1', at: 52.3, text: 'Smart PC Tools.', speed: 0.9, mood: 'warm' },
  { id: 'close-2', at: 54.5, text: 'Free, for Windows.', speed: 0.92, mood: 'direct' },
  { id: 'close-3', at: 56.2, text: 'One simple question at a time.', speed: 0.9, mood: 'warm, memorable' },
];

// Words on screen. Kept short, and each on screen for at least 1.5 s.
export const TITLES: { from: number; to: number; text: string; scene: SceneId }[] = [
  { from: 6.4, to: 10.6, text: 'Storage full.', scene: 'problem' },
  { from: 10.9, to: 15.0, text: 'Start again?', scene: 'problem' },
  { from: 22.5, to: 25.1, text: 'iPhone, Android, any drive.', scene: 'transfer' },
  { from: 25.3, to: 28.0, text: 'Pause any time.', scene: 'transfer' },
  { from: 28.2, to: 32.0, text: 'Every file checked.', scene: 'transfer' },
  { from: 33.4, to: 37.0, text: 'Free up space, safely.', scene: 'cleanup' },
  { from: 38.6, to: 42.5, text: 'A faster PC, your choice.', scene: 'memory' },
];

// Sound effects, synthesized in scripts/audio.mjs. gain is in dB.
export type SfxKind = 'bell' | 'swell' | 'tick' | 'stall' | 'whoosh' | 'impact' | 'riser' | 'tap' | 'glide' | 'shimmer' | 'chime';
export const SFX: { at: number; kind: SfxKind; gain?: number }[] = [
  { at: 0.4, kind: 'bell', gain: -19 },
  { at: 1.6, kind: 'swell', gain: -20 },
  { at: 5.0, kind: 'whoosh', gain: -9 },
  { at: 6.4, kind: 'tick', gain: -14 },
  { at: 8.9, kind: 'stall', gain: -16 },
  { at: 13.9, kind: 'riser', gain: -16 },
  { at: 15.2, kind: 'impact', gain: -9 },
  { at: 21.9, kind: 'whoosh', gain: -9 },
  { at: 25.6, kind: 'tap', gain: -15 },
  { at: 29.2, kind: 'shimmer', gain: -27 },
  { at: 32.2, kind: 'whoosh', gain: -9 },
  { at: 35.3, kind: 'tap', gain: -15 },
  { at: 37.2, kind: 'whoosh', gain: -9 },
  { at: 39.9, kind: 'tap', gain: -16 },
  { at: 40.6, kind: 'glide', gain: -17 },
  { at: 42.7, kind: 'impact', gain: -10 },
  { at: 47.0, kind: 'shimmer', gain: -25 },
  { at: 51.0, kind: 'riser', gain: -16 },
  { at: 51.6, kind: 'chime', gain: -21 },
];

// The music follows the story. See scripts/audio.mjs for what each part plays.
export type MusicPart = 'air' | 'tension' | 'lift' | 'drive' | 'peak' | 'resolve';
export const MUSIC: { at: number; part: MusicPart }[] = [
  { at: 0, part: 'air' },
  { at: 5, part: 'tension' },
  { at: 15.2, part: 'lift' },
  { at: 21.9, part: 'drive' },
  { at: 42.7, part: 'peak' },
  { at: 51.6, part: 'resolve' },
];
