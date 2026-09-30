"""Verify sigrok UART annotations against independent AES golden values."""
import argparse
import json
import re
from pathlib import Path
from golden_model import compute

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('annotations', type=Path)
parser.add_argument('--full-rate', action='store_true')
args = parser.parse_args()
parts = []
for line in args.annotations.read_text(encoding='utf-8-sig').splitlines():
    if not line.startswith('uart-1: '):
        continue
    token = line[len('uart-1: '):]
    parts.append({'[0D]': '\r', '[0A]': '\n'}.get(token, token))
text = ''.join(parts)
output = args.annotations.parent
(output / 'board_uart.txt').write_text(text, encoding='ascii', newline='')
golden = compute()
if 'FAIL' in text or re.search(r'U0 AESB F', text):
    raise SystemExit('FAIL: board reported failure')
if args.full_rate:
    expected = ''.join(golden['aes_ciphertexts']).upper()
    frames = []
    for line in text.splitlines(keepends=True):
        if line.startswith('AES27') and line.endswith('\n'):
            match = re.fullmatch(r'AES27 PASS R=([0-9A-F]{2}) ([0-9A-F]{128})\n', line)
            if not match:
                raise SystemExit('FAIL: malformed complete full-rate report')
            frames.append(match.groups())
    if not frames or any(cycles != '0A' or cipher != expected for cycles, cipher in frames):
        raise SystemExit('FAIL: missing full-rate frame, wrong latency or ciphertext')
    result = dict(status='PASS', complete_frames=len(frames), vectors_per_frame=4,
                  ciphertext_bytes_per_frame=64, round_cycles=10,
                  scope='full-rate AES at 27 MHz, internal stimulus')
else:
    header = text.count('CRYPT M=001F P=001F')
    aes = text.count(f"U0 AESB P D={golden['digests']['AESB']:08X}")
    if not header or not aes:
        raise SystemExit('FAIL: missing original selftest header or AES digest')
    result = dict(status='PASS', headers=header, aes_reports=aes,
                  scope='AES-only original selftest, clk_en once per 16 clocks')
(output / 'board_verdict.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result))
