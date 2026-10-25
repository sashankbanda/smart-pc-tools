// Shared look: colours, easing, the night backdrop, the horizon of light, film grain, titles,
// photo tiles, the phone, the laptop and the logo.
import React from 'react';
import { AbsoluteFill, Easing, Img, random, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { FPS } from './timeline';

export const useTime = () => useCurrentFrame() / FPS;
export const useLayout = () => {
  const { width, height } = useVideoConfig();
  return { W: width, H: height, vertical: height > width };
};

export const clamp01 = (x: number) => Math.max(0, Math.min(1, x));
export const E = {
  out: Easing.bezier(0.16, 1, 0.3, 1),
  inOut: Easing.bezier(0.65, 0, 0.35, 1),
  in: Easing.bezier(0.7, 0, 0.84, 0),
  soft: Easing.bezier(0.33, 0, 0.2, 1),
};
// 0 before a, 1 after b, eased in between.
export const prog = (t: number, a: number, b: number, ease = E.inOut) => ease(clamp01((t - a) / (b - a)));
export const mix = (a: number, b: number, p: number) => a + (b - a) * p;
// Fades in over fi seconds from a, out over fo seconds ending at b.
export const life = (t: number, a: number, b: number, fi = 0.5, fo = 0.5) => Math.min(prog(t, a, a + fi, E.out), 1 - prog(t, b - fo, b));

export const C = {
  bg: '#04050d',
  ink: '#F8FAFC',
  soft: '#CBD5E1',
  muted: '#8B95A9',
  indigo: '#6366F1',
  indigoLight: '#A5B4FC',
  cyan: '#22D3EE',
  green: '#22C55E',
  red: '#F43F5E',
};
export const FONT = '"Inter Variable", Inter, "Segoe UI", sans-serif';

// ---------------------------------------------------------------------------
// atmosphere
// ---------------------------------------------------------------------------

export const Backdrop: React.FC<{ glow: number; warm?: number }> = ({ glow, warm = 0 }) => (
  <AbsoluteFill
    style={{
      background: [
        `radial-gradient(ellipse 70% 55% at 50% 108%, rgba(79,70,229,${0.42 * glow}) 0%, transparent 70%)`,
        `radial-gradient(ellipse 50% 40% at 18% 10%, rgba(34,211,238,${0.07 * glow}) 0%, transparent 70%)`,
        `radial-gradient(ellipse 60% 50% at 50% 50%, rgba(244,63,94,${0.10 * warm}) 0%, transparent 70%)`,
        C.bg,
      ].join(','),
    }}
  />
);

// A planet's edge of light, rising from below. rise 0 = hidden, 1 = fully up.
export const Horizon: React.FC<{ rise: number }> = ({ rise }) => {
  const { W, H, vertical } = useLayout();
  if (rise <= 0.001) return null;
  const D = vertical ? H * 1.7 : W * 2.3;
  const top = mix(H + 60, vertical ? H * 0.74 : H * 0.69, rise);
  const ring: React.CSSProperties = { position: 'absolute', left: W / 2 - D / 2, top, width: D, height: D, borderRadius: '50%' };
  return (
    <AbsoluteFill style={{ pointerEvents: 'none', maskImage: 'linear-gradient(90deg, transparent 2%, black 28%, black 72%, transparent 98%)' }}>
      {/* the glow in the sky above the edge */}
      <div style={{ ...ring, boxShadow: `0 0 ${160 * rise}px ${50 * rise}px rgba(99,102,241,${0.5 * rise}), 0 0 ${420 * rise}px ${150 * rise}px rgba(34,211,238,${0.16 * rise})` }} />
      {/* the planet, with its bright rim */}
      <div
        style={{
          ...ring,
          background: 'radial-gradient(circle at 50% 0%, #1b1a4a 0%, #090a1c 12%, #04050d 30%)',
          boxShadow: `inset 0 3px 2px -1px rgba(224,231,255,${0.95 * rise}), inset 0 14px 34px -8px rgba(129,140,248,${0.8 * rise}), inset 0 60px 120px -40px rgba(34,211,238,${0.35 * rise})`,
        }}
      />
    </AbsoluteFill>
  );
};

export const Grain: React.FC<{ opacity?: number }> = ({ opacity = 0.09 }) => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill style={{ opacity, mixBlendMode: 'overlay', pointerEvents: 'none' }}>
      <svg width="100%" height="100%">
        <filter id="grain">
          <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves={2} seed={f % 113} stitchTiles="stitch" />
          <feColorMatrix type="saturate" values="0" />
        </filter>
        <rect width="100%" height="100%" filter="url(#grain)" />
      </svg>
    </AbsoluteFill>
  );
};

export const Vignette: React.FC = () => (
  <AbsoluteFill style={{ pointerEvents: 'none', background: 'radial-gradient(ellipse 85% 80% at 50% 50%, transparent 55%, rgba(0,0,0,0.6) 100%)' }} />
);

