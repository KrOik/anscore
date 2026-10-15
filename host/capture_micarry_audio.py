import argparse
import csv
import math
import struct
import sys
import time
import wave
from pathlib import Path

import serial


HEADER = b"\xA7\x5A"
FRAME_LEN = 22
SLOT_NAMES = ["d0_r", "d0_l", "d1_r", "d1_l", "d2_r", "d2_l", "d3_r", "d3_l"]
MIC_NAMES = ["mic0", "mic1", "mic2", "mic3", "mic4", "mic5", "mic_center"]


def parse_frame(frame: bytes):
    if len(frame) != FRAME_LEN:
        return None
    if frame[:2] != HEADER or frame[-2:] != b"\r\n":
        return None
    seq = struct.unpack(">H", frame[2:4])[0]
    slots = struct.unpack(">hhhhhhhh", frame[4:20])
    return seq, slots


def read_frames(port: str, baud: int, seconds: float, max_frames: int | None):
    ser = serial.Serial(port, baudrate=baud, timeout=0.1)
    buf = bytearray()
    frames = []
    start = time.monotonic()
    try:
        while True:
            if seconds is not None and (time.monotonic() - start) >= seconds:
                break
            if max_frames is not None and len(frames) >= max_frames:
                break

            chunk = ser.read(4096)
            if chunk:
                buf.extend(chunk)
            else:
                time.sleep(0.005)

            while True:
                idx = buf.find(HEADER)
                if idx < 0:
                    if len(buf) > FRAME_LEN:
                        del buf[:-1]
                    break
                if len(buf) < idx + FRAME_LEN:
                    if idx > 0:
                        del buf[:idx]
                    break
                frame = bytes(buf[idx : idx + FRAME_LEN])
                del buf[:idx + FRAME_LEN]
                parsed = parse_frame(frame)
                if parsed is not None:
                    frames.append(parsed)
    finally:
        elapsed = time.monotonic() - start
        ser.close()
    return frames, elapsed


def open_ftdi(interface: int, baud: int):
    import os

    import usb.core
    import usb.backend.libusb1 as libusb1
    from pyftdi.ftdi import Ftdi

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


def read_frames_ftdi(interface: int, baud: int, seconds: float, max_frames: int | None):
    ftdi = open_ftdi(interface, baud)
    buf = bytearray()
    frames = []
    start = time.monotonic()
    try:
        while True:
            if seconds is not None and (time.monotonic() - start) >= seconds:
                break
            if max_frames is not None and len(frames) >= max_frames:
                break

            chunk = bytes(ftdi.read_data_bytes(4096, attempt=8))
            if chunk:
                buf.extend(chunk)
            else:
                time.sleep(0.005)

            while True:
                idx = buf.find(HEADER)
                if idx < 0:
                    if len(buf) > FRAME_LEN:
                        del buf[:-1]
                    break
                if len(buf) < idx + FRAME_LEN:
                    if idx > 0:
                        del buf[:idx]
                    break
                frame = bytes(buf[idx : idx + FRAME_LEN])
                del buf[:idx + FRAME_LEN]
                parsed = parse_frame(frame)
                if parsed is not None:
                    frames.append(parsed)
    finally:
        elapsed = time.monotonic() - start
        ftdi.close()
    return frames, elapsed


def rms(values):
    if not values:
        return 0.0
    return math.sqrt(sum(v * v for v in values) / len(values))


def write_wav(path: Path, samples, sample_rate: int):
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        clipped = [max(-32768, min(32767, int(v))) for v in samples]
        wf.writeframes(struct.pack("<" + "h" * len(clipped), *clipped))


