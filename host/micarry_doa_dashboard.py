import argparse
import math
import os
import queue
import struct
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import ttk

import serial


HEADER = b"\xAA\x55\x01"
FRAME_LEN = 24


def parse_frame(frame: bytes):
    if len(frame) != FRAME_LEN or frame[:3] != HEADER or frame[-2:] != b"\r\n":
        return None
    report0, report1, report2, report3 = struct.unpack(">IIII", frame[4:20])
    delay03, delay14, delay25, status = struct.unpack("bbbB", frame[8:12])
    vec_x, vec_y = struct.unpack(">hh", frame[12:16])
    score_gap, best_score = struct.unpack(">HH", frame[16:20])
    return {
        "flags": frame[3] >> 4,
        "led": frame[3] & 0x0F,
        "energy": report0,
        "delay03": delay03,
        "delay14": delay14,
        "delay25": delay25,
        "status": status,
        "vec_x": vec_x,
        "vec_y": vec_y,
        "score_gap": score_gap,
        "best_score": best_score,
        "sequence": struct.unpack(">H", frame[20:22])[0],
        "raw": (report0, report1, report2, report3),
    }


class SerialSource:
    def __init__(self, port, baud):
        self.port = port
        self.baud = baud
        self.handle = None

    def open(self):
        self.handle = serial.Serial(self.port, self.baud, timeout=0.05)

    def read(self, size):
        return self.handle.read(size)

    def close(self):
        if self.handle:
            self.handle.close()


class FtdiSource:
    def __init__(self, interface):
        self.interface = interface
        self.handle = None

    def open(self):
        import usb.core
        import usb.backend.libusb1 as libusb1
        from pyftdi.ftdi import Ftdi

        root = Path(__file__).resolve().parents[1]
        lib_dir = root / "tools" / "oss-cad-suite" / "oss-cad-suite" / "lib"
        libusb_dll = lib_dir / "libusb-1.0.dll"
        os.add_dll_directory(str(lib_dir))
        backend = libusb1.get_backend(find_library=lambda _: str(libusb_dll))
        dev = usb.core.find(idVendor=0x0403, idProduct=0x6010, backend=backend)
        if dev is None:
            raise RuntimeError("FT2232 VID_0403 PID_6010 not found")
        self.handle = Ftdi()
        self.handle.open_from_device(dev, self.interface)
        self.handle.set_baudrate(115200)
        self.handle.set_line_property(8, 1, "N")
        self.handle.set_flowctrl("")
        self.handle.purge_buffers()

    def read(self, size):
        return bytes(self.handle.read_data_bytes(size, attempt=8))

    def close(self):
        if self.handle:
            self.handle.close()


class ReaderThread(threading.Thread):
    def __init__(self, source, out_queue, stop_event):
        super().__init__(daemon=True)
        self.source = source
        self.out_queue = out_queue
        self.stop_event = stop_event

    def run(self):
        buf = bytearray()
        try:
            self.source.open()
            self.out_queue.put(("state", "connected"))
            while not self.stop_event.is_set():
                chunk = self.source.read(512)
                if chunk:
                    buf.extend(chunk)
                else:
                    time.sleep(0.01)
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
                    frame = bytes(buf[idx : idx + FRAME_LEN])
                    del buf[:idx + FRAME_LEN]
                    parsed = parse_frame(frame)
                    if parsed:
                        self.out_queue.put(("frame", parsed))
        except Exception as exc:
            self.out_queue.put(("error", str(exc)))
        finally:
            self.source.close()
            self.out_queue.put(("state", "closed"))