// ---------------------------------------------------------------------------
// type
// ---------------------------------------------------------------------------

// Words arrive one after another: rising a little, sharpening out of a soft blur.
export const Words: React.FC<{
  text: string; t: number; from: number; to: number;
  size?: number; weight?: number; color?: string; align?: 'left' | 'center'; stagger?: number; style?: React.CSSProperties;
}> = ({ text, t, from, to, size = 64, weight = 620, color = C.ink, align = 'left', stagger = 0.07, style }) => {
  if (t < from - 0.1 || t > to + 0.1) return null;
  const leave = prog(t, to - 0.45, to);
  return (
    <div style={{ fontFamily: FONT, fontSize: size, fontWeight: weight, letterSpacing: '-0.025em', lineHeight: 1.08, color, textAlign: align, opacity: 1 - leave, transform: `translateY(${-14 * leave}px)`, ...style }}>
      {text.split(' ').map((w, i) => {
        const p = prog(t, from + i * stagger, from + i * stagger + 0.7, E.out);
        return (
          <span key={i} style={{ display: 'inline-block', opacity: p, transform: `translateY(${(1 - p) * 0.45 * size}px)`, filter: `blur(${(1 - p) * 10}px)`, marginRight: '0.26em' }}>
            {w}
          </span>
        );
      })}
    </div>
  );
};

export const Eyebrow: React.FC<{ text: string; icon?: string; t: number; from: number; to: number; align?: 'left' | 'center' }> = ({ text, icon, t, from, to, align = 'left' }) => {
  const o = life(t, from, to, 0.6, 0.45);
  if (o <= 0) return null;
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 14, justifyContent: align === 'center' ? 'center' : 'flex-start', opacity: o, transform: `translateX(${(1 - prog(t, from, from + 0.8, E.out)) * -18}px)` }}>
      {icon && <Img src={staticFile(`screens/${icon}.png`)} style={{ width: 40, height: 40, borderRadius: 10 }} />}
      <span style={{ fontFamily: FONT, fontSize: 22, fontWeight: 600, letterSpacing: '0.18em', textTransform: 'uppercase', color: C.indigoLight }}>{text}</span>
    </div>
  );
};

// ---------------------------------------------------------------------------
// photos, phone, laptop
// ---------------------------------------------------------------------------

// Made-up photo thumbnails: a sky, a horizon, a sun. No real photos are used.
const PALETTES = [
  ['#f59e0b', '#f472b6', '#7c3aed', '#1e1b4b', '#fde68a'],
  ['#7dd3fc', '#bae6fd', '#0369a1', '#0c4a6e', '#fefce8'],
  ['#a7f3d0', '#e0f2fe', '#166534', '#14532d', '#fef9c3'],
  ['#312e81', '#c026d3', '#1e1b4b', '#020617', '#f0abfc'],
  ['#fcd34d', '#fdba74', '#b45309', '#78350f', '#fffbeb'],
  ['#cbd5e1', '#f1f5f9', '#e2e8f0', '#94a3b8', '#ffffff'],
  ['#0f172a', '#1e3a8a', '#111827', '#030712', '#fbbf24'],
  ['#fda4af', '#fecdd3', '#9f1239', '#4c0519', '#fff1f2'],
  ['#67e8f9', '#a5f3fc', '#0e7490', '#164e63', '#ecfeff'],
];
export const tileBackground = (i: number) => {
  const p = PALETTES[Math.floor(random(`pal${i}`) * PALETTES.length)];
  const h = 45 + random(`h${i}`) * 25, sx = 15 + random(`sx${i}`) * 70, sy = 15 + random(`sy${i}`) * (h - 25), r = 6 + random(`r${i}`) * 9;
  return `radial-gradient(circle at ${sx}% ${sy}%, ${p[4]} 0, ${p[4]} ${r}%, transparent ${r + 7}%), linear-gradient(180deg, ${p[0]} 0%, ${p[1]} ${h}%, ${p[2]} ${h}%, ${p[3]} 100%)`;
};

