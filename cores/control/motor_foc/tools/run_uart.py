"""One disabled-drive diagnostic on an already-loaded25K motor UART image."""
import argparse,hashlib,importlib.util,json,os,sys
from pathlib import Path
from motor_host import command,run_case,validate_build,word
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port',required=True)
    parser.add_argument('--build-summary',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--sample-id',type=int,required=True)
    parser.add_argument('--d',type=int,default=0);parser.add_argument('--q',type=int,default=0)
    parser.add_argument('--ack-after-save',action='store_true')
    args=parser.parse_args()
    config=command(sample_id=args.sample_id,d=args.d,q=args.q)
    build=validate_build(args.build_summary)
    args.output.mkdir(parents=True,exist_ok=False)
    raw=None;report=dict(status='FAIL',transport='UART',drive_enabled_by_tool=False,
        physical_motor_verified=False,physical_jtag_verified=False,loaded_image_hash_verified=False,
        supplied_bitstream_sha256=build['bitstream_sha256'])
    directory=ROOT/'cores/storage/buffer_dma/tools';sys.path.insert(0,str(directory))
    host_files=[Path(__file__).resolve(),Path(__file__).with_name('motor_host.py'),directory/'run_uart.py',directory/'decode_metrics.py']
    report['host_sources']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in host_files}
    try:
        spec=importlib.util.spec_from_file_location('_motor_uart_transport',directory/'run_uart.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        import serial
        def save(data):
            tmp=args.output/'capture.tmp'
            with tmp.open('w') as stream:
                json.dump(data,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
            os.replace(tmp,args.output/'capture.json')
        with serial.Serial(args.port,115200,timeout=.1,write_timeout=2) as port:
            raw=module.UartCsr(port)
            if word(raw,4)&4:raise ValueError('diagnostic requires drive disabled; no automatic disable')
            capture=run_case(raw,config,int(build['hardware_build_id'],16),save,
                             ack_after_save=args.ack_after_save)
            report.update(status='PASS',capture_status=capture['status'],loaded_configuration_fingerprint_verified=True,
                          scope='one disabled diagnostic UART command;not real-time replay/hardJTAG/LA/motor acceptance')
    except Exception as exc:report['reason']=str(exc);raise
    finally:
        sys.path.pop(0)
        if raw is not None:(args.output/'uart_exchanges.json').write_text(json.dumps(raw.exchanges,indent=2)+'\n')
        (args.output/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
        print('Evidence='+str(args.output))
if __name__=='__main__':main()
