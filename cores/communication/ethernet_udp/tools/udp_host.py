"""Transport-neutral bounded acceptance of finite UDP/RMII controlled replay."""
import math
import hashlib
import json
from pathlib import Path
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
import time
import zlib


def config(packets, length, seed, timeout, run_id):
    if any(type(v) is not int for v in (packets,length,seed,timeout,run_id)):
        raise ValueError('integer configuration required')
    if not 1<=packets<=65535 or not 4<=length<=1472 or not 0<=seed<2**32 or not 0<timeout<2**32 or not 0<=run_id<2**32:
        raise ValueError('configuration range')
    if packets*length>16*1024*1024:
        raise ValueError('host acceptance profile limited to16MiB per run')
    return [packets|(length<<16),seed,timeout,0,run_id,0,0,0]


def golden_crc(words):
    packets=words[0]&65535;length=words[0]>>16;seed=words[1]
    crc=0
    for packet in range(packets):
        data=bytes((packet>>(8*n))&255 if n<4 else ((seed&255)+(packet&255)*17+(n&255)*29)&255 for n in range(length))
        crc=zlib.crc32(data,crc)
    return crc


def identify(bus, build_id):
    if type(build_id) is not int or not 0<build_id<2**64 or bus.access(0)!=0x55445031:
        raise ValueError('UDP identity')
    if bus.access(20)|(bus.access(24)<<32)!=build_id:
        raise ValueError('loaded build fingerprint differs')


def run_case(bus, words, build_id, save, seconds=10, max_polls=10000):
    if not math.isfinite(seconds) or seconds<=0 or type(max_polls) is not int or max_polls<1:
        raise ValueError('bounded positive polling required')
    if len(words)!=8 or words!=config(words[0]&65535,words[0]>>16,words[1],words[2],words[4]):
        raise ValueError('requires normal canonical acceptance configuration')
    expected_crc=golden_crc(words);packets=words[0]&65535;length=words[0]>>16
    identify(bus,build_id)
    if bus.access(4)!=9:raise ValueError('requires idle without pending/held operation')
    version=bus.access(8)
    for n,word in enumerate(words):bus.access(0x40+4*n,word)
    bus.access(12,1);deadline=time.monotonic()+seconds
    for _ in range(max_polls):
        status=bus.access(4)
        if status&2:break
        if time.monotonic()>=deadline:raise TimeoutError('completion timeout; no automatic retry/ACK')
        time.sleep(.001)
    else:raise TimeoutError('completion poll limit')
    capture=dict(status='READING',build_id=f'{build_id:016x}',configuration=words,words={})
    save(capture)
    for address in range(0x80,0xa4,4):
        value=bus.access(address)
        if type(value) is not int or not 0<=value<2**32:raise ValueError('invalid CSR word')
        capture['words'][f'{address:02x}']=value;save(capture)
    w=capture['words']
    expected={'80':words[4],'84':0,'8c':packets,'90':packets,'94':packets*length,'98':packets*length,'9c':expected_crc,'a0':expected_crc}
    if any(w[k]!=v for k,v in expected.items()) or not 0<w['88']<words[2]:
        raise ValueError('result identity/error/count/CRC/cycles differ')
    identify(bus,build_id)
    if bus.access(8)!=(version+1)%2**32 or bus.access(4)!=status or bus.access(0x80)!=w['80']:
        raise ValueError('incoherent held result')
    capture['status']='VERIFIED';save(capture)
    bus.access(16,1)
    capture['status']='ACKNOWLEDGED';save(capture)
    return capture


def validate_build(path):
    build=json.loads(path.read_text())
    if build['status']!='PASS' or build['target']!='GW5A-LV25MG121NES' or build['clock_mhz']!=50:
        raise ValueError('requires completed50MHz25K build')
    if any(c['achieved']<50 or c['constraint']!=50 for c in build['pnr_report']['fmax'].values()) or not build['pnr_report']['fmax']:
        raise ValueError('physical timing not closed')
    if hashlib.sha256((path.parent/'udp.fs').read_bytes()).hexdigest()!=build['bitstream_sha256']:
        raise ValueError('packed image hash mismatch')
    for name,digest in build['sources'].items():
        if hashlib.sha256((ROOT/name).read_bytes()).hexdigest()!=digest:raise ValueError('current source differs: '+name)
    fingerprint=hashlib.sha256(json.dumps(build['sources'],sort_keys=True,separators=(',',':')).encode()).hexdigest()[:16]
    if fingerprint!=build['hardware_build_id']:raise ValueError('build fingerprint manifest mismatch')
    return build

