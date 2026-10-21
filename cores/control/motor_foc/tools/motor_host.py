"""Transport-neutral, bounded motor sample submission and durable result capture."""
import math,time
import hashlib,json
from pathlib import Path

def validate_build(summary):
    """Validate current/frozen inputs and supplied image; not loaded SRAM hash."""
    summary=Path(summary).resolve();report=json.loads(summary.read_text())
    root=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
    if report.get('status')!='PASS' or report.get('target')!='GW5A-LV25MG121NES':
        raise ValueError('qualified25K board build required')
    sources=report['sources']
    required=['cores/control/motor_foc/examples/25k/motor_top.v',
              'cores/control/motor_foc/examples/25k/motor.cst',
              'cores/control/motor_foc/rtl/motor_control_csr.v']
    if not all(p in sources for p in required):raise ValueError('missing board binding')
    snap=(summary.parent/report['source_snapshot']).resolve()
    if not snap.is_relative_to(summary.parent):raise ValueError('snapshot path escapes artifact')
    for name,digest in sources.items():
        relative=Path(name)
        if relative.is_absolute() or '..' in relative.parts:raise ValueError('source path')
        for path in [root/relative,snap/relative]:
            if hashlib.sha256(path.read_bytes()).hexdigest()!=digest:raise ValueError('source changed: '+name)
    fingerprint=hashlib.sha256(json.dumps(sources,sort_keys=True,separators=(',',':')).encode()).hexdigest()[:16]
    if report['hardware_build_id']!=fingerprint:raise ValueError('build fingerprint mismatch')
    if hashlib.sha256((summary.parent/'motor.fs').read_bytes()).hexdigest()!=report['bitstream_sha256']:
        raise ValueError('supplied image hash mismatch')
    return report

def word(bus,address,value=None):
    result=bus.access(address,value)
    if type(result) is not int or not 0<=result<2**32:
        raise ValueError('invalid CSR response word')
    return result

def command(*,sample_id,ia=0,ib=0,ic=0,theta=0,mode=0,restart=True,
            freeze=False,target_position=0,target_speed=0,d=0,q=0,
            kp=8,ki=4,gain_shift=4,period=256,dead=2):
    fields=[(sample_id,0,2**32-1),(ia,-512,511),(ib,-512,511),(ic,-512,511),
            (theta,0,255),(mode,0,2),(target_position,-2**31,2**31-1),
            (target_speed,-32768,32767),(d,-2048,2047),(q,-2048,2047),
            (kp,-2048,2047),(ki,-2048,2047),(gain_shift,0,15),
            (period,4,65535),(dead,1,32767)]
    if any(type(v) is not int or not lo<=v<=hi for v,lo,hi in fields) or 2*dead>=period:
        raise ValueError('motor command range')
    if type(restart) is not bool or type(freeze) is not bool:raise ValueError('boolean command flags')
    values=[mode|(int(restart)<<8)|(int(freeze)<<9),ia,ib,ic,theta,target_position,
            target_speed,d,q,kp,ki,gain_shift,period,dead,sample_id]
    return [v&0xffffffff for v in values]

def signed(value):return value-2**32 if value&2**31 else value

def run_case(bus,config,build_id,save,*,ack_after_save=False,seconds=2,max_polls=1000):
    """save must persist the supplied dictionary or raise before ACK is possible.

    This API never enables,clears faults,retries a command or schedules real-time
    control. On failure it preserves ownership for explicit diagnosis/recovery.
    """
    if type(build_id) is not int or not 0<build_id<2**64:raise ValueError('build fingerprint')
    if type(ack_after_save) is not bool:raise ValueError('explicit ACK policy')
    if not math.isfinite(seconds) or seconds<=0 or type(max_polls) is not int or max_polls<1:
        raise ValueError('bounded polling required')
    if type(config) is not list or len(config)!=15 or any(type(v) is not int or not 0<=v<2**32 for v in config):
        raise ValueError('canonical command required')
    # Reconstruct through the public range checker to reject unused/alias bits.
    rebuilt=command(sample_id=config[14],ia=signed(config[1]),ib=signed(config[2]),ic=signed(config[3]),
        theta=config[4],mode=config[0]&3,restart=bool(config[0]&256),freeze=bool(config[0]&512),
        target_position=signed(config[5]),target_speed=signed(config[6]),d=signed(config[7]),q=signed(config[8]),
        kp=signed(config[9]),ki=signed(config[10]),gain_shift=config[11],period=config[12],dead=config[13])
    if config!=rebuilt:raise ValueError('noncanonical command encoding')
    if word(bus,0)!=0x464f4331 or word(bus,8)|(word(bus,12)<<32)!=build_id:
        raise ValueError('loaded identity/build mismatch')
    status=word(bus,4)
    if status&11:raise ValueError('busy,result owned,or clear held; explicit lifecycle required')
    if status&4 and (status&0x30)!=0x10:raise ValueError('enabled drive fault')
    capture=dict(status='CONFIGURING',build_id=f'{build_id:016x}',config=list(config),words={},ack_requested=ack_after_save)
    save(capture)
    try:
        before=word(bus,36)
        for n,v in enumerate(config):word(bus,64+4*n,v)
        word(bus,16,1);capture['status']='RUNNING';save(capture)
        deadline=time.monotonic()+seconds
        for _ in range(max_polls):
            if word(bus,4)&2:break
            if time.monotonic()>=deadline:raise TimeoutError('motor result timeout')
        else:raise TimeoutError('motor poll limit')
        capture['status']='READING';save(capture)
        for n in range(12):
            capture['words'][f'{128+4*n:02x}']=word(bus,128+4*n);save(capture)
        serial=word(bus,36);stamp=word(bus,40)|(word(bus,44)<<32)
        capture.update(serial=serial,timestamp=stamp,live_cause=word(bus,20),fault_count=word(bus,24))
        values=list(capture['words'].values())
        if values[0]!=config[14] or serial!=(before+1)&0xffffffff or stamp==0:
            raise ValueError('result ID/serial/timestamp mismatch')
        if any(word(bus,128+4*n)!=v for n,v in enumerate(values)) or word(bus,36)!=serial:
            raise ValueError('incoherent result snapshot')
        if values[1]!=0:raise ValueError(f'motor terminal error 0x{values[1]:02x}')
        if any(v>config[12] for v in values[8:11]):raise ValueError('duty exceeds carrier')
        if values[11] or capture['live_cause']:raise ValueError('motor fault recorded')
        capture['status']='SAVED';save(capture)
        if ack_after_save:
            word(bus,16,2);capture['status']='ACKNOWLEDGED';save(capture)
        return capture
    except Exception as exc:
        capture['status']='FAIL';capture['reason']=str(exc);save(capture)
        raise
