"""Executable mutations prove structural warning gates reject unsafe reports."""
import argparse,datetime,json,shutil
from pathlib import Path
from audit_build import audit

def main():
    p=argparse.ArgumentParser();p.add_argument('build',type=Path);a=p.parse_args()
    here=Path(__file__).resolve().parent;root=here.parents[3]
    out=here/'evidence'/datetime.datetime.now().strftime('audit_negative_%Y%m%d_%H%M%S_%f');out.mkdir()
    reports=[]
    for name,warning in [('loop','Warning: found logic loop in module injected'),('latch','Warning: Latch inferred for signal injected'),('clock','Warning: No clocks found in design!')]:
        case=out/name;case.mkdir()
        for filename in ('yosys.log','nextpnr.log','top.json'):shutil.copy2(a.build/filename,case/filename)
        with (case/'yosys.log').open('a') as log:log.write('\n'+warning+'\n')
        try:audit(case,root/'tools/oss-cad-suite/oss-cad-suite')
        except AssertionError:reports.append(dict(case=name,status='REJECTED'))
        else:raise AssertionError('Unsafe warning accepted: '+name)
    (out/'summary.json').write_text(json.dumps(dict(status='PASS',mutations=reports),indent=2))
    print('AUDIT NEGATIVE PASS',out)

if __name__=='__main__':main()
