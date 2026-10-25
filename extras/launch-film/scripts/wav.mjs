// Float WAV files: channels are Float32Arrays of samples between -1 and 1.
import { readFileSync, writeFileSync } from 'node:fs';

export function writeWav(path, channels, rate, bits = 16) {
  const n = channels[0].length, ch = channels.length, bytes = bits / 8;
  const buf = Buffer.alloc(44 + n * ch * bytes);
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + n * ch * bytes, 4); buf.write('WAVE', 8);
  buf.write('fmt ', 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(bits === 32 ? 3 : 1, 20); buf.writeUInt16LE(ch, 22);
  buf.writeUInt32LE(rate, 24); buf.writeUInt32LE(rate * ch * bytes, 28); buf.writeUInt16LE(ch * bytes, 32); buf.writeUInt16LE(bits, 34);
  buf.write('data', 36); buf.writeUInt32LE(n * ch * bytes, 40);
  let o = 44;
  for (let i = 0; i < n; i++) {
    for (let c = 0; c < ch; c++) {
      const v = Math.max(-1, Math.min(1, channels[c][i]));
      if (bits === 32) buf.writeFloatLE(v, o); else buf.writeInt16LE(Math.round(v * 32767), o);
      o += bytes;
    }
  }
  writeFileSync(path, buf);
}

export function readWav(path) {
  const buf = readFileSync(path);
  let pos = 12, fmt = null;
  while (pos + 8 <= buf.length) {
    const id = buf.toString('ascii', pos, pos + 4), size = buf.readUInt32LE(pos + 4);
    if (id === 'fmt ') fmt = { format: buf.readUInt16LE(pos + 8), ch: buf.readUInt16LE(pos + 10), rate: buf.readUInt32LE(pos + 12), bits: buf.readUInt16LE(pos + 22) };
    if (id === 'data') {
      const bytes = fmt.bits / 8, n = Math.floor(Math.min(size, buf.length - pos - 8) / (bytes * fmt.ch));
      const channels = Array.from({ length: fmt.ch }, () => new Float32Array(n));
      let o = pos + 8;
      for (let i = 0; i < n; i++) for (let c = 0; c < fmt.ch; c++) {
        channels[c][i] = fmt.format === 3 ? buf.readFloatLE(o) : buf.readInt16LE(o) / 32768;
        o += bytes;
      }
      return { channels, rate: fmt.rate };
    }
    pos += 8 + size + (size & 1);
  }
  throw new Error(`No audio data in ${path}`);
}
