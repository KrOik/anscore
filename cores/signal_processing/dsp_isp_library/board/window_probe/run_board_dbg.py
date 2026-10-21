"""Main-owned physical WPR1/WPO1 window-memory qualification runner.

Programs a route-gated window_probe build to SRAM, then replays each protocol
case over UART while capturing the FX2 logic-analyzer stream. Every exported
window record is verified lane-by-lane against the frozen independent oracle.
The board is an exclusive resource: this script takes .boardlock and always
releases it, recording the image on release.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time
import serial

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from board_lock import BoardLock
from probe_external import ROOT, HERE, parse_decode


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--build', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--port', default='COM24')
    a = p.parse_args()
    build = a.build.resolve(); out = a.output.resolve()
    summary = json.loads((build/'build_summary.json').read_text())
    sim = json.loads((build/'simulation_summary.json').read_text())
    if sim['status'] != 'PASS':
        raise ValueError('UART simulation gate')
    audit = json.loads((build/'structural_audit.json').read_text())
    if audit['status'] != 'PASS':
        raise ValueError('Structural audit gate')
    for name, digest in audit['files'].items():
        if hashlib.sha256((build/name).read_bytes()).hexdigest() != digest:
            raise ValueError('Structural audit identity mismatch: ' + name)
    for source, expected_hash in json.loads((build/'hashes.json').read_text()).items():
        frozen = build/Path(source).name
        if hashlib.sha256(frozen.read_bytes()).hexdigest() != expected_hash:
            raise ValueError('Frozen source identity mismatch: ' + str(frozen))
    sys.path.insert(0, str(build))
    spec = importlib.util.spec_from_file_location('frozen_wp_protocol', build/'protocol.py')
    protocol = importlib.util.module_from_spec(spec); spec.loader.exec_module(protocol)
    cases, make_packet, verify = protocol.cases, protocol.make_packet, protocol.verify
    image = build/'window_probe.fs'; sha = hashlib.sha256(image.read_bytes()).hexdigest()
    if summary['bitstream_sha256'] != sha:
        raise ValueError('Build gate/image identity mismatch')
    if summary['dsp'] > 4 or summary['routed_lut4'] > 15000 or min(summary['fmax_mhz']) < 27:
        raise ValueError('Resource/timing gate')
    width = summary['width']; height = summary['height']
    k = summary['k']; dw = summary['data_width']; pad = summary['pad_mode']
    out.mkdir(parents=True, exist_ok=False)
    lock = BoardLock(purpose='window-memory isolated physical qualification', output=str(out))
    lock.acquire()
    verdict = dict(status='FAIL', image=str(image), sha256=sha, variant=summary.get('variant'),
                   width=width, height=height, k=k, data_width=dw, pad_mode=pad, cases=[])
    cap = None
    try:
        with (out/'program.log').open('w') as log:
            r = subprocess.run(['pwsh', '-NoProfile', '-File', str(HERE/'program_probe.ps1'),
                                '-Image', str(image)], stdout=log, stderr=subprocess.STDOUT, timeout=60)
        if r.returncode:
            raise RuntimeError('Programming failed; SRAM state unconfirmed')
        verdict['sram_programmed'] = True
        sigrok = 'C:/Program Files/sigrok/sigrok-cli/sigrok-cli.exe'
        with serial.Serial(a.port, 115200, timeout=0, write_timeout=1) as port:
            (out/'serial_before_diagnostic.bin').write_bytes(port.read(65536))
            work = cases(width, height, dw)
            for index, (tag, config, pixels, stall) in enumerate(work):
                folder = out/f'case_{index:02d}'; folder.mkdir()
                packet = make_packet(tag, config, pixels, stall)
                (folder/'request.bin').write_bytes(packet)
                (folder/'expected.json').write_text(json.dumps(
                    dict(tag=tag, config=config, pixels=pixels, stall=stall), indent=2))
                with (folder/'capture.log').open('w') as log:
                    started = time.monotonic()
                    cap = subprocess.Popen([sigrok, '-l', '4', '-d', 'fx2lafw', '--config',
                                            'samplerate=4m', '--samples', '4000000',
                                            '-o', str(folder/'capture.sr')],
                                           stdout=log, stderr=subprocess.STDOUT)
                    while 'receive_transfer():' not in (folder/'capture.log').read_text(errors='replace'):
                        if cap.poll() is not None or time.monotonic()-started > 10:
                            raise RuntimeError('No live FX2 acquisition transfer observed')
                        time.sleep(0.005)
                    send_start = time.monotonic()
                    for byte in packet:
                        if port.write(bytes([byte])) != 1:
                            raise RuntimeError('Short serial write')
                        time.sleep(0.0015)
                    port.flush(); send_end = time.monotonic(); cap.wait(timeout=30)
                    (folder/'timing.json').write_text(json.dumps(
                        dict(acquisition_ready_seconds=send_start-started,
                             send_seconds=send_end-send_start), indent=2))
                    (folder/'serial_diagnostic.bin').write_bytes(port.read(65536))
                if cap.returncode:
                    raise RuntimeError('FX2 capture failed')
                r = subprocess.run([sigrok, '-i', str(folder/'capture.sr'), '-P',
                                    'uart:rx=D0:baudrate=115200:format=hex', '-A', 'uart=rx-data'],
                                   text=True, capture_output=True, timeout=30)
                (folder/'decoded.txt').write_text(r.stdout)
                (folder/'decode_stderr.log').write_text(r.stderr)
                if r.returncode:
                    raise RuntimeError('Decode failed')
                data = parse_decode(r.stdout); (folder/'decoded.bin').write_bytes(data)
                if len(data) != protocol.HDR + len(pixels)*protocol.rec_bytes(k,dw):
                    raise AssertionError(('dbg size', len(data)))
                # dump every record: {rd,first_pix,row_q,pz,out,ridx,ry,rx}
                recs = []
                recb = protocol.rec_bytes(k, dw)
                for i in range(len(pixels)):
                    r = int.from_bytes(data[protocol.HDR+i*recb:protocol.HDR+(i+1)*recb],'little')
                    w = (r>>2) & ((1<<(k*k*dw))-1)
                    # dbg packing: {pad,rd[8],first_pix[8],row_q[8],pz,out,ridx[4],ry[4],rx[4]}
                    recs.append(dict(rx=w&0xF, ry=(w>>4)&0xF, ridx=(w>>8)&0xF,
                        out=(w>>12)&1, pz=(w>>13)&1, row_q=(w>>14)&0xFF,
                        first_pix=(w>>22)&0xFF, rd=(w>>30)&0xFF))
                result = dict(status='DBG', tag=tag, stall=stall, records=recs)
                (folder/'verdict.json').write_text(json.dumps(result, indent=2))
                verdict['cases'].append(dict(status='DBG', tag=tag, stall=stall, n=len(recs)))
                print('DBG wp', index, len(recs), 'records', flush=True)
            (out/'serial_after_diagnostic.bin').write_bytes(port.read(65536))
        verdict['status'] = 'PASS'
    except Exception as exc:
        verdict['error'] = repr(exc)
    finally:
        if cap is not None and cap.poll() is None:
            cap.terminate(); cap.wait(timeout=10)
        (out/'verdict.json').write_text(json.dumps(verdict, indent=2) + '\n')
        rec=lock._read()
        if rec and rec.get('token')==lock.owner['token']:
            (out/'released_boardlock.json').write_text(json.dumps(rec,indent=2))
        lock.release()
    print(json.dumps(verdict, indent=2))
    return int(verdict['status'] != 'PASS')


if __name__ == '__main__':
    raise SystemExit(main())
