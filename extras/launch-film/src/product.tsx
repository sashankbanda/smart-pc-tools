// The real app, on a glass panel: it rises out of the horizon in the reveal, moves to the right
// of the frame, and shows the real screens one after another, with the camera pushing in on
// what matters. Screen coordinates below are in the window's own pixels (1164 x 761).
import React from 'react';
import { Img, staticFile } from 'remotion';
import { C, E, life, mix, prog, useLayout } from './kit';

const SW = 1164, SH = 761;
type Key = { t: number; z: number; f: [number, number] };
type Ring = { from: number; to: number; rect: [number, number, number, number]; radius?: number };
type Spark = { at: number; x: number; y: number };
type Shot = { img: string; from: number; to: number; slide?: boolean; cam: Key[]; rings?: Ring[]; sparks?: Spark[] };

const CENTER: [number, number] = [SW / 2, SH / 2];
export const SHOTS: Shot[] = [
  { img: 'transfer-source', from: 18.3, to: 23.0, cam: [{ t: 21.6, z: 1, f: CENTER }, { t: 23.0, z: 1.1, f: [445, 262] }] },
  {
    img: 'transfer-copying', from: 23.0, to: 28.1,
    cam: [{ t: 23.0, z: 1.08, f: [700, 250] }, { t: 24.9, z: 1.16, f: [700, 240] }, { t: 26.0, z: 1.35, f: [1060, 651] }, { t: 27.5, z: 1.38, f: [1060, 655] }, { t: 28.1, z: 1.3, f: [900, 500] }],
    rings: [{ from: 25.45, to: 27.9, rect: [787, 699, 118, 46], radius: 10 }],
  },
  {
    img: 'transfer-result', from: 28.1, to: 32.2,
    cam: [{ t: 28.1, z: 1.2, f: [600, 170] }, { t: 29.0, z: 1.6, f: [560, 150] }, { t: 31.7, z: 1.68, f: [560, 160] }, { t: 32.2, z: 1.3, f: CENTER }],
    sparks: [{ at: 29.2, x: 358, y: 78 }],
  },
  {
    img: 'cleanup-findings', from: 32.2, to: 37.2, slide: true,
    cam: [{ t: 32.2, z: 1, f: CENTER }, { t: 33.0, z: 1, f: CENTER }, { t: 34.1, z: 1.45, f: [600, 213] }, { t: 34.9, z: 1.45, f: [600, 213] }, { t: 35.8, z: 1.65, f: [1013, 722] }, { t: 37.2, z: 1.7, f: [1013, 722] }],
    rings: [{ from: 33.7, to: 35.0, rect: [321, 153, 770, 119], radius: 14 }, { from: 35.35, to: 37.1, rect: [918, 699, 190, 46], radius: 10 }],
  },
  { img: 'memory-home', from: 37.2, to: 38.8, slide: true, cam: [{ t: 37.2, z: 1.1, f: [714, 242] }, { t: 38.8, z: 1.45, f: [560, 230] }] },
  {
    img: 'memory-apps', from: 38.8, to: 40.5,
    cam: [{ t: 38.8, z: 1.2, f: [714, 300] }, { t: 39.6, z: 1.3, f: [1074, 654] }, { t: 40.5, z: 1.35, f: [1074, 660] }],
    rings: [{ from: 39.75, to: 40.6, rect: [918, 699, 190, 46], radius: 10 }],
  },
  { img: 'memory-closed', from: 40.5, to: 43.4, cam: [{ t: 40.5, z: 1.45, f: [480, 150] }, { t: 42.7, z: 1.62, f: [480, 140] }], sparks: [{ at: 40.8, x: 358, y: 78 }] },
];

function camera(keys: Key[], t: number) {
  if (t <= keys[0].t) return keys[0];
  for (let i = 0; i < keys.length - 1; i++) {
    const a = keys[i], b = keys[i + 1];
    if (t <= b.t) { const p = prog(t, a.t, b.t); return { t, z: mix(a.z, b.z, p), f: [mix(a.f[0], b.f[0], p), mix(a.f[1], b.f[1], p)] as [number, number] }; }
  }
  return keys[keys.length - 1];
}

