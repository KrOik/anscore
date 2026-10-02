"""Host-side orchestrator for Tang Primer 25K (GW5A) board rounds.

Stages a harness build directory (the frozen evidence dir a harness run.py
produced, rebuilt for gw5a) on the rig host, loads the bitstream into SRAM over
JTAG, drives the per-case UART protocol from the host side of the dock's own
serial console, and pulls the whole evidence tree back.  Each round reprograms
the FPGA, so a --rounds 2 run is a genuine re-program/repeat check.

    python run_25k.py --mode transport --fs <design_25k.fs> --out <dir>
    python run_25k.py --build <harness evidence dir> --mode dstream \
                      --image design_25k.fs --out <dir> [--rounds 2] [--limit N]

SRAM only: power-cycling the board restores whatever is in flash.
"""
import argparse, datetime, json, posixpath, subprocess, sys, time
from pathlib import Path

import paramiko

HERE = Path(__file__).resolve().parent
BOARD = HERE.parent
sys.path.insert(0, str(BOARD))
from board_lock import BoardLock  # noqa: E402

HOST, USER, PASSWORD = '192.168.31.176', 'bianbu', 'bianbu'
RBASE = '/tmp/tang25k_run'
# only these extensions are staged; logs, vvp and traces stay on the host
KEEP = {'.fs', '.py', '.json', '.vh', '.mem'}


def stamp():
    return datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')


def sh(cmd, timeout=1800, check=True):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True,
                       timeout=timeout)
    if check and r.returncode:
        raise RuntimeError('%s rc=%d\n%s\n%s' % (cmd, r.returncode, r.stdout[-800:],
                                                 r.stderr[-800:]))
    return r


