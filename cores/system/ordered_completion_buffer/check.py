#!/usr/bin/env python3
"""Bounded offline source and unit checks; never launches synthesis."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent


def main():
    report_path=ROOT/'verification.json'
    report_path.unlink(missing_ok=True)
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite'
    env=os.environ.copy()
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','')
    tool={name:os.environ.get(name.upper()) or shutil.which(name,path=env['PATH'])
          for name in ('iverilog','vvp')}
    if not all(tool.values()):
        raise SystemExit('NOT_RUN: local iverilog and vvp required')
    records=[]
    temporary=''

    def run(args,expect_rejection=False):
        command=[tool[args[0]],*args[1:]]
        record={'command':args,'timeout_seconds':20}
        try:
            result=subprocess.run(command,cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired:
            record['status']='NOT_RUN_TIMEOUT';records.append(record)
            raise RuntimeError('NOT_RUN_TIMEOUT: check stopped')
        record.update(exit_code=result.returncode,stdout=result.stdout.strip(),stderr=result.stderr.strip())
        passed=(result.returncode!=0 and 'ordered_completion_buffer_invalid_parameters' in result.stderr) if expect_rejection else result.returncode==0
        record['status']='PASS' if passed else 'FAIL'
        records.append(record)
        if not passed: raise RuntimeError(result.stdout+result.stderr)
        return result.stdout.strip()

    passed=False
    try:
        version=run(['iverilog','-V']).splitlines()[0]
        print(version,flush=True)
        run(['iverilog','-g2012','-Wall','-tnull','-s','ordered_completion_buffer','-f','files.f'])
        run(['iverilog','-g2012','-Wall','-tnull','-s','ordered_worker_results','-f','files.f',
             'examples/ordered_worker_results.sv'])
        for parameter,value in [('DEPTH',0),('DEPTH',65),('DATA_W',0),('META_W',0)]:
            run(['iverilog','-g2012','-tnull','-s','ordered_completion_buffer',
                 f'-Pordered_completion_buffer.{parameter}={value}','-f','files.f'],True)
        with tempfile.TemporaryDirectory(prefix='anscore_ordered_completion_') as temporary:
            for depth,data_w,meta_w in [(1,1,1),(3,8,5),(8,32,16),(17,64,32)]:
                image=str(Path(temporary)/'unit.vvp')
                run(['iverilog','-g2012','-Wall','-s','tb_ordered_completion_buffer',
                     f'-Ptb_ordered_completion_buffer.DEPTH={depth}',
                     f'-Ptb_ordered_completion_buffer.DATA_W={data_w}',
                     f'-Ptb_ordered_completion_buffer.META_W={meta_w}',
                     '-o',image,'-f','files.f','sim/tb_ordered_completion_buffer.sv'])
                output=run(['vvp',image])
                if f'PASS depth={depth} data={data_w} meta={meta_w}' not in output:
                    raise RuntimeError('unit test did not emit completion marker')
                print(output,flush=True)
        passed=True
    finally:
        sources=['.gitattributes','files.f','rtl/ordered_completion_buffer.sv',
                 'examples/ordered_worker_results.sv','sim/tb_ordered_completion_buffer.sv','check.py']
        for record in records:
            record['command']=[a.replace(temporary,'<temporary>') if temporary else a for a in record['command']]
        report={'scope':'Icarus syntax/elaboration and finite deterministic unit checks',
                'status':['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'] if passed else ['RTL_CANDIDATE','HW_UNVERIFIED'],
                'tools':tool,'checks':records,
                'source_sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources},
                'not_run':['synthesis','place_and_route','STA','hardware']}
        report_path.write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__':
    main()
