#!/usr/bin/env python3
# Decode 115200-8N1 UART bytes from an fx2lafw binary capture.
# Usage: python la_uart_decode.py <capture.bin> [samplerate_hz] [out.txt]
# Finds the channel carrying UART frames (idle-high, start-bit density)
# then decodes at 115200 baud. Prints decoded text and stats.
import sys

BAUD = 115200.0

def decode_channel(bits, sr, n):
    spb = sr / BAUD
    out = bytearray()
    i = 1
    while i < n - int(10 * spb):
        if bits[i - 1] == 1 and bits[i] == 0:      # falling edge = start
            byte = 0
            ok = True
            for b in range(10):                   # start + 8 data + stop
                c = i + int((b + 0.5) * spb)
                if c >= n:
                    ok = False; break
                v = bits[c]
                if b == 0:
                    if v != 0: ok = False; break
                elif b == 9:
                    if v != 1: ok = False; break
                else:
                    byte |= v << (b - 1)
            if ok:
                out.append(byte)
                i += int(10 * spb)
                continue
        i += 1
    return bytes(out)

def main():
    path = sys.argv[1]
    sr = float(sys.argv[2]) if len(sys.argv) > 2 else 1e6
    outp = sys.argv[3] if len(sys.argv) > 3 else None
    d = open(path, "rb").read()
    n = len(d)
    print(f"samples={n} rate={sr:.0f} dur={n/sr:.2f}s")
    best_ch, best_txt = -1, b""
    for ch in range(8):
        # count falling edges cheaply
        falls = 0
        prev = (d[0] >> ch) & 1
        bits = [0] * n
        for i in range(n):
            v = (d[i] >> ch) & 1
            bits[i] = v
            if prev == 1 and v == 0:
                falls += 1
            prev = v
        if falls < 4:
            print(f"ch{ch}: {falls} falling edges -- silent, skip")
            continue
        txt = decode_channel(bits, sr, n)
        printable = sum(32 <= c < 127 or c in (10, 13) for c in txt)
        print(f"ch{ch}: {falls} falling edges, decoded {len(txt)} bytes, "
              f"printable {printable}")
        if len(txt) > len(best_txt):
            best_ch, best_txt = ch, txt
    if best_ch < 0:
        print("NO UART CHANNEL FOUND")
        return
    print(f"--- decoded on ch{best_ch} ({len(best_txt)} bytes) ---")
    sys.stdout.write(best_txt.decode("ascii", "replace"))
    if outp:
        open(outp, "wb").write(best_txt)
        print(f"\nsaved -> {outp}")

if __name__ == "__main__":
    main()
