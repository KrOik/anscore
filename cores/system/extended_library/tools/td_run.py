#!/usr/bin/env python3
"""td_run.py -- host driver for top_tapedbg (tapeout-debug verification top).

Exercises every checklist facility over the dock UART (FT2232 iface B,
115200 8N1 via pyftdi/libusb; falls back to --com COMx with pyserial):

  'W' a d0 d1 d2 d3 -> regs[a] = {d3,d2,d1,d0}   (d0 = LSB first)
  'R' a             -> "R=XXXXXXXX\r\n"
  'P' s             -> probe page select
  'T'               -> 16-reg report (regs 0x10..0x1F)

Usage:  python td_run.py [--com COM24] [--iface 2] [--quick]
"""
import argparse, os, re, sys, time
from pathlib import Path

MAGIC = 0x54415045
GOLD  = 0xDB2D98F1

def open_ftdi(iface, baud):
    root = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
    libdir = root / "tools" / "oss-cad-suite" / "oss-cad-suite" / "lib"
    dll = libdir / "libusb-1.0.dll"
    os.add_dll_directory(str(libdir))
    import usb.core, usb.backend.libusb1 as libusb1
    from pyftdi.ftdi import Ftdi
    backend = libusb1.get_backend(find_library=lambda _: str(dll))
    dev = usb.core.find(idVendor=0x0403, idProduct=0x6010, backend=backend)
    if dev is None:
        raise RuntimeError("FT2232 not found (0x0403:0x6010)")
    ftdi = Ftdi(); ftdi.open_from_device(dev, iface)
    ftdi.set_baudrate(baud); ftdi.set_line_property(8, 1, "N")
    ftdi.set_flowctrl(""); ftdi.purge_buffers()
    return ftdi

class Uart:
    def __init__(self, args):
        self.ser = None; self.ftdi = None; self.rxbuf = bytearray()
        if args.com:
            import serial
            self.ser = serial.Serial(args.com, 115200, timeout=0.05)
            self.ser.reset_input_buffer()
        else:
            self.ftdi = open_ftdi(args.iface, 115200)
    def send(self, *bs):
        # uart_rx drops back-to-back start bits; keep ~1ms between bytes
        for b in bs:
            self._w(bytes([b])); time.sleep(0.001)
    def _w(self, b):
        if self.ser: self.ser.write(b); self.ser.flush()
        else: self.ftdi.write_data(b)
    def _r(self, n):
        if self.ser: return self.ser.read(n)
        try: return bytes(self.ftdi.read_data_bytes(n, attempt=1))
        except Exception: return b""
    def drain(self, dur=0.15):
        end = time.time() + dur
        while time.time() < end:
            c = self._r(256)
            if c: self.rxbuf.extend(c); end = time.time() + dur
            else: time.sleep(0.01)
    def read_reg(self, a, timeout=3.0):
        self.rxbuf.clear()
        self.send(0x52, a)
        end = time.time() + timeout
        while time.time() < end:
            c = self._r(256)
            if c:
                self.rxbuf.extend(c)
                m = re.search(rb"R=([0-9A-F]{8})", bytes(self.rxbuf))
                if m: return int(m.group(1), 16)
            else: time.sleep(0.01)
        return None
    def report(self):
        self.rxbuf.clear()
        self.send(0x54)
        end = time.time() + 8.0
        while len(self.rxbuf) < 16*13 and time.time() < end:
            c = self._r(256)
            if c: self.rxbuf.extend(c)
            else: time.sleep(0.01)
        return dict(re.findall(rb"R([0-9A-F])=([0-9A-F]{8})", bytes(self.rxbuf)))

PASS = []
def chk(name, cond, val=None):
    PASS.append((name, bool(cond), val))
    tag = "PASS" if cond else "FAIL"
    v = f" ({val:#010x})" if isinstance(val, int) else ""
    print(f"{tag} {name}{v}", flush=True)

def jt(u, tms, tdi):
    u.send(0x57, 0x0A, (4 | (tdi << 1) | tms) & 0xFF, 0, 0, 0)

