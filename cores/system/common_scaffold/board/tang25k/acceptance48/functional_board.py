"""Functional SRAM/UART tests with explicit UNPROVEN hold timing status.

Consumes retained route evidence. Setup, resource and reported hold violations
remain blocking. This does not produce a timing-signoff or delivery-accepted status.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import serial

BOARD = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BOARD))
import resume_candidate_route_official as route


def run(candidate, attempt, port_name, repetitions):
    candidate = Path(candidate).resolve()
    state = json.loads((candidate/f'route_{attempt}_status.json').read_text(encoding='utf-8'))
    current=route.verify_simulation_gate(candidate)
    previous=state['simulation_provenance']
    for key in ('source_sha256_verified','freeze_files_sha256_verified','build_status_sha256'):
        if current.get(key)!=previous.get(key):
            raise RuntimeError('simulation freeze changed after route: '+key)
    frozen=set(current.get('source_sha256_verified',{}))|set(current.get('freeze_files_sha256_verified',{}))
    if not {'case.json','expected_uart.txt','tang25k.cst'} <= frozen:
        raise RuntimeError('case/expected UART/constraints must be frozen')
    report = state['route_report']
    required = ('route_process','route_complete','lut4_device_gate','dff_device_gate',
                'bsram_device_gate','mult12_device_gate','lut_15k','dsp_4','timing_50mhz')
    if any(report['gates'].get(key) is not True for key in required):
        raise RuntimeError('missing or failed required functional-build gate')
    excluded = {'hold', 'hold_model_qualification'}
    if not all(value for key,value in report['gates'].items() if key not in excluded):
        raise RuntimeError('resource/setup/route failure blocks functional board test')
    if report['hold_violation_lines'] or any(s < 0 for s in report['hold_slacks_ns']):
        raise RuntimeError('reported hold violations block functional board test')
    if route.sha256_file(candidate/'top25k.json') != state['input_top25k_sha256']:
        raise RuntimeError('synthesized netlist changed')
    names = state['artifacts']
    routed = candidate/names['pnr']
    summary=json.loads((candidate/f'build_{attempt}_summary.json').read_text(encoding='utf-8'))
    if summary.get('routed_json') != routed.name or summary.get('routed_json_sha256') != route.sha256_file(routed):
        raise RuntimeError('routed JSON is not frozen by the retained route-only summary')
    if summary.get('input_top25k_sha256') != state['input_top25k_sha256']:
        raise RuntimeError('route summary input-netlist mismatch')
    if route.sha256_file(candidate/names['cst']) != state['derived_cst_sha256']:
        raise RuntimeError('derived constraints changed')
    if route.sha256_file(Path(state['chipdb'])) != state['chipdb_sha256']:
        raise RuntimeError('chip timing database changed')
    image = candidate/f'functional_{attempt}.fs'
    if image.exists():
        retained=[json.loads(p.read_text(encoding='utf-8')) for p in candidate.glob(f'functional_board_{attempt}*.json')]
        if not any(r.get('bitstream_sha256')==route.sha256_file(image) and
                   r.get('routed_sha256')==route.sha256_file(routed) for r in retained):
            raise RuntimeError('existing bitstream has no matching retained provenance')
    else:
        _, packer, provenance = route.validate_official_runtime()
        env = route.pack_environment(route.OFFICIAL_RUNTIME)
        command = [provenance['baseline_python311'], str(packer), '-d', route.device_flow.FAMILY,
                   '--sspi_as_gpio', '-o', image.name, routed.name]
        pack_log=candidate/f'functional_pack_{attempt}.log'
        if pack_log.exists():
            pack_log=candidate/f'functional_pack_{attempt}_{datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f")}.log'
        with pack_log.open('x',encoding='utf-8') as log:
            subprocess.run(command,cwd=candidate,env=env,stdout=log,stderr=subprocess.STDOUT,
                           timeout=900,check=True)
    expected=(candidate/'expected_uart.txt').read_bytes()
    if not re.fullmatch(rb'A48 [0-9A-F]{8} PASS E=00000000 D=[0-9A-F]{8} T=0\r\n',expected):
        raise RuntimeError('expected UART must be an error-free, non-timeout acceptance result')
    image_sha=route.sha256_file(image)
    loader=route.ROOT/'tools/oss-cad-suite/oss-cad-suite/bin/openFPGALoader.exe'
    loader_env=route.device_flow.tool_env()
    result=dict(status='FUNCTIONAL_BOARD_FAIL',timing_signoff='NOT_QUALIFIED_HOLD_UNPROVEN',
                device=route.device_flow.DEVICE,clock_mhz=50,scope='bounded public-IP fixtures only',
                programming='volatile SRAM only',bitstream_sha256=image_sha,
                routed_sha256=route.sha256_file(routed),route_attempt=attempt,runs=[])
    record=candidate/f'functional_board_{attempt}_{datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f")}.json'
    try:
        with serial.Serial(port_name,115200,timeout=.2) as port:
            for index in range(repetitions):
                if route.verify_simulation_gate(candidate)!=current:
                    raise RuntimeError('simulation freeze changed during programming')
                if route.sha256_file(image)!=image_sha:
                    raise RuntimeError('bitstream changed')
                detect=subprocess.run([str(loader),'-b','tangprimer25k','--detect'],env=loader_env,
                                      capture_output=True,text=True,timeout=15)
                result.setdefault('jtag_detection',[]).append(dict(returncode=detect.returncode,
                    stdout=detect.stdout,stderr=detect.stderr))
                if detect.returncode or not re.search(r'(?i)idcode\s+0x0*1281b\b',detect.stdout+detect.stderr):
                    raise RuntimeError('unexpected JTAG IDCODE')
                port.reset_input_buffer()
                programmed=subprocess.run([str(loader),'-b','tangprimer25k',str(image)],env=loader_env,
                                          capture_output=True,text=True,timeout=45)
                raw=bytearray();deadline=time.monotonic()+25
                while time.monotonic()<deadline:
                    raw.extend(port.read(1024))
                    if b'\n' in raw:break
                raw.extend(port.read(1024))
                passed=programmed.returncode==0 and bytes(raw)==expected
                result['runs'].append(dict(index=index,status='PASS' if passed else 'FAIL',
                    programmer_returncode=programmed.returncode,stdout=programmed.stdout,
                    stderr=programmed.stderr,uart_hex=raw.hex(),expected_hex=expected.hex()))
                if not passed:raise RuntimeError('programming or exact UART mismatch')
        result['status']='FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN'
    except Exception as error:
        result['error']=str(error)
        raise
    finally:
        result['date']=datetime.datetime.now().astimezone().isoformat()
        record.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
        print(result['status'],record,flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate',type=Path)
    parser.add_argument('--attempt',required=True)
    parser.add_argument('--port',default='COM44')
    parser.add_argument('--repetitions',type=int,choices=range(1,11),default=3)
    args=parser.parse_args()
    run(args.candidate,args.attempt,args.port,args.repetitions)
