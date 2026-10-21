"""Supplementary finite UART acceptance of an already-loaded25K video image."""
import argparse
from datetime import datetime,timezone
import hashlib,importlib.util,json,math,sys
from pathlib import Path
from video_host import ROOT,BankedBus,profile,run_case,validate_build
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port',required=True);p.add_argument('--build-summary',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True);p.add_argument('--seconds',type=float,default=10)
    args=p.parse_args()
    if not math.isfinite(args.seconds) or args.seconds<=0:p.error('positive finite timeout required')
    build=validate_build(args.build_summary)
    profiles=[[profile(w,h,g+1,(0x123456+g*0x10101+run*0x112233)&0xffffff) for g,(w,h) in enumerate(sizes)] for run,sizes in enumerate([[(320,240),(160,120),(80,60)],[(640,480),(320,240),(160,120)]])]
    args.output.mkdir(parents=True,exist_ok=False)
    host_files=[Path(__file__).resolve(),Path(__file__).with_name('video_host.py'),ROOT/'cores/storage/buffer_dma/tools/run_uart.py',ROOT/'cores/storage/buffer_dma/tools/decode_metrics.py']
    report=dict(status='FAIL',time_utc=datetime.now(timezone.utc).isoformat(),transport='UART',source_kind='internal digital reference scanouts',physical_display_verified=False,physical_jtag_verified=False,loaded_image_hash_verified=False,supplied_bitstream_sha256=build['bitstream_sha256'],runs=[],host_sources={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in host_files})
    directory=ROOT/'cores/storage/buffer_dma/tools';sys.path.insert(0,str(directory));raw=None
    try:
        spec=importlib.util.spec_from_file_location('_video_uart_transport',directory/'run_uart.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        import serial
        with serial.Serial(args.port,115200,timeout=.1,write_timeout=2) as port:
            port.reset_input_buffer();raw=module.UartCsr(port);bus=BankedBus(raw)
            for n,configuration in enumerate(profiles):
                def save(data):(args.output/f'run{n}.json').write_text(json.dumps(data,indent=2)+'\n')
                report['runs'].append(run_case(bus,configuration,int(build['hardware_build_id'],16),save,args.seconds))
            report.update(status='PASS',loaded_configuration_fingerprint_verified=True,scope='finite digital controlled scanouts; no continuous external display/hardJTAG/LA claim')
    except Exception as exc:report['reason']=str(exc);raise
    finally:
        sys.path.pop(0)
        if raw is not None:(args.output/'uart_exchanges.json').write_text(json.dumps(raw.exchanges,indent=2)+'\n')
        (args.output/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
        print('Evidence='+str(args.output))
if __name__=='__main__':main()