class Dashboard(tk.Tk):
    def __init__(self, source):
        super().__init__()
        self.title("micarry DOA dashboard")
        self.geometry("980x620")
        self.configure(bg="#101418")

        self.source = source
        self.q = queue.Queue()
        self.stop_event = threading.Event()
        self.reader = ReaderThread(source, self.q, self.stop_event)

        self.last_seq = None
        self.frames = 0
        self.valid_frames = 0
        self.active_frames = 0
        self.gaps = 0
        self.start_time = time.monotonic()
        self.latest = None

        self._build_ui()
        self.reader.start()
        self.after(50, self._poll_queue)
        self.protocol("WM_DELETE_WINDOW", self._close)

    def _build_ui(self):
        style = ttk.Style()
        style.theme_use("clam")
        style.configure("TLabel", background="#101418", foreground="#d8dee9", font=("Segoe UI", 11))
        style.configure("Title.TLabel", font=("Segoe UI", 16, "bold"))
        style.configure("Value.TLabel", foreground="#ffffff", font=("Consolas", 13))

        root = ttk.Frame(self)
        root.pack(fill="both", expand=True, padx=16, pady=16)

        left = ttk.Frame(root)
        left.pack(side="left", fill="both", expand=True)
        right = ttk.Frame(root)
        right.pack(side="right", fill="y", padx=(18, 0))

        ttk.Label(left, text="麦克风阵列状态", style="Title.TLabel").pack(anchor="w")
        self.canvas = tk.Canvas(left, width=560, height=520, bg="#101418", highlightthickness=0)
        self.canvas.pack(fill="both", expand=True, pady=(12, 0))

        self.status = {}
        for name in [
            "connection",
            "fps",
            "frames",
            "valid",
            "active",
            "gaps",
            "led",
            "energy",
            "delays",
            "vector",
            "confidence",
            "score",
            "overrun",
        ]:
            row = ttk.Frame(right)
            row.pack(fill="x", pady=5)
            ttk.Label(row, text=name, width=12).pack(side="left")
            val = ttk.Label(row, text="-", width=24, style="Value.TLabel")
            val.pack(side="left")
            self.status[name] = val

        self.status["connection"].configure(text="opening")

    def _poll_queue(self):
        try:
            while True:
                typ, payload = self.q.get_nowait()
                if typ == "frame":
                    self._handle_frame(payload)
                elif typ == "state":
                    self.status["connection"].configure(text=payload)
                elif typ == "error":
                    self.status["connection"].configure(text=f"error: {payload[:40]}")
        except queue.Empty:
            pass
        self._draw()
        self.after(50, self._poll_queue)

    def _handle_frame(self, frame):
        self.latest = frame
        self.frames += 1
        if self.last_seq is not None:
            expected = (self.last_seq + 1) & 0xFFFF
            if frame["sequence"] != expected:
                self.gaps += 1
        self.last_seq = frame["sequence"]
        direction_valid = (frame["status"] >> 6) & 1
        active = frame["flags"] & 1
        self.valid_frames += int(direction_valid)
        self.active_frames += int(active)

    def _draw(self):
        self.canvas.delete("all")
        w = self.canvas.winfo_width()
        h = self.canvas.winfo_height()
        cx, cy = w // 2, h // 2 + 10
        radius = min(w, h) * 0.34
        led = self.latest["led"] if self.latest else 0
        active = bool(self.latest and (self.latest["flags"] & 1))

        for i in range(12):
            angle = -math.pi / 2 + i * 2 * math.pi / 12
            x = cx + radius * math.cos(angle)
            y = cy + radius * math.sin(angle)
            color = "#24313d"
            if i == 0:
                color = "#38506a"
            if active and i in {led, (led - 1) % 12, (led + 1) % 12}:
                color = "#ff4b3a" if i == led else "#8a352f"
            self.canvas.create_oval(x - 22, y - 22, x + 22, y + 22, fill=color, outline="#d8dee9")
            self.canvas.create_text(x, y, text=str(i), fill="#ffffff", font=("Segoe UI", 12, "bold"))

        if self.latest:
            vx = self.latest["vec_x"]
            vy = self.latest["vec_y"]
            scale = 10
            x2 = cx + max(-140, min(140, vx * scale))
            y2 = cy - max(-140, min(140, vy * scale))
            self.canvas.create_line(cx, cy, x2, y2, fill="#88c0d0", width=4, arrow="last")
            self.canvas.create_text(cx, cy + radius + 70, text="红色: DOA方向  蓝色/灰色: 灯环方位参考", fill="#b8c0cc")
            self._update_status()

    def _update_status(self):
        f = self.latest
        elapsed = max(0.001, time.monotonic() - self.start_time)
        confidence = f["status"] & 0x3F
        direction_valid = (f["status"] >> 6) & 1
        overrun = (f["status"] >> 7) & 1
        self.status["fps"].configure(text=f"{self.frames / elapsed:.1f}")
        self.status["frames"].configure(text=str(self.frames))
        self.status["valid"].configure(text=f"{self.valid_frames} / {direction_valid}")
        self.status["active"].configure(text=f"{self.active_frames} / {f['flags'] & 1}")
        self.status["gaps"].configure(text=str(self.gaps))
        self.status["led"].configure(text=f"{f['led']:02d}")
        self.status["energy"].configure(text=str(f["energy"]))
        self.status["delays"].configure(text=f"{f['delay03']:+d}, {f['delay14']:+d}, {f['delay25']:+d}")
        self.status["vector"].configure(text=f"{f['vec_x']:+d}, {f['vec_y']:+d}")
        self.status["confidence"].configure(text=str(confidence))
        self.status["score"].configure(text=f"{f['score_gap']} / {f['best_score']}")
        self.status["overrun"].configure(text=str(overrun))

    def _close(self):
        self.stop_event.set()
        self.destroy()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default=None)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--ftdi-interface", type=int, default=2)
    args = parser.parse_args()

    source = SerialSource(args.port, args.baud) if args.port else FtdiSource(args.ftdi_interface)
    Dashboard(source).mainloop()


if __name__ == "__main__":
    main()
