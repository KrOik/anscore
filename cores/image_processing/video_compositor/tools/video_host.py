"""Bounded, transport-neutral one-frame acceptance of three digital scanouts."""
import hashlib,json,math,time,zlib
from pathlib import Path
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())

class BankedBus:
    def __init__(self,bus):self.bus=bus
    def access(self,address,value=None):
        if type(address) is not int or not 0<=address<1024 or address%4 or address%256==252:raise ValueError('CSR address')
        self.bus.access(252,address>>8)
        return self.bus.access(address&255,value)

def blend(base,aux,alpha):
    return sum((((((base>>s)&255)*(256-alpha)+((aux>>s)&255)*alpha+128)>>8)&255)<<s for s in (0,8,16))

def profile(width,height,divider,base):
    if any(type(x) is not int for x in (width,height,divider,base)) or not(1<=width<=4096 and 1<=height<=4096 and 1<=divider<=65535 and 0<=base<2**24) or width*height>1024*1024:raise ValueError('bounded profile range')
    return dict(timing=[width,1,1,2,height,1,1,1,divider,1],layers=[base,0x654321,0xabcdef,0x00400080,0x103,0,0,0])

def golden_crc(p):
    crc=0;layers=p['layers']
    for y in range(p['timing'][4]):
        row=bytearray()
        for x in range(p['timing'][0]):
            pixel=blend(blend(layers[0]^(((x&255)<<16)|((y&255)<<8)),layers[1],128),layers[2],64)
            row.extend(pixel.to_bytes(3,'little'))
        crc=zlib.crc32(row,crc)
    return crc

def identify(bus,build_id):
    if type(build_id) is not int or not 0<build_id<2**64 or bus.access(0)!=0x56494431:raise ValueError('video identity')
    if bus.access(8)|(bus.access(12)<<32)!=build_id:raise ValueError('loaded build fingerprint differs')

def run_case(bus,profiles,build_id,save,seconds=10,max_polls=10000):
    if not math.isfinite(seconds) or seconds<=0 or type(max_polls) is not int or max_polls<1:raise ValueError('bounded polling required')
    if len(profiles)!=3 or any(p!=profile(p['timing'][0],p['timing'][4],p['timing'][8],p['layers'][0]) for p in profiles):raise ValueError('canonical one-frame profiles required')
    identify(bus,build_id)
    if bus.access(4)!=0:raise ValueError('unacknowledged result; explicit operator ownership required')
    capture=dict(status='CONFIGURING',profiles=profiles,build_id=f'{build_id:016x}',lanes=[]);save(capture)
    drops=[bus.access(0xa0+4*g) for g in range(3)];versions=[]
    for g,p in enumerate(profiles):
        base=(g+1)*256
        if bus.access(base+44)!=1:raise ValueError('requires clean idle lane')
        versions.append((bus.access(base+52)+1)%2**32)
        for n,v in enumerate(p['timing']):bus.access(base+n*4,v)
        for n,v in enumerate(p['layers']):bus.access(base+64+n*4,v)
        bus.access(base+56,1)
        if bus.access(base+52)!=versions[g]:raise ValueError('configuration not applied')
    expected=[golden_crc(p) for p in profiles]
    for g in range(3):bus.access((g+1)*256+48,1)
    capture['status']='RUNNING';save(capture);deadline=time.monotonic()+seconds
    for _ in range(max_polls):
        if bus.access(4)==7 and all(bus.access((g+1)*256+44)==1 for g in range(3)):break
        if time.monotonic()>=deadline:raise TimeoutError('scanout timeout; no automatic ACK/retry')
        time.sleep(.001)
    else:raise TimeoutError('scanout poll limit')
    capture['status']='READING';save(capture)
    for g,p in enumerate(profiles):
        words={};capture['lanes'].append(words)
        for n in range(8):words[f'{n*4:02x}']=bus.access(64+g*32+n*4);save(capture)
        if any(type(v) is not int or not 0<=v<2**32 for v in words.values()):raise ValueError('invalid CSR word')
        if [words[k] for k in ('00','04','08','0c','10')]!=[0,expected[g],p['timing'][0]*p['timing'][4],0,versions[g]&8191]:raise ValueError('frame/CRC/count/error/version mismatch')
        if words['14']==0 or (words['18']|(words['1c']<<32))==0:raise ValueError('missing capture sequence/timestamp')
        if bus.access((g+1)*256+96)!=1 or bus.access(0xa0+g*4)!=drops[g]:raise ValueError('produced count/overrun mismatch')
        if any(bus.access(64+g*32+n*4)!=words[f'{n*4:02x}'] for n in range(8)):raise ValueError('incoherent result snapshot')
    identify(bus,build_id)
    if bus.access(4)!=7:raise ValueError('lost result ownership')
    capture['status']='VERIFIED';save(capture)
    bus.access(16,7)
    capture['status']='ACKNOWLEDGED';save(capture)
    return capture

def validate_build(path):
    path=Path(path);build=json.loads(path.read_text())
    if build['status']!='PASS' or build['target']!='GW5A-LV25MG121NES' or build['clock_mhz']!=50:raise ValueError('requires completed50MHz25K build')
    fmax=build['pnr_report']['fmax']
    if not fmax or any(c['achieved']<50 or c['constraint']!=50 for c in fmax.values()):raise ValueError('timing not closed')
    if hashlib.sha256((path.parent/'video.fs').read_bytes()).hexdigest()!=build['bitstream_sha256']:raise ValueError('image hash mismatch')
    for name,digest in build['sources'].items():
        for root in (ROOT,path.parent/'source_snapshot'):
            if hashlib.sha256((root/name).read_bytes()).hexdigest()!=digest:raise ValueError('source hash mismatch '+name)
    fingerprint=hashlib.sha256(json.dumps(build['sources'],sort_keys=True,separators=(',',':')).encode()).hexdigest()[:16]
    if fingerprint!=build['hardware_build_id']:raise ValueError('fingerprint mismatch')
    return build
