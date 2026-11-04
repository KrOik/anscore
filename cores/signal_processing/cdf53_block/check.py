#!/usr/bin/env python3
"""Finite source compilation and deterministic Icarus checks; no synthesis."""
import hashlib
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def transform(values, inverse):
    """Independent split-band list implementation with unbounded integers."""
    if len(values) == 1:
        return values[:], []
    low_len = (len(values) + 1) // 2
    touched = []
    if not inverse:
        low, high = values[::2], values[1::2]
        high = [v - (low[i] + low[min(i+1, len(low)-1)]) // 2
                for i, v in enumerate(high)]
        touched += high
        low = [v + (high[max(0, i-1)] + high[min(i,len(high)-1)] + 2) // 4
               for i, v in enumerate(low)]
        touched += low
        return low + high, touched
    low, high = values[:low_len], values[low_len:]
    low = [v - (high[max(0, i-1)] + high[min(i,len(high)-1)] + 2) // 4
           for i, v in enumerate(low)]
    touched += low
    high = [v + (low[i] + low[min(i+1,len(low)-1)]) // 2
            for i, v in enumerate(high)]
    touched += high
    return [v for i in range(len(high)) for v in (low[i],high[i])] + low[len(high):], touched


def main():
    (ROOT/'verification.json').unlink(missing_ok=True)
    results = []
    bundled = ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite'
    if (bundled/'bin/iverilog.exe').is_file():
        os.environ['PATH'] = str(bundled/'bin')+os.pathsep+str(bundled/'lib')+os.pathsep+os.environ['PATH']
    tools = {t: shutil.which(t) for t in ("iverilog", "vvp")}
    if not all(tools.values()):
        raise SystemExit("NOT_RUN: requires iverilog and vvp on PATH")
    print(subprocess.run([tools['iverilog'],'-V'],capture_output=True,text=True,timeout=10).stdout.splitlines()[0])
    def run(cmd, cwd):
        result = subprocess.run(cmd,cwd=cwd,capture_output=True,text=True,timeout=15)
        if result.returncode:
            raise RuntimeError(result.stdout+result.stderr)
        return result.stdout.strip(), result.stderr.strip()
    with tempfile.TemporaryDirectory(prefix="anscore_cdf53_") as temp:
        path = Path(temp)
        lint_cmd = [tools['iverilog'],'-g2012','-Wall','-tnull','-s','cdf53_roundtrip',
                    str(ROOT/'rtl/cdf53_block.sv'),str(ROOT/'examples/cdf53_roundtrip.sv')]
        lint_out, lint_err=run(lint_cmd,path)
        results.append({'check':'source_and_example_compile','status':'PASS','command':lint_cmd,'stderr':lint_err})
        for param,value in [('SAMPLE_W',1),('SAMPLE_W',25),('BLOCK_LEN',0),('BLOCK_LEN',257),('INVERSE',2)]:
            cmd=[tools['iverilog'],'-g2012','-tnull','-s','cdf53_block',
                 f'-Pcdf53_block.{param}={value}',str(ROOT/'rtl/cdf53_block.sv')]
            rejected=subprocess.run(cmd,cwd=path,capture_output=True,text=True,timeout=15)
            if rejected.returncode==0 or 'cdf53_invalid_parameter__see_README' not in rejected.stderr:
                raise RuntimeError('illegal parameter not rejected: '+str(cmd)+rejected.stderr)
            results.append({'check':'illegal_parameter_rejection','parameter':param,'value':value,'status':'PASS'})
        for width,length in [(2,1),(2,2),(3,3),(8,5),(8,16),(16,16),(16,17),(16,256),(24,7)]:
            rng=random.Random(53000+width*1000+length)
            limit=1<<(width-1); cw=width+2; cm=1<<(cw-1)
            cases=[[0]*length,[limit-1]*length,[-limit]*length,
                   [limit-1 if i%2 else -limit for i in range(length)],
                   [(-1 if i%2 else 0) for i in range(length)]]
            cases += [[rng.randrange(-limit,limit) for _ in range(length)] for _ in range(3)]
            for values in cases:
                assert transform(transform(values,False)[0],True)[0] == values
            for inverse in (0,1):
                inputs=[transform(x,False)[0] if inverse else x for x in cases]
                # Invalid forward source and extreme arbitrary inverse coeffs
                # exercise declared range-error and output saturation behavior.
                inputs += [[cm-1 if i%2 else -cm for i in range(length)],
                           [cm-1]*length]
                expected=[]; errors=[]
                for values in inputs:
                    out,touched=transform(values,bool(inverse))
                    error=(not inverse and any(not -limit<=x<limit for x in values)) or any(not -cm<=x<cm for x in touched+out)
                    expected += [min(cm-1,max(-cm,x)) for x in out]
                    errors += [int(error)]*length
                for name,values in [('input',sum(inputs,[])),('expected',expected),('error',errors)]:
                    (path/(name+'.mem')).write_text(''.join(f'{v&((1<<cw)-1):x}\n' for v in values))
                compile_cmd=[tools['iverilog'],'-g2012','-Wall','-s','tb_cdf53_block',
                             f'-Ptb_cdf53_block.SAMPLE_W={width}',f'-Ptb_cdf53_block.BLOCK_LEN={length}',
                             f'-Ptb_cdf53_block.INVERSE={inverse}',f'-Ptb_cdf53_block.BLOCKS={len(inputs)}',
                             '-o',str(path/'test.vvp'),str(ROOT/'rtl/cdf53_block.sv'),str(ROOT/'sim/tb_cdf53_block.sv')]
                _,stderr=run(compile_cmd,path)
                output,simerr=run([tools['vvp'],str(path/'test.vvp')],path)
                if 'PASS samples=' not in output: raise RuntimeError(output)
                result={'sample_w':width,'block_len':length,'inverse':inverse,'status':'PASS','result':output,'compile_stderr':stderr,'sim_stderr':simerr}
                results.append(result); print(result)
        cmd=[tools['iverilog'],'-g2012','-Wall','-s','tb_cdf53_roundtrip','-o',str(path/'chain.vvp'),
             str(ROOT/'rtl/cdf53_block.sv'),str(ROOT/'examples/cdf53_roundtrip.sv'),str(ROOT/'sim/tb_cdf53_roundtrip.sv')]
        _,stderr=run(cmd,path)
        output,simerr=run([tools['vvp'],str(path/'chain.vvp')],path)
        if 'PASS roundtrip samples=64' not in output: raise RuntimeError(output)
        results.append({'check':'forward_inverse_connected_example','status':'PASS','result':output,'stderr':stderr+simerr})
        print(output)
    hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in [ROOT/'files.f',ROOT/'rtl/cdf53_block.sv',ROOT/'sim/tb_cdf53_block.sv',ROOT/'sim/tb_cdf53_roundtrip.sv',ROOT/'examples/cdf53_roundtrip.sv',Path(__file__)]}
    report={'scope':['iverilog -tnull','finite deterministic unit simulation'],'status':['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],
            'checked_at_utc':datetime.now(timezone.utc).isoformat(),
            'source_sha256':hashes,'checks':results,'not_run':['synthesis','place_and_route','STA','hardware'],
            'reproduce':'python -B cores/signal_processing/cdf53_block/check.py','per_process_timeout_seconds':15}
    (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__': main()
