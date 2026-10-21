"""72-bit user-scan wire codec; no physical JTAG backend is implemented here."""
from dataclasses import dataclass


def crc8(payload: bytes) -> int:
    crc = 0
    for byte in payload:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ (0x07 if crc & 0x80 else 0)) & 0xff
    return crc


def encode_command(tag: int, address: int, data: int = 0, *, write: bool = False,
                   strobe: int = 15) -> bytes:
    for value, limit in ((tag, 256), (address, 256), (data, 1 << 32), (strobe, 16)):
        if not isinstance(value, int) or not 0 <= value < limit:
            raise ValueError('scan field out of range')
    word = (0xa5 << 56) | (tag << 48) | (int(bool(write)) << 47)
    word |= (strobe << 43) | (address << 35) | (data << 3)
    payload = word.to_bytes(8, 'little')
    return payload + bytes([crc8(payload)])


@dataclass(frozen=True)
class Response:
    tag: int
    busy: bool
    valid: bool
    csr_error: bool
    command_error: bool
    data: int


def decode_response(frame: bytes) -> Response:
    if len(frame) != 9 or crc8(frame[:8]) != frame[8]:
        raise ValueError('scan response length/CRC')
    word = int.from_bytes(frame[:8], 'little')
    if word >> 56 != 0x5a or word & 255 != 1 or (word >> 44) & 15:
        raise ValueError('scan response magic/version/reserved bits')
    flags = (word >> 40) & 15
    return Response((word >> 48) & 255, bool(flags & 1), bool(flags & 2),
                    bool(flags & 4), bool(flags & 8), (word >> 8) & 0xffffffff)
