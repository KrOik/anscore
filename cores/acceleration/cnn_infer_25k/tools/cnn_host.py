"""Transport-neutral complete CNN loading and exact per-layer readback acceptance."""
import hashlib
import json
from pathlib import Path
import time
import math
import re
from model import validate,infer,model_hash

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
TAPS=('conv1_acc','conv1_quant','pool1','conv2_acc','conv2_quant','pool2','scores','top3')


def validate_build(path):
    build=json.loads(path.read_text())
    if build['status']!='PASS' or build['target']!='GW5A-LV25MG121NES' or build['clock_mhz']!=50:
        raise ValueError('requires completed50MHz25K build')
    if any(c['achieved']<50 or c['constraint']!=50 for c in build['pnr_report']['fmax'].values()) or not build['pnr_report']['fmax']:
        raise ValueError('physical timing not closed')
    if hashlib.sha256((path.parent/'cnn.fs').read_bytes()).hexdigest()!=build['bitstream_sha256']:
        raise ValueError('packed image hash mismatch')
    for name,digest in build['sources'].items():
        if hashlib.sha256((ROOT/name).read_bytes()).hexdigest()!=digest:raise ValueError('current source differs: '+name)
    fingerprint=hashlib.sha256(json.dumps(build['sources'],sort_keys=True,separators=(',',':')).encode()).hexdigest()[:16]
    if fingerprint!=build['hardware_build_id']:raise ValueError('build fingerprint manifest mismatch')
    return build


def fixture(path):
    manifest=json.loads((path/'manifest.json').read_text())
    if manifest['schema']!='cnn25k_export_v1':raise ValueError('fixture schema')
    for name,digest in manifest['files'].items():
        # Converter emits flat filenames only; do not follow arbitrary paths.
        if Path(name).name!=name or '/' in name or '\\' in name:raise ValueError('fixture path')
        if hashlib.sha256((path/name).read_bytes()).hexdigest()!=digest:raise ValueError('fixture hash: '+name)
    model=json.loads((path/'model.json').read_text());validate(model)
    if model_hash(model)!=manifest['model_sha256']:raise ValueError('model hash')
    names=manifest['inputs']
    if not names or any(not isinstance(n,str) or not re.fullmatch(r'[A-Za-z0-9_]+',n) for n in names) or len(names)!=len(set(names)):
        raise ValueError('fixture input names')
    inputs={name:json.loads((path/(name+'.json')).read_text())['input'] for name in names}
    for image in inputs.values():infer(model,image)  # validate before opening hardware
    return model,inputs


def identify(bus,expected_id):
    if bus.access(0)!=0x434e4e31:raise ValueError('CNN CSR identifier')
    actual=bus.access(0x30)|(bus.access(0x34)<<32)
    if expected_id==0 or actual!=expected_id:raise ValueError('loaded configuration fingerprint mismatch')


def load_region(bus,region,values):
    bus.access(8,region)
    for value in values:bus.access(0x10,value&0xffffffff if region==2 else value&255)
    if bus.access(0x0c)!=len(values):raise ValueError('loader cursor mismatch')


def load_model(bus,model,expected_id):
    validate(model);identify(bus,expected_id)
    if bus.access(4)&7!=3:raise ValueError('CNN must be idle without held completion')
    load_region(bus,1,model['conv1']+model['conv2']+model['dense'])
    load_region(bus,2,model['bias1']+model['bias2']+model['bias3'])


def run_case(bus,model,image,expected_id,save,timeout=10.0,max_polls=10000):
    if not math.isfinite(timeout) or timeout<=0 or type(max_polls) is not int or max_polls<1:raise ValueError('invalid poll bounds')
    golden=infer(model,image);identify(bus,expected_id)
    if bus.access(4)&7!=3:raise ValueError('CNN runner not idle')
    load_region(bus,0,image);bus.access(0x14,1)
    deadline=time.monotonic()+timeout
    for _ in range(max_polls):
        status=bus.access(4)
        if status&4:break
        if time.monotonic()>=deadline:raise TimeoutError('CNN completion timeout')
        time.sleep(0.001)
    else:raise TimeoutError('CNN completion poll limit')
    if status&0xf0 or bus.access(0x20)!=0:raise ValueError('CNN engine error')
    if bus.access(0x1c)!=10597:raise ValueError('incomplete layer capture')
    cycles=bus.access(0x18)
    if cycles==0:raise ValueError('invalid measured run cycles')
    capture=dict(schema='cnn25k_layers_v1',build_id=f'{expected_id:016x}',model_sha256=model_hash(model),
                 clock_hz=50000000,run_cycles=cycles,values=[],status='READING')
    bus.access(0x24,0)
    for index in range(10597):
        value=bus.access(0x28)
        if type(value) is not int or not 0<=value<1<<32:raise ValueError('invalid CSR word')
        capture['values'].append(value-(1<<32) if value&0x80000000 else value)
        if index%256==255:save(capture)
    capture['status']='CAPTURED';save(capture)
    expected=sum((golden[name] for name in TAPS),[])
    if capture['values']!=expected:
        index=next(i for i,(a,b) in enumerate(zip(capture['values'],expected)) if a!=b)
        raise ValueError(f'layer value mismatch index={index}: {capture["values"][index]} vs {expected[index]}')
    identify(bus,expected_id)
    if bus.access(4)!=status or bus.access(0x18)!=cycles or bus.access(0x1c)!=10597:
        raise ValueError('completion changed during readback')
    capture.update(status='PASS',scores=golden['scores'],top3=golden['top3'],
                   nominal_latency_seconds=cycles/50000000,
                   nominal_compute_inferences_per_second=50000000/cycles)
    save(capture)
    bus.access(0x14,2)
    return capture