def export_capture(frames, out_dir: Path, sample_rate: int, elapsed: float):
    out_dir.mkdir(parents=True, exist_ok=True)
    slot_columns = {name: [] for name in SLOT_NAMES}
    seqs = []
    gaps = 0
    last_seq = None

    for seq, slots in frames:
        if last_seq is not None and seq != ((last_seq + 1) & 0xFFFF):
            gaps += 1
        last_seq = seq
        seqs.append(seq)
        for name, value in zip(SLOT_NAMES, slots):
            slot_columns[name].append(value)

    d3_r_rms = rms(slot_columns["d3_r"])
    d3_l_rms = rms(slot_columns["d3_l"])
    center_slot = "d3_r" if d3_r_rms >= d3_l_rms else "d3_l"
    mic_columns = {
        "mic0": slot_columns["d0_r"],
        "mic1": slot_columns["d0_l"],
        "mic2": slot_columns["d1_r"],
        "mic3": slot_columns["d1_l"],
        "mic4": slot_columns["d2_r"],
        "mic5": slot_columns["d2_l"],
        "mic_center": slot_columns[center_slot],
    }

    csv_path = out_dir / "micarry_slots.csv"
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["index", "seq", *SLOT_NAMES])
        for i, (seq, slots) in enumerate(frames):
            writer.writerow([i, seq, *slots])

    mic_csv_path = out_dir / "micarry_7mic.csv"
    with mic_csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["index", "seq", *MIC_NAMES])
        for i, seq in enumerate(seqs):
            writer.writerow([i, seq, *[mic_columns[name][i] for name in MIC_NAMES]])

    for name in SLOT_NAMES:
        write_wav(out_dir / f"slot_{name}.wav", slot_columns[name], sample_rate)
    for name in MIC_NAMES:
        write_wav(out_dir / f"{name}.wav", mic_columns[name], sample_rate)

    report_path = out_dir / "report.txt"
    with report_path.open("w", encoding="utf-8") as f:
        f.write(f"frames={len(frames)}\n")
        f.write(f"elapsed_seconds={elapsed:.6f}\n")
        f.write(f"sample_rate={sample_rate}\n")
        f.write(f"sequence_gaps={gaps}\n")
        f.write(f"center_slot={center_slot}\n")
        f.write("slot_rms:\n")
        for name in SLOT_NAMES:
            f.write(f"  {name}={rms(slot_columns[name]):.2f}\n")
        f.write("mic_mapping:\n")
        f.write("  mic0=d0_r\n")
        f.write("  mic1=d0_l\n")
        f.write("  mic2=d1_r\n")
        f.write("  mic3=d1_l\n")
        f.write("  mic4=d2_r\n")
        f.write("  mic5=d2_l\n")
        f.write(f"  mic_center={center_slot}\n")

    return csv_path, mic_csv_path, report_path, center_slot, gaps


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default=None)
    parser.add_argument("--ftdi-interface", type=int, default=None)
    parser.add_argument("--baud", type=int, default=2_000_000)
    parser.add_argument("--seconds", type=float, default=5.0)
    parser.add_argument("--max-frames", type=int, default=None)
    parser.add_argument("--out", default=None)
    parser.add_argument("--sample-rate", type=int, default=0)
    args = parser.parse_args()

    timestamp = time.strftime("%Y%m%d_%H%M%S")
    out_dir = Path(args.out) if args.out else Path("captures") / f"micarry_audio_{timestamp}"

    if args.ftdi_interface is not None:
        frames, elapsed = read_frames_ftdi(
            args.ftdi_interface, args.baud, args.seconds, args.max_frames
        )
    elif args.port:
        frames, elapsed = read_frames(args.port, args.baud, args.seconds, args.max_frames)
    else:
        print("specify --port COMx or --ftdi-interface N", file=sys.stderr)
        return 2
    if not frames:
        print("no valid frames captured", file=sys.stderr)
        return 2

    sample_rate = args.sample_rate
    if sample_rate <= 0:
        sample_rate = max(1, int(round(len(frames) / elapsed))) if elapsed > 0 else 1

    csv_path, mic_csv_path, report_path, center_slot, gaps = export_capture(
        frames, out_dir, sample_rate, elapsed
    )
    print(f"frames={len(frames)} elapsed={elapsed:.3f}s sample_rate={sample_rate} gaps={gaps} center_slot={center_slot}")
    print(f"csv={csv_path}")
    print(f"mic_csv={mic_csv_path}")
    print(f"report={report_path}")
    print(f"wav_dir={out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
