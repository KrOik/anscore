"""Hardware-free tests of real host transport framing and partial reads."""
from run_uart import UartCsr, crc8


class FakePort:
    def __init__(self, error=False, corrupt=False):
        self.error, self.corrupt = error, corrupt
        self.pending = b''

    def write(self, command):
        assert len(command) == 8 and command[0] == 0xa5
        assert crc8(command[:7]) == command[7]
        value = int.from_bytes(command[3:7], 'little')
        assert command[1] in (0, 1)
        if command[1]:
            assert value == 0x12345678
        body = bytes((0x5a, int(self.error), command[2])) + (0x87654321).to_bytes(4, 'little')
        self.pending = body + bytes((crc8(body) ^ int(self.corrupt),))

    def read(self, count):
        value, self.pending = self.pending[:1], self.pending[1:]
        return value


if __name__ == '__main__':
    assert crc8(b'123456789') == 0xf4
    bus = UartCsr(FakePort())
    assert bus.access(0xfc) == 0x87654321
    assert bus.access(0xe4, 0x12345678) == 0x87654321
    assert len(bus.exchanges) == 2
    for port in (FakePort(error=True), FakePort(corrupt=True)):
        try:
            UartCsr(port).access(0xfc)
        except RuntimeError:
            pass
        else:
            raise AssertionError('bad reply accepted')
    print('PASS host UART codec known CRC, read/write, partial replies and error rejection')
