"""Host config, independent integer golden and coherent ISP snapshot checks."""
import importlib.util
import math
from pathlib import Path
import sys
import uuid
import zlib

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
# Reuse the existing wire protocol implementation without editing its project.
_transport_dir = ROOT/'cores/storage/buffer_dma/tools'
sys.path.insert(0, str(_transport_dir))
try:
    _spec = importlib.util.spec_from_file_location('_isp_reused_uart', _transport_dir/'run_uart.py')
    _transport = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_transport)
finally:
    sys.path.pop(0)
UartCsr = _transport.UartCsr
crc8 = _transport.crc8


def uint(value, bits):
    if type(value) is not int or not 0 <= value < 1 << bits:
        raise ValueError(f'expected uint{bits}')
    return value


def color_parameters(raw_bits, levels, target, gains, matrix):
    if raw_bits not in (8,10,12):raise ValueError('invalid RAW width')
    if len(levels)!=4 or len(gains)!=3 or len(matrix)!=12:
        raise ValueError('expected4 black levels,3 gains,12 CCM terms')
    for v in (*levels,target):uint(v,raw_bits)
    for v in gains:uint(v,16)
    for v in matrix:
        if type(v) is not int or not -32768<=v<=32767:raise ValueError('expected signed16 CCM term')


IDENTITY_MATRIX=(1024,0,0,0,1024,0,0,0,1024,0,0,0)


def config_words(width, height, frames, period, seed=71, raw_bits=10, pattern=0,
                 bypass=False, gamma=False, bayer_bypass=False, awb_bypass=False,
                 ccm_bypass=False, blc_bypass=False, *, levels=(0,0,0,0), target=0,
                 gains=(256,256,256), matrix=IDENTITY_MATRIX):
    color_parameters(raw_bits,levels,target,gains,matrix)
    for v in (width, height):
        uint(v,16)
    if not 5 <= width <= 640 or height < 5:
        raise ValueError('default board image requires 5<=width<=640 and height>=5')
    uint(frames,32);uint(period,32);uint(seed,raw_bits);uint(pattern,2)
    if raw_bits not in (8,10,12) or frames == 0 or period < 2:
        raise ValueError('invalid RAW width/frame count/period')
    w = [0]*16
    flags=(pattern<<4)|(int(bypass)<<2)|(int(gamma)<<1)|int(blc_bypass)|(int(bayer_bypass)<<3)|(int(awb_bypass)<<6)|(int(ccm_bypass)<<7)
    w[:5] = [width|(height<<16),frames,period,seed,flags]
    w[5]=target
    w[6],w[7]=levels[0]|(levels[1]<<16),levels[2]|(levels[3]<<16)
    w[8],w[9] = gains[0]|(gains[1]<<16),gains[2]
    for i in range(6):w[10+i]=(matrix[2*i]&65535)|((matrix[2*i+1]&65535)<<16)
    return w


