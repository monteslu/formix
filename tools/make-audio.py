#!/usr/bin/env python3
"""Generate every sound this game ships.

The audio is SYNTHESISED rather than sourced, for the same reason the art
is generated: it keeps the whole cart originally licensed with no third
party in it, and it means the soundscape can be tuned by editing numbers
instead of hunting for a replacement clip.

The palette is deliberately narrow and organic -- this is an ambient game,
and the loudest thing in it should be rain. Everything here is either
filtered noise (wind, rain, soil texture) or a soft sine cluster (the
season chimes). Nothing is percussive, nothing is bright.

Writes plain 16-bit mono WAV. The engine decodes ogg too, but WAV needs no
encoder dependency and the whole set is well under a megabyte at these
lengths; cart size is not the constraint here, reproducibility is.

  python3 tools/make-audio.py [outdir]

Default outdir is app/sounds relative to this file's parent.
"""

import math
import os
import random
import struct
import sys

RATE = 44100


def write_wav(path, samples, rate=RATE):
    """16-bit mono WAV, written by hand so this script has no dependencies."""
    frames = bytearray()
    for s in samples:
        v = int(max(-1.0, min(1.0, s)) * 32767)
        frames += struct.pack("<h", v)
    data_len = len(frames)
    with open(path, "wb") as f:
        f.write(b"RIFF")
        f.write(struct.pack("<I", 36 + data_len))
        f.write(b"WAVEfmt ")
        f.write(struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16))
        f.write(b"data")
        f.write(struct.pack("<I", data_len))
        f.write(frames)
    return data_len


def envelope(n, attack, release):
    """Attack/release envelope in SAMPLES, returned as a list."""
    env = []
    for i in range(n):
        a = min(1.0, i / max(1, attack))
        r = min(1.0, (n - i) / max(1, release))
        env.append(a * r)
    return env


class OnePole:
    """A one-pole filter. Low-pass by default; the complement is high-pass.

    Filtered noise is the whole basis of the natural sounds here: white
    noise is a hiss, but noise through a slow low-pass is wind, and through
    a fast one it is soil. The filter is what makes it organic.
    """

    def __init__(self, cutoff, rate=RATE):
        self.a = math.exp(-2.0 * math.pi * cutoff / rate)
        self.z = 0.0

    def lp(self, x):
        self.z = x * (1 - self.a) + self.z * self.a
        return self.z

    def hp(self, x):
        return x - self.lp(x)


