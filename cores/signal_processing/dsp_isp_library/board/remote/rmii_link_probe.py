"""Remote RMII link probe for the Tang Primer 20K DOCK.

The FX2 logic analyser can be absent or bandwidth-limited, so the dock's
on-board 100M RMII PHY is the alternative board transport.  This probe answers
one question before any harness is built on top of it: is the dock's Ethernet
link physically alive on the LAN right now?

Method: SRAM-program the already-verified RSA UDP endpoint image through the
remote host's JTAG, then exchange real UDP request/response traffic with that
endpoint from the remote host.  A reply proves PHY link plus the MAC/ARP/UDP
path end to end.

    python rmii_link_probe.py --image cores/crypto/rsa_udp/build_oss/rsa_udp_20k.fs \
        --output artifacts/rmii_link_probe_<tag>
"""
import argparse, hashlib, json, sys, time
from pathlib import Path

import paramiko

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / 'cores/signal_processing/dsp_isp_library/board'))
from board_lock import BoardLock

HOST, USER, PASSWORD = '192.168.31.176', 'bianbu', 'bianbu'
RDIR = '/tmp/rmii_link_probe'
ENDPOINT_IP = '192.168.137.15'
PROBE_IP = '192.168.137.1'
UDP_PORT = 11451


def run(cli, cmd, timeout=120):
    stdin, out, err = cli.exec_command(cmd, timeout=timeout)
    o = out.read().decode(errors='replace')
    e = err.read().decode(errors='replace')
    return stdin.channel.recv_exit_status(), o, e


def build_request(message_hex):
    return b'RSA1' + bytes([1]) + bytes.fromhex(message_hex)


def client_src(req):
    return (
        'import json, socket, time\n'
        f'req = {req!r}\n'
        'sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)\n'
        'sock.bind(("", 0))\n'
        'sock.settimeout(4.0)\n'
        't0 = time.monotonic()\n'
        f"sock.sendto(req, ('{ENDPOINT_IP}', {UDP_PORT}))\n"
        'try:\n'
        '    data, addr = sock.recvfrom(2048)\n'
        '    dt = time.monotonic() - t0\n'
        '    print(json.dumps(dict(ok=True, rx=len(data),\n'
        '        magic=data[:4].decode("latin1"), status=data[4],\n'
        '        rtt_ms=round(dt * 1000, 3), peer=addr[0],\n'
        '        bytes_per_s=round(len(data) / dt), hex=data[:48].hex())))\n'
        'except Exception as ex:\n'
        '    print(json.dumps(dict(ok=False, error=repr(ex))))\n'
    )


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--image', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--rounds', type=int, default=3)
    p.add_argument('--no-program', action='store_true',
                   help='skip JTAG programming and only probe the endpoint')
    a = p.parse_args()
    image = a.image.resolve()
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    sha = hashlib.sha256(image.read_bytes()).hexdigest()

    verdict = dict(status='FAIL', image=str(image), sha256=sha,
                   endpoint_ip=ENDPOINT_IP, host=f'{USER}@{HOST}', rounds=[])
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        cli.connect(HOST, username=USER, password=PASSWORD, timeout=15,
                    allow_agent=False, look_for_keys=False)
        with BoardLock(purpose='rmii_link_probe', output=out):
            run(cli, f'mkdir -p {RDIR}')
            sftp = cli.open_sftp()
            if not a.no_program:
                sftp.put(str(image), f'{RDIR}/probe.fs')
                rc, o, e = run(cli, f'cd {RDIR} && openFPGALoader '
                                    f'-b tangprimer20k probe.fs 2>&1', timeout=300)
                (out / 'program.log').write_text(o + e)
                verdict['program_rc'] = rc
                if rc != 0:
                    raise RuntimeError('JTAG programming failed')
            # Allow PHY auto-negotiation and endpoint boot.
            time.sleep(3.0)
            rc, o, _ = run(cli, f'echo {PASSWORD} | sudo -S -p "" '
                                f'ip addr add {PROBE_IP}/24 dev end0 2>&1; '
                                f'ip -br addr show end0')
            verdict['probe_ip_setup'] = o.strip()
            for i in range(a.rounds):
                with sftp.open(f'{RDIR}/client.py', 'w') as f:
                    f.write(client_src(build_request('%064x' % (0x1234567890ABCDEF + i))))
                rc, o, e = run(cli, f'python3 {RDIR}/client.py 2>&1', timeout=60)
                text = (o + e).strip()
                try:
                    row = json.loads(text.splitlines()[-1]) if text else {'ok': False}
                except Exception:
                    row = dict(ok=False, raw=text[:300])
                verdict['rounds'].append(row)
                print('round', i, json.dumps(row)[:220], flush=True)
                time.sleep(0.5)
            sftp.close()
            run(cli, f'echo {PASSWORD} | sudo -S -p "" '
                     f'ip addr del {PROBE_IP}/24 dev end0 2>&1')
    except Exception as exc:
        verdict['error'] = repr(exc)
    finally:
        cli.close()

    ok = [r for r in verdict['rounds']
          if r.get('ok') and r.get('magic') == 'RSAR' and r.get('status') == 0]
    verdict['ok_rounds'] = len(ok)
    verdict['rtt_ms'] = [r.get('rtt_ms') for r in ok]
    verdict['status'] = 'PASS' if ok else 'FAIL'
    if not ok:
        verdict['error'] = verdict.get('error') or \
            'No RMII UDP response from endpoint; check dock Ethernet cabling/link'
    (out / 'verdict.json').write_text(json.dumps(verdict, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps(verdict, indent=2)[:1600])
    return 0 if verdict['status'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
