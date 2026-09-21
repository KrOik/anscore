#!/usr/bin/env python3
"""Generate expected byte streams for tb_cnn_meas / board capture compare.

Writes (hex, one byte per line, $readmemh format):
  sim/meas_expected_il.mem : 720 bytes = 40 windows x 18B (r=0..8, ch0, ch1)
  sim/meas_expected_ly.mem : 160 bytes = 80 beats x 2B (ch0, ch1 dup)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from golden_model import il_window_byte


def il_bytes():
    bs = []
    for oy in range(5):
        for ox in range(8):
            for r in range(9):
                for ch in range(2):
                    bs.append(il_window_byte(oy, ox, r, ch))
    return bs


def ly_bytes():
    bs = []
    for oy in range(5):
        for ox in range(8):
            acc = sum(il_window_byte(oy, ox, r, ch)
                      for r in range(9) for ch in range(2))
            acc += 8
            rnd = (acc >> 4) + ((acc >> 3) & 1)
            v = 0 if rnd < 0 else (255 if rnd >= 255 else rnd)
            for _ in range(2):
                bs += [v, v]
    return bs


def write_mem(path, bs):
    with open(path, "w") as f:
        for b in bs:
            f.write(f"{b:02x}\n")
    print(f"wrote {path}: {len(bs)} bytes")


if __name__ == "__main__":
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    write_mem(os.path.join(root, "sim", "meas_expected_il.mem"), il_bytes())
    write_mem(os.path.join(root, "sim", "meas_expected_ly.mem"), ly_bytes())
