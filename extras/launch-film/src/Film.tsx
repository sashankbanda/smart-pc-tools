import React from 'react';
import { AbsoluteFill, Audio, staticFile } from 'remotion';
import { Backdrop, E, Grain, Horizon, Vignette, mix, prog, useTime } from './kit';
import { Product } from './product';
import { Close, Hook, Outcome, Problem, Reveal, ToolWords } from './story';
import { DURATION } from './timeline';

// How high the horizon of light stands, and how much the sky glows, through the film.
const horizon = (t: number) => {
  if (t < 15.2) return 0;
  if (t < 18.1) return prog(t, 15.2, 16.8, E.out);   // lands with the impact
  if (t < 21.0) return mix(1, 0.6, prog(t, 18.1, 19.2));
  if (t < 42.7) return mix(0.6, 0.32, prog(t, 21.0, 22.5));
  if (t < 51.3) return mix(0.32, 0, prog(t, 42.7, 43.6));
  return prog(t, 51.3, 52.8);
};
const glow = (t: number) => {
  if (t < 5) return 0.15 + 0.25 * prog(t, 1, 5);
  if (t < 15.2) return mix(0.4, 0.1, prog(t, 5, 9));
  return mix(0.4, 1, prog(t, 15.2, 16.5));
};

// A soft bloom of light on each impact in the soundtrack.
const flash = (t: number) => Math.max(...[[15.2, 0.32], [42.7, 0.14]].map(([at, k]) => (t < at ? 0 : k * Math.min(1, (t - at) / 0.05) * Math.exp(-(t - at) / 0.35))));

export const Film: React.FC = () => {
  const t = useTime();
  const fadeOut = prog(t, DURATION - 0.7, DURATION - 0.05);
  const bloom = flash(t);
  return (
    <AbsoluteFill style={{ backgroundColor: '#000' }}>
      <AbsoluteFill style={{ opacity: 1 - fadeOut }}>
        <Backdrop glow={glow(t)} warm={t > 8.9 && t < 15 ? 0.6 * (1 - prog(t, 13.5, 15)) : 0} />
        <Horizon rise={horizon(t)} />
        <Hook t={t} />
        <Problem t={t} />
        <Reveal t={t} />
        <Product t={t} />
        <ToolWords t={t} />
        <Outcome t={t} />
        <Close t={t} />
        {bloom > 0.003 && <AbsoluteFill style={{ background: `radial-gradient(ellipse 80% 60% at 50% 85%, rgba(199,210,254,${bloom}) 0%, rgba(99,102,241,${bloom * 0.5}) 40%, transparent 75%)`, mixBlendMode: 'screen' }} />}
        <Vignette />
        <Grain />
      </AbsoluteFill>
      <Audio src={staticFile('audio/mix.wav')} />
    </AbsoluteFill>
  );
};
