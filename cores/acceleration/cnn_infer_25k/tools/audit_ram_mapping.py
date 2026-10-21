"""Check narrow DPB warning cones in a frozen CNN netlist; not hardware proof."""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path


def audit(module):
    cells=module['cells'];consumers=defaultdict(list);constants={}
    for name,cell in cells.items():
        if cell['type'] in ('GND','VCC'):
            for port,bits in cell['connections'].items():
                if cell['port_directions'][port]=='output':
                    for bit in bits:constants[bit]='0' if cell['type']=='GND' else '1'
        for port,bits in cell['connections'].items():
            if cell['port_directions'][port]=='input':
                for bit in bits:consumers[bit].append(name+'.'+port)
    for name,port in module.get('ports',{}).items():
        if port['direction']=='output':
            for bit in port['bits']:consumers[bit].append('top.'+name)
    checked=[]
    for name,cell in cells.items():
        if cell['type']!='DPB':continue
        widths=[int(cell['parameters'][p],2) for p in ('BIT_WIDTH_0','BIT_WIDTH_1')]
        if widths!=[4,4]:raise ValueError('unexpected DPB geometry '+name)
        record=dict(cell=name,widths=widths,ports={})
        for suffix in ('A','B'):
            bits=cell['connections']['DI'+suffix]
            write=cell['connections']['WRE'+suffix][0]
            enabled=constants.get(write,write)!='0'
            if enabled and any(constants.get(b,b)=='x' for b in bits[:4]):
                raise ValueError('unknown live write data '+name)
            output=cell['connections']['DO'+suffix]
            if any(consumers[b] for b in output[4:]):raise ValueError('narrow RAM high output consumed '+name)
            record['ports'][suffix]=dict(write_disabled=not enabled,active_width=4,high_outputs_unused=True)
        checked.append(record)
    if len(checked)!=2:raise ValueError('expected two narrow fmap DPBs')
    return checked


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('build',type=Path);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--top',default='cnn_serial_engine')
    args=p.parse_args();args.output.mkdir(parents=True,exist_ok=False)
    report=dict(status='FAIL',physical_measurement=False,scope='narrow DPB live-bit/disabled-write audit; not full primitive equivalence')
    try:
        design=args.build/'design.json';summary=json.loads((args.build/'summary.json').read_text())
        if summary['status']!='PASS':raise ValueError('synthesis not passed')
        report['netlist_sha256']=hashlib.sha256(design.read_bytes()).hexdigest()
        report['auditor_sha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        report['checked']=audit(json.loads(design.read_text())['modules'][args.top])
        report['status']='PASS';print('PASS narrow DPB warning cone audit')
    except Exception as exc:
        report['reason']=str(exc);raise
    finally:(args.output/'summary.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
