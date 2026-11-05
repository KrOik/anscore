"""SPDX-License-Identifier: Apache-2.0. Finite L2 IOC checks, no hardware tools."""
from pathlib import Path
import datetime,hashlib,json,os,random,shutil,subprocess,sys,time
ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
PROFILES=[(1,1,1,1),(3,8,8,8),(32,32,32,32)]
INPUTS=['rtl/price_level_ioc_matcher.sv','sim/tb_price_level_ioc_matcher.sv','sim/tb_quote_ioc16.sv',
 'run_checks.py','files.f','example/files.f','example/quote_ioc16.sv',
 '../../system/common_scaffold/memory/src/cip_sync_sp_ram.v',
 '../../storage/ram_ordered_dictionary/rtl/ram_ordered_dictionary.sv',
 '../../storage/price_level_order_book/rtl/price_level_order_book.sv']
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def vectors(levels,pw,qw,tw):
    """Independent ordinary Python dictionaries, sorted each sweep; no FSM model."""
    book=[{},{}];lines=[];counts=dict(maintenance=0,ioc=0,fills=0,resets=0,priority=0)
    pmax=(1<<pw)-1;qmax=(1<<qw)-1;tmax=(1<<tw)-1
    rng=random.Random(350000+levels)
    def ordered(side):return sorted(book[side],reverse=not side)
    def maint(op,side=0,p=0,q=0,rank=0):
        tag=(counts['maintenance']*17+3)&tmax
        status=found=price=after=previous=0;b=book[side]
        if op>7:status=7
        elif op<=2 and q==0:status=3
        elif op==5 and rank>=levels:status=6
        elif op<=3:
            old=b.get(p,0)
            if op==0 or op==1:
                value=q if op==0 else old+q
                if value>qmax:status=4
                elif p not in b and len(b)==levels:status=2
                else:
                    found=int(p in b);price=p;previous=old;after=value;b[p]=value
            elif not old:status=1
            elif op==2 and old<q:status=5
            else:
                found=1;price=p;previous=old;after=0 if op==3 else old-q
                if after:b[p]=after
                else:del b[p]
        elif op in (4,5):
            index=0 if op==4 else rank;keys=ordered(side)
            if index>=len(keys):status=1
            else:found=1;price=keys[index];after=b[price]
        elif op==6:b.clear()
        else:book[0].clear();book[1].clear()
        lines.append(f'0 {op} {side} {p} {q} {rank} {tag} {status} {found} {price} {after} {previous} {len(book[0])} {len(book[1])}\n')
        counts['maintenance']+=1
    def ioc(buy,market,limit,q):
        tag=(counts['ioc']*31+1)&tmax;remain=q;fills=[];b=book[buy]
        if not q:reason=3
        else:
            for price in sorted(b,reverse=not buy):
                if not market and ((buy and price>limit)or(not buy and price<limit)):
                    reason=2;break
                take=min(remain,b[price]);remain-=take;b[price]-=take
                if not b[price]:del b[price]
                fills.append((price,take,remain,len(fills),tag))
                if remain==0:reason=0;break
            else:reason=1
        lines.append(f'1 {buy} {market} {limit} {q} {tag} {len(fills)} {reason} {q-remain} {remain} {len(book[0])} {len(book[1])}\n')
        lines.extend(' '.join(map(str,row))+'\n'for row in fills)
        counts['ioc']+=1;counts['fills']+=len(fills)
    def inspect():
        for side in (0,1):
            maint(4,side)
            for rank in range(len(book[side])+1):maint(5,side,rank=rank)
    maint(4);maint(4,1);ioc(1,0,0,1);ioc(0,1,pmax,1);ioc(1,1,0,0)
    for op in range(8,16):maint(op)
    for side in(0,1):
        for op in (0,1,2):maint(op,side,0,0)
        maint(5,side,rank=0xffffffff);maint(2,side,0,1);maint(3,side)
    maint(0,0,pmax,qmax);maint(1,0,pmax,1);maint(2,0,pmax,qmax)
    maint(0,1,0,1);maint(2,1,0,qmax);inspect();maint(7)
    # Full capacity and worst finite number of fills; endpoint prices are ordinary.
    for side in(0,1):
        for p in range(min(levels,pmax+1)):maint(0,side,p,1)
        maint(0,side,pmax,1)
    ioc(1,1,0,qmax);inspect();ioc(0,1,0,qmax);inspect();maint(7)
    # Inclusive limit boundary, limit stop without mutation, partial, then drain.
    maint(0,1,pmax,qmax);ioc(1,0,0,1);ioc(1,0,pmax,1);inspect()
    maint(7);maint(0,0,0,qmax);ioc(0,0,pmax,1);ioc(0,0,0,1);inspect()
    for buy in(0,1):
        maint(7)
        for p in range(min(levels,pmax+1)):maint(0,buy,p,1)
        ioc(buy,0,min(pmax,1),qmax);inspect()
    # Same-side liquidity survives an opposite-side sweep.
    maint(7);maint(0,0,pmax,1);maint(0,1,0,1);ioc(1,1,pmax,1);inspect()
    for _ in range(90):
        if rng.randrange(3)==0:
            ioc(rng.randrange(2),rng.randrange(2),rng.randrange(pmax+1),rng.choice([0,1,qmax,rng.randrange(qmax+1)]))
        else:
            side=rng.randrange(2);p=rng.choice(list(book[side]))if book[side]and rng.randrange(2)else rng.randrange(pmax+1)
            maint(rng.choice([0,1,2,3,4,5,6,7]),side,p,rng.choice([0,1,qmax]),rng.randrange(levels+2))
    inspect()
    for phase in range(4):
        maint(7);maint(0,1,0,1);lines.append(f'2 {phase}\n');counts['resets']+=1;book[0].clear();book[1].clear();inspect()
    maint(7);lines.append('3\n');counts['priority']+=1;book[1][0]=1;inspect()
    return ''.join(lines),counts

