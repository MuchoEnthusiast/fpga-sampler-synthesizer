import argparse
import math
from pathlib import Path
import struct
import wave

RATE = 16_000
ACTIVE_SAMPLES = 16_000
MEMORY_DEPTH = 16_384

OUTPUT = Path(__file__).resolve().parents[1] / "samples" / "sample_a4.mem"

def clamp8(v):
    return max(-128, min(127, v))

def load_wav(path):
    with wave.open(str(path), "rb") as w:
        channels = w.getnchannels()
        width = w.getsampwidth()
        rate = w.getframerate()

        if rate != RATE or channels not in (1, 2) or width not in (1, 2):
            raise ValueError(
                "WAV must be 16 kHz, 8/16-bit PCM, mono or stereo"
            )

        if w.getcomptype() != "NONE":
            raise ValueError("Compressed WAV not supported")

        raw = w.readframes(min(w.getnframes(), ACTIVE_SAMPLES))

    if width == 1:
        # WAV 8-bit samples are unsigned.
        vals = [v - 128 for v in raw]
    else:
        # Convert little-endian signed 16-bit to signed 8-bit.
        vals = [v >> 8 for (v,) in struct.iter_unpack("<h", raw)]

    if channels == 2:
        vals = [
            clamp8(round((vals[i] + vals[i + 1]) / 2))
            for i in range(0, len(vals), 2)
        ]

    return vals

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--wav", type=Path)
    args = parser.parse_args()

    if args.wav:
        samples = load_wav(args.wav)
    else:
        samples = [
            round(96 * math.sin(2 * math.pi * 440 * n / RATE))
            for n in range(ACTIVE_SAMPLES)
        ]

    samples = samples[:ACTIVE_SAMPLES]
    samples.extend([0] * (MEMORY_DEPTH - len(samples)))

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(
        "".join(f"{clamp8(v) & 0xFF:08b}\n" for v in samples),
        encoding="ascii"
    )

    print(f"Generated {MEMORY_DEPTH} samples: {OUTPUT}")

if __name__ == "__main__":
    main()
