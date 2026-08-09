#!/usr/bin/env python3
"""Verify a decoded WAV actually contains the injected test tone.

Pure-stdlib Goertzel analysis: measures signal power at the expected tone
frequency and at several off-target reference frequencies. The tone counts as
detected when target power dominates every reference frequency by a margin
and the overall RMS is clearly above digital silence.

Exit 0 = tone detected, exit 1 = not detected.
"""

import argparse
import json
import math
import struct
import sys
import wave


def read_wav(path):
    with wave.open(path, "rb") as handle:
        channels = handle.getnchannels()
        width = handle.getsampwidth()
        rate = handle.getframerate()
        count = handle.getnframes()
        raw = handle.readframes(count)
    if width == 4:
        # Assume float32 (what decode_relay_frames.swift writes).
        samples = struct.unpack("<%df" % (count * channels), raw)
    elif width == 2:
        ints = struct.unpack("<%dh" % (count * channels), raw)
        samples = [value / 32768.0 for value in ints]
    else:
        raise SystemExit(f"unsupported sample width: {width}")
    if channels > 1:
        samples = samples[::channels]
    return samples, rate


def goertzel(samples, rate, frequency):
    omega = 2.0 * math.pi * frequency / rate
    coefficient = 2.0 * math.cos(omega)
    s_prev = s_prev2 = 0.0
    for sample in samples:
        s = sample + coefficient * s_prev - s_prev2
        s_prev2 = s_prev
        s_prev = s
    power = s_prev2 * s_prev2 + s_prev * s_prev - coefficient * s_prev * s_prev2
    return max(power, 0.0) / max(len(samples), 1)


def main():
    parser = argparse.ArgumentParser(description="Detect an injected test tone in a WAV")
    parser.add_argument("wav")
    parser.add_argument("--tone-hz", type=float, default=880.0)
    parser.add_argument("--min-rms", type=float, default=0.001)
    parser.add_argument("--dominance", type=float, default=5.0,
                        help="target power must exceed each reference by this factor")
    args = parser.parse_args()

    samples, rate = read_wav(args.wav)
    if len(samples) < rate // 10:
        raise SystemExit("wav too short for analysis")

    rms = math.sqrt(sum(sample * sample for sample in samples) / len(samples))
    references = [250.0, 500.0, 1500.0, 2500.0, 3500.0]
    target_power = goertzel(samples, rate, args.tone_hz)
    reference_powers = {f: goertzel(samples, rate, f) for f in references}

    floor = 1e-12
    ratios = {f: target_power / max(p, floor) for f, p in reference_powers.items()}
    detected = rms >= args.min_rms and all(ratio >= args.dominance for ratio in ratios.values())

    print(json.dumps({
        "wav": args.wav,
        "seconds": round(len(samples) / rate, 3),
        "rms": round(rms, 6),
        "toneHz": args.tone_hz,
        "tonePower": target_power,
        "referencePowers": {str(int(f)): p for f, p in reference_powers.items()},
        "dominanceRatios": {str(int(f)): round(r, 2) for f, r in ratios.items()},
        "toneDetected": detected,
    }, sort_keys=True, indent=2))
    sys.exit(0 if detected else 1)


if __name__ == "__main__":
    main()