def main():
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    out=ROOT/'reports'/stamp;out.mkdir(parents=True);archive=out/'executed_inputs';archive.mkdir()
    work=ROOT/'.work'/stamp;work.mkdir(parents=True)
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';suffix='.exe'if os.name=='nt'else''
    tools={n:suite/'bin'/(n+suffix)for n in['iverilog','vvp']}
    env=dict(os.environ);env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    report=dict(schema='anscore-b35-finite-checks-v1',status='INCOMPLETE',checks=[],profiles=[],source_sha256={},archived_sources={},tools={},hard_seconds_per_child=20,
        synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',hardware='HW_UNVERIFIED')
    stopped=False
    def save():(out/'results.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())
    save()
    try:
        for name in INPUTS:
            file=(ROOT/name).resolve();target=archive/file.relative_to(REPO);target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(file,target);report['source_sha256'][name]=digest(target);report['archived_sources'][name]=target.relative_to(ROOT).as_posix()
        for name,file in tools.items():report['tools'][name]=dict(path=str(file),sha256=digest(file))
        for l,p,q,t in PROFILES:
            data,counts=vectors(l,p,q,t);label=f'l{l}_p{p}_q{q}_t{t}';file=out/(label+'.txt');file.write_bytes(data.encode('ascii'))
            report['profiles'].append(dict(label=label,levels=l,price_w=p,quantity_w=q,tag_w=t,counts=counts,vector=file.name,vector_sha256=digest(file)))
    except Exception as exc:report.update(status='NOT_RUN',preparation_error=repr(exc));save();return 1
    save()
    def run(name,args):
        nonlocal stopped
        if stopped:return False
        rec=dict(name=name,argv=list(map(str,args)),cwd=str(ROOT));start=time.monotonic();stdout=stderr=b''
        try:
            proc=subprocess.Popen(rec['argv'],cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=os.name!='nt')
            try:
                stdout,stderr=proc.communicate(timeout=20);rec.update(status='PASS'if proc.returncode==0 else'FAIL',returncode=proc.returncode)
            except subprocess.TimeoutExpired as exc:
                stdout,stderr=exc.stdout or b'',exc.stderr or b'';rec.update(status='TIMEOUT',returncode=None)
                try:
                    if os.name=='nt':subprocess.run(['taskkill','/PID',str(proc.pid),'/T','/F'],capture_output=True,timeout=5)
                    else:
                        import signal
                        os.killpg(proc.pid,signal.SIGKILL)
                except(OSError,subprocess.SubprocessError)as exc:stderr+=str(exc).encode()
                try:
                    if proc.poll()is None:proc.kill()
                    stdout,stderr=proc.communicate(timeout=2)
                except(OSError,subprocess.SubprocessError)as exc:stderr+=str(exc).encode()
        except OSError as exc:rec.update(status='NOT_RUN',returncode=None);stderr=str(exc).encode()
        marker=b'PASS quote_ioc16'if name=='sim_example'else b'PASS price_level_ioc_matcher'
        if name.startswith('sim_')and rec['status']=='PASS'and(marker not in stdout or b'$finish'not in stdout):rec['status']='FAIL_NO_MARKER'
        rec.update(seconds=round(time.monotonic()-start,4),stdout_sha256=hashlib.sha256(stdout).hexdigest(),stderr_sha256=hashlib.sha256(stderr).hexdigest())
        (out/(name+'.stdout.txt')).write_bytes(stdout);(out/(name+'.stderr.txt')).write_bytes(stderr)
        if '-o'in rec['argv']:
            image=Path(rec['argv'][rec['argv'].index('-o')+1])
            if image.is_file():rec.update(image=str(image.relative_to(ROOT)),image_sha256=digest(image))
        report['checks'].append(rec);save();print(name,rec['status'],flush=True)
        stopped=rec['status']!='PASS';return not stopped
    run('syntax_default',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','price_level_ioc_matcher','-f','files.f'])
    run('syntax_limit',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','price_level_ioc_matcher','-Pprice_level_ioc_matcher.LEVELS=32','-Pprice_level_ioc_matcher.PRICE_W=32','-Pprice_level_ioc_matcher.QTY_W=32','-Pprice_level_ioc_matcher.TAG_W=32','-f','files.f'])
    run('syntax_example',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','quote_ioc16','-f','example/files.f'])
    for p in report['profiles']:
        if stopped:break
        label=p['label'];image=work/(label+'.vvp')
        if run('compile_'+label,[tools['iverilog'],'-g2012','-Wall','-s','tb_price_level_ioc_matcher',f'-Ptb_price_level_ioc_matcher.L={p["levels"]}',f'-Ptb_price_level_ioc_matcher.P={p["price_w"]}',f'-Ptb_price_level_ioc_matcher.Q={p["quantity_w"]}',f'-Ptb_price_level_ioc_matcher.T={p["tag_w"]}','-o',image,'-f','files.f','sim/tb_price_level_ioc_matcher.sv']):run('sim_'+label,[tools['vvp'],image,'+vectors='+(out/p['vector']).as_posix()])
    image=work/'example.vvp'
    if run('compile_example',[tools['iverilog'],'-g2012','-Wall','-s','tb_quote_ioc16','-o',image,'-f','example/files.f','sim/tb_quote_ioc16.sv']):run('sim_example',[tools['vvp'],image])
    expected=['syntax_default','syntax_limit','syntax_example']+[kind+p['label']for p in report['profiles']for kind in['compile_','sim_']]+['compile_example','sim_example']
    unchanged=all(digest(ROOT/p)==h for p,h in report['source_sha256'].items())
    ok=not stopped and unchanged and[c['name']for c in report['checks']]==expected
    report.update(sources_unchanged=unchanged,status='PASS'if ok else'INCOMPLETE')
    report['maturity']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']if ok else['RTL_CANDIDATE','HW_UNVERIFIED']
    save();print(out.relative_to(ROOT).as_posix(),flush=True);return 0 if ok else 1
if __name__=='__main__':sys.exit(main())
