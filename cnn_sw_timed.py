#!/usr/bin/env python3
"""
Software reference for the CNNAccelTeam9 conv — same math as the HW golden model.

  IFM 8x8 INT8, KS=3, P=4 filters → OFM 6x6x4
  Weights layout: wgt[(tap)*P + filter]  with tap = fr*KS + fc
  Output layout:  out[(patch)*P + filter] with patch = orow*OFM_W + ocol

Times the pure convolution (and optionally load/save). Also prints estimated
HW cycle counts so you can compare SW wall time vs HW at a given clock.

Usage:
  python3 cnn_sw_timed.py                    # SW vs 4-MAC @ 19 ns (defaults)
  python3 cnn_sw_timed.py --clk-ns 19        # same, explicit
  python3 cnn_sw_timed.py --image image.png
  python3 cnn_sw_timed.py --mem-a mem_a.hex --weights weights.hex
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path

import numpy as np

# Match cnn_pkg.sv
IFM_H, IFM_W = 8, 8
KS = 3
P = 4
OFM_H = IFM_H - KS + 1  # 6
OFM_W = IFM_W - KS + 1  # 6
N_PATCH = OFM_H * OFM_W  # 36
N_TAP = KS * KS  # 9
A_DEPTH = IFM_H * IFM_W  # 64
B_DEPTH = N_TAP * P  # 36
C_DEPTH = N_PATCH * P  # 144
DW = 8
LAT = 2  # MAC pipeline depth in HW


def hex_file_to_int8(path: Path, depth: int) -> np.ndarray:
    vals = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            u = int(line, 16) & 0xFF
            vals.append(u - 256 if u >= 128 else u)
    arr = np.array(vals, dtype=np.int32)
    if arr.size != depth:
        raise ValueError(f"{path}: expected {depth} values, got {arr.size}")
    return arr


def image_to_int8_flat(path: Path) -> np.ndarray:
    from PIL import Image

    img = Image.open(path).convert("L").resize((IFM_W, IFM_H))
    pixels = np.array(img.getdata(), dtype=np.int32) - 128  # signed INT8
    return pixels.astype(np.int32)


def random_int8(n: int, rng: np.random.Generator) -> np.ndarray:
    return rng.integers(-128, 128, size=n, dtype=np.int32)


def conv_hw_golden(img: np.ndarray, wgt: np.ndarray) -> np.ndarray:
    """
    Same nested loops as tb_conv_top golden_model (no flat-i /6 in the model).
    img: [64] INT8, wgt: [36] INT8, returns exp_c: [144] INT32 (fits ACC_W=20)
    """
    out = np.zeros(C_DEPTH, dtype=np.int32)
    for orow in range(OFM_H):
        for ocol in range(OFM_W):
            for f in range(P):
                s = 0
                for fr in range(KS):
                    for fc in range(KS):
                        a = img[(orow + fr) * IFM_W + (ocol + fc)]
                        b = wgt[(fr * KS + fc) * P + f]
                        s += int(a) * int(b)
                out[(orow * OFM_W + ocol) * P + f] = s
    return out


def conv_numpy_im2col(img: np.ndarray, wgt: np.ndarray) -> np.ndarray:
    """Faster equivalent using im2col + matmul (same numeric result)."""
    patches = np.empty((N_PATCH, N_TAP), dtype=np.int32)
    p = 0
    for orow in range(OFM_H):
        for ocol in range(OFM_W):
            t = 0
            for fr in range(KS):
                for fc in range(KS):
                    patches[p, t] = img[(orow + fr) * IFM_W + (ocol + fc)]
                    t += 1
            p += 1
    # wgt[tap * P + f] → matrix (N_TAP, P)
    W = wgt.reshape(N_TAP, P)
    # (N_PATCH, P) then flatten as patch*P+f
    return (patches @ W).reshape(-1)


def hw_cycle_estimate(mode: str = "4mac") -> dict:
    """Rough cycle counts matching your RTL schedules (not wall time)."""
    if mode == "1mac":
        # i, j, k loops: N_PATCH * P * N_TAP multiply cycles + drain
        mac_cycles = N_PATCH * P * N_TAP
        write_cycles = C_DEPTH  # one write per result (overlapped-ish; order-of-mag)
        return {
            "mac_cycles": mac_cycles,
            "approx_total": mac_cycles + LAT + C_DEPTH,
            "note": "1 MAC: k fastest, then j, then i",
        }
    # 4mac: all P filters per tap; then burst P writes per patch
    mac_cycles = N_PATCH * N_TAP
    burst_writes = N_PATCH * P  # still C_DEPTH writes, burst after each patch
    return {
        "mac_cycles": mac_cycles,
        "burst_write_cycles": burst_writes,
        "approx_total": mac_cycles + burst_writes + LAT,
        "note": "4 MAC: k then i; 4 filters/cycle; P-cycle write burst/patch",
    }


def save_output_maps(out: np.ndarray, path: Path) -> None:
    path.write_text("\n".join(str(int(x)) for x in out) + "\n")


def save_feature_pngs(out: np.ndarray, out_dir: Path, scale: int = 100) -> None:
    from PIL import Image

    out_dir.mkdir(parents=True, exist_ok=True)
    maps = out.reshape(N_PATCH, P).T.reshape(P, OFM_H, OFM_W)
    # HW stores addr = patch*P+f → reshape (N_PATCH, P) then per-filter plane
    planes = np.zeros((P, OFM_H, OFM_W), dtype=np.int32)
    for patch in range(N_PATCH):
        r, c = divmod(patch, OFM_W)
        for f in range(P):
            planes[f, r, c] = out[patch * P + f]

    for f in range(P):
        fm = planes[f]
        mn, mx = fm.min(), fm.max()
        if mn == mx:
            disp = np.zeros((OFM_H, OFM_W), dtype=np.uint8)
        else:
            disp = ((fm.astype(np.float64) - mn) * 255.0 / (mx - mn)).astype(np.uint8)
        img = Image.fromarray(disp, mode="L").resize(
            (OFM_W * scale, OFM_H * scale), Image.Resampling.NEAREST
        )
        img.save(out_dir / f"sw_feature_map_filter_{f}.png")


def main() -> None:
    ap = argparse.ArgumentParser(description="Timed SW CNN vs 4-MAC ASIC estimate")
    ap.add_argument("--image", type=Path, help="input PNG (resized to 8x8, INT8)")
    ap.add_argument("--mem-a", type=Path, help="64-line hex file for memA")
    ap.add_argument("--weights", type=Path, help="36-line hex file for memB")
    ap.add_argument("--reps", type=int, default=1000, help="timed repetitions")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--method", choices=("golden", "im2col", "both"), default="im2col")
    ap.add_argument("--clk-ns", type=float, default=19.0, help="ASIC clock period (ns), default 19")
    ap.add_argument("--save-maps", type=Path, default=Path("output_maps_sw.txt"))
    ap.add_argument("--save-png-dir", type=Path, default=Path("sw_feature_maps"))
    ap.add_argument("--no-save", action="store_true", help="skip writing maps/PNGs")
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)

    if args.mem_a:
        if not args.mem_a.is_file():
            raise SystemExit(
                f"ERROR: {args.mem_a} not found.\n"
                f"  Generate with: python3 input_image_converter.py\n"
                f"  Or omit --mem-a to use random INT8."
            )
        img = hex_file_to_int8(args.mem_a, A_DEPTH)
    elif args.image:
        if not args.image.is_file():
            raise SystemExit(
                f"ERROR: {args.image} not found.\n"
                f"  Put a PNG named image.png in this folder, or run without --image\n"
                f"  for a random INT8 demo."
            )
        img = image_to_int8_flat(args.image)
    else:
        img = random_int8(A_DEPTH, rng)

    if args.weights:
        if not args.weights.is_file():
            raise SystemExit(
                f"ERROR: {args.weights} not found. Omit --weights for random, "
                f"or use the sample weights.hex in this folder."
            )
        wgt = hex_file_to_int8(args.weights, B_DEPTH)
    else:
        wgt = random_int8(B_DEPTH, rng)

    out_g = conv_hw_golden(img, wgt)
    out_i = conv_numpy_im2col(img, wgt)
    if not np.array_equal(out_g, out_i):
        raise SystemExit("ERROR: golden vs im2col mismatch")

    def time_fn(fn, label: str) -> float:
        fn(img, wgt)  # warmup
        t0 = time.perf_counter()
        for _ in range(args.reps):
            fn(img, wgt)
        per = (time.perf_counter() - t0) / args.reps
        print(f"\n[{label}]")
        print(f"  reps           : {args.reps}")
        print(f"  per inference  : {per*1e6:.3f} us")
        return per

    print("=" * 60)
    print(" SW vs 4-MAC ASIC")
    print(f"  IFM {IFM_H}x{IFM_W}  KS={KS}  P={P}  OFM {OFM_H}x{OFM_W}")
    print(f"  ASIC clock     : {args.clk_ns:g} ns  ({1e3/args.clk_ns:.2f} MHz)")
    print("=" * 60)

    per_g = per_i = None
    if args.method in ("golden", "both"):
        per_g = time_fn(conv_hw_golden, "nested-loop golden")
    if args.method in ("im2col", "both"):
        per_i = time_fn(conv_numpy_im2col, "im2col + matmul")

    if not args.no_save:
        save_output_maps(out_g, args.save_maps)
        save_feature_pngs(out_g, args.save_png_dir)
        print(f"\nWrote {args.save_maps} and PNGs under {args.save_png_dir}/")

    sw_s = per_i if per_i is not None else per_g
    mac = N_PATCH * N_TAP          # 36*9 = 324
    wr = N_PATCH * P               # 36*4 = 144
    hw_cycles = mac + wr + LAT     # 324+144+2 = 470
    hw_s = hw_cycles * args.clk_ns * 1e-9
    f_mhz = 1e3 / args.clk_ns

    print("\n" + "=" * 60)
    print(" Platform              Cycles    Time_us     Clock")
    print("-" * 60)
    print(f" CPU (Python im2col)   n/a       {sw_s*1e6:<10.3f} host CPU")
    print(f" ASIC 4-MAC            {hw_cycles:<8d} {hw_s*1e6:<10.3f} {args.clk_ns:g} ns (~{f_mhz:.1f} MHz)")
    print("-" * 60)
    print(f" Speedup               {sw_s/hw_s:.1f}x")
    print()
    print(f" Notes: cycles = {N_PATCH}*{N_TAP} MAC + {N_PATCH}*{P} writes + {LAT} LAT")
    print(f"        = {mac}+{wr}+{LAT} = {hw_cycles};  time = {hw_cycles}*{args.clk_ns:g}ns")
    print("=" * 60)
    print("Done.")


if __name__ == "__main__":
    main()
