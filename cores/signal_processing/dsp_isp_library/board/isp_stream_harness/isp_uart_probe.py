"""Transport matrix probe: which dock UART (tx_port -> rx_port,baud) carries IMG1/IMR1.

For every candidate transmit port the probe sends one IMG1 request and reads
each candidate receive port at several baud rates, reporting the leading bytes,
the total received length and the offset of the 'IMR1' magic.  This settles
which physical dock UART line is wired to the ISP harness' uart_tx/uart_rx
pins; historically the reply was only ever observed on an FX2 probe pin.
"""
import sys, time, json
import serial
sys.path.insert(0, '.')
import protocol as pr

BAUDS = [115200, 57600, 230400, 9600]
PORTS = ['/dev/ttyUSB1', '/dev/ttyUSB0']

core = pr._core()
tag, config, words, stall = pr.cases(8, core=core)[0]
packet = pr.make_packet(tag, config, words, stall)
print('request tag %08x bytes %d' % (tag, len(packet)), flush=True)

results = []
for tx_port in PORTS:
    try:
        tx = serial.Serial(tx_port, 115200, timeout=0.05, write_timeout=3)
    except Exception as exc:
        print('tx open %s failed %r' % (tx_port, exc), flush=True)
        continue
    for rx_port in PORTS:
        for baud in BAUDS:
            key = '%s@%d' % (rx_port, baud)
            try:
                p = serial.Serial(rx_port, baud, timeout=0.05)
            except Exception as exc:
                results.append(dict(tx=tx_port, rx=key, error=repr(exc)))
                continue
            buf = bytearray()
            port_busy = False
            try:
                p.reset_input_buffer()
            except Exception as exc:
                port_busy = True
                p.close()
                results.append(dict(tx=tx_port, rx=key, error='open:%r' % (exc,)))
                continue
            tx.reset_input_buffer()
            tx.write(packet)
            tx.flush()
            deadline = time.monotonic() + 2.5
            while len(buf) < 600 and time.monotonic() < deadline:
                c = p.read(64)
                if c:
                    buf += c
            p.close()
            data = bytes(buf)
            off = data.find(b'IMR1')
            rec = dict(tx=tx_port, rx=key, length=len(data), imr1_offset=off,
                       head=data[:20].hex(' '))
            results.append(rec)
            print('%s -> %-22s len %3d imr1@%-4s %s'
                  % (tx_port, key, len(data), off, data[:20].hex(' ')), flush=True)
    tx.close()
print(json.dumps(results, indent=1))