def stage_dir(build, mode, image, rounds, limit):
    """Files to upload for one run."""
    files = []
    if mode in ('transport', 'beacon'):
        script = ('transport_check_25k.py' if mode == 'transport'
                  else 'beacon_check_25k.py')
        files.append(Path(image))
        files.append(HERE / script)
        return files
    for f in sorted(Path(build).iterdir()):
        if f.is_file() and f.suffix in KEEP:
            files.append(f)
    files.append(HERE / ('rom_round_25k.py' if mode == 'rom'
                         else 'board_case_25k.py'))
    return files


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--build', type=Path)
    p.add_argument('--mode', required=True,
                   choices=['transport', 'beacon', 'dstream', 'drate', 'isp',
                            'rom'])
    p.add_argument('--fs', type=Path, help='bitstream for --mode transport')
    p.add_argument('--image', default='design_25k.fs')
    p.add_argument('--out', required=True, type=Path)
    p.add_argument('--rounds', type=int, default=2)
    p.add_argument('--limit', type=int, default=0)
    p.add_argument('--bytes', type=int, default=200)
    p.add_argument('--bits', type=int, default=8)
    p.add_argument('--board', default='tangprimer25k')
    p.add_argument('--uart', default='/dev/ttyUSB1')
    a = p.parse_args()

    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    tag = '%s_%s' % (a.mode, stamp())
    top = dict(status='FAIL', mode=a.mode, run_tag=tag, board=a.board,
               started_at=datetime.datetime.utcnow().isoformat() + 'Z',
               rounds=[])
    files = stage_dir(a.build, a.mode, a.fs if a.fs else (Path(a.build) / a.image),
                      a.rounds, a.limit)

    with BoardLock(purpose='tang25k %s board round' % a.mode, output=out,
                   timeout=300):
        cli = paramiko.SSHClient()
        cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        cli.connect(HOST, username=USER, password=PASSWORD, timeout=15,
                    allow_agent=False, look_for_keys=False)
        sftp = cli.open_sftp()
        rd = posixpath.join(RBASE, tag)
        cli.exec_command('mkdir -p %s' % rd)[1].channel.recv_exit_status()
        for f in files:
            sftp.put(str(f), posixpath.join(rd, f.name))

        def remote(cmd, timeout=1800):
            chan = cli.get_transport().open_session()
            chan.settimeout(timeout)
            chan.exec_command('cd %s && %s' % (rd, cmd))
            o = b''
            e = b''
            end = time.time() + timeout
            while time.time() < end:
                while chan.recv_ready():
                    o += chan.recv(65536)
                while chan.recv_stderr_ready():
                    e += chan.recv(32768)
                if chan.exit_status_ready():
                    break
                # A closed stdout with nothing buffered ends the round even if the
                # exit-status request never arrives; without this the loop would sit
                # out its full timeout on a command that already died.
                if chan.eof_received and not chan.recv_ready():
                    break
                time.sleep(0.05)
            try:
                rc = chan.recv_exit_status()
            except Exception:
                rc = 124
            return rc, o.decode('utf-8', 'replace'), e.decode('utf-8', 'replace')

        for r in range(1, a.rounds + 1):
            subdir = 'round_%02d' % r
            cli.exec_command('mkdir -p %s/%s' % (rd, subdir))
            time.sleep(0.3)
            if a.mode in ('transport', 'beacon'):
                script = ('transport_check_25k.py' if a.mode == 'transport'
                          else 'beacon_check_25k.py')
                cmd = ('python3 %s --fs %s --out %s --board %s --uart %s '
                       '--bytes %d' % (script, files[0].name, subdir, a.board,
                                       a.uart, a.bytes))
            elif a.mode == 'rom':
                # the image injects its own cases, so the host only has to be
                # listening before SRAM starts running
                cmd = ('python3 rom_round_25k.py --build . --out %s --image %s '
                       '--board %s --uart %s'
                       % (subdir, a.image, a.board, a.uart))
            else:
                cmd = ('python3 board_case_25k.py --build . --out %s --mode %s '
                       '--image %s --board %s --uart %s --bits %d%s'
                       % (subdir, a.mode, a.image, a.board, a.uart, a.bits,
                          ' --limit %d' % a.limit if a.limit else ''))
            rc, o, e = remote(cmd, timeout=3600)
            (out / ('round_%02d_console.log' % r)).write_text(
                '$ %s\nrc=%d\n%s\n%s\n' % (cmd, rc, o, e), encoding='utf-8')
            local = out / subdir
            local.mkdir(exist_ok=True)

            def walk(d, dest):
                for item in sftp.listdir_attr(d):
                    rp = posixpath.join(d, item.filename)
                    lp = dest / item.filename
                    if stat_is_dir(sftp, rp):
                        lp.mkdir(exist_ok=True)
                        walk(rp, lp)
                    else:
                        try:
                            sftp.get(rp, str(lp))
                        except Exception as exc:
                            print('fetch skip', rp, repr(exc), flush=True)

            walk(posixpath.join(rd, subdir), local)
            vj = local / 'verdict.json'
            row = dict(round=r, rc=rc,
                       verdict=json.loads(vj.read_text()) if vj.exists() else None)
            row['status'] = (row['verdict'] or {}).get('status', 'NO_VERDICT')
            top['rounds'].append(row)
            print('round %d %s rc=%d' % (r, row['status'], rc), flush=True)

        sftp.close()
        cli.close()

    ok = (len(top['rounds']) == a.rounds
          and all(r['status'] == 'PASS' for r in top['rounds']))
    top['status'] = 'PASS' if ok else 'FAIL'
    top['files'] = [f.name for f in files]
    (out / 'verdict.json').write_text(json.dumps(top, indent=2) + '\n')
    print(json.dumps(dict(status=top['status'], run=str(out)), indent=2))
    return 0 if ok else 1


def stat_is_dir(sftp, path):
    import stat as st
    try:
        return st.S_ISDIR(sftp.stat(path).st_mode)
    except Exception:
        return False


if __name__ == '__main__':
    sys.exit(main())