def loop_seam(samples, fade):
    """Cross-fade a buffer's tail over its head so it loops without a click.

    A loop that clicks is the single most noticeable flaw in an ambient
    bed -- the ear locks onto the period instantly and the illusion of a
    continuous world is gone.
    """
    n = len(samples)
    fade = min(fade, n // 4)
    out = list(samples)
    for i in range(fade):
        w = i / fade
        out[i] = samples[i] * w + samples[n - fade + i] * (1 - w)
    return out[: n - fade]


# ── the ambient beds ───────────────────────────────────────────────────
# One per season. Each is a slow noise wash plus a couple of quiet drifting
# tones; the difference between them is filter cutoff and the tone set, so
# the year has a continuous identity rather than four unrelated tracks.

SEASON_BEDS = {
    # name:     (cutoff, tones (Hz), tone gain, noise gain, wobble)
    "spring": (900, [196.0, 293.7, 392.0], 0.055, 0.045, 0.20),
    "summer": (1400, [220.0, 329.6, 440.0], 0.050, 0.060, 0.28),
    "autumn": (620, [174.6, 261.6, 349.2], 0.058, 0.050, 0.16),
    "winter": (380, [146.8, 220.0, 293.7], 0.052, 0.038, 0.10),
}


def make_bed(name, seconds=24.0):
    cutoff, tones, tgain, ngain, wobble = SEASON_BEDS[name]
    rng = random.Random(hash(name) & 0xFFFF)
    n = int(RATE * seconds)
    lp1 = OnePole(cutoff)
    lp2 = OnePole(cutoff * 0.55)
    out = []

    # Each tone gets its own slow detune drift, which is what stops a
    # sustained chord sounding like a synth pad held down.
    phases = [rng.random() * math.tau for _ in tones]
    drifts = [rng.random() * 0.02 + 0.005 for _ in tones]

    for i in range(n):
        t = i / RATE
        # Filtered noise: the ground of the sound.
        w = rng.uniform(-1.0, 1.0)
        w = lp2.lp(lp1.lp(w))
        # A very slow swell so the bed breathes.
        swell = 0.65 + 0.35 * math.sin(t * 0.11 + 1.3)
        s = w * ngain * 12.0 * swell

        for k, f in enumerate(tones):
            det = 1.0 + math.sin(t * drifts[k] * math.tau + phases[k]) * 0.0035
            amp = tgain * (0.55 + 0.45 * math.sin(t * (0.07 + k * 0.031) + phases[k]))
            s += math.sin(t * f * det * math.tau + phases[k]) * amp

        out.append(s * 0.9)

    return loop_seam(out, int(RATE * 1.5))


# ── weather ────────────────────────────────────────────────────────────

def make_rain(seconds=12.0):
    """Rain: high-passed noise with a slow density wobble, plus drips."""
    rng = random.Random(9001)
    n = int(RATE * seconds)
    hp = OnePole(1800)
    lp = OnePole(6500)
    out = [0.0] * n
    for i in range(n):
        t = i / RATE
        w = rng.uniform(-1.0, 1.0)
        w = lp.lp(hp.hp(w))
        density = 0.72 + 0.28 * math.sin(t * 0.37)
        out[i] = w * 0.34 * density

    # Individual drips over the wash, so it is rain rather than static.
    for _ in range(int(seconds * 14)):
        at = rng.randrange(0, n - 4000)
        f = rng.uniform(700, 2100)
        dur = rng.randrange(900, 2600)
        env = envelope(dur, 40, dur)
        for j in range(dur):
            out[at + j] += math.sin(j / RATE * f * math.tau) * env[j] * 0.05
    return loop_seam(out, int(RATE * 1.0))


def make_wind(seconds=16.0):
    """Wind through grass: band-passed noise, slowly swelling."""
    rng = random.Random(4242)
    n = int(RATE * seconds)
    hp = OnePole(320)
    lp = OnePole(1500)
    out = []
    for i in range(n):
        t = i / RATE
        w = rng.uniform(-1.0, 1.0)
        w = lp.lp(hp.hp(w))
        gust = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(t * 0.19 + math.sin(t * 0.07) * 2))
        out.append(w * 0.26 * gust)
    return loop_seam(out, int(RATE * 1.2))


# ── one-shots ──────────────────────────────────────────────────────────

def make_link(seconds=0.55):
    """Laying a trail: a soft rising swell. The player's one loud verb."""
    n = int(RATE * seconds)
    env = envelope(n, int(RATE * 0.05), int(RATE * 0.4))
    out = []
    for i in range(n):
        t = i / RATE
        f = 320 + 180 * (i / n) ** 0.6
        s = math.sin(t * f * math.tau) * 0.35
        s += math.sin(t * f * 2.01 * math.tau) * 0.12
        s += math.sin(t * f * 3.02 * math.tau) * 0.05
        out.append(s * env[i])
    return out


def make_refuse(seconds=0.28):
    """A refused action: a short, low, soft thud. Never a buzzer.

    The game does not scold. This says "not now" and nothing more.
    """
    n = int(RATE * seconds)
    env = envelope(n, int(RATE * 0.01), int(RATE * 0.22))
    lp = OnePole(600)
    rng = random.Random(77)
    out = []
    for i in range(n):
        t = i / RATE
        s = math.sin(t * 118 * math.tau) * 0.5
        s += lp.lp(rng.uniform(-1, 1)) * 0.25
        out.append(s * env[i] * 0.7)
    return out


def make_discover(seconds=1.1):
    """A new place found: a small three-note bloom, up."""
    n = int(RATE * seconds)
    out = [0.0] * n
    for k, f in enumerate([392.0, 523.3, 659.3]):
        start = int(k * RATE * 0.13)
        dur = n - start
        env = envelope(dur, int(RATE * 0.02), int(RATE * 0.6))
        for j in range(dur):
            t = j / RATE
            out[start + j] += (math.sin(t * f * math.tau) * 0.22
                               + math.sin(t * f * 2.0 * math.tau) * 0.06) * env[j]
    return out


