#!/usr/bin/env python3
"""Generate the launcher icon.

Generated rather than drawn, like everything else the cart ships, so the
whole artifact stays originally licensed and the icon can be re-derived
from this file alone.

The image is the game in one glance: the nest at the centre, three glowing
trails radiating out, and an ant on each. A 1024x1024 adaptive-icon
FOREGROUND -- transparent background, content kept inside the centre ~61%
safe zone, because launchers mask the rest into a circle or a squircle and
anything outside that radius is simply gone.

Writes a PNG by hand (zlib + struct) so this has no image-library
dependency, the same approach the Cavern port's asset generator used.

  python3 tools/make-icon.py [out.png]
"""

import math
import os
import struct
import sys
import zlib

SIZE = 1024
CENTER = SIZE / 2
# Launchers mask an adaptive icon down to roughly the middle 61%. Keep
# every meaningful pixel inside this radius or it may not survive.
SAFE_R = SIZE * 0.305


def blend(dst, x, y, r, g, b, a):
    """Alpha-composite one pixel into the RGBA buffer."""
    if a <= 0 or x < 0 or y < 0 or x >= SIZE or y >= SIZE:
        return
    i = (y * SIZE + x) * 4
    da = dst[i + 3] / 255.0
    sa = min(1.0, a)
    out_a = sa + da * (1 - sa)
    if out_a <= 0:
        return
    for k, sc in enumerate((r, g, b)):
        dc = dst[i + k] / 255.0
        dst[i + k] = int(max(0, min(255, (sc * sa + dc * da * (1 - sa)) / out_a * 255)))
    dst[i + 3] = int(max(0, min(255, out_a * 255)))


def disc(dst, cx, cy, rad, color, softness=1.5):
    """A filled circle with a soft edge (cheap antialiasing)."""
    r, g, b = color
    x0, x1 = int(cx - rad - 2), int(cx + rad + 3)
    y0, y1 = int(cy - rad - 2), int(cy + rad + 3)
    for y in range(max(0, y0), min(SIZE, y1)):
        for x in range(max(0, x0), min(SIZE, x1)):
            d = math.hypot(x + 0.5 - cx, y + 0.5 - cy)
            a = max(0.0, min(1.0, (rad - d) / softness + 0.5))
            if a > 0:
                blend(dst, x, y, r, g, b, a)


def stroke(dst, pts, width, color, alpha=1.0):
    """A polyline of overlapping discs -- simple, and the soft edges join
    into a smooth ribbon without any curve maths."""
    r, g, b = color
    for i in range(len(pts) - 1):
        x0, y0 = pts[i]
        x1, y1 = pts[i + 1]
        seg = max(1, int(math.hypot(x1 - x0, y1 - y0)))
        for s in range(seg + 1):
            t = s / seg
            cx = x0 + (x1 - x0) * t
            cy = y0 + (y1 - y0) * t
            disc(dst, cx, cy, width / 2, (r, g, b), 1.6)
    # Re-apply global alpha by scaling what we just wrote is fiddly; the
    # caller passes pre-multiplied colours instead when it wants a wash.


def trail(dst, angle, length, bow):
    """One glowing road out of the nest: a wide dim halo under a bright core."""
    pts = []
    steps = 26
    for i in range(steps + 1):
        t = i / steps
        # A gentle bow, the same shape the game draws its trails with.
        off = 4 * t * (1 - t) * bow
        r = SAFE_R * 0.28 + length * t
        a = angle + off
        pts.append((CENTER + math.cos(a) * r, CENTER + math.sin(a) * r))
    stroke(dst, pts, 54, (0.15, 0.34, 0.18))
    stroke(dst, pts, 30, (0.35, 0.72, 0.38))
    stroke(dst, pts, 13, (0.78, 0.96, 0.66))
    return pts