def golden_frame(width, height, frame, seed=71, raw_bits=10, pattern=0, bypass=False, bayer_bypass=False,
                 *, levels=(0,0,0,0), target=0, gains=(256,256,256), matrix=IDENTITY_MATRIX,
                 blc_bypass=False, awb_bypass=False, ccm_bypass=False):
    """Integer BLC/Bayer/AWB/CCM/Sobel oracle; identity/off Gamma."""
    color_parameters(raw_bits,levels,target,gains,matrix)
    mask=(1<<raw_bits)-1
    raw=[[(seed+23*x+37*y+57*frame)&mask for x in range(width)] for y in range(height)]
    if not blc_bypass:
        raw=[[max(0,min(mask,v-levels[((y&1)*2+(x&1))^pattern]+target))
              for x,v in enumerate(row)] for y,row in enumerate(raw)]
    gains=(256,256,256) if awb_bypass else gains
    matrix=IDENTITY_MATRIX if ccm_bypass else matrix
    sums=[0,0,0];luma=[]
    for y in range(1,height-1):
        row=[]
        for x in range(1,width-1):
            c=raw[y][x]
            horizontal=(raw[y][x-1]+raw[y][x+1]+1)//2
            vertical=(raw[y-1][x]+raw[y+1][x]+1)//2
            cross=(raw[y-1][x]+raw[y][x-1]+raw[y][x+1]+raw[y+1][x]+2)//4
            diag=(raw[y-1][x-1]+raw[y-1][x+1]+raw[y+1][x-1]+raw[y+1][x+1]+2)//4
            site=(((y&1)*2+(x&1))^pattern)
            native=(c,c,c) if bayer_bypass else ((c,cross,diag),(horizontal,c,vertical),(vertical,c,horizontal),(diag,cross,c))[site]
            rgb=tuple(v>>(raw_bits-8) for v in native)
            rgb=[min(255,(v*g+128)//256) for v,g in zip(rgb,gains)]
            rgb=[max(0,min(255,(sum(matrix[3*c+i]*rgb[i] for i in range(3))+512)//1024+matrix[9+c])) for c in range(3)]
            for channel in range(3):sums[channel]+=rgb[channel]
            row.append((rgb[0]+2*rgb[1]+rgb[2])>>2)
        luma.append(row)
    output=bytearray()
    for y in range(1,height-3):
        for x in range(1,width-3):
            gx=sum(k*(luma[y+d][x+1]-luma[y+d][x-1]) for d,k in ((-1,1),(0,2),(1,1)))
            gy=sum(k*(luma[y+1][x+d]-luma[y-1][x+d]) for d,k in ((-1,1),(0,2),(1,1)))
            output.append(luma[y][x] if bypass else min(255,(abs(gx)+abs(gy))>>2))
    return bytes(output),sums


def capture_snapshot(bus, clock_hz, source_kind='board', epoch_id=None):
    selector=bus.access(0x1c)
    bus.access(0x0c,1)
    first=bus.access(0x18)
    timestamp=bus.access(0x10)|(bus.access(0x14)<<32)
    words=[]
    try:
        for page in range(2):
            bus.access(0x1c,(selector&3)|(page<<8))
            words.extend(bus.access(0xc0+4*i) for i in range(16))
    finally:
        bus.access(0x1c,selector)
    last=bus.access(0x18)
    return {'schema':'isp_metrics_v1','source_kind':source_kind,'epoch_id':epoch_id or str(uuid.uuid4()),
            'clock_hz':clock_hz,'captured':bus.access(0x0c)==1,
            'snapshot_id_before':first,'snapshot_id_after':last,'timestamp':timestamp,'words':words}


def decode(capture):
    if capture['schema']!='isp_metrics_v1' or capture['source_kind'] not in ('board','simulation'):
        raise ValueError('invalid snapshot schema/provenance')
    if not isinstance(capture['epoch_id'],str) or not capture['epoch_id']:
        raise ValueError('missing reset/run epoch')
    hz=capture['clock_hz']
    if type(hz) not in (int,float) or not math.isfinite(hz) or hz<=0:
        raise ValueError('invalid clock')
    uint(capture['timestamp'],64)
    if capture['captured'] is not True or uint(capture['snapshot_id_before'],32)!=uint(capture['snapshot_id_after'],32):
        raise ValueError('uncaptured/incoherent snapshot')
    w=capture['words']
    if len(w)!=32:raise ValueError('expected32metric words')
    for value in w:uint(value,32)
    if w[0]&~15 or w[11]&~0x3ffff or any(w[i]>65535 for i in (15,17,19,21)) or w[22]>255 or any(w[23:]):
        raise ValueError('invalid reserved/high metric bits')
    return {'status':w[0],'completed_frames':w[1],'deadline_misses':w[2],'command_stalls':w[3],
            'pixel_stalls':w[4],'run_cycles':w[5],'output_bytes':w[6],'output_frames':w[7],
            'crc32':w[8],'last_frame_crc32':w[9],'last_frame_cycles':w[10],
            'stats_frame_id':w[11]&65535,'stats_overflow':bool(w[11]&(1<<16)),
            'stats_protocol_error':bool(w[11]&(1<<17)),'stats_pixels':w[12],'stats_lines':w[13],
            'rgb_sums':[w[14+2*c]|(w[15+2*c]<<32) for c in range(3)],
            'config_version':w[20],'source_frame_id':w[21],'mode_flags':w[22],
            'snapshot_id':capture['snapshot_id_before'],'timestamp':capture['timestamp'],'clock_hz':hz}


def verify_run(capture, width, height, frames, seed=71, raw_bits=10, pattern=0, bypass=False, gamma=False,
               bayer_bypass=False, awb_bypass=False, ccm_bypass=False, blc_bypass=False,
               *, levels=(0,0,0,0), target=0, gains=(256,256,256), matrix=IDENTITY_MATRIX):
    decoded=decode(capture)
    crc=0;last_crc=0;sums=[]
    for frame in range(frames):
        payload,sums=golden_frame(width,height,frame,seed,raw_bits,pattern,bypass,bayer_bypass,
                                 levels=levels,target=target,gains=gains,matrix=matrix,
                                 blc_bypass=blc_bypass,awb_bypass=awb_bypass,ccm_bypass=ccm_bypass)
        crc=zlib.crc32(payload,crc);last_crc=zlib.crc32(payload)
    expected={'status':3,'completed_frames':frames,'deadline_misses':0,'command_stalls':0,
              'output_bytes':(width-4)*(height-4)*frames,'output_frames':frames,'crc32':crc,
              'last_frame_crc32':last_crc,'stats_frame_id':(frames-1)&65535,'stats_overflow':False,
              'stats_protocol_error':False,'stats_pixels':(width-2)*(height-2),'stats_lines':height-2,
              'rgb_sums':sums,'source_frame_id':(frames-1)&65535,
              'mode_flags':(pattern<<4)|(int(bypass)<<2)|(int(gamma)<<1)|int(blc_bypass)|(int(bayer_bypass)<<3)|(int(awb_bypass)<<6)|(int(ccm_bypass)<<7)}
    for key,value in expected.items():
        if decoded[key]!=value:raise ValueError(f'{key}: captured={decoded[key]!r}, expected={value!r}')
    return decoded
