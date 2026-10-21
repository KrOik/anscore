import argparse
import os
import struct
import sys
import time
from pathlib import Path

import usb.core
import usb.backend.libusb1 as libusb1
from pyftdi.ftdi import Ftdi


HEADER = b"\xAA\x55\x01"
FRAME_LEN = 24
LED_ON_ENERGY_GATE = 450
LED_SCORE_GAP_GATE = 48


def strength_to_red(value: int) -> int:
    if value >= 8192:
        return 255
    return max(8, value >> 5)


def parse_frame(frame: bytes):
    if len(frame) != FRAME_LEN:
        return None
    if frame[:3] != HEADER or frame[-2:] != b"\r\n":
        return None
    report0, report1, report2, report3 = struct.unpack(">IIII", frame[4:20])
    delay03, delay14, delay25, status = struct.unpack("bbbB", frame[8:12])
    vec_x, vec_y = struct.unpack(">hh", frame[12:16])
    score_gap, best_score = struct.unpack(">HH", frame[16:20])
    return {
        "flags": frame[3] >> 4,
        "led_index": frame[3] & 0x0F,
        "reports": (report0, report1, report2, report3),
        "delay03": delay03,
        "delay14": delay14,
        "delay25": delay25,
        "status": status,
        "vec_x": vec_x,
        "vec_y": vec_y,
        "score_gap": score_gap,
        "best_score": best_score,
        "sequence": struct.unpack(">H", frame[20:22])[0],
    }


def open_ftdi(interface: int):
    root = Path(__file__).resolve().parents[1]
    lib_dir = root / "tools" / "oss-cad-suite" / "oss-cad-suite" / "lib"
    libusb_dll = lib_dir / "libusb-1.0.dll"
    if not libusb_dll.exists():
        raise FileNotFoundError(f"libusb runtime not found: {libusb_dll}")

    os.add_dll_directory(str(lib_dir))
    backend = libusb1.get_backend(find_library=lambda _: str(libusb_dll))
    if backend is None:
        raise RuntimeError("libusb backend is unavailable")

    dev = usb.core.find(idVendor=0x0403, idProduct=0x6010, backend=backend)
    if dev is None:
        raise RuntimeError("FT2232 device not found over WinUSB/libusb")

    ftdi = Ftdi()
    ftdi.open_from_device(dev, interface)
    ftdi.set_baudrate(115200)
    ftdi.set_line_property(8, 1, "N")
    ftdi.set_flowctrl("")
    ftdi.purge_buffers()
    return ftdi


def read_frames(
    interface: int,
    seconds: float | None = None,
    max_frames: int | None = None,
    active_only: bool = False,
):
    ftdi = open_ftdi(interface)
    print(f"open FTDI interface {interface} path={ftdi.usb_path}", flush=True)
    buf = bytearray()
    last_sequence = None
    start_time = time.monotonic()
    frame_count = 0
    active_count = 0
    valid_count = 0
    try:
        while True:
            if seconds is not None and (time.monotonic() - start_time) >= seconds:
                break
            if max_frames is not None and frame_count >= max_frames:
                break

            chunk = bytes(ftdi.read_data_bytes(256, attempt=8))
            if chunk:
                buf.extend(chunk)
            else:
                time.sleep(0.05)

            while True:
                idx = buf.find(HEADER)
                if idx < 0:
                    if len(buf) > 64:
                        del buf[:-2]
                    break
                if len(buf) < idx + FRAME_LEN:
                    if idx > 0:
                        del buf[:idx]
                    break
                frame = bytes(buf[idx:idx + FRAME_LEN])
                del buf[:idx + FRAME_LEN]
                parsed = parse_frame(frame)
                if not parsed:
                    continue

                frame_count += 1
                r0, r1, r2, r3 = parsed["reports"]
                tag = "hb" if (parsed["flags"] & 0x1) else "doa"
                gap_note = ""
                if last_sequence is not None:
                    expected = (last_sequence + 1) & 0xFFFF
                    if parsed["sequence"] != expected:
                        gap_note = f" gap={((parsed['sequence'] - expected) & 0xFFFF):d}"
                last_sequence = parsed["sequence"]
                if tag == "hb":
                    last_sample = r3 if r3 < 0x80000000 else r3 - 0x100000000
                    print(
                        f"{tag} "
                        f"seq={parsed['sequence']:05d} "
                        f"led={parsed['led_index']:02d} "
                        f"bclk={r0:08d} ws={r1:08d} samp={r2:08d} last0={last_sample:+08d}"
                        f"{gap_note}",
                        flush=True,
                    )
                else:
                    confidence = parsed["status"] & 0x3F
                    dir_valid = (parsed["status"] >> 6) & 0x1
                    overrun = (parsed["status"] >> 7) & 0x1
                    led_active = bool(parsed["flags"] & 0x1)
                    if dir_valid:
                        valid_count += 1
                    if led_active:
                        active_count += 1
                    if active_only and not led_active:
                        continue
                    center_red = strength_to_red(r0)
                    side_red = center_red >> 1
                    prev_led = (parsed["led_index"] - 1) % 12
                    next_led = (parsed["led_index"] + 1) % 12
                    led_note = (
                        f"leds=({prev_led:02d}:{side_red:03d},"
                        f"{parsed['led_index']:02d}:{center_red:03d},"
                        f"{next_led:02d}:{side_red:03d})"
                        if led_active
                        else "leds=off"
                    )
                    print(
                        f"{tag} "
                        f"seq={parsed['sequence']:05d} "
                        f"led={parsed['led_index']:02d} "
                        f"sum={r0:08d} "
                        f"d=({parsed['delay03']:+03d},{parsed['delay14']:+03d},{parsed['delay25']:+03d}) "
                        f"v=({parsed['vec_x']:+04d},{parsed['vec_y']:+04d}) "
                        f"conf={confidence:02d} valid={dir_valid:d} ovf={overrun:d} "
                        f"gap={parsed['score_gap']:05d} best={parsed['best_score']:05d}"
                        f" {led_note}"
                        f"{gap_note}",
                        flush=True,
                    )
    finally:
        elapsed = time.monotonic() - start_time
        print(
            f"summary frames={frame_count} valid={valid_count} active_led={active_count} seconds={elapsed:.1f}",
            flush=True,
        )
        ftdi.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--interface", type=int, default=2)
    parser.add_argument("--seconds", type=float, default=None)
    parser.add_argument("--max-frames", type=int, default=None)
    parser.add_argument("--active-only", action="store_true")
    args = parser.parse_args()
    read_frames(args.interface, args.seconds, args.max_frames, args.active_only)


if __name__ == "__main__":
    sys.exit(main())
