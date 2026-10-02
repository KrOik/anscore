"""Local driver: upload a dsp_isp_library harness build dir + support files to
the remote board, run board_case_remote.py there, download evidence.

Handles both dsp_chain_harness (chain.fs, self-contained) and block_harness
(block.fs, needs shared protocol.py + model files) builds.

Usage:
    python cores/signal_processing/dsp_isp_library/board/remote/run_board_remote.py \
        --build cores/signal_processing/dsp_isp_library/board/<harness>/evidence/<build> \
        --output artifacts/remote_<tag>
"""
import argparse, json, sys, time
from pathlib import Path

import paramiko

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.stderr.reconfigure(encoding='utf-8', errors='replace')

HOST, USER, PASSWORD = '192.168.31.176', 'bianbu', 'bianbu'
REMOTE_BASE = '/tmp/dsp_isp_remote_run'
REMOTE_SUPPORT = '/tmp/dsp_isp_remote_support'
HERE = Path(__file__).resolve().parent
LIB = HERE.parents[1]  # cores/signal_processing/dsp_isp_library
BOARD_RUNNER = HERE / 'board_case_remote.py'

# block_harness protocol.py resolves models via LIB=parents[1] of its own path;
# it is uploaded to REMOTE_SUPPORT/block_harness so LIB == REMOTE_SUPPORT.
SUPPORT_FILES = [
    (LIB / 'board/block_harness/protocol.py', 'board/block_harness/protocol.py'),
    (LIB / 'isp/csc_model.py', 'isp/csc_model.py'),
    (LIB / 'dsp/dc/models/dc_reference.py', 'dsp/dc/models/dc_reference.py'),
]


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
    cur = ''
    for part in path.strip('/').split('/'):
        cur += '/' + part
        try:
            sftp.mkdir(cur)
        except IOError:
            pass


def sftp_get_tree(sftp, remote_dir, local_dir):
    local_dir = Path(local_dir)
    local_dir.mkdir(parents=True, exist_ok=True)
    for item in sftp.listdir_attr(remote_dir):
        rp = f'{remote_dir}/{item.filename}'
        lp = local_dir / item.filename
        if item.st_mode & 0o40000:
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
        for item in build.iterdir():
            if item.is_file():
                sftp.put(str(item), f'{rbuild}/{item.name}')
        # support layout for block-mode protocol.py
        for local, rel in SUPPORT_FILES:
            parent = str(Path(rel).parent).replace('\\', '/')
            sftp_mkdirs(sftp, f'{REMOTE_SUPPORT}/{parent}')
            sftp.put(str(local), f'{REMOTE_SUPPORT}/{rel}')
        sftp.put(str(BOARD_RUNNER), f'{REMOTE_BASE}/board_case_remote.py')
        if a.vector_json:
            sftp.put(str(a.vector_json), f'{REMOTE_BASE}/host_vectors.json')

        cmd = (f'cd {REMOTE_BASE} && python3 board_case_remote.py '
               f'--build build --out out --uart {a.uart} --support {REMOTE_SUPPORT}')
        if a.vector_json:
            cmd += ' --vector-json host_vectors.json'
        rc, stdout, stderr = run(cli, cmd, timeout=1800)
        sys.stdout.write(stdout)
        if stderr:
            sys.stderr.write(stderr)

        print('downloading evidence...', flush=True)
        sftp_get_tree(sftp, rout, out)
        (out / 'driver_rc.txt').write_text(str(rc))
        try:
            verdict = json.loads((out / 'verdict.json').read_text())
        except Exception:
            verdict = {'status': 'UNKNOWN', 'error': 'verdict.json not retrieved'}
        return 0 if verdict.get('status') == 'PASS' else 1
    finally:
        cli.close()


if __name__ == '__main__':
    sys.exit(main())
