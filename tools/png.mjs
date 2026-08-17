// png.mjs - just enough PNG to read pixels back, in Node.
//
// The pixel gates used to shell out to `python3 -c 'from PIL import
// Image...'`. That is an unmanaged dependency on a machine that may not
// have it -- and on this one it does not, so test-grey and test-render
// died on a ModuleNotFoundError before reaching a single assertion. A
// suite that cannot run is worse than a suite that fails: it reports
// nothing and looks like a tooling problem rather than a gate.
//
// Node ships zlib, and romdev writes plain 8-bit non-interlaced PNGs, so
// the whole decoder is the IHDR, the concatenated IDAT and the five
// filter types. No dependency, no install, and the gates keep asserting
// on real pixels.
import { inflateSync } from 'zlib';
import { readFileSync } from 'fs';

// Returns { w, h, at(x, y) -> [r, g, b] }.
export function readPNG(path) {
  const buf = readFileSync(path);
  if (buf.readUInt32BE(0) !== 0x89504e47) throw new Error(`${path}: not a PNG`);

  let pos = 8, w = 0, h = 0, depth = 0, colour = 0, interlace = 0;
  const idat = [];
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos);
    const type = buf.toString('ascii', pos + 4, pos + 8);
    const data = buf.subarray(pos + 8, pos + 8 + len);
    if (type === 'IHDR') {
      w = data.readUInt32BE(0);
      h = data.readUInt32BE(4);
      depth = data[8]; colour = data[9]; interlace = data[12];
    } else if (type === 'IDAT') {
      idat.push(data);
    } else if (type === 'IEND') break;
    pos += 12 + len;               // len + type + data + crc
  }
  if (depth !== 8) throw new Error(`${path}: only 8-bit supported (got ${depth})`);
  if (interlace !== 0) throw new Error(`${path}: interlaced PNG unsupported`);
  // 2 = truecolour (RGB), 6 = truecolour + alpha. Those are what the
  // emulator writes; anything else would need a palette or grey path.
  const channels = colour === 6 ? 4 : colour === 2 ? 3 : 0;
  if (!channels) throw new Error(`${path}: colour type ${colour} unsupported`);

  const raw = inflateSync(Buffer.concat(idat));
  const stride = w * channels;
  const out = Buffer.alloc(h * stride);

  // UNFILTER. Each scanline carries a filter byte, and types 2-4 refer to
  // the line ABOVE -- which is why this has to run top to bottom over the
  // already-reconstructed output rather than over the raw bytes.
  for (let y = 0; y < h; y++) {
    const ft = raw[y * (stride + 1)];
    const src = (y * (stride + 1)) + 1;
    const dst = y * stride;
    const up = dst - stride;
    for (let i = 0; i < stride; i++) {
      const x = raw[src + i];
      const a = i >= channels ? out[dst + i - channels] : 0;   // left
      const b = y > 0 ? out[up + i] : 0;                       // above
      const c = (i >= channels && y > 0) ? out[up + i - channels] : 0; // up-left
      let v;
      switch (ft) {
        case 0: v = x; break;
        case 1: v = x + a; break;
        case 2: v = x + b; break;
        case 3: v = x + ((a + b) >> 1); break;
        case 4: {
          const p = a + b - c;
          const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
          v = x + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c);
          break;
        }
        default: throw new Error(`${path}: bad filter type ${ft} on row ${y}`);
      }
      out[dst + i] = v & 0xff;
    }
  }

  return {
    w, h,
    at(x, y) {
      const i = y * stride + x * channels;
      return [out[i], out[i + 1], out[i + 2]];
    },
  };
}

// ── the two measurements the gates actually make ───────────────────────

// Mean COLOURFULNESS (max channel minus min) over a disc. This is the
// number the fog gate lives on: warm earth is saturated, grey stone is
// not, so one scalar separates "I have stood here" from "I have not".
export function meanSaturation(path, cx, cy, radius, step = 2) {
  const im = readPNG(path);
  let tot = 0, n = 0;
  for (let dy = -radius; dy < radius; dy += step) {
    for (let dx = -radius; dx < radius; dx += step) {
      if (dx * dx + dy * dy > radius * radius) continue;
      const x = cx + dx, y = cy + dy;
      if (x < 0 || y < 0 || x >= im.w || y >= im.h) continue;
      const [r, g, b] = im.at(x, y);
      tot += Math.max(r, g, b) - Math.min(r, g, b);
      n++;
    }
  }
  return n ? +(tot / n).toFixed(2) : 0;
}

// How many pixels in a disc are brighter than a threshold -- "is there
// anything drawn here at all".
export function brightCount(path, cx, cy, radius, minLum = 90, step = 1) {
  const im = readPNG(path);
  let n = 0;
  for (let dy = -radius; dy < radius; dy += step) {
    for (let dx = -radius; dx < radius; dx += step) {
      if (dx * dx + dy * dy > radius * radius) continue;
      const x = cx + dx, y = cy + dy;
      if (x < 0 || y < 0 || x >= im.w || y >= im.h) continue;
      const [r, g, b] = im.at(x, y);
      if (Math.max(r, g, b) >= minLum) n++;
    }
  }
  return n;
}
