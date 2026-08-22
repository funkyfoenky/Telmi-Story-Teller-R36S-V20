#!/usr/bin/env python3
import math
import struct
import wave
from pathlib import Path

path = Path(__file__).resolve().parent / "tone.wav"
rate, dur, freq = 44100, 2.0, 440.0
n = int(rate * dur)
with wave.open(str(path), "w") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(rate)
    frames = bytearray()
    for i in range(n):
        env = min(1.0, i / 1000.0, (n - i) / 1000.0)
        v = int(16000 * env * math.sin(2 * math.pi * freq * i / rate))
        frames += struct.pack("<hh", v, v)
    w.writeframes(frames)
print(f"wrote {path} ({path.stat().st_size} bytes)")
