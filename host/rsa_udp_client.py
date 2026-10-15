#!/usr/bin/env python3
import argparse
import json
import socket
import sys
import time


MODULUS = int(
    "b7f4820717df346b5ef24c7d132de33aa96a477b3edd40ace2a4a982c4be1ec7",
    16,
)
EXPONENT = 65537
WIDTH_BYTES = 32

STATUS = {
    0: "ok",
    1: "bad_magic",
    2: "bad_len",
    3: "message_out_of_range",
    4: "bad_op",
}


def parse_message(value: str) -> int:
    text = value.strip().lower()
    if text.startswith("0x"):
        text = text[2:]
    if not text:
        raise ValueError("empty message")
    msg = int(text, 16)
    if msg < 0 or msg >= 1 << (WIDTH_BYTES * 8):
        raise ValueError(f"message must fit in {WIDTH_BYTES} bytes")
    return msg


def build_request(message: int) -> bytes:
    return b"RSA1" + bytes([1]) + message.to_bytes(WIDTH_BYTES, "big")


def parse_response(data: bytes):
    if len(data) != 8 + WIDTH_BYTES:
        raise ValueError(f"unexpected response length {len(data)}")
    if data[:4] != b"RSAR":
        raise ValueError(f"unexpected response magic {data[:4]!r}")
    status = data[4]
    cycles = int.from_bytes(data[5:7], "big")
    width = data[7]
    if width != WIDTH_BYTES:
        raise ValueError(f"unexpected RSA width {width}")
    ciphertext = int.from_bytes(data[8:], "big")
    return status, cycles, ciphertext


def request_once(args, message: int):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.settimeout(args.timeout)
        sock.bind((args.bind_ip, args.source_port))
        payload = build_request(message)
        start = time.perf_counter()
        sock.sendto(payload, (args.fpga_ip, args.fpga_port))
        data, addr = sock.recvfrom(2048)
        elapsed_ms = (time.perf_counter() - start) * 1000.0
    finally:
        sock.close()

    status, cycles, ciphertext = parse_response(data)
    expected = pow(message, EXPONENT, MODULUS) if message < MODULUS else 0
    ok = status == 0 and ciphertext == expected
    return {
        "ok": ok,
        "status": status,
        "status_name": STATUS.get(status, f"unknown_{status}"),
        "cycles": cycles,
        "elapsed_ms": round(elapsed_ms, 3),
        "from": f"{addr[0]}:{addr[1]}",
        "message_hex": f"{message:0{WIDTH_BYTES * 2}x}",
        "ciphertext_hex": f"{ciphertext:0{WIDTH_BYTES * 2}x}",
        "expected_hex": f"{expected:0{WIDTH_BYTES * 2}x}",
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Send one RSA-256 encrypt request to the Tang Primer 20K UDP endpoint."
    )
    parser.add_argument("--fpga-ip", default="192.168.137.15")
    parser.add_argument("--fpga-port", type=int, default=11451)
    parser.add_argument(
        "--bind-ip",
        default="0.0.0.0",
        help="Bind to the wired NIC address when needed; default works with the current 192.168.137.0/24 test subnet.",
    )
    parser.add_argument("--source-port", type=int, default=5000)
    parser.add_argument("--timeout", type=float, default=3.0)
    parser.add_argument(
        "--message-hex",
        default="123456789abcdef00112233445566778899aabbccddeeff00123456789abcdef",
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    try:
        message = parse_message(args.message_hex)
        result = request_once(args, message)
    except Exception as exc:
        print(f"RSA UDP request failed: {exc}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(f"status={result['status_name']} cycles={result['cycles']} elapsed_ms={result['elapsed_ms']}")
        print(f"ciphertext={result['ciphertext_hex']}")
        print(f"expected  ={result['expected_hex']}")

    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
