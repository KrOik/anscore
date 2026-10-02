"""Local driver for remote board probing (bianbu @ 192.168.31.176).

Uploads the bitstream + probe_remote_board.py to the board, runs the full
program/inject/capture/decode sequence there, then downloads artifacts and
prints the verdict. Usage:

    python cores/signal_processing/dsp_isp_library/board/remote/probe_remote.py \
        --image artifacts/dsp_isp_20260925/uart_probe_build_01/probe.fs \
        --output artifacts/remote_board_<tag>
"""
import argparse, json, sys, time
from pathlib import Path

import paramiko

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.stderr.reconfigure(encoding="utf-8", errors="replace")

HOST = "192.168.31.176"
USER = "bianbu"
PASSWORD = "bianbu"

REMOTE_DIR = '/tmp/dsp_isp_remote'
BOARD_SCRIPT = Path(__file__).resolve().parent / 'probe_remote_board.py'


def connect():
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, username=USER, password=PASSWORD, timeout=15,
                allow_agent=False, look_for_keys=False)
    return cli


def run(cli, cmd, timeout=120):
    chan = cli.get_transport().open_session()
    chan.exec_command(cmd)
    out = []
    start = time.time()
    while True:
        while chan.recv_ready():
            out.append(chan.recv(65536).decode('utf-8', 'replace'))
        if chan.exit_status_ready() and not chan.recv_ready():
            break
        if time.time() - start > timeout:
            chan.close()
            raise TimeoutError(cmd)
        time.sleep(0.05)
    return chan.recv_exit_status(), ''.join(out)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--image', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--uart', default='/dev/ttyUSB1')
    a = p.parse_args()
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=False)

    cli = connect()
    try:
        sftp = cli.open_sftp()
        run(cli, f'mkdir -p {REMOTE_DIR}/out {REMOTE_DIR}/img && rm -rf {REMOTE_DIR}/out/*')
        sftp.put(str(a.image), f'{REMOTE_DIR}/img/{a.image.name}')
        sftp.put(str(BOARD_SCRIPT), f'{REMOTE_DIR}/probe_remote_board.py')

        cmd = (f'cd {REMOTE_DIR} && python3 probe_remote_board.py '
               f'--image img/{a.image.name} --out out --uart {a.uart}')
        _, stdout = run(cli, cmd, timeout=300)
        sys.stdout.write(stdout)

        for name in ('verdict.json', 'program.log', 'capture.log',
                     'decoded.txt', 'decode_stderr.log', 'decoded.bin',
                     'input_packet.bin', 'expected_packet.bin',
                     'sent.bin', 'serial_received.bin', 'capture.sr'):
            try:
                sftp.get(f'{REMOTE_DIR}/out/{name}', str(out / name))
            except IOError:
                pass
        (out / 'driver_stdout.txt').write_text(stdout)
        try:
            verdict = json.loads((out / 'verdict.json').read_text())
        except Exception:
            verdict = {'status': 'UNKNOWN', 'error': 'verdict.json not retrieved'}
        return 0 if verdict.get('status') == 'PASS' else 1
    finally:
        cli.close()


if __name__ == '__main__':
    sys.exit(main())
