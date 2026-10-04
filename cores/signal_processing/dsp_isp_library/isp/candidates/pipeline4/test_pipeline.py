"""Four-cycle candidate regression; transaction model never reads RTL output."""
import datetime,itertools,json,os,random,subprocess,sys,hashlib
from pathlib import Path
HERE=Path(__file__).resolve().parent;ISP=HERE.parents[1];ROOT=ISP.parents[2]
sys.path.insert(0,str(ISP))
from csc_model import bit_exact
from test_csc_rtl import TB,packed,verify

def vectors(bits):
    rng=random.Random(bits+4709);m=(1<<bits)-1;pipe=[None]*4;active=0;pending=None;err=0;stim=[];expected=[];accepted=0
    def step(src=None,ready=1,cfg=None,reset=1):
        nonlocal pipe,active,pending,err,accepted
        out=pipe[-1];sr=out is None or ready;commit=bool(src and sr and src[1] and pending is not None);cr=pending is None or commit
        expected.append((int(sr),int(out is not None),*(out or (0,0,0)),int(cr),err))
        p,u,l=src or (0,0,0);stim.append((reset,int(src is not None),p,u,l,ready,int(cfg is not None),cfg or 0))
        if not reset:pipe=[None]*4;active=0;pending=None;err=0;return sr,cr
        selected=pending if src and src[1] and pending is not None else active
        if commit:active=pending;pending=None
        err=0
        if cfg is not None and cr:
            if cfg>>2==3:err=1
            else:pending=cfg
        if sr:
            new=None
            if src:
                result=bit_exact(((p>>(2*bits))&m,(p>>bits)&m,p&m),bits,('601','709')[(selected>>1)&1],bool(selected&1),('forward','inverse','gray')[selected>>2])
                new=(packed(result,bits),u,l);accepted+=1
            pipe=[new]+pipe[:-1]
        return sr,cr
    step(reset=0);step(reset=0)
    for config in range(12):
        while not step(cfg=config)[1]:pass
        samples=list(itertools.product((0,1,m//2,m-1,m),repeat=3))+[(v,v,v) for v in range(m+1)]+[tuple(rng.randrange(m+1) for _ in range(3)) for _ in range(200)]
        for i,p in enumerate(samples):
            src=(packed(p,bits),int(i==0 or i==128),int(i%16==15 or i==len(samples)-1))
            if i<128 and rng.random()<.3:step(ready=int(rng.random()<.7))
            while not step(src=src,ready=1 if i>=128 else int(rng.random()<.65),cfg=12 if i==30 else None)[0]:pass
        for _ in range(35):step(ready=0)
        for _ in range(6):step()
    step(cfg=5)
    for _ in range(3):step(src=(packed((m,0,0),bits),1,1))
    step(ready=0,reset=0)
    for _ in range(6):step()
    step(cfg=1);step(src=(0,1,1),cfg=6);step(src=(0,0,1));step(src=(0,1,1))
    step(cfg=2)
    for _ in range(10):step(src=(0,0,1),cfg=9)
    step(src=(0,1,1),cfg=9);step(src=(0,1,1))
    for _ in range(7):step()
    return stim,expected,accepted

def main():
    dest=HERE/'evidence'/datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f');dest.mkdir(parents=True)
    binpath=ROOT/'tools/oss-cad-suite/oss-cad-suite/bin';env=os.environ.copy();env['PATH']=str(binpath)+os.pathsep+str(binpath.parent/'lib')+os.pathsep+env['PATH'];results=[]
    for bits in (8,10):
        stim,expected,accepted=vectors(bits);(dest/'tb.v').write_text(TB)
        (dest/f'stim{bits}.txt').write_text(''.join(f'{r} {v} {p:x} {u} {l} {ready} {cv} {c:x}\n' for r,v,p,u,l,ready,cv,c in stim))
        commands=[[str(binpath/'iverilog.exe'),'-g2012','-Wall','-I',str(ISP),'-s','tb',f'-Ptb.BITS={bits}','-o',str(dest/'test.vvp'),str(HERE/'csc_stream.v'),str(dest/'tb.v')],[str(binpath/'vvp.exe'),str(dest/'test.vvp'),f'+stim={dest}/stim{bits}.txt',f'+trace={dest}/trace{bits}.txt']]
        for i,cmd in enumerate(commands):
            p=subprocess.run(cmd,env=env,capture_output=True,text=True);(dest/f'{bits}_{i}.log').write_text(p.stdout+p.stderr)
            if p.returncode:raise RuntimeError(p.stdout+p.stderr)
        actual=[]
        for line in (dest/f'trace{bits}.txt').read_text().splitlines():
            fields=line.split()
            for j,value in enumerate(fields):
                if any(c in value.lower() for c in 'xz') and (j!=2 or fields[1]!='0'):
                    raise AssertionError('unknown on valid/control output')
            actual.append(tuple(0 if any(c in x.lower() for c in 'xz') else int(x,16 if j==2 else 10) for j,x in enumerate(fields)))
        verify(actual,expected)
        idx=next(i for i,a in enumerate(actual) if a[1]);mutations=[]
        for field in (0,1,2,3,4,5,6):
            bad=actual.copy();row=list(bad[idx]);row[field]^=1;bad[idx]=tuple(row);mutations.append(bad)
        mutations.append(actual[:-1]);bad=actual.copy();j=next(i for i in range(idx+1,len(bad)) if bad[i][1] and bad[i][2]!=bad[idx][2]);bad[idx],bad[j]=bad[j],bad[idx];mutations.append(bad)
        for bad in mutations:
            try:verify(bad,expected)
            except AssertionError:pass
            else:raise AssertionError('mutation accepted')
        results.append(dict(bits=bits,cycles=len(stim),accepted=accepted,configs=12,latency=4,mutations=len(mutations),status='PASS'))
    (dest/'summary.json').write_text(json.dumps(dict(status='PASS',results=results,sha256=hashlib.sha256((HERE/'csc_stream.v').read_bytes()).hexdigest()),indent=2));print('PASS',dest,results)

if __name__=='__main__':main()
