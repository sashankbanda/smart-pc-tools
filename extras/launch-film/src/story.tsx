// The scenes. Every time here is absolute (seconds from the start), matching src/timeline.ts.
import React from 'react';
import { AbsoluteFill, Img, staticFile } from 'remotion';
import { C, E, Eyebrow, FONT, Laptop, Logo, Phone, Tile, Words, life, mix, prog, useLayout } from './kit';
import { TITLES } from './timeline';

// ---------------------------------------------------------------------------
// 1. hook (0-5) and the library that the outcome comes back to
// ---------------------------------------------------------------------------

const COLS = 40, ROWS = 24, SIZE = 64, GAP = 10;
const CC = Math.floor(COLS / 2), CR = Math.floor(ROWS / 2);

// The whole photo library. appear(i, d) and check(i, x, y) decide each tile's state.
const Library: React.FC<{ scale: number; tilt: number; opacity: number; appear: (d: number, i: number) => number; check?: (x: number, y: number) => number; blur?: number; centreGlow?: number }> = ({ scale, tilt, opacity, appear, check, blur = 0, centreGlow = 0 }) => {
  const { W, H } = useLayout();
  const gw = COLS * (SIZE + GAP), gh = ROWS * (SIZE + GAP);
  return (
    <AbsoluteFill style={{ perspective: 1600, opacity, filter: blur ? `blur(${blur}px)` : undefined }}>
      <div style={{
        position: 'absolute', left: W / 2 - (CC * (SIZE + GAP) + SIZE / 2), top: H / 2 - (CR * (SIZE + GAP) + SIZE / 2), width: gw, height: gh,
        transformOrigin: `${CC * (SIZE + GAP) + SIZE / 2}px ${CR * (SIZE + GAP) + SIZE / 2}px`, transform: `rotateX(${tilt}deg) scale(${scale})`,
      }}>
        {Array.from({ length: COLS * ROWS }, (_, i) => {
          const x = i % COLS, y = Math.floor(i / COLS);
          const d = Math.hypot(x - CC, (y - CR) * 1.15);
          const o = appear(d, i);
          if (o <= 0.003) return null;
          const centre = x === CC && y === CR;
          return (
            <Tile key={i} i={i} size={SIZE} check={check ? check(x, y) : 0}
              style={{ left: x * (SIZE + GAP), top: y * (SIZE + GAP), opacity: o, boxShadow: centre && centreGlow ? `0 0 ${50 * centreGlow}px rgba(255,255,255,${0.35 * centreGlow})` : undefined }} />
          );
        })}
      </div>
    </AbsoluteFill>
  );
};

export const Hook: React.FC<{ t: number }> = ({ t }) => {
  if (t > 6.4) return null;
  const pull = prog(t, 1.3, 5.3, E.inOut);
  const compress = prog(t, 5.0, 6.2, E.in);
  return (
    <Library
      scale={mix(4.4, 0.95, pull) * mix(1, 0.2, compress)}
      tilt={mix(0, 10, pull)}
      opacity={1 - prog(t, 5.5, 6.3)}
      centreGlow={1 - prog(t, 1.5, 3.5)}
      appear={(d) => (d === 0 ? prog(t, 0.25, 1.4, E.out) : 0.82 * prog(t, 1.55 + d * 0.085, 2.1 + d * 0.085, E.out))}
    />
  );
};

// ---------------------------------------------------------------------------
// 2. problem (5-15.2)
// ---------------------------------------------------------------------------

const STALL = 8.9;

