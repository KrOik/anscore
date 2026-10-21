"""Run complete numerical CNN acceptance on an already loaded25K UART image."""
import argparse
from datetime import datetime,timezone
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import sys
from cnn_host import ROOT,validate_build,fixture,load_model,run_case


def transport():
    directory=ROOT/'cores/storage/buffer_dma/tools';sys.path.insert(0,str(directory))
    try:
        spec=importlib.util.spec_from_file_location('_cnn_uart',directory/'run_uart.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        return module.UartCsr
    finally:sys.path.pop(0)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port',required=True);p.add_argument('--build-summary',type=Path,required=True)
    p.add_argument('--fixture',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--seconds',type=float,default=10)
    args=p.parse_args()
    if not math.isfinite(args.seconds) or args.seconds<=0:p.error('positive finite timeout required')
    args.output.mkdir(parents=True,exist_ok=False)
    report=dict(status='FAIL',source_kind='board',transport='UART',physical_jtag_verified=False,
                loaded_image_hash_verified=False,time_utc=datetime.now(timezone.utc).isoformat(),
                host_sources={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in
                    (Path(__file__).resolve(),Path(__file__).with_name('cnn_host.py'),Path(__file__).with_name('model.py'),
                     ROOT/'cores/storage/buffer_dma/tools/run_uart.py',ROOT/'cores/storage/buffer_dma/tools/decode_metrics.py')})
    bus=None
    try:
        build=validate_build(args.build_summary);model,images=fixture(args.fixture)
        report['supplied_bitstream_sha256']=build['bitstream_sha256']
        expected_id=int(build['hardware_build_id'],16)
        import serial
        with serial.Serial(args.port,115200,timeout=0.1,write_timeout=2) as port:
            port.reset_input_buffer();bus=transport()(port)
            load_model(bus,model,expected_id)
            report['loaded_configuration_fingerprint_verified']=True
            report['runs']={}
            for name,image in images.items():
                def save(capture):
                    (args.output/(name+'.json')).write_text(json.dumps(capture,indent=2)+'\n')
                capture=run_case(bus,model,image,expected_id,save,args.seconds)
                report['runs'][name]={k:v for k,v in capture.items() if k!='values'}
            report.update(status='PASS',scope='finite UART per-layer numerical runs; hardware JTAG/LA gates separate')
    except Exception as exc:report['reason']=str(exc);raise
    finally:
        if bus is not None:(args.output/'uart_exchanges.json').write_text(json.dumps(bus.exchanges,indent=2)+'\n')
        (args.output/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(args.output))


if __name__=='__main__':main()
