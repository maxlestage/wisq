/// Draws the site's icons and social card, and encodes them as PNG.
///
/// Written out rather than committed as binaries, and encoded by hand rather
/// than with an image library, for the same reason the rest of this project
/// avoids dependencies it does not need: the artwork is four rectangles and a
/// pixel wordmark, and a PNG is a header, one deflated block and a checksum.
/// A committed binary is a thing nobody can diff and everybody has to trust.
///
/// iOS is the reason these are PNG at all. A manifest may point at an SVG and
/// Chromium will use it; Safari will not put one on the Home Screen, and this
/// is a project about iPhones.

import { deflateSync } from "node:zlib";

// The palette, matching the dark theme in styles.css.
const BACKGROUND: RGB = [0x0b, 0x0d, 0x10];
const MARK: RGB = [0x8b, 0x83, 0xff];

type RGB = [number, number, number];

class Canvas {
  readonly pixels: Uint8Array;

  constructor(
    readonly width: number,
    readonly height: number,
    fill: RGB,
  ) {
    this.pixels = new Uint8Array(width * height * 4);
    this.rect(0, 0, width, height, fill);
  }

  rect(x: number, y: number, width: number, height: number, colour: RGB) {
    const x0 = Math.max(0, Math.round(x));
    const y0 = Math.max(0, Math.round(y));
    const x1 = Math.min(this.width, Math.round(x + width));
    const y1 = Math.min(this.height, Math.round(y + height));
    for (let row = y0; row < y1; row++) {
      for (let column = x0; column < x1; column++) {
        const offset = (row * this.width + column) * 4;
        this.pixels[offset] = colour[0];
        this.pixels[offset + 1] = colour[1];
        this.pixels[offset + 2] = colour[2];
        this.pixels[offset + 3] = 0xff;
      }
    }
  }
}

/// The wisq mark: U+259A, the quadrants upper-left and lower-right.
///
/// `inset` is the fraction of the canvas the mark occupies. Anything at or
/// under 0.8 stays inside the safe area a maskable icon may be cropped to, so
/// an Android launcher can round it into any shape without eating the artwork.
function drawMark(canvas: Canvas, inset: number) {
  const side = Math.min(canvas.width, canvas.height) * inset;
  const x = (canvas.width - side) / 2;
  const y = (canvas.height - side) / 2;
  // The same proportions as the full mark in `src/components/Logo.tsx`: the two
  // quadrants stand apart rather than touching at a point, because what is
  // between them is the product. Here there is no room to draw the link, only
  // the space it runs through — an icon is the mark with the detail removed,
  // not a different mark.
  const gap = side * 0.1;
  const quadrant = (side - gap) / 2;
  canvas.rect(x, y, quadrant, quadrant, MARK);
  canvas.rect(x + quadrant + gap, y + quadrant + gap, quadrant, quadrant, MARK);
}

// A 5×7 bitmap for the four letters the wordmark needs. Blocky on purpose: the
// mark is two squares, and a wordmark drawn from the same grid belongs with it.
const GLYPHS: Record<string, string[]> = {
  w: ["00000", "00000", "10001", "10001", "10101", "11011", "10001"],
  i: ["00100", "00000", "01100", "00100", "00100", "00100", "01110"],
  s: ["00000", "00000", "01111", "10000", "01110", "00001", "11110"],
  q: ["00000", "00000", "01111", "10001", "10001", "01111", "00001"],
};

function drawWord(canvas: Canvas, word: string, x: number, y: number, scale: number, colour: RGB) {
  let cursor = x;
  for (const character of word) {
    const glyph = GLYPHS[character];
    if (!glyph) throw new Error(`glyphe absent du jeu minimal : ${character}`);
    glyph.forEach((row, rowIndex) => {
      [...row].forEach((bit, columnIndex) => {
        if (bit === "1") {
          canvas.rect(
            cursor + columnIndex * scale,
            y + rowIndex * scale,
            scale,
            scale,
            colour,
          );
        }
      });
    });
    cursor += 6 * scale;
  }
}

// PNG encoding.

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (const byte of bytes) c = CRC_TABLE[(c ^ byte) & 0xff]! ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Uint8Array): Uint8Array {
  const name = new TextEncoder().encode(type);
  const out = new Uint8Array(12 + data.length);
  const view = new DataView(out.buffer);
  view.setUint32(0, data.length);
  out.set(name, 4);
  out.set(data, 8);
  const body = out.subarray(4, 8 + data.length);
  view.setUint32(8 + data.length, crc32(body));
  return out;
}

export function encodePNG(canvas: Canvas): Uint8Array {
  // One filter byte per scanline; filter 0 means the row is stored as-is.
  // Predictive filters would compress better, and these images are flat colour
  // where they would win almost nothing.
  const stride = canvas.width * 4;
  const raw = new Uint8Array((stride + 1) * canvas.height);
  for (let row = 0; row < canvas.height; row++) {
    raw[row * (stride + 1)] = 0;
    raw.set(canvas.pixels.subarray(row * stride, (row + 1) * stride), row * (stride + 1) + 1);
  }

  const header = new Uint8Array(13);
  const headerView = new DataView(header.buffer);
  headerView.setUint32(0, canvas.width);
  headerView.setUint32(4, canvas.height);
  header[8] = 8; // bit depth
  header[9] = 6; // colour type: truecolour with alpha
  header[10] = 0; // deflate
  header[11] = 0; // adaptive filtering
  header[12] = 0; // no interlace

  const signature = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const idat = new Uint8Array(deflateSync(raw, { level: 9 }));

  const parts = [
    signature,
    chunk("IHDR", header),
    chunk("IDAT", idat),
    chunk("IEND", new Uint8Array(0)),
  ];
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const png = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    png.set(part, offset);
    offset += part.length;
  }
  return png;
}

export function appIcon(size: number, maskable: boolean): Uint8Array {
  const canvas = new Canvas(size, size, BACKGROUND);
  // A maskable icon may be cropped to a circle, so its artwork has to sit well
  // inside the square; a plain one can use the room.
  drawMark(canvas, maskable ? 0.46 : 0.62);
  return encodePNG(canvas);
}

/// The image a link to this site unfurls into. 1200×630 is what the scrapers
/// crop to, so drawing at exactly that size means nothing gets cut.
export function socialCard(): Uint8Array {
  const canvas = new Canvas(1200, 630, BACKGROUND);

  const markSide = 210;
  const markX = 110;
  const markY = 175;
  canvas.rect(markX, markY, markSide / 2, markSide / 2, MARK);
  canvas.rect(markX + markSide / 2, markY + markSide / 2, markSide / 2, markSide / 2, MARK);

  drawWord(canvas, "wisq", 400, 210, 20, [0xe8, 0xed, 0xf3]);
  // An accent rule under the wordmark, the width of it.
  canvas.rect(400, 380, 6 * 20 * 4 - 20, 10, MARK);

  return canvas.pixels.length ? encodePNG(canvas) : new Uint8Array();
}

export { Canvas };