export const Tile: React.FC<{ i: number; size: number; style?: React.CSSProperties; check?: number }> = ({ i, size, style, check = 0 }) => (
  <div style={{ position: 'absolute', width: size, height: size, borderRadius: size * 0.1, background: tileBackground(i), ...style }}>
    {check > 0 && (
      <div style={{ position: 'absolute', right: -size * 0.1, top: -size * 0.1, width: size * 0.42, height: size * 0.42, borderRadius: '50%', background: C.green, boxShadow: `0 0 ${size * 0.3}px rgba(34,197,94,0.7)`, transform: `scale(${check})`, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <svg viewBox="0 0 24 24" width="62%" height="62%"><path d="M5 12.5l4.2 4.2L19 7" fill="none" stroke="white" strokeWidth={3.2} strokeLinecap="round" strokeLinejoin="round" /></svg>
      </div>
    )}
  </div>
);

export const Phone: React.FC<{ fill: number; style?: React.CSSProperties; label?: string; danger?: number }> = ({ fill, style, label, danger = 1 }) => {
  const W = 360, H = 740, cols = 4, size = 70, gap = 9;
  const barColor = `rgb(${mix(34, 244, danger)}, ${mix(197, 63, danger)}, ${mix(94, 94, danger)})`;
  return (
    <div style={{ position: 'absolute', width: W, height: H, borderRadius: 58, background: '#0a0e1c', border: '9px solid #1d2338', boxShadow: '0 50px 120px -30px rgba(0,0,0,0.9), inset 0 0 0 1px rgba(255,255,255,0.06), 0 0 0 1px rgba(255,255,255,0.08)', overflow: 'hidden', ...style }}>
      <div style={{ position: 'absolute', left: W / 2 - 60, top: 14, width: 104, height: 28, borderRadius: 14, background: '#000', zIndex: 2 }} />
      <div style={{ position: 'absolute', left: 18, top: 150, width: W, height: H }}>
        {Array.from({ length: cols * 7 }, (_, i) => (
          <Tile key={i} i={i + 300} size={size} style={{ left: (i % cols) * (size + gap), top: Math.floor(i / cols) * (size + gap), opacity: 0.95 }} />
        ))}
      </div>
      <div style={{ position: 'absolute', left: 16, right: 16, top: 58, padding: '14px 16px', borderRadius: 18, background: 'rgba(15,20,40,0.92)', border: '1px solid rgba(255,255,255,0.08)', fontFamily: FONT, zIndex: 1 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', color: C.soft, fontSize: 15, fontWeight: 600 }}>
          <span>Storage</span>
          <span style={{ color: barColor }}>{label}</span>
        </div>
        <div style={{ marginTop: 10, height: 8, borderRadius: 4, background: 'rgba(255,255,255,0.12)' }}>
          <div style={{ width: `${fill * 100}%`, height: '100%', borderRadius: 4, background: barColor, boxShadow: `0 0 14px ${barColor}` }} />
        </div>
      </div>
    </div>
  );
};

export const Laptop: React.FC<{ children: React.ReactNode; style?: React.CSSProperties }> = ({ children, style }) => (
  <div style={{ position: 'absolute', width: 820, height: 560, ...style }}>
    <div style={{ position: 'absolute', left: 0, top: 0, width: 820, height: 520, borderRadius: 22, background: '#0a0e1c', border: '12px solid #1d2338', boxShadow: '0 50px 120px -30px rgba(0,0,0,0.9), 0 0 0 1px rgba(255,255,255,0.08)', overflow: 'hidden' }}>
      {children}
    </div>
    <div style={{ position: 'absolute', left: -60, top: 518, width: 940, height: 26, borderRadius: '4px 4px 18px 18px', background: 'linear-gradient(180deg, #2a3150, #151a2e)', boxShadow: '0 30px 60px -20px rgba(0,0,0,0.9)' }} />
  </div>
);

// ---------------------------------------------------------------------------
// logo
// ---------------------------------------------------------------------------

export const Logo: React.FC<{ t: number; from: number; scale?: number; style?: React.CSSProperties }> = ({ t, from, scale = 1, style }) => {
  const icons = ['icon-transfer', 'icon-cleanup', 'icon-memory'];
  const word = 'Smart PC Tools';
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', transform: `scale(${scale})`, ...style }}>
      <div style={{ display: 'flex', gap: 18, marginBottom: 34 }}>
        {icons.map((ic, i) => {
          const p = prog(t, from + i * 0.09, from + i * 0.09 + 0.9, E.out);
          return <Img key={ic} src={staticFile(`screens/${ic}.png`)} style={{ width: 76, height: 76, borderRadius: 19, opacity: p, transform: `translateY(${(1 - p) * 26}px) scale(${mix(0.85, 1, p)})`, boxShadow: `0 18px 40px -12px rgba(0,0,0,0.8), 0 0 ${40 * p}px rgba(99,102,241,0.35)` }} />;
        })}
      </div>
      <div style={{ fontFamily: FONT, fontSize: 112, fontWeight: 650, letterSpacing: '-0.035em', lineHeight: 1, whiteSpace: 'nowrap' }}>
        {word.split('').map((ch, i) => {
          const p = prog(t, from + 0.3 + i * 0.03, from + 0.3 + i * 0.03 + 0.8, E.out);
          return (
            <span key={i} style={{ display: 'inline-block', opacity: p, filter: `blur(${(1 - p) * 12}px)`, transform: `translateY(${(1 - p) * 20}px)`, background: 'linear-gradient(180deg, #ffffff 30%, #c7d2fe 100%)', WebkitBackgroundClip: 'text', color: 'transparent', whiteSpace: 'pre' }}>
              {ch}
            </span>
          );
        })}
      </div>
    </div>
  );
};
