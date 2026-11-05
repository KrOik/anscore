"""One future separately approved finite preparation; refuses existing output."""
from __future__ import annotations
import argparse,hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    if sys.flags.optimize:raise RuntimeError('optimized Python forbidden')
    parser=argparse.ArgumentParser();parser.add_argument('--approved-author',required=True);a=parser.parse_args()
    author=ROOT/'AUTHOR_INPUTS.json';assert sha(author)==a.approved_author
    frozen=json.loads(author.read_bytes())
    for n,h in frozen['sources'].items():assert sha(ROOT/n)==h,n
    for n,h in frozen['external_sources'].items():assert sha(ROOT.parents[2]/n)==h,n
    output=ROOT/'prepared';output.mkdir(exist_ok=False)
    with (output/'LOCK.json').open('x',encoding='utf-8') as f:json.dump({'status':'STARTED_ONCE','author_sha256':a.approved_author},f)
    sys.dont_write_bytecode=True
    from oracle import evaluate,reset_commands
    raw=json.loads((ROOT/'RAW_INPUTS.json').read_bytes());inventory={};counts={}
    def save(profile,name,program):
        answers=evaluate(program,profile['capacity'])
        folder=output/'fixtures'/profile['name'];folder.mkdir(parents=True,exist_ok=True)
        obj=folder/(name+'.json');txt=folder/(name+'.txt')
        with obj.open('x',encoding='utf-8',newline='\n') as f:json.dump(answers,f,indent=2);f.write('\n')
        with txt.open('x',encoding='utf-8',newline='\n') as f:
            f.write(str(len(answers))+'\n')
            for c in answers:
                f.write(' '.join(map(str,c['command']+[len(c['responses'])]))+'\n')
                for row in c['responses']:f.write(' '.join(map(str,row))+'\n')
        for path in [obj,txt]:inventory[path.relative_to(ROOT).as_posix()]=sha(path)
        return {'commands':len(answers),'records':sum(len(x['responses']) for x in answers)}
    for p in raw['profiles']:
        pc={'main':save(p,'main',p['commands']),'resets':{}}
        for target in raw['reset_targets'][p['name']]:
            pc['resets'][target]=save(p,'reset_'+target,reset_commands(p,target))
        counts[p['name']]=pc
    for n,h in frozen['sources'].items():assert sha(ROOT/n)==h,n
    for n,h in frozen['external_sources'].items():assert sha(ROOT.parents[2]/n)==h,n
    receipt={'status':'PREPARED_FIXED_FINITE','author_sha256':a.approved_author,'files_sha256':inventory,
             'counts':counts,'preparation_invocations':1,'oracle_passes':'one evaluate per frozen named program',
             'input_expansion':False,'automatic_retry':False,'hardware':'HW_UNVERIFIED'}
    with (output/'receipt.json').open('x',encoding='utf-8',newline='\n') as f:json.dump(receipt,f,indent=2);f.write('\n')
    print('PASS PREPARATION FIXED_PROGRAMS',flush=True)
if __name__=='__main__':main()