// One screen inside the panel: zoomed z around focus f, drifting the focus toward the middle so
// the thing that matters is never stuck at an edge, and never showing past the screen's edges.
const Screen: React.FC<{ shot: Shot; t: number; width: number }> = ({ shot, t, width }) => {
  const k = width / SW, h = SH * k;
  const cam = camera(shot.cam, t);
  const pull = 0.6 * (1 - 1 / cam.z);
  const px = mix(cam.f[0], SW / 2, pull) * k, py = mix(cam.f[1], SH / 2, pull) * k;
  let tx = px - cam.f[0] * k * cam.z, ty = py - cam.f[1] * k * cam.z;
  tx = Math.min(0, Math.max(width - width * cam.z, tx));
  ty = Math.min(0, Math.max(h - h * cam.z, ty));
  return (
    <div style={{ position: 'absolute', left: 0, top: 0, width, height: h, transformOrigin: '0 0', transform: `translate(${tx}px, ${ty}px) scale(${cam.z})`, background: '#F1F5F9' /* the window's own colour: screenshots leave it transparent */ }}>
      <Img src={staticFile(`screens/${shot.img}.png`)} style={{ width, height: h, display: 'block' }} />
      {shot.rings?.map((r, i) => {
        const o = life(t, r.from, r.to, 0.35, 0.3);
        if (o <= 0) return null;
        const pulse = 1 + 0.06 * Math.sin((t - r.from) * 5.5) * Math.exp(-(t - r.from) * 0.6);
        return (
          <div key={i} style={{
            position: 'absolute', left: (r.rect[0] - 5) * k, top: (r.rect[1] - 5) * k, width: (r.rect[2] + 10) * k, height: (r.rect[3] + 10) * k,
            borderRadius: (r.radius ?? 10) * k + 5 * k, border: `${2.5 * k}px solid ${C.indigo}`, opacity: o, transform: `scale(${pulse})`,
            boxShadow: `0 0 ${24 * k}px rgba(99,102,241,0.75), inset 0 0 ${14 * k}px rgba(99,102,241,0.35)`,
          }} />
        );
      })}
      {shot.sparks?.map((s, i) => {
        const p = prog(t, s.at, s.at + 1.1, E.out);
        if (t < s.at || t > s.at + 1.3) return null;
        return (
          <div key={i} style={{ position: 'absolute', left: s.x * k, top: s.y * k }}>
            <div style={{ position: 'absolute', left: -60 * k * p, top: -60 * k * p, width: 120 * k * p, height: 120 * k * p, borderRadius: '50%', border: `${3 * k}px solid rgba(34,197,94,${1 - p})` }} />
            {Array.from({ length: 8 }, (_, j) => {
              const a = (j / 8) * Math.PI * 2, d = 46 + 40 * p;
              return <div key={j} style={{ position: 'absolute', left: Math.cos(a) * d * k - 3 * k, top: Math.sin(a) * d * k - 3 * k, width: 6 * k, height: 6 * k, borderRadius: '50%', background: '#86efac', opacity: 1 - p, boxShadow: '0 0 8px #4ade80' }} />;
            })}
          </div>
        );
      })}
    </div>
  );
};

// Where the panel is: in the reveal it stands in the middle of the fan; then it moves right.
function geometry(t: number, W: number, H: number, vertical: boolean) {
  const fan = { cx: W / 2, cy: vertical ? H * 0.5 : H * 0.6, w: vertical ? 640 : 700, rx: 0, ry: 0 };
  const panel = vertical ? { cx: W / 2, cy: H * 0.36, w: 980, rx: 2, ry: 0 } : { cx: W * 0.645, cy: H * 0.5, w: 1150, rx: 2, ry: -7 };
  const rise = prog(t, 18.6, 19.8, E.out);   // after the logo has made room (18.1-19.1)
  const move = prog(t, 21.0, 22.5);
  const leave = prog(t, 42.7, 43.4, E.in);
  return {
    cx: mix(fan.cx, panel.cx, move),
    cy: mix(fan.cy + 320, fan.cy, rise) + (move > 0 ? mix(0, panel.cy - fan.cy, move) : 0),
    w: mix(fan.w, panel.w, move),
    rx: mix(mix(22, 4, rise), panel.rx, move),
    ry: mix(0, panel.ry, move) + Math.sin(t * 0.45) * 1.2 * move,
    opacity: rise * (1 - leave),
    scale: mix(1, 0.86, leave),
  };
}

export const Product: React.FC<{ t: number }> = ({ t }) => {
  const { W, H, vertical } = useLayout();
  if (t < 18.3 || t > 43.5) return null;
  const g = geometry(t, W, H, vertical);
  const h = g.w * SH / SW;
  const visible = SHOTS.filter((s) => t >= s.from - 0.01 && t <= s.to + 0.6);
  return (
    <div style={{ position: 'absolute', inset: 0, perspective: 2200, opacity: g.opacity }}>
      {/* light behind the panel, and its reflection on the floor */}
      <div style={{ position: 'absolute', left: g.cx - g.w * 0.7, top: g.cy - h * 0.7, width: g.w * 1.4, height: h * 1.4, background: 'radial-gradient(ellipse at 50% 50%, rgba(99,102,241,0.28), transparent 65%)' }} />
      <div style={{
        position: 'absolute', left: g.cx - g.w / 2, top: g.cy - h / 2, width: g.w, height: h, borderRadius: 18, overflow: 'hidden',
        transform: `rotateX(${g.rx}deg) rotateY(${g.ry}deg) scale(${g.scale})`,
        boxShadow: '0 70px 160px -30px rgba(0,0,0,0.85), 0 0 0 1px rgba(255,255,255,0.10), 0 0 80px -10px rgba(99,102,241,0.35)',
        background: '#F1F5F9',   // the app's own background, so screens cross-fade cleanly
      }}>
        {visible.map((s) => {
          const next = SHOTS[SHOTS.indexOf(s) + 1];
          // Each screen fades (or slides) in over the one before it.
          const dur = s.slide ? 0.6 : 0.35;
          const pin = s.from <= 18.31 ? 1 : prog(t, s.from, s.from + dur, s.slide ? E.inOut : E.soft);
          const pout = next?.slide ? prog(t, next.from, next.from + 0.6) : 0;
          const x = s.slide ? (1 - pin) * g.w * 0.35 : 0;
          return (
            <div key={s.img} style={{ position: 'absolute', inset: 0, opacity: s.slide ? Math.min(1, pin * 1.6) * (1 - pout) : pin * (1 - pout), transform: `translateX(${x - pout * g.w * 0.25}px)` }}>
              <Screen shot={s} t={t} width={g.w} />
            </div>
          );
        })}
        {/* glass: a soft sheen across the top */}
        <div style={{ position: 'absolute', inset: 0, background: 'linear-gradient(160deg, rgba(255,255,255,0.10) 0%, rgba(255,255,255,0) 30%)', pointerEvents: 'none' }} />
      </div>
    </div>
  );
};
