"""Configure a loaded ISP image and verify a finite physical UART run."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import time
import uuid
from isp_host import ROOT, UartCsr, config_words, capture_snapshot, decode, verify_run, IDENTITY_MATRIX


def color_args(args):
    return dict(levels=getattr(args,'black_levels',(0,0,0,0)),target=getattr(args,'blc_target',0),
                gains=getattr(args,'gains',(256,256,256)),matrix=getattr(args,'matrix',IDENTITY_MATRIX))


def validate_build(path):
    build=json.loads(path.read_text())
    if build['status']!='PASS' or build['target']!='GW5A-LV25MG121NES' or build['clock_mhz']!=50:
        raise ValueError('expected successful50MHz25K build')
    image=path.parent/'isp.fs'
    if hashlib.sha256(image.read_bytes()).hexdigest()!=build['bitstream_sha256']:
        raise ValueError('bitstream hash mismatch')
    for name,digest in build['sources'].items():
        if hashlib.sha256((ROOT/name).read_bytes()).hexdigest()!=digest:
            raise ValueError('build source changed: '+name)
    return build['bitstream_sha256']


def execute(bus, words, args, save_snapshot):
    if bus.access(8)!=0x49535031:raise ValueError('unexpected ISP identifier')
    if bus.access(0)&3!=1:raise ValueError('runner must be idle with no pending configuration')
    version=bus.access(4)
    bus.access(0x1c,args.probe_page)
    if args.gamma_identity:
        for channel in range(3):
            for address in range(256):bus.access(0x10,(channel<<24)|(address<<16)|address)
    for index,word in enumerate(words):bus.access(0x20+index*4,word)
    bus.access(4,1)
    deadline=time.monotonic()+args.seconds
    epoch=str(uuid.uuid4())
    while True:
        capture=capture_snapshot(bus,50000000,'board',epoch)
        save_snapshot(capture)
        measured=decode(capture)
        if measured['config_version']==((version+1)&0xffffffff) and measured['status']&2:
            break
        if time.monotonic()>=deadline:raise TimeoutError('ISP run completion timeout')
        time.sleep(0.01)
    return capture,verify_run(capture,args.width,args.height,args.frames,args.seed,args.raw_bits,
                              args.pattern,args.center_bypass,args.gamma_identity,
                              *(getattr(args,name,False) for name in ('bayer_bypass','awb_bypass','ccm_bypass','blc_bypass')),
                              **color_args(args))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port',required=True)
    parser.add_argument('--build-summary',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--width',type=int,default=320)
    parser.add_argument('--height',type=int,default=240)
    parser.add_argument('--frames',type=int,default=3)
    parser.add_argument('--period-cycles',type=int,default=1666667)
    parser.add_argument('--seed',type=lambda v:int(v,0),default=71)
    # The supplied physical top uses default RAW10. Other widths are test APIs.
    parser.add_argument('--pattern',type=int,choices=range(4),default=0)
    parser.add_argument('--center-bypass',action='store_true')
    parser.add_argument('--gamma-identity',action='store_true')
    parser.add_argument('--bayer-bypass',action='store_true')
    parser.add_argument('--awb-bypass',action='store_true')
    parser.add_argument('--ccm-bypass',action='store_true')
    parser.add_argument('--blc-bypass',action='store_true')
    parser.add_argument('--black-levels',type=int,nargs=4,default=(0,0,0,0))
    parser.add_argument('--blc-target',type=int,default=0)
    parser.add_argument('--gains',type=int,nargs=3,default=(256,256,256),help='RGB Q8.8 gains')
    parser.add_argument('--matrix',type=int,nargs=12,default=IDENTITY_MATRIX,help='row-major signed Q10 3x3 coefficients, then RGB integer biases')
    parser.add_argument('--probe-page',type=int,choices=range(4),default=0)
    parser.add_argument('--seconds',type=float,default=20)
    args=parser.parse_args();args.raw_bits=10
    try:
        words=config_words(args.width,args.height,args.frames,args.period_cycles,args.seed,10,args.pattern,args.center_bypass,args.gamma_identity,
                           args.bayer_bypass,args.awb_bypass,args.ccm_bypass,args.blc_bypass,**color_args(args))
        if not math.isfinite(args.seconds) or args.seconds<=0 or args.frames*args.period_cycles>=1<<32 or (args.width-4)*(args.height-4)*args.frames>=1<<32:
            raise ValueError('invalid timeout or run exceeds32-bit telemetry range')
    except ValueError as exc:parser.error(str(exc))
    args.output.mkdir(parents=True,exist_ok=False)
    report={'status':'IN_PROGRESS','source_kind':'board','transport':'UART','clock_hz':50000000,
            'time_utc':datetime.now(timezone.utc).isoformat(),'config_words':words,
            'physical_jtag_verified':False,'loaded_image_hash_verified':False,
            'host_sources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (
                Path(__file__).resolve(),Path(__file__).with_name('isp_host.py'),
                ROOT/'cores/storage/buffer_dma/tools/run_uart.py',ROOT/'cores/storage/buffer_dma/tools/decode_metrics.py')}}
    bus=None
    def save(capture):
        (args.output/'snapshot.json').write_text(json.dumps(capture,indent=2)+'\n')
    try:
        report['supplied_build_bitstream_sha256']=validate_build(args.build_summary)
        import serial
        with serial.Serial(args.port,115200,timeout=0.1,write_timeout=2) as port:
            port.reset_input_buffer();bus=UartCsr(port)
            capture,measured=execute(bus,words,args,save)
            (args.output/'decoded.json').write_text(json.dumps(measured,indent=2)+'\n')
            report.update(status='PASS',snapshot_id=capture['snapshot_id_before'],verified=measured,
                          scope='finite UART numerical run; JTAG/LA and physical acceptance gates separate')
    except Exception as exc:
        report.update(status='FAIL',reason=str(exc));raise
    finally:
        if bus is not None:(args.output/'uart_exchanges.json').write_text(json.dumps(bus.exchanges,indent=2)+'\n')
        (args.output/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
        print('Evidence='+str(args.output))


if __name__=='__main__':main()