const CopyDialog: React.FC<{ t: number }> = ({ t }) => {
  const progress = t < STALL ? mix(0.04, 0.34, prog(t, 7.8, STALL, (x) => x)) : mix(0.34, 0, prog(t, 11.0, 11.8));
  const stalled = t >= STALL && t < 11.0, restarting = t >= 11.0;
  const status = stalled ? 'Copy interrupted' : restarting ? 'Starting over...' : 'About 2 hours left';
  const barColor = stalled ? C.red : C.indigo;
  const question = prog(t, 12.6, 13.3);
  return (
    <AbsoluteFill style={{ background: 'linear-gradient(180deg, #111731, #0b1022)', fontFamily: FONT }}>
      <div style={{ position: 'absolute', left: 56, top: 70, right: 56, opacity: 1 - question }}>
        <div style={{ color: C.ink, fontSize: 30, fontWeight: 600 }}>Copying photos and videos</div>
        <div style={{ color: stalled ? C.red : C.muted, fontSize: 21, marginTop: 10 }}>{status}</div>
        <div style={{ marginTop: 34, height: 12, borderRadius: 6, background: 'rgba(255,255,255,0.1)' }}>
          <div style={{ width: `${progress * 100}%`, height: '100%', borderRadius: 6, background: barColor, boxShadow: `0 0 18px ${barColor}` }} />
        </div>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 10, marginTop: 40 }}>
          {Array.from({ length: 18 }, (_, i) => {
            const landed = i / 18 < progress * 2.6;
            return <div key={i} style={{ position: 'relative', width: 70, height: 70, opacity: landed ? 1 : 0.12 }}><Tile i={i + 600} size={70} style={{ filter: stalled && landed ? 'grayscale(0.7)' : undefined }} /></div>;
          })}
        </div>
      </div>
      {/* did everything make it? A folder with gaps. */}
      <div style={{ position: 'absolute', left: 56, top: 70, right: 56, opacity: question }}>
        <div style={{ color: C.ink, fontSize: 30, fontWeight: 600 }}>Photos</div>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 10, marginTop: 34 }}>
          {Array.from({ length: 24 }, (_, i) => {
            const missing = [3, 8, 13, 14, 20].includes(i);
            return missing
              ? <div key={i} style={{ width: 70, height: 70, borderRadius: 7, border: '2px dashed rgba(244,63,94,0.7)' }} />
              : <div key={i} style={{ position: 'relative', width: 70, height: 70 }}><Tile i={i + 600} size={70} /></div>;
          })}
        </div>
      </div>
      <div style={{ position: 'absolute', right: 40, bottom: 34, width: 84, height: 84, borderRadius: '50%', background: 'rgba(244,63,94,0.15)', border: '2px solid rgba(244,63,94,0.8)', color: '#fecdd3', fontSize: 52, fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center', opacity: question, transform: `scale(${mix(0.6, 1, prog(t, 12.8, 13.5, E.out)) * (1 + 0.05 * Math.sin(t * 5))})` }}>?</div>
    </AbsoluteFill>
  );
};

