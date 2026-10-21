"""Finite controlled-input lock-in acceptance on an already loaded25K image."""
import argparse
import csv
from datetime import datetime, timezone
import importlib.util
import json
import math
from pathlib import Path
import sys
from lockin_host import ROOT, configuration, run_case, validate_build


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port', required=True)
    p.add_argument('--build-summary', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--seconds', type=float, default=10)
    args = p.parse_args()
    if not math.isfinite(args.seconds) or args.seconds <= 0:
        p.error('positive finite timeout required')
    build = validate_build(args.build_summary)
    cases = [configuration(b, a, ph, period=16, run_id=n) for n, (b, a, ph) in enumerate([
        (1, [1000,4000,12000,24000], [0,32,192,96]),
        (3, [64,2000,8000,20000], [16,64,128,224]),
        (7, [500,5000,16000,28000], [240,80,160,48])])]
    args.output.mkdir(parents=True, exist_ok=False)
    report = dict(status='FAIL', source_kind='board-controlled digital input', transport='UART',
                  physical_jtag_verified=False, analog_end_to_end=False,
                  loaded_image_hash_verified=False, supplied_bitstream_sha256=build['bitstream_sha256'],
                  time_utc=datetime.now(timezone.utc).isoformat(), runs=[])
    directory = ROOT/'cores/storage/buffer_dma/tools'
    sys.path.insert(0, str(directory))
    bus = None
    try:
        spec = importlib.util.spec_from_file_location('_lockin_uart', directory/'run_uart.py')
        module = importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        import serial
        with serial.Serial(args.port, 115200, timeout=.1, write_timeout=2) as port:
            port.reset_input_buffer();bus = module.UartCsr(port)
            rows = []
            for n, cfg in enumerate(cases):
                def save(data):
                    (args.output/f'run{n}.json').write_text(json.dumps(data, indent=2)+'\n')
                capture = run_case(bus, cfg, int(build['hardware_build_id'],16), save, args.seconds)
                report['runs'].append(capture)
                for lane in capture['lanes']:
                    rows.append(dict(run=n, bins=cfg['bins'], input_amplitude=cfg['amplitudes'][lane['lane']],
                                     input_phase_index=cfg['phases'][lane['lane']], **lane))
            with (args.output/'errors.csv').open('w', newline='') as f:
                writer = csv.DictWriter(f, fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
            report.update(status='PASS', loaded_configuration_fingerprint_verified=True)
    except Exception as exc:
        report['reason'] = str(exc)
        raise
    finally:
        sys.path.pop(0)
        if bus is not None:
            (args.output/'uart_exchanges.json').write_text(json.dumps(bus.exchanges,indent=2)+'\n')
        (args.output/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
        print('Evidence='+str(args.output))


if __name__ == '__main__':
    main()
