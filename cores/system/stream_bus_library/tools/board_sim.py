import argparse
import os
import sys
import json
import xml.etree.ElementTree as ET
from common import ROOT,CORES,env,evidence,hashes

def sources(profile,half_cycle_rom=False,phase_capture=False):
    files=list((ROOT/'rtl').glob('*.v'))+list((ROOT/'board').glob('*.v'))
    if half_cycle_rom:
        assert profile==8,'phase-adjusted ROM only applies to profile8'
        files.remove(ROOT/'board/sys_auto_vectors_8.v'); files.append(ROOT/'diagnostics/auto_8_hold_safe.v')
    if phase_capture:
        files.remove(ROOT/'board/sys_auto_top.v'); files.append(ROOT/'diagnostics/sys_auto_top_phase.v')
    if 1<=profile<=7:
        sys.path.insert(0,str(ROOT.parent/'production_ip_25k/tools'))
        from catalog import CORES as OLD
        files+=[ROOT.parent/'production_ip_25k/rtl'/('prod_'+e['name']+'.v') for e in OLD[(profile-1)*8:profile*8]]
    return files

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--profiles',default='0,1,2,3,4,5,6,7'); ap.add_argument('--adapters',action='store_true'); ap.add_argument('--auto',action='store_true'); ap.add_argument('--half-cycle-rom',action='store_true'); ap.add_argument('--phase-capture',action='store_true'); a=ap.parse_args()
    os.environ.update(env()); sys.path[:0]=[str(ROOT/'sim'),str(ROOT/'models')]
    from cocotb_tools.runner import get_runner
    out=evidence('auto_sim' if a.auto else ('adapter_sim' if a.adapters else 'board_sim')); summary={'status':'IN_PROGRESS','sources':hashes(),'profiles':[],'half_cycle_rom':a.half_cycle_rom,'phase_capture':a.phase_capture}
    try:
        for p in map(int,a.profiles.split(',')):
            r=get_runner('icarus'); d=out/str(p)
            top='tb_auto_top' if a.auto else ('tb_adapters' if a.adapters else 'tb_sys_top')
            params={'PROFILE':p} if (a.adapters or a.auto) else {'PROFILE':p,'BIT_CYCLES':12}
            r.build(sources=sources(p,a.half_cycle_rom,a.phase_capture)+[ROOT/'sim'/(top+'.v')],hdl_toplevel=top,parameters=params,
                    build_dir=d,timescale=('1ns','1ps'),build_args=['-g2012'],log_file=out/f'{p}_compile.log')
            xml=r.test(test_module='auto_tests' if a.auto else ('adapter_tests' if a.adapters else 'board_tests'),hdl_toplevel=top,build_dir=d,test_dir=ROOT,
                 results_xml=str(out/f'{p}.xml'),extra_env={'SYS_PROFILE':str(p),'PYTHONPATH':os.pathsep.join([str(ROOT/'models'),str(ROOT/'sim')])},
                 log_file=out/f'{p}_run.log')
            cases=ET.parse(xml).getroot().findall('.//testcase')
            assert cases and not any(c.find('failure') is not None for c in cases),'profile'+str(p)
            summary['profiles'].append({'profile':p,'status':'PASS'})
            (out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n'); print('BOARD SIM profile='+str(p)+' PASS',flush=True)
        summary['status']='PASS'
    except Exception as e: summary['status']='FAIL'; summary['reason']=str(e); raise
    finally:
        (out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n'); print('Evidence='+str(out))

if __name__=='__main__': main()