def jread(u):
    v = u.read_reg(0x0A)
    return v

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--com", default=None)
    ap.add_argument("--iface", type=int, default=2)
    ap.add_argument("--quick", action="store_true",
                    help="skip slow JTAG/scan shift loops")
    args = ap.parse_args()
    u = Uart(args)
    time.sleep(0.3)

    # ---- bus + magic ----
    v = u.read_reg(0x1F); chk("magic TAPE", v == MAGIC, v)
    u.send(0x57, 0, 0xEF, 0xBE, 0xAD, 0xDE); time.sleep(0.05)
    v = u.read_reg(0x00); chk("scratch rw", v == 0xDEADBEEF, v)
    v = u.read_reg(0xF0); chk("invalid addr", v == 0xDEAD00F0, v)

    # ---- A18/A7 POR status ----
    v = u.read_reg(0x10)
    chk("por_cycles", v is not None and (v & 0xFFFF) == 4096, v)
    chk("rst_glitch=0", v is not None and ((v >> 23) & 1) == 0, v)

    # ---- A6 PLL ----
    v = u.read_reg(0x11)
    chk("pll lock seen", v is not None and (v >> 31) & 1, v)
    chk("pll locked",    v is not None and (v >> 30) & 1, v)

    # ---- A1 scan boot check ----
    v = u.read_reg(0x09)
    chk("scan boot ok", v is not None and (v >> 2) & 1, v)

    # ---- A2 MBIST (auto-run) ----
    for _ in range(20):
        v = u.read_reg(0x18)
        if v is not None and (v >> 18) & 1: break
    chk("mbist done",   v is not None and (v >> 18) & 1, v)
    chk("mbist nofail", v is not None and ((v >> 17) & 1) == 0, v)

    # ---- A9 golden ----
    for _ in range(20):
        v = u.read_reg(0x15)
        if v is not None and (v >> 31) & 1: break
    chk("golden done",  v is not None and (v >> 31) & 1, v)
    chk("golden match", v is not None and (v >> 30) & 1, v)
    v = u.read_reg(0x14); chk("golden digest", v == GOLD, v)

    # ---- A17 loopback ----
    v = u.read_reg(0x1E)
    chk("lb bytes", v is not None and ((v >> 16) & 0xFF) > 0, v)

    # ---- A10 pipe + bypass ----
    def f0(x): return (((x << 1) | (x >> 15)) & 0xFFFF) + 0x1021 & 0xFFFF
    def f1(x): return ((x ^ 0x5A5A) + 3) & 0xFFFF
    def f2(x): return ((~x & 0xFFFF) + (x & 0xFF)) & 0xFFFF
    u.send(0x57, 0x0E, 0, 0, 0, 0)
    u.send(0x57, 0x0D, 0x34, 0x12, 0x01, 0x00); time.sleep(0.05)
    v = u.read_reg(0x1B)
    chk("pipe y0", v is not None and (v >> 16) == f0(0x1234), v)
    chk("pipe y1", v is not None and (v & 0xFFFF) == f1(f0(0x1234)), v)
    v = u.read_reg(0x1C)
    chk("pipe y2", v is not None and (v >> 16) == f2(f1(f0(0x1234))), v)

    # ---- A14 RAM host port ----
    u.send(0x57, 0x0F, 0xA5, 0x55, 0x01, 0x00)   # we: addr=0x55 data=0xA5
    u.send(0x57, 0x0F, 0x00, 0x55, 0x02, 0x00)   # re: addr=0x55
    time.sleep(0.05)
    v = u.read_reg(0x0F); chk("ram host rd", v is not None and (v & 0xFF) == 0xA5, v)

    # ---- A7/A12 domain reset + single-step ----
    u.send(0x57, 3, 1, 0, 0, 0)                # dom_rst dclk
    u.send(0x57, 5, 2, 0, 0, 0)                # step_mode
    u.send(0x57, 3, 0, 0, 0, 0)
    time.sleep(0.05)
    v = u.read_reg(0x17); chk("gate frozen", v is not None and (v & 0xFFFF) == 0, v)
    u.send(0x57, 2, 2, 0, 0, 0); time.sleep(0.05)
    v = u.read_reg(0x17); chk("step cnt1", v is not None and (v & 0xFFFF) == 1, v)
    u.send(0x57, 5, 1, 0, 0, 0)                # gate_en
    for _ in range(20):
        v = u.read_reg(0x15)
        if v is not None and (v >> 31) & 1: break
    v = u.read_reg(0x14); chk("golden rerun", v == GOLD, v)

    # ---- A5 clock bypass ----
    for sel, tag in ((1, "54MHz"), (2, "13.5MHz"), (0, "27MHz")):
        u.send(0x57, 4, sel, 0, 0, 0)
        ok = False
        for _ in range(30):
            v = u.read_reg(0x15)
            if v is not None and (v >> 31) & 1: ok = True; break
        v = u.read_reg(0x14); chk(f"digest @{tag}", v == GOLD and ok, v)

    # ---- A13 ring osc ----
    v = u.read_reg(0x13); chk("ro alive", v is not None and (v >> 24) & 1, v)

    # ---- A11+B2 ILA trigger on injected fault ----
    u.send(0x57, 0x0B, 0x00, 0x02, 0x00, 0x00)   # mask=0x80
    u.send(0x57, 0x0B, 0x01, 0x02, 0x00, 0x00)   # val =0x80
    u.send(0x57, 0x0B, 0x22, 0x00, 0x00, 0x00)   # pre =8
    u.send(0x57, 0x0B, 0x07, 0x00, 0x00, 0x00)   # mode=rising
    u.send(0x57, 0x0B, 0x00, 0x00, 0x04, 0x00)   # arm
    u.send(0x57, 0x06, 1, 0, 0, 0)               # fi_golden
    u.send(0x57, 3, 1, 0, 0, 0); u.send(0x57, 3, 0, 0, 0, 0)
    for _ in range(30):
        v = u.read_reg(0x1D)
        if v is not None and (v >> 30) & 1: break
    chk("ila done",  v is not None and (v >> 30) & 1, v)
    chk("ila fired", v is not None and (v >> 29) & 1, v)
    tptr = (v or 0) & 0x3FF
    u.send(0x57, 0x0C, tptr & 0xFF, (tptr >> 8) & 3, 0, 0); time.sleep(0.05)
    v = u.read_reg(0x0C); chk("ila trig bit7", v is not None and (v >> 7) & 1, v)
    v = u.read_reg(0x15)
    chk("first_err",   v is not None and (v >> 28) & 1, v)
    chk("trig_sticky", v is not None and (v >> 27) & 1, v)
    v = u.read_reg(0x16)
    chk("err exp^got", v is not None and ((v >> 16) ^ (v & 0xFFFF)) == 0xFF, v)
    u.send(0x57, 0x06, 0, 0, 0, 0)
    u.send(0x57, 3, 1, 0, 0, 0); u.send(0x57, 3, 0, 0, 0, 0)
    for _ in range(30):
        v = u.read_reg(0x15)
        if v is not None and (v >> 31) & 1: break
    chk("clean rerun", v is not None and (v >> 31) & 1 and ((v >> 28) & 1) == 0, v)

    # ---- A2 fault injection ----
    u.send(0x57, 0x06, 2, 0, 0, 0)
    u.send(0x57, 0x07, 0x42, 0, 0, 0)
    u.send(0x57, 0x08, 1, 0, 0, 0)
    for _ in range(30):
        v = u.read_reg(0x18)
        if v is not None and (v >> 18) & 1: break
    chk("mbist fi fail", v is not None and (v >> 17) & 1, v)
    chk("mbist fi addr", v is not None and (v & 0xFF) == 0x42, v)
    u.send(0x57, 0x06, 0, 0, 0, 0)
    u.send(0x57, 0x08, 1, 0, 0, 0)
    for _ in range(30):
        v = u.read_reg(0x18)
        if v is not None and (v >> 18) & 1: break
    chk("mbist clean", v is not None and ((v >> 17) & 1) == 0, v)

    if not args.quick:
        # ---- A1 scan loopback ----
        patt = 0xCAFEBABE12345678
        u.send(0x57, 9, 1, 0, 0, 0)
        for i in range(64):
            u.send(0x57, 9, 0x09 | (((patt >> i) & 1) << 1), 0, 0, 0)
        out = 0
        for i in range(64):
            v = u.read_reg(9)
            if v is not None: out |= (v & 1) << i
            u.send(0x57, 9, 9, 0, 0, 0)
        chk("scan loopback", out == patt, out & 0xFFFFFFFF)
        # stuck-at-0 at cell3: all-ones in -> all-zeros out
        u.send(0x57, 0x06, 4, 0, 0, 0)
        for i in range(64): u.send(0x57, 9, 0x0B, 0, 0, 0)
        out = 0
        for i in range(64):
            v = u.read_reg(9)
            if v is not None: out |= (v & 1) << i
            u.send(0x57, 9, 9, 0, 0, 0)
        chk("scan stuck det", out == 0, out & 0xFFFFFFFF)
        u.send(0x57, 0x06, 0, 0, 0, 0); u.send(0x57, 9, 0, 0, 0, 0)

        # ---- A3 TAP ----
        for _ in range(5): jt(u, 1, 0)
        jt(u, 0, 0); jt(u, 1, 0); jt(u, 1, 0); jt(u, 0, 0); jt(u, 0, 0)
        jt(u, 0, 1); jt(u, 0, 0); jt(u, 0, 0); jt(u, 1, 0)   # IR=0001
        jt(u, 1, 0); jt(u, 0, 0)
        jt(u, 1, 0); jt(u, 0, 0); jt(u, 0, 0)
        idc = 0
        for i in range(32):
            v = jread(u); idc |= ((v >> 5) & 1) << i if v is not None else 0
            jt(u, 1 if i == 31 else 0, 0)
        chk("tap idcode", idc == 0x54414E47, idc)

    # ---- A18 POR retrig ----
    u.send(0x57, 1, 8, 0, 0, 0)
    u.send(0x57, 2, 1, 0, 0, 0)
    time.sleep(0.2)
    v = u.read_reg(0x10)
    chk("retrig por_cycles", v is not None and (v & 0xFFFF) == 256, v)
    chk("retrig por_count",  v is not None and (v >> 24) == 1, v)

    # ---- T report ----
    rep = u.report()
    chk("T report 16 regs", len(rep) == 16, len(rep))
    chk("T magic", rep.get(b'F') == b'54415045', rep.get(b'F'))

    # ---- A16 lock (LAST) ----
    v0 = u.read_reg(0)
    u.send(0x57, 2, 4, 0, 0, 0)
    u.send(0x57, 0, 0x78, 0x56, 0x34, 0x12); time.sleep(0.05)
    v = u.read_reg(0); chk("lock blocks W", v == v0, v)

    fails = [p for p in PASS if not p[1]]
    print(f"\nTAPEDBG BOARD: {len(PASS)-len(fails)}/{len(PASS)} PASS")
    for n, _, v in fails: print(f"  FAIL {n} ({v})")
    sys.exit(1 if fails else 0)

if __name__ == "__main__":
    main()
