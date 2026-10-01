"""Full-log warning gate and mapped-netlist check without resynthesis."""
import argparse,datetime,hashlib,json,os,re,shutil,subprocess
from pathlib import Path

def audit(build,tool):
    build=Path(build).resolve();tool=Path(tool).resolve()
    if (build/'structural_audit.json').exists():
        history=build/('audit_history_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'));history.mkdir()
        for name in ('structural_audit.json','mapped_check.log','mapped_check.ys'):
            if (build/name).exists():shutil.copy2(build/name,history/name)
    evidence={'status':'FAIL','files':{},'warnings':{},'rejected':[]}
    for name in ('yosys.log','nextpnr.log'):
        path=build/name;text=path.read_text(errors='replace')
        evidence['files'][name]=hashlib.sha256(path.read_bytes()).hexdigest()
        warnings=[line for line in text.splitlines() if re.search(r'\b(?:warning|error)\s*:',line,re.I)]
        evidence['warnings'][name]=warnings
        for line in warnings:
            allowed=name=='yosys.log' and line.startswith('Warning: Replacing memory ') and ' with list of registers.' in line
            # ABC maps combinational partitions between sequential boxes; these
            # informational warnings do not report a combinational feedback loop.
            if name=='yosys.log' and (line=='ABC: Warning: The network is combinational.' or re.fullmatch(r'ABC: Warning: AIG with boxes has internal fanout in 0 complex flops and \d+ carries\.',line)):
                allowed=True
            if not allowed:evidence['rejected'].append(name+': '+line)
        for line in text.splitlines():
            if re.search(r'found logic loop|combinational loop|^Latch inferred|unconstrained|no clocks? (?:found|defined)|no timing constraints',line,re.I):
                evidence['rejected'].append(name+': '+line)
    env=os.environ.copy();env['PATH']=str(tool/'bin')+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
    script='read_json top.json; hierarchy -top dsp_chain_harness; check -assert'
    (build/'mapped_check.ys').write_text(script+'\n')
    with (build/'mapped_check.log').open('w') as log:
        result=subprocess.run([str(tool/'bin/yosys.exe'),'-Q','mapped_check.ys'],cwd=build,env=env,stdout=log,stderr=subprocess.STDOUT)
    evidence['mapped_check_exit']=result.returncode
    evidence['files']['top.json']=hashlib.sha256((build/'top.json').read_bytes()).hexdigest()
    if result.returncode:evidence['rejected'].append('mapped check -assert failed')
    if not evidence['rejected']:evidence['status']='PASS'
    (build/'structural_audit.json').write_text(json.dumps(evidence,indent=2)+'\n')
    if evidence['status']!='PASS':raise AssertionError(evidence['rejected'])
    return evidence

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('build',type=Path);a=p.parse_args()
    root=Path(__file__).resolve().parents[4]
    result=audit(a.build,root/'tools/oss-cad-suite/oss-cad-suite')
    print('STRUCTURAL AUDIT',result['status'],a.build)
