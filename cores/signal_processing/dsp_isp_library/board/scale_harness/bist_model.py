"""Golden model for scale_bist.v: replicates the on-chip LFSR input frame,
runs the bit-exact scaler model, and CRC32s the output stream in the same
byte order the hardware uses (B, G, R, marker per pixel, LE first).
Marker byte = {sof, eol, 6'b0}: tuser at bit7, tlast at bit6.
"""
import sys, zlib
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'isp' / 'scale'))
from scale_model import scale_frame


def lfsr_frame(n):
    """24-bit pixel words from the BIST 32-bit Fibonacci LFSR
    (taps 31,21,1,0), sampled on each input_fire."""
    lfsr = 1
    out = []
    for _ in range(n):
        out.append(lfsr & 0xFFFFFF)
        fb = ((lfsr >> 31) ^ (lfsr >> 21) ^ (lfsr >> 1) ^ lfsr) & 1
        lfsr = ((lfsr << 1) & 0xFFFFFFFF) | fb
    return out


def expected_crc(iw, ih, ow, oh):
    """CRC32 (zlib, init applied) of the byte stream the hardware produces."""
    words = lfsr_frame(iw * ih)
    frame = [[((w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF)
              for w in words[y * iw:(y + 1) * iw]] for y in range(ih)]
    out = scale_frame(frame, iw, ih, ow, oh)   # [oh][ow] of (r,g,b)
    crc = 0xFFFFFFFF
    buf = bytearray()
    for y in range(oh):
        for x in range(ow):
            r, g, b = out[y][x]
            marker = (0x80 if (x == 0 and y == 0) else 0) | \
                     (0x40 if x == ow - 1 else 0)
            buf += bytes((b, g, r, marker))
    return zlib.crc32(bytes(buf), 0xFFFFFFFF) & 0xFFFFFFFF, out, words


if __name__ == '__main__':
    for dims in ((32, 24, 64, 32), (64, 32, 32, 24), (40, 30, 52, 34)):
        c, out, _ = expected_crc(*dims)
        print(dims, 'crc=%08X' % c, 'outpix=%d' % (dims[2] * dims[3]))