export const Problem: React.FC<{ t: number }> = ({ t }) => {
  const { W, H, vertical } = useLayout();
  if (t < 5.0 || t > 15.4) return null;
  const phoneIn = prog(t, 5.3, 6.3, E.out);
  const split = prog(t, 7.0, 7.9);
  const sink = prog(t, 14.3, 15.25, E.in);
  const laptopIn = prog(t, 7.0, 8.0, E.out);

  // Phone and laptop positions (centre points).
  const phone = vertical ? { x: W / 2, y: mix(H / 2, H * 0.3, split) } : { x: mix(W / 2, W * 0.27, split), y: H * 0.54 };
  const laptop = vertical ? { x: W / 2, y: H * 0.72 } : { x: W * 0.64, y: H * 0.55 };
  const lapScale = vertical ? 0.95 : 0.92;

  // One cable from the phone's port to the laptop; at the stall its laptop end drops out.
  const phoneScale = vertical ? 0.78 : 0.92;
  const a = { x: phone.x, y: phone.y + 370 * phoneScale - 4 };
  const plugged = vertical ? { x: laptop.x + 300, y: laptop.y - 280 * lapScale + 30 } : { x: laptop.x - 410 * lapScale + 8, y: laptop.y + 120 };
  const drop = prog(t, STALL, STALL + 0.55, E.out);
  const b = { x: plugged.x + (vertical ? 60 : -70) * drop, y: plugged.y + 110 * drop };
  const c1 = vertical ? { x: a.x + 40, y: a.y + 140 } : { x: a.x, y: a.y + 150 };
  const c2 = vertical ? { x: b.x + 160, y: b.y - 160 } : { x: b.x - 200, y: b.y + 40 };
  const cable = `M ${a.x} ${a.y} C ${c1.x} ${c1.y} ${c2.x} ${c2.y} ${b.x} ${b.y}`;
  const draw = prog(t, 7.4, 8.1);
  const flowing = t > 7.8 && t < STALL;
  const cableColor = t < STALL ? 'rgba(129,140,248,0.9)' : 'rgba(148,163,184,0.5)';

  const titleTop = vertical ? H * 0.06 : H * 0.1;
  return (
    <AbsoluteFill style={{ opacity: (1 - sink) * prog(t, 5.0, 5.4), transform: `translateY(${sink * 40}px) scale(${mix(1, 0.96, sink)})` }}>
      <svg width={W} height={H} style={{ position: 'absolute', inset: 0, opacity: draw * laptopIn }}>
        <path d={cable} stroke={cableColor} strokeWidth={5} fill="none" strokeLinecap="round" strokeDasharray={2400} strokeDashoffset={2400 * (1 - draw)} />
        {/* the plug */}
        <rect x={b.x - 9} y={b.y - 14} width={18} height={28} rx={4} fill={t < STALL ? '#c7d2fe' : '#64748b'} transform={`rotate(${vertical ? -30 + 40 * drop : 90 - 50 * drop} ${b.x} ${b.y})`} opacity={draw} />
        {flowing && <path d={cable} stroke="#e0e7ff" strokeWidth={5} fill="none" strokeLinecap="round" strokeDasharray="4 46" strokeDashoffset={-t * 160} style={{ filter: 'drop-shadow(0 0 6px #818cf8)' }} />}
      </svg>
      <div style={{ position: 'absolute', left: phone.x - 180, top: phone.y - 370, opacity: phoneIn, transform: `scale(${mix(1.3, vertical ? 0.78 : 0.92, phoneIn)})` }}>
        <Phone fill={0.97} label="Almost full" />
      </div>
      <div style={{ position: 'absolute', left: laptop.x - 410, top: laptop.y - 280, opacity: laptopIn, transform: `translateX(${(1 - laptopIn) * 60}px) scale(${lapScale})` }}>
        <Laptop><CopyDialog t={t} /></Laptop>
      </div>
      <div style={{ position: 'absolute', left: 0, right: 0, top: titleTop }}>
        {TITLES.filter((x) => x.scene === 'problem').map((x) => (
          <Words key={x.text} text={x.text} t={t} from={x.from} to={x.to} size={vertical ? 76 : 68} align="center" style={{ position: 'absolute', left: 0, right: 0 }} />
        ))}
      </div>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------
// 3. reveal (15.2-21.9): the logo, then the three tools in a fan
// ---------------------------------------------------------------------------

export const Reveal: React.FC<{ t: number }> = ({ t }) => {
  const { W, H, vertical } = useLayout();
  if (t < 15.2 || t > 22.3) return null;
  const up = prog(t, 18.1, 19.1);
  const gone = prog(t, 21.0, 21.8);
  const logoY = mix(H * (vertical ? 0.4 : 0.38), H * (vertical ? 0.12 : 0.12), up);
  const side = (dir: -1 | 1, img: string, label: string) => {
    const p = prog(t, 18.75 + (dir > 0 ? 0.12 : 0), 19.9 + (dir > 0 ? 0.12 : 0), E.out);
    const w = vertical ? 470 : 640, h = w * 761 / 1164;
    const cx = W / 2 + dir * (vertical ? 330 : 600) + dir * gone * 300;
    const cy = (vertical ? H * 0.5 : H * 0.6) + (1 - p) * 300;
    return (
      <div key={img} style={{ position: 'absolute', left: cx - w / 2, top: cy - h / 2, width: w, opacity: p * (1 - gone), transform: `perspective(2000px) rotateY(${-dir * 32}deg) scale(0.86)` }}>
        <div style={{ position: 'relative', borderRadius: 16, overflow: 'hidden', background: '#F1F5F9', boxShadow: '0 50px 120px -30px rgba(0,0,0,0.9), 0 0 0 1px rgba(255,255,255,0.1)' }}>
          <Img src={staticFile(`screens/${img}.png`)} style={{ width: w, display: 'block' }} />
          {/* a little shade, so the middle card leads (a CSS filter here would blank the image in 3D) */}
          <div style={{ position: 'absolute', inset: 0, background: `linear-gradient(${dir > 0 ? 90 : 270}deg, rgba(4,5,13,0.05), rgba(4,5,13,0.35))` }} />
        </div>
        <div style={{ marginTop: 28, textAlign: 'center', fontFamily: FONT, fontSize: 28, fontWeight: 600, color: C.soft }}>{label}</div>
      </div>
    );
  };
  const centreLabel = life(t, 19.3, 21.2, 0.6, 0.4);
  return (
    <AbsoluteFill>
      <div style={{ position: 'absolute', left: 0, right: 0, top: logoY - 110, display: 'flex', justifyContent: 'center', opacity: 1 - gone }}>
        <Logo t={t} from={15.55} scale={mix(vertical ? 0.78 : 1, 0.55, up)} />
      </div>
      {side(-1, 'cleanup-task', 'Smart Cleanup')}
      {side(1, 'memory-home', 'Smart Memory')}
      <div style={{ position: 'absolute', left: 0, right: 0, top: (vertical ? H * 0.5 : H * 0.6) + (vertical ? 250 : 270), textAlign: 'center', fontFamily: FONT, fontSize: 28, fontWeight: 600, color: C.ink, opacity: centreLabel }}>Smart Transfer</div>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------
// 4. the tools at work (21.9-42.7): words beside the panel (the panel is in product.tsx)
// ---------------------------------------------------------------------------

const SEGMENTS = [
  { scene: 'transfer', label: 'Smart Transfer', icon: 'icon-transfer', from: 22.2, to: 32.1 },
  { scene: 'cleanup', label: 'Smart Cleanup', icon: 'icon-cleanup', from: 32.5, to: 37.1 },
  { scene: 'memory', label: 'Smart Memory', icon: 'icon-memory', from: 37.5, to: 42.6 },
] as const;

export const ToolWords: React.FC<{ t: number }> = ({ t }) => {
  const { W, H, vertical } = useLayout();
  if (t < 22 || t > 42.8) return null;
  const box: React.CSSProperties = vertical
    ? { position: 'absolute', left: 80, right: 80, top: H * 0.66 }
    : { position: 'absolute', left: W * 0.06, width: W * 0.27, top: H * 0.5 - 90 };
  const align = vertical ? 'center' : 'left';
  return (
    <div style={box}>
      {SEGMENTS.map((s) => (
        <div key={s.scene} style={{ position: 'absolute', left: 0, right: 0, top: 0 }}>
          <Eyebrow text={s.label} icon={s.icon} t={t} from={s.from} to={s.to} align={align} />
        </div>
      ))}
      <div style={{ position: 'absolute', left: 0, right: 0, top: 70 }}>
        {TITLES.filter((x) => ['transfer', 'cleanup', 'memory'].includes(x.scene)).map((x) => (
          <Words key={x.text} text={x.text} t={t} from={x.from} to={x.to} size={vertical ? 78 : 66} align={align} style={{ position: 'absolute', left: 0, right: 0 }} />
        ))}
      </div>
    </div>
  );
};

// ---------------------------------------------------------------------------
// 5. outcome (42.7-51.6)
// ---------------------------------------------------------------------------

export const Outcome: React.FC<{ t: number }> = ({ t }) => {
  const { W, H, vertical } = useLayout();
  if (t < 42.7 || t > 52.4) return null;
  const phoneIn = prog(t, 42.8, 43.7, E.out);
  const drain = prog(t, 43.7, 45.8, E.inOut);
  const into = prog(t, 46.2, 47.3, E.in);
  const wide = prog(t, 46.6, 47.8, E.out);
  const end = prog(t, 51.0, 52.0);
  const wave = (x: number, y: number) => {
    // a band of light crossing the library from left to right; tiles get their tick as it passes
    const pos = mix(-6, COLS + 6, prog(t, 46.9, 48.8, (v) => v));
    const p = (pos - x - (y - CR) * 0.35) / 3;
    return Math.max(0, Math.min(1, p)) > 0 ? Math.min(1, E.out(Math.min(1, Math.max(0, p)))) : 0;
  };
  const phone = vertical ? { x: W / 2, y: H * 0.34 } : { x: W * 0.66, y: H * 0.52 };
  const lines = [
    { text: 'Everything copied.', from: 43.4 },
    { text: 'Everything checked.', from: 45.1 },
  ];
  const linesBox: React.CSSProperties = vertical ? { position: 'absolute', left: 80, right: 80, top: H * 0.66 } : { position: 'absolute', left: W * 0.1, top: H * 0.42, width: W * 0.4 };
  return (
    <AbsoluteFill style={{ opacity: 1 - end }}>
      {wide > 0 && (
        <Library scale={mix(1.5, 0.92, wide)} tilt={8} opacity={wide} blur={mix(0, 6, prog(t, 47.5, 48.8))}
          appear={() => mix(0.35, 0.75, prog(t, 47.0, 48.2))} check={wave} />
      )}
      {wide > 0 && <AbsoluteFill style={{ background: `radial-gradient(ellipse 60% 45% at 50% 50%, rgba(4,5,13,${0.85 * prog(t, 47.4, 48.6)}) 0%, rgba(4,5,13,${0.6 * prog(t, 47.4, 48.6)}) 100%)` }} />}
      <div style={{ position: 'absolute', left: phone.x - 180, top: phone.y - 370, opacity: phoneIn * (1 - into), transform: `scale(${mix(0.8, vertical ? 0.78 : 0.92, phoneIn) * mix(1, 2.6, into)})` }}>
        <Phone fill={mix(0.97, 0.22, drain)} danger={1 - drain} label={drain > 0.55 ? 'Plenty of space' : 'Almost full'} />
      </div>
      <div style={{ ...linesBox, opacity: 1 - into }}>
        {lines.map((l, i) => (
          <Words key={l.text} text={l.text} t={t} from={l.from} to={47.0} size={vertical ? 76 : 70} align={vertical ? 'center' : 'left'} style={{ position: 'absolute', left: 0, right: 0, top: i * 92 }} />
        ))}
      </div>
      <div style={{ position: 'absolute', left: 0, right: 0, top: H / 2 - 70 }}>
        <Words text="Room to breathe." t={t} from={47.5} to={51.3} size={vertical ? 104 : 124} weight={650} align="center" stagger={0.12}
          style={{ textShadow: '0 0 60px rgba(99,102,241,0.55)' }} />
      </div>
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------------------
// 6. close (51.6-60)
// ---------------------------------------------------------------------------

export const Close: React.FC<{ t: number }> = ({ t }) => {
  const { H, vertical } = useLayout();
  if (t < 51.5) return null;
  const line = (text: string, from: number, size: number, color: string, top: number, weight = 500) => (
    <div style={{ position: 'absolute', left: 0, right: 0, top, textAlign: 'center', fontFamily: FONT, fontSize: size, fontWeight: weight, letterSpacing: '-0.01em', color, opacity: prog(t, from, from + 0.9, E.out), transform: `translateY(${(1 - prog(t, from, from + 0.9, E.out)) * 14}px)` }}>{text}</div>
  );
  const y = H * (vertical ? 0.36 : 0.3);
  return (
    <AbsoluteFill>
      <div style={{ position: 'absolute', left: 0, right: 0, top: y, display: 'flex', justifyContent: 'center' }}>
        <Logo t={t} from={51.7} scale={vertical ? 0.78 : 1} />
      </div>
      {line('Free for Windows 10 and 11', 54.4, vertical ? 40 : 38, C.soft, y + (vertical ? 250 : 290))}
      {line('One simple question at a time.', 56.1, vertical ? 34 : 30, C.indigoLight, y + (vertical ? 310 : 350))}
      {line('github.com/sashankbanda/smart-pc-tools', 56.8, vertical ? 30 : 26, C.muted, H * (vertical ? 0.86 : 0.88), 500)}
    </AbsoluteFill>
  );
};