def ant(dst, x, y, angle, scale, color):
    """The game's own three-segment ant: gaster, thorax, head, plus legs."""
    c, s = math.cos(angle), math.sin(angle)

    def place(fx, fy):
        return CENTER + 0 + (x - CENTER) + (c * fx - s * fy) * scale, \
               CENTER + 0 + (y - CENTER) + (s * fx + c * fy) * scale

    # legs
    for i in (-1, 0, 1):
        for side in (1, -1):
            bx = 0.5 + i * 0.55
            ang = angle + side * (0.95 + i * 0.4)
            kx, ky = place(bx, side * 0.36)
            ex = kx + math.cos(ang) * 1.5 * scale
            ey = ky + math.sin(ang) * 1.5 * scale
            stroke(dst, [(kx, ky), (ex, ey)], max(2, 0.34 * scale),
                   (color[0] * 0.5, color[1] * 0.5, color[2] * 0.5))

    gx, gy = place(-1.70, 0)
    tx, ty = place(0.42, 0)
    hx, hy = place(1.80, 0)
    disc(dst, gx, gy, 1.05 * scale, (color[0] * 0.8, color[1] * 0.8, color[2] * 0.8))
    disc(dst, tx, ty, 0.72 * scale, color)
    disc(dst, hx, hy, 0.62 * scale, (min(1, color[0] * 1.12), color[1], color[2]))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "icon.png")

    buf = bytearray(SIZE * SIZE * 4)      # transparent

    # Soil disc under everything, so the icon reads as ground rather than
    # as floating shapes. Well inside the safe radius.
    disc(buf, CENTER, CENTER, SAFE_R, (0.13, 0.17, 0.11), 3.0)
    disc(buf, CENTER, CENTER, SAFE_R * 0.97, (0.16, 0.21, 0.13), 3.0)

    # Three roads, spread evenly, each bowed a different way.
    # Length is measured so the far END of a road, plus its halo and the ant
    # riding it, still lands inside SAFE_R. The first pass ran the roads to
    # 0.74 of the radius on top of a 0.28 start offset, which put the tips
    # (and their 54px halo) outside the mask -- fine in a preview, clipped
    # on a real launcher.
    angles = [-1.9, 0.35, 2.35]
    bows = [0.20, -0.16, 0.13]
    paths = []
    for a, b in zip(angles, bows):
        paths.append(trail(buf, a, SAFE_R * 0.56, b))

    # The nest: concentric rings and two dark entrances.
    disc(buf, CENTER, CENTER, SAFE_R * 0.34, (0.30, 0.21, 0.13), 2.5)
    disc(buf, CENTER, CENTER, SAFE_R * 0.27, (0.36, 0.25, 0.15), 2.5)
    disc(buf, CENTER, CENTER, SAFE_R * 0.19, (0.26, 0.18, 0.11), 2.5)
    disc(buf, CENTER - SAFE_R * 0.07, CENTER - SAFE_R * 0.05, SAFE_R * 0.055,
         (0.07, 0.05, 0.04), 2.0)
    disc(buf, CENTER + SAFE_R * 0.06, CENTER + SAFE_R * 0.06, SAFE_R * 0.045,
         (0.07, 0.05, 0.04), 2.0)

    # One ant on each road, out where the trail is widest.
    for pts, a in zip(paths, angles):
        px, py = pts[len(pts) * 2 // 3]
        nx, ny = pts[len(pts) * 2 // 3 + 1]
        ant(buf, px, py, math.atan2(ny - py, nx - px), SIZE * 0.020,
            (0.90, 0.64, 0.28))

    # A carried grain on one of them: the game's most informative pixel.
    px, py = paths[0][len(paths[0]) * 2 // 3 + 3]
    disc(buf, px, py, SIZE * 0.016, (0.98, 0.88, 0.40), 2.0)

    write_png(out, buf)
    print(f"wrote {out} ({SIZE}x{SIZE}, {os.path.getsize(out)/1024:.1f} KiB)")


def write_png(path, rgba):
    raw = bytearray()
    for y in range(SIZE):
        raw.append(0)                      # filter: none
        raw += rgba[y * SIZE * 4:(y + 1) * SIZE * 4]

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    main()
