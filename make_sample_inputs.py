#!/usr/bin/env python3
"""Create sample image.png + mem_a.hex + weights.hex for demos."""
from pathlib import Path

import numpy as np

try:
    from PIL import Image
except ImportError:
    raise SystemExit("pip install pillow")

HERE = Path(__file__).resolve().parent

# 8x8 gradient
arr = (np.arange(64, dtype=np.uint8).reshape(8, 8) * 4).clip(0, 255)
img = Image.fromarray(arr, mode="L")
img = img.resize((64, 64), Image.Resampling.NEAREST)  # nicer preview; converter resizes to 8x8
img.save(HERE / "image.png")
print("Wrote image.png")

# mem_a hex (signed from 0..63 as unsigned then -128 style: store raw 00..3F)
with (HERE / "mem_a.hex").open("w") as f:
    for i in range(64):
        f.write(f"{i:02X}\n")
print("Wrote mem_a.hex")

# weights: filter 0 = centre tap 1, others 0  (identity-ish)
with (HERE / "weights.hex").open("w") as f:
    for t in range(9):
        for filt in range(4):
            f.write("01\n" if (t == 4 and filt == 0) else "00\n")
print("Wrote weights.hex")
