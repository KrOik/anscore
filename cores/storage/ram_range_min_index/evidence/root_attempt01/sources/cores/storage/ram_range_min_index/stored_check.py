"""Stored tuple/hash/shape validation only. Never imports or calls the oracle."""
from pathlib import Path
import hashlib,json,sys
ROOT=Path(__file__).resolve().parent
def main():
    if sys.flags.optimize:raise RuntimeError('optimized Python forbidden')
    receipt=json.loads((ROOT/'prepared/receipt.json').read_bytes())
    for n,h in receipt['files_sha256'].items():assert hashlib.sha256((ROOT/n).read_bytes()).hexdigest()==h,n
    raw=json.loads((ROOT/'RAW_INPUTS.json').read_bytes())
    for p in raw['profiles']:
        programs=[('main',p['commands'])]
        for j in p['reset_jobs']:
            programs.extend([('pre_'+j['name'],j['preload']),('fresh_'+j['name'],j['fresh'])])
            control=ROOT/'prepared/fixtures'/p['name']/('cancel_'+j['name']+'.txt')
            assert control.read_bytes()==(' '.join(map(str,j['cancel_command']))+'\n').encode()
        for name,commands in programs:
            rows=json.loads((ROOT/'prepared/fixtures'/p['name']/(name+'.json')).read_bytes())
            assert len(rows)==len(commands)
            assert [x['name'] for x in rows]==[x[0] for x in commands]
            assert [x['command'] for x in rows]==[x[1:] for x in commands]
            assert all(len(x['response'])==5 for x in rows)
            expected=str(len(rows))+'\n'+''.join(' '.join(map(str,x['command']+x['response']))+'\n' for x in rows)
            assert (ROOT/'prepared/fixtures'/p['name']/(name+'.txt')).read_bytes()==expected.encode()
    print('PASS STORED HASHES NO_ORACLE_REEXECUTION',flush=True)
if __name__=='__main__':main()
