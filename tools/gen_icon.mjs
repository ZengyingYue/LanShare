// Generates the LanShare app icon (rounded square + paper plane) as PNG
// without any image dependencies. Run: node tools/gen_icon.mjs
import { deflateSync } from 'node:zlib';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

const BG = [79, 70, 229];    // indigo #4F46E5
const FG = [255, 255, 255];  // paper plane white

function render(size) {
  const px = new Uint8Array(size * size * 4);
  const r = size * 48 / 216;          // corner radius
  const scale = size / 216;
  // paper plane triangles in 216-space
  const tri = [
    [[46, 108], [170, 62], [92, 136]],   // body
    [[92, 136], [170, 62], [126, 156]],  // wing
  ];
  const insideTri = (x, y, t) => {
    let sign = 0;
    for (let i = 0; i < 3; i++) {
      const [x1, y1] = t[i];
      const [x2, y2] = t[(i + 1) % 3];
      const cross = (x2 - x1) * (y - y1) - (y2 - y1) * (x - x1);
      if (cross !== 0) {
        const s = cross > 0 ? 1 : -1;
        if (sign === 0) sign = s;
        else if (sign !== s) return false;
      }
    }
    return true;
  };
  const insideRounded = (x, y) => {
    const min = r, max = size - r;
    if (x >= min && x <= max) return true;
    if (y >= min && y <= max) return true;
    const cx = x < min ? min : max;
    const cy = y < min ? min : max;
    const dx = x - cx, dy = y - cy;
    return dx * dx + dy * dy <= r * r;
  };
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      // 2x supersampling for smooth edges
      let fgHits = 0, bgHits = 0;
      for (const [ox, oy] of [[0.25, 0.25], [0.75, 0.25], [0.25, 0.75], [0.75, 0.75]]) {
        const sx = x + ox, sy = y + oy;
        if (insideRounded(sx, sy)) {
          let inPlane = false;
          for (const t of tri) {
            if (insideTri(sx / scale, sy / scale, t)) { inPlane = true; break; }
          }
          if (inPlane) fgHits++; else bgHits++;
        }
      }
      const i = (y * size + x) * 4;
      if (fgHits + bgHits === 0) {
        px[i + 3] = 0; // outside rounded corner: transparent
        continue;
      }
      const mix = (c) => {
        const a = fgHits / (fgHits + bgHits);
        return Math.round(c[0] * a + BG[0] * (1 - a));
      };
      px[i] = mix(FG);
      px[i + 1] = Math.round(FG[1] * fgHits / (fgHits + bgHits) + BG[1] * (1 - fgHits / (fgHits + bgHits)));
      px[i + 2] = Math.round(FG[2] * fgHits / (fgHits + bgHits) + BG[2] * (1 - fgHits / (fgHits + bgHits)));
      px[i + 3] = 255;
    }
  }
  return px;
}

const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const out = Buffer.alloc(8 + data.length + 4);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, 'ascii');
  data.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}

function encodePng(size, rgba) {
  const raw = Buffer.alloc(size * (size * 4 + 1));
  for (let y = 0; y < size; y++) {
    raw[y * (size * 4 + 1)] = 0; // filter: none
    Buffer.from(rgba.buffer, y * size * 4, size * 4).copy(raw, y * (size * 4 + 1) + 1);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; ihdr[9] = 6; // 8-bit RGBA
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

const targets = [
  join(ROOT, 'app/ohos/AppScope/resources/base/media/app_icon.png'),
  join(ROOT, 'app/ohos/entry/src/main/resources/base/media/app_icon.png'),
];
for (const path of targets) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, encodePng(216, render(216)));
  console.log(`wrote ${path}`);
}
