import argparse
import os
import sys
import time
from pathlib import Path

import usb.backend.libusb1 as libusb1
import usb.core
from pyftdi.ftdi import Ftdi


def open_ftdi(interface: int, baud: int):
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
    ftdi.set_baudrate(baud)
    ftdi.set_line_property(8, 1, "N")
    ftdi.set_flowctrl("")
    ftdi.purge_buffers()
    return ftdi


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--interface", type=int, default=2)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--seconds", type=float, default=5.0)
    args = parser.parse_args()

    ftdi = open_ftdi(args.interface, args.baud)
    print(f"open FTDI interface {args.interface} @ {args.baud} path={ftdi.usb_path}", flush=True)
    deadline = time.monotonic() + args.seconds
    received = bytearray()
    try:
        while time.monotonic() < deadline:
            chunk = bytes(ftdi.read_data_bytes(256, attempt=8))
            if chunk:
                received.extend(chunk)
                sys.stdout.buffer.write(chunk)
                sys.stdout.flush()
            else:
                time.sleep(0.02)
    finally:
        ftdi.close()

    print(f"\nsummary bytes={len(received)} seconds={args.seconds:.1f}", flush=True)
    return 0 if received else 1


if __name__ == "__main__":
    raise SystemExit(main())