def make_season(seconds=2.6):
    """The season turning: a low bell cluster. The year's punctuation."""
    n = int(RATE * seconds)
    out = [0.0] * n
    env = envelope(n, int(RATE * 0.03), int(RATE * 2.0))
    for f, g in [(174.6, 0.20), (261.6, 0.14), (349.2, 0.09), (523.3, 0.05)]:
        for j in range(n):
            t = j / RATE
            # Slight inharmonicity, which is what makes a bell a bell.
            out[j] += math.sin(t * f * math.tau) * g * env[j]
            out[j] += math.sin(t * f * 2.76 * math.tau) * g * 0.18 * env[j]
    return out


def make_threat(seconds=0.9):
    """A spider arriving: a low descending scrape. Unpleasant, not loud."""
    n = int(RATE * seconds)
    env = envelope(n, int(RATE * 0.04), int(RATE * 0.55))
    lp = OnePole(900)
    rng = random.Random(1313)
    out = []
    for i in range(n):
        t = i / RATE
        f = 240 - 120 * (i / n)
        s = math.sin(t * f * math.tau) * 0.30
        s += lp.lp(rng.uniform(-1, 1)) * 0.30 * (1 - i / n)
        out.append(s * env[i])
    return out


def make_deliver(seconds=0.16):
    """Food reaching the nest: a tiny tick. Played sparsely and quietly --
    at 150 ants this would be a machine gun if it fired every time."""
    n = int(RATE * seconds)
    env = envelope(n, int(RATE * 0.004), int(RATE * 0.12))
    out = []
    for i in range(n):
        t = i / RATE
        s = math.sin(t * 880 * math.tau) * 0.5 + math.sin(t * 1320 * math.tau) * 0.2
        out.append(s * env[i] * 0.5)
    return out


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(here), "app", "sounds")
    os.makedirs(outdir, exist_ok=True)

    jobs = []
    for name in SEASON_BEDS:
        jobs.append(("bed-" + name + ".wav", lambda n=name: make_bed(n)))
    jobs += [
        ("rain.wav", make_rain),
        ("wind.wav", make_wind),
        ("link.wav", make_link),
        ("refuse.wav", make_refuse),
        ("discover.wav", make_discover),
        ("season.wav", make_season),
        ("threat.wav", make_threat),
        ("deliver.wav", make_deliver),
    ]

    # Encode to ogg when an encoder is available. The engine decodes ogg
    # (stb_vorbis is compiled in), and these are long noise beds where
    # 16-bit PCM is 10 MiB of a cart for no benefit at all -- Vorbis is
    # ~15x smaller on this material and the difference is inaudible on
    # filtered noise. WAV is kept as the fallback so the generator has no
    # hard dependency: a machine without ffmpeg still produces a working
    # cart, just a fatter one.
    import shutil
    import subprocess
    encoder = shutil.which("ffmpeg")

    total = 0
    for filename, fn in jobs:
        wav_path = os.path.join(outdir, filename)
        size = write_wav(wav_path, fn())
        final, kind = wav_path, "wav"

        if encoder:
            ogg_path = wav_path[:-4] + ".ogg"
            try:
                subprocess.run(
                    [encoder, "-y", "-loglevel", "error", "-i", wav_path,
                     "-c:a", "libvorbis", "-q:a", "3", ogg_path],
                    check=True)
                os.remove(wav_path)
                size = os.path.getsize(ogg_path)
                final, kind = ogg_path, "ogg"
            except (subprocess.CalledProcessError, OSError) as exc:
                print(f"    (ogg encode failed for {filename}: {exc}; "
                      f"keeping wav)")

        total += size
        print(f"  {os.path.basename(final):22s} {size/1024:8.1f} KiB  {kind}")

    print(f"wrote {len(jobs)} files, {total/1024/1024:.2f} MiB to {outdir}")
    if not encoder:
        print("  NOTE: no ffmpeg found, shipped uncompressed WAV. "
              "Install ffmpeg for a ~15x smaller cart.")


if __name__ == "__main__":
    main()
