"""Local driver: upload a dsp_chain_harness build dir to the remote board,
run chain_board_remote.py there, download the evidence tree.

Usage:
    python cores/signal_processing/dsp_isp_library/board/remote/run_chain_remote.py \
        --build cores/signal_processing/dsp_isp_library/board/dsp_chain_harness/evidence/chain_XXXX \
        --output artifacts/dsp_isp_remote_<tag>
"""
import argparse, json, sys, time
from pathlib import Path

import paramiko

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.stderr.reconfigure(encoding='utf-8', errors='replace')

HOST, USER, PASSWORD = '192.168.31.176', 'bianbu', 'bianbu'
REMOTE_BASE = '/tmp/dsp_isp_remote_chain'
BOARD_RUNNER = Path(__file__).resolve().parent / 'chain_board_remote.py'


def connect():
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, username=USER, password=PASSWORD, timeout=15,
                allow_agent=False, look_for_keys=False)
    return cli


def run(cli, cmd, timeout=120):
    chan = cli.get_transport().open_session()
    chan.exec_command(cmd)
    out, err = [], []
    start = time.time()
    while True:
        while chan.recv_ready():
            out.append(chan.recv(65536).decode('utf-8', 'replace'))
        while chan.recv_stderr_ready():
            err.append(chan.recv_stderr(65536).decode('utf-8', 'replace'))
        if chan.exit_status_ready() and not chan.recv_ready() and not chan.recv_stderr_ready():
            break
        if time.time() - start > timeout:
            chan.close()
            raise TimeoutError(cmd)
        time.sleep(0.05)
    return chan.recv_exit_status(), ''.join(out), ''.join(err)


def sftp_mkdirs(sftp, path):
    parts = path.strip('/').split('/')
    cur = ''
    for part in parts:
        cur += '/' + part
        try:
            sftp.mkdir(cur)
        except IOError:
            pass


def sftp_put_tree(sftp, local_dir, remote_dir):
    sftp_mkdirs(sftp, remote_dir)
    for item in Path(local_dir).iterdir():
        if item.is_dir():
            continue  # build dirs are flat; skip evidence subdirs
        sftp.put(str(item), f'{remote_dir}/{item.name}')


def sftp_get_tree(sftp, remote_dir, local_dir):
    local_dir = Path(local_dir)
    local_dir.mkdir(parents=True, exist_ok=True)
    for item in sftp.listdir_attr(remote_dir):
        rp = f'{remote_dir}/{item.filename}'
        lp = local_dir / item.filename
        if item.st_mode & 0o40000:  # directory
            sftp_get_tree(sftp, rp, lp)
        else:
            sftp.get(rp, str(lp))


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--build', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--uart', default='/dev/ttyUSB1')
    p.add_argument('--vector-json', type=Path)
    a = p.parse_args()
    build = a.build.resolve()
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=False)

    cli = connect()
    try:
        sftp = cli.open_sftp()
        rbuild = f'{REMOTE_BASE}/build'
        rout = f'{REMOTE_BASE}/out'
        run(cli, f'rm -rf {rbuild} {rout} && mkdir -p {rbuild} {rout}')
        print('uploading build dir...', flush=True)
        sftp_put_tree(sftp, build, rbuild)
        sftp.put(str(BOARD_RUNNER), f'{REMOTE_BASE}/chain_board_remote.py')
        if a.vector_json:
            sftp.put(str(a.vector_json), f'{REMOTE_BASE}/host_vectors.json')

        cmd = (f'cd {REMOTE_BASE} && python3 chain_board_remote.py '
               f'--build build --out out --uart {a.uart}')
        if a.vector_json:
            cmd += ' --vector-json host_vectors.json'
        rc, stdout, stderr = run(cli, cmd, timeout=1800)
        sys.stdout.write(stdout)
        if stderr:
            sys.stderr.write(stderr)

        print('downloading evidence...', flush=True)
        sftp_get_tree(sftp, rout, out)
        try:
            verdict = json.loads((out / 'verdict.json').read_text())
        except Exception:
            verdict = {'status': 'UNKNOWN', 'error': 'verdict.json not retrieved'}
        (out / 'driver_rc.txt').write_text(str(rc))
        return 0 if verdict.get('status') == 'PASS' else 1
    finally:
        cli.close()


if __name__ == '__main__':
    sys.exit(main())
