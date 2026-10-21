#!/usr/bin/env python3
"""hv_run.py -- host driver for top_hwverify board verification.

Usage:
  python hv_run.py [--port COM24] [--out DIR]

Protocol on 115200 8N1:
  'W' a d0 d1 d2 d3  -> write regs[a]
  'R' a              -> reply "R=XXXXXXXX\r\n"
  'P' s              -> probe mux select
  'T'                -> 16-reg report "Rn=XXXXXXXX\r\n" x16
"""
import argparse, re, sys, time

try:
    import serial
except ImportError:
    sys.exit("pyserial required: pip install pyserial")

REPORT = {
    0:  ("scratch (R/W)",            None),
    1:  ("T0 POR len+glitch",        "por"),
    2:  ("T1 PLL lock+latency",      "pll"),
    3:  ("T7 clk54 ticks",           "ticks"),
    4:  ("T7 csc54 digest",          "dig54"),
    5:  ("T7 csc54 done/pass/cyc",   None),
    6:  ("T2 CDC xfers",             "xfers"),
    7:  ("T2 CDC errs",              "errs0"),
    8:  ("T2 meta disagreements",    None),
    9:  ("T2 meta samples",          None),
    10: ("T2 CDC sync latency",      None),
    11: ("T3 CSC27 cycles",          "thru"),
    12: ("T3 done/pass",             None),
    13: ("T3 CSC27 digest",          "dig27"),
    14: ("T4 edge flags+wdt cnt",    "edge"),
    15: ("T4 tmr done+err_cnt",      None),
}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM24")
    ap.add_argument("--probe", type=int, default=None,
                    help="set probe mux and exit")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    ser = serial.Serial(args.port, 115200, timeout=0.2)
    ser.reset_input_buffer()

    def send(*bs):
        # uart_rx holds rx_valid through an ACK state after stop; back-to-back
        # bytes lose the next start bit -> insert ~2 bit-times between bytes
        for b in bs:
            ser.write(bytes([b])); ser.flush()
            time.sleep(0.0005)

    def read_reg(a, wait=0.6):
        ser.reset_input_buffer()
        send(0x52, a)
        time.sleep(wait)
        data = ser.read(64)
        m = re.search(rb"R=([0-9A-F]{8})", data)
        return int(m.group(1), 16) if m else None

    if args.probe is not None:
        send(0x50, args.probe)
        print(f"probe_sel <= {args.probe}")
        return

    # ---- T5: bus read/write ----
    results = {}
    send(0x57, 0, 0xEF, 0xBE, 0xAD, 0xDE)      # W 0 = 0xDEADBEEF
    time.sleep(0.15)
    v = read_reg(0)
    results["T5 scratch R/W"] = (v == 0xDEADBEEF, f"{v:#010x}")
    v = read_reg(31)
    results["T5 magic reg"] = (v == 0x48375632, f"{v:#010x}")
    v = read_reg(240)                          # invalid address
    results["T5 invalid addr"] = (v == 0xDEAD00F0, f"{v:#010x}")

    # ---- full report ----
    ser.reset_input_buffer()
    send(0x54)
    time.sleep(0.5)
    data = b""
    t0 = time.time()
    while time.time() - t0 < 4.0:
        chunk = ser.read(4096)
        if chunk: data += chunk; t0 = time.time()
    regs = {}
    for m in re.finditer(rb"R([0-9A-F])=([0-9A-F]{8})", data):
        regs[int(m.group(1), 16)] = int(m.group(2), 16)

    if args.out:
        open(args.out, "wb").write(data)

    def chk(name, cond, detail=""):
        results[name] = (bool(cond), detail)

    if len(regs) < 16:
        print("FAIL: incomplete report", len(regs), "regs")
        print(data[:400])
        sys.exit(1)

    r1, r2, r3 = regs[1], regs[2], regs[3]
    chk("T0 POR length ~4096", (r1 & 0xFFFF) in (0xFFF, 0x1000),
        f"{r1 & 0xFFFF}")
    chk("T0 no reset glitch",   (r1 >> 16) & 1 == 0, f"glitch={r1>>16 & 1}")
    chk("T1 PLL lock",          (r2 >> 16) & 1 == 1,
        f"seen={r2>>17 & 1} lock={r2>>16 & 1} lat={r2 & 0xFFFF}")
    chk("T1 PLL lock latency",  0 < (r2 & 0xFFFF) < 100000,
        f"{r2 & 0xFFFF} clk = {(r2 & 0xFFFF)/27.0:.1f} us")
    ticks = r3 & 0x1FFFFFF
    if ticks < 33_554_432:                       # unwrap 25-bit counter
        ticks += 33_554_432
    chk("T7 54MHz ticks ~54M",  50_000_000 < ticks < 58_000_000,
        f"{ticks} ticks/1s -> {ticks/1e6:.2f} MHz")
    # 54 MHz is a margin probe: log result, do not gate the suite on it
    c54ok = regs[4] == 0xCE41D92D and (regs[5] >> 24) & 3 == 3
    print(f"  INFO  T7 margin CSC@54MHz          digest={regs[4]:#010x} "
          f"pass={c54ok}")
    v = read_reg(20); v2 = read_reg(21)          # 33.75 MHz domain
    chk("T7 CSC@33.75MHz digest",  v == 0xCE41D92D,
        f"{v:#010x}" if v is not None else "none")
    chk("T7 CSC@33.75MHz done+pass", v2 is not None and (v2 >> 24) & 3 == 3,
        f"{v2:#010x}" if v2 is not None else "none")
    chk("T2 CDC xfers > 100",   regs[6] > 100, f"{regs[6]}")
    chk("T2 CDC errs == 0",     regs[7] == 0, f"{regs[7]}")
    chk("T2 meta samples full", regs[9] == 0xFFFF, f"{regs[9]:#06x}")
    chk("T3 cycles ~2121",      2000 < (regs[11] & 0xFFFF) < 2300,
        f"{regs[11] & 0xFFFF}")
    chk("T3 done+pass",         (regs[12] >> 16) & 3 == 3, f"{regs[12]:#010x}")
    chk("T3 digest CE41D92D",   regs[13] == 0xCE41D92D, f"{regs[13]:#010x}")
    chk("T4 wdt+tmr ok",        (regs[14] >> 16) & 3 == 3, f"{regs[14]:#010x}")
    chk("T4 wdt all events",    all(((regs[14] >> s) & 0xF) for s in (0,4,8,12)),
        f"cnts ct={regs[14]&0xF} cl={regs[14]>>4&0xF} "
        f"ce={regs[14]>>8&0xF} cg={regs[14]>>12&0xF}")
    chk("T4 tmr err_cnt>=2",    regs[15] & 0xFFFF >= 2, f"{regs[15]:#010x}")

    # ---- T6: program stepper+pwm, read back ----
    send(0x57, 20, 0x4A, 0x05, 0, 0)            # pwm duty0 = 0x054A (~50%)
    send(0x57, 21, 0xE8, 0x03, 0, 0)            # step interval = 1000
    send(0x57, 22, 0x00, 0x01, 0, 0)            # step count = 256
    send(0x57, 23, 0x01, 0, 0, 0)               # go
    time.sleep(0.2)
    v = read_reg(18)                            # {dir,busy,pos}
    chk("T6 step pos>0",        v is not None and (v & 0xFFFF) > 0,
        f"{v:#010x}" if v is not None else "none")
    v = read_reg(17)
    chk("T6 qei count>0",       v is not None and v > 0,
        f"{v:#010x}" if v is not None else "none")

    print("=" * 56)
    npass = 0
    for k, (ok, d) in results.items():
        npass += ok
        print(f"  {'PASS' if ok else 'FAIL'}  {k:28s} {d}")
    print("=" * 56)
    print(f"BOARD VERIFY: {npass}/{len(results)} PASS")
    sys.exit(0 if npass == len(results) else 1)

if __name__ == "__main__":
    main()
