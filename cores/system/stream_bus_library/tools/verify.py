"""Native-interface cocotb regressions, with immutable evidence directories."""
import argparse
import json
import os
import sys
import xml.etree.ElementTree as ET
from common import ROOT, CORES, env, evidence, hashes

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--cores',default=','.join(c[0] for c in CORES))
    a=ap.parse_args()
    os.environ.update(env())
    sys.path.insert(0,str(ROOT/'sim'))
    sys.path.insert(0,str(ROOT/'models'))
    from cocotb_tools.runner import get_runner
    out=evidence('sim')
    summary={'status':'IN_PROGRESS','sources':hashes(),'tests':[]}
    try:
        for name in a.cores.split(','):
            variants=[{}]
            if name=='width_converter': variants=[{'MODE':0},{'MODE':1}]
            if name=='packet_async_fifo': variants=[{'DEPTH':8}]
            if name=='trigger_window': variants=[{}, {'PRE':0,'POST':0}]
            if name=='march_controller': variants=[{'DEPTH':8,'TIMEOUT':16}]
            if name=='capture_replay': variants=[{'DEPTH':32,'TIMEOUT':128}]
            for params in variants:
                tag=name+''.join('_'+str(k)+str(v) for k,v in params.items())
                d=out/tag
                runner=get_runner('icarus')
                runner.build(sources=[ROOT/'rtl'/('sys_'+name+'.v')],hdl_toplevel='sys_'+name,
                             parameters=params,build_dir=d,timescale=('1ns','1ps'),
                             build_args=['-g2012'],log_file=out/(tag+'_compile.log'))
                xml=runner.test(test_module='native_tests',hdl_toplevel='sys_'+name,
                            build_dir=d,test_dir=ROOT/'sim',results_xml=str(out/(tag+'.xml')),
                            extra_env={'SYS_CORE':name,'SYS_PARAMS':json.dumps(params),
                                       'PYTHONPATH':os.pathsep.join([str(ROOT/'sim'),str(ROOT/'models')])},
                            log_file=out/(tag+'_run.log'))
                cases=ET.parse(xml).getroot().findall('.//testcase')
                assert cases and not any(c.find('failure') is not None or c.find('error') is not None for c in cases),tag
                summary['tests'].append({'core':name,'parameters':params,'status':'PASS'})
                print(tag+' PASS',flush=True)
                (out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
        summary['status']='PASS'
    except Exception as e:
        summary['status']='FAIL'; summary['reason']=str(e)
        raise
    finally:
        (out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
        print('Evidence='+str(out),flush=True)

if __name__=='__main__': main()
