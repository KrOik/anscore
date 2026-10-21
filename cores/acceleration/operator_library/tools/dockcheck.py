"""Read-only dock health check: is the JTAG adapter enumerated and unheld?

Prints remote enumeration, any process that could own the adapter, and one
--detect retry. Nothing here programs the board.
"""
import argparse
from remote_board import CAPTURE, connect, execute

ap = argparse.ArgumentParser()
ap.add_argument('--host', default='192.168.31.176')
ap.add_argument('--user', default='bianbu')
args = ap.parse_args()

client = connect(args)
CHECKS = [
    ('adapter-nodes', ['bash', '-lc', 'ls -l /dev/ttyUSB* 2>&1 | tail -6']),
    ('jtag-holders', ['bash', '-lc', 'pgrep -af "openFPGALoader|dfu-util" | grep -v pgrep || echo none']),
    # --detect never writes. If the FT2232 re-enumerated and the JTAG interface
    # landed on the other channel, only one of these three can answer.
    ('detect-default', ['openFPGALoader', '-b', 'tangprimer25k', '--detect']),
    ('detect-ch0', ['openFPGALoader', '-c', 'ft2232', '--ftdi-channel', '0',
                    '-b', 'tangprimer25k', '--detect']),
    ('detect-ch1', ['openFPGALoader', '-c', 'ft2232', '--ftdi-channel', '1',
                    '-b', 'tangprimer25k', '--detect']),
    # A configured, powered FPGA streams its self-test verdicts. Frames on the
    # UART while JTAG is deaf means the adapter, not the board, is the fault.
    ('uart-live', ['python3', '-c', CAPTURE, '/dev/ttyUSB1', '4']),
]
for label, argv in CHECKS:
    code, text = execute(client, argv)
    print(f'== {label} exit={code}')
    print(text.strip()[-1200:])
client.close()
