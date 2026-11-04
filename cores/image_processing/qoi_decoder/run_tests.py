"""Original pixel-to-QOI encoder oracle and frozen, bounded owner-only checks."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parent
BASELINE='ff2aadf8ebdc8e5475b7022cd68d47e496b9f593'
PROFILES=[(1,1,27,1),(3,2,52,3),(4,4,102,8),(8,8,342,8),(16,16,1302,32)]
NEGATIVES=[('w0',0,8,342,8),('w17',17,8,342,8),('h0',8,0,342,8),('h17',8,17,342,8),
           ('b26',8,8,26,8),('b1303',8,8,1303,8),('t0',8,8,342,0),('t33',8,8,342,33)]
END=bytes([0]*7+[1])
def sha(raw):return hashlib.sha256(raw).hexdigest()
def header(w,h,channels,colorspace):return b'qoif'+w.to_bytes(4,'big')+h.to_bytes(4,'big')+bytes([channels,colorspace])
def color_hash(p):return sum(a*b for a,b in zip(p,[3,5,7,11]))%64
def signed_delta(a,b):return (a-b+128)%256-128
def encode(pixels):
    """Choose shortest legal chunk candidates from original pixels, not decode states."""
    table=[(0,0,0,0)]*64;previous=(0,0,0,255);chunks=[];families=[];i=0
    while i<len(pixels):
        pixel=tuple(pixels[i])
        if pixel==previous:
            length=1
            while i+length<len(pixels) and length<62 and tuple(pixels[i+length])==previous:length+=1
            chunks.append(bytes([0xc0+length-1]));families.append(3)
            table[color_hash(pixel)]=pixel;i+=length;continue
        choices=[(bytes([0xff,*pixel]),5)]
        slot=color_hash(pixel)
        if table[slot]==pixel:choices.append((bytes([slot]),0))
        if pixel[3]==previous[3]:
            choices.append((bytes([0xfe,*pixel[:3]]),4))
            dr,dg,db=[signed_delta(pixel[k],previous[k]) for k in range(3)]
            if all(-2<=v<=1 for v in [dr,dg,db]):choices.append((bytes([0x40+((dr+2)<<4)+((dg+2)<<2)+db+2]),1))
            rg,bg=signed_delta(dr,dg),signed_delta(db,dg)
            if -32<=dg<=31 and -8<=rg<=7 and -8<=bg<=7:choices.append((bytes([0x80+dg+32,((rg+8)<<4)+bg+8]),2))
        payload,family=min(choices,key=lambda q:(len(q[0]),q[0]))
        chunks.append(payload);families.append(family);table[slot]=pixel;previous=pixel;i+=1
    return b''.join(chunks),families
def selfcheck():
    assert encode([(0,0,0,0)])[0]==b'\0'
    assert encode([(0,0,0,255)]*62)[0]==b'\xfd'
    assert encode([(1,1,1,255)])[0]==b'\x7f'
    assert encode([(38,31,38,255)])[0]==b'\xbf\xff'
    assert encode([(100,0,200,255)])[0]==bytes([254,100,0,200])
    assert encode([(1,2,3,4)])[0]==bytes([255,1,2,3,4])
def reset_ids(p):
    return [i for i in range(42) if (i not in [35,36,40] or p>=2) and
            (i not in [37,38,39] or p>=62) and (i!=41 or p>=6)]
def valid(w,h,channels,cs,pixels,chunks=None,families=None):
    if chunks is None:chunks,families=encode(pixels)
    assert len(pixels)==w*h and all(len(p)==4 and all(0<=x<256 for x in p) for p in pixels)
    data=header(w,h,channels,cs)+chunks+END
    index_reads=families.count(0)
    return dict(data=data,pixels=pixels,w=w,h=h,channels=channels,colorspace=cs,status=0,
                latency=5+3*len(data)+len(pixels)+2*index_reads,fetches=len(data),commits=len(pixels),index_reads=index_reads,
                opmask=sum(1<<x for x in set(families)))
def bad(data,status,latency,fetches=0,commits=0,index_reads=0,opmask=0):
    return dict(data=data,pixels=[(0,0,0,0)],w=0,h=0,channels=0,colorspace=0,status=status,
                latency=latency,fetches=fetches,commits=commits,index_reads=index_reads,opmask=opmask)
def cases(mw,mh,capacity):
    out=[valid(1,1,4,0,[(0,0,0,0)],b'\x2e',[0]),
         valid(1,1,4,0,[(64,0,0,0)],bytes([255,64,0,0,0]),[5]),
         valid(1,1,4,0,[(0,0,0,0)],b'\0',[0])]
    simple=[(b'\0',[(0,0,0,0)],[0]),(b'\x3f',[(0,0,0,0)],[0]),
            (b'\x40',[(254,254,254,255)],[1]),(b'\x7f',[(1,1,1,255)],[1]),
            (b'\x80\0',[(216,224,216,255)],[2]),(b'\xbf\xff',[(38,31,38,255)],[2]),
            (b'\xc0',[(0,0,0,255)],[3]),(bytes([254,255,0,254]),[(255,0,254,255)],[4]),
            (bytes([255,255,0,254,1]),[(255,0,254,1)],[5])]
    for k,(payload,pixels,families) in enumerate(simple):out.append(valid(1,1,3 if k%2 else 4,k%2,pixels,payload,families))
    # Alpha opcode in channels3 is intentionally accepted; metadata does not erase alpha.
    out.append(valid(1,1,3,1,[(17,34,51,68)],bytes([255,17,34,51,68]),[5]))
    # Every channel byte value occurs in the 16x16 maximum RGBA literal image.
    pixels=[(i%256,255-i%256,(7*i)%256,i%256) for i in range(mw*mh)]
    full=valid(mw,mh,4,1,pixels);assert len(full['data'])==5*mw*mh+22==capacity;out.append(full)
    out.append(valid(mw,mh,3,0,[(i%256,(3*i)%256,(11*i)%256,255) for i in range(mw*mh)]))
    out.append(valid(mw,mh,4,0,[(0,0,0,255)]*(mw*mh)))
    if mw*mh>=6:
        # Same hash0 is overwritten by B; initial slot63 yields transparent0,
        # which subsequently overwrites hash0 again. No adjacent equal index.
        payload=bytes([255,0,0,0,0,255,64,0,0,0,0,63,0,254,1,2,3])
        pixels=[(0,0,0,0),(64,0,0,0),(64,0,0,0),(0,0,0,0),(0,0,0,0),(1,2,3,0)]
        out.append(valid(3,2,3,1,pixels,payload,[5,5,0,0,0,4]))
        pixels=[(255,255,255,255),(0,0,0,255),(254,254,254,255),(216,224,216,255),(0,255,0,255),(0,0,0,0)]
        out.append(valid(3,2,4,0,pixels))
    rng=random.Random(0xB20000+mw*31+mh)
    for k in range(12):
        w=rng.randint(1,mw);h=rng.randint(1,mh);channels=3 if k%3==0 else 4
        pixels=[]
        for i in range(w*h):
            if pixels and i%4==1:pixel=pixels[-1]
            elif pixels and i%4==3:pixel=pixels[0]
            else:pixel=tuple(rng.randrange(256) for _ in range(3))+(255 if channels==3 else rng.randrange(256),)
            pixels.append(pixel)
        out.append(valid(w,h,channels,k%2,pixels))
    base=header(1,1,4,1)+bytes([255,17,34,51,68])+END
    out += [bad(b'\0',3,1),bad(base+bytes(capacity+2-len(base)),1,1),
            bad(b'x'+base[1:],2,4,1),bad(base[:13]+b'\2'+base[14:],2,43,14)]
    for w,h,c in [(0,1,4),(1,0,4),(mw+1,1,4),(1,mh+1,4),(0x10000001,1,4),(1,0x10000001,4),(1,1,2)]:
        out.append(bad(header(w,h,c,1)+base[14:],2,44,14))
    out += [bad(header(1,1,4,1)+END,3,45,14),
            bad(header(1,1,4,1)+bytes([254,17])+END,3,51,16,opmask=16),
            bad(base[:-1],3,57,18,opmask=32),
            bad(header(1,1,4,1)+b'\xc1'+END,4,47,15,opmask=8),
            bad(header(1,1,4,1)+b'\xfd'+END,4,47,15,opmask=8),
            bad(base[:-8]+b'\1'+base[-7:],5,63,20,1,opmask=32),
            bad(base[:-1]+b'\0',5,84,27,1,opmask=32),
            bad(base+b'\0',1,1) if len(base)+1>capacity else bad(base+b'\0',5,60,19,1,opmask=32),
            bad(base[:-8]+b'\0'+END,1,1) if len(base)+1>capacity else bad(base[:-8]+b'\0'+END,5,60,19,1,opmask=32)]
    if mw*mh>=2:out.append(bad(header(2,1,4,0)+b'\0\0'+END,6,53,16,1,1,1))
    assert all(len(q['data'])>=1 for q in out)
    return out
def pack(values):
    z=0
    for v,bits in values:z=(z<<bits)|(v&((1<<bits)-1))
    return z
def source_hashes():
    return {p.relative_to(ROOT).as_posix():sha(p.read_bytes()) for p in sorted(ROOT.rglob('*'))
            if p.is_file() and p.name not in ['TEST_PLAN.json','verification.json'] and '__pycache__' not in p.parts}
def freeze():
    assert not (ROOT/'verification.json').exists(),'do not overwrite evidence'
    selfcheck();profiles=[]
    for mw,mh,capacity,tw in PROFILES:
        xw=max(1,(mw-1).bit_length());yw=max(1,(mh-1).bit_length());fcw=capacity.bit_length()
        rows=[];stats=dict(frames=0,input_bytes=0,outputs=0,pixels=0,success=0,status=[0]*7,fetches=0,commits=0,index_reads=0,opmask=0)
        for index,q in enumerate(cases(mw,mh,capacity)):
            data=q['data'];tag=(index*37+9)&((1<<tw)-1)
            rows.append(f"{len(data)} {len(q['pixels'])} {q['latency']} {q['fetches']} {q['commits']} {q['index_reads']} {q['opmask']:x}\n")
            for k,b in enumerate(data):rows.append(f'{pack([(b,8),(k==len(data)-1,1),(tag if k==0 else tag^((1<<tw)-1),tw)]):x}\n')
            for k,pixel in enumerate(q['pixels']):
                x=k%q['w'] if q['status']==0 else 0;y=k//q['w'] if q['status']==0 else 0
                expected=pack([(int.from_bytes(bytes(pixel),'big'),32),(x,xw),(y,yw),(k==0,1),
                    (q['status']!=0 or x+1==q['w'],1),(k+1==len(q['pixels']),1),(q['w'],32),(q['h'],32),
                    (q['channels'],8),(q['colorspace'],1),(q['status'],3),(min(len(data),capacity),fcw),(tag,tw)])
                rows.append(f'{expected:x}\n')
            stats['frames']+=1;stats['input_bytes']+=len(data);stats['outputs']+=len(q['pixels']);stats['status'][q['status']]+=1
            stats['pixels']+=len(q['pixels']) if q['status']==0 else 0;stats['success']+=q['status']==0
            for k in ['fetches','commits','index_reads']:stats[k]+=q[k]
            stats['opmask']|=q['opmask']
        name=f'w{mw}_h{mh}_b{capacity}_t{tw}';fixture='sim/fixtures/'+name+'.txt';raw=''.join(rows).encode()
        (ROOT/fixture).parent.mkdir(parents=True,exist_ok=True);(ROOT/fixture).write_bytes(raw)
        profiles.append(dict(name=name,w=mw,h=mh,b=capacity,t=tw,fixture=fixture,sha256=sha(raw),statistics=stats,
                             reset_ids=reset_ids(mw*mh),latency_bound=5+3*capacity+3*mw*mh))
    plan=dict(schema=1,baseline=BASELINE,frozen_before_first_hdl=True,profiles=profiles,negative_parameters=NEGATIVES,children=21,timeout_seconds=20,
              source_hashes=source_hashes(),oracle='original source RGBA + independent shortest-candidate QOI encoder; hand-anchored opcode/error files',
              reset_policy='immediate observed phase; full fresh RGBA file validation/pixel/hold/retirement after every reset',
              source_policy='actual next frozen file byte held until accepted or canceled by reset',no_synthesis=True,no_inherited_reruns=True)
    (ROOT/'TEST_PLAN.json').write_bytes((json.dumps(plan,indent=2)+'\n').encode());print('FROZEN',sha((ROOT/'TEST_PLAN.json').read_bytes()))
    print(json.dumps(profiles,indent=2))
def parse_frozen_fixture(raw):
    """Read annotations/tokens for input-preserving evidence checks; no oracle."""
    lines=raw.decode('utf-8').splitlines();frames=[];position=0
    while position<len(lines):
        fields=lines[position].split();assert len(fields)==7
        work=[int(v,16 if k==6 else 10) for k,v in enumerate(fields)];position+=1
        length,count=work[:2];inputs=lines[position:position+length];position+=length
        outputs=lines[position:position+count];position+=count
        assert len(inputs)==length and len(outputs)==count
        frames.append(dict(work=work,inputs=inputs,outputs=outputs))
    assert position==len(lines)
    return frames
def run(repair=False):
    plan_raw=(ROOT/'TEST_PLAN.json').read_bytes();plan=json.loads(plan_raw);assert source_hashes()==plan['source_hashes']
    prior_attempts=[]
    receipt_path=ROOT/'verification.json'
    if receipt_path.exists():
        assert repair and plan.get('repair_history'),'existing raw evidence blocks automatic reruns'
        for item in plan['repair_history']:
            archive_raw=(ROOT/item['archive']).read_bytes();assert sha(archive_raw)==item['archive_sha256']
            archive=json.loads(archive_raw)
            for key in ['original_plan','original_receipt']:
                value=archive[key];raw=value['utf8'].encode('utf-8')
                assert len(raw)==value['byte_count'] and sha(raw)==value['sha256']
            oldplan=json.loads(archive['original_plan']['utf8']);oldreport=json.loads(archive['original_receipt']['utf8'])
            assert oldreport['status']=='FAIL' and all(r['status'] not in ['TIMEOUT_TERMINAL','TIMEOUT'] for r in oldreport['records'])
            assert archive['original_plan']['sha256']==item['plan_sha256']
            assert archive['original_receipt']['sha256']==item['receipt_sha256']
            for key,value in oldplan.items():
                if key not in ['source_hashes','repair_history','profiles']:assert plan[key]==value,key
            assert len(plan['profiles'])==len(oldplan['profiles'])==5
            for oldq,newq in zip(oldplan['profiles'],plan['profiles']):
                if oldq==newq:continue
                fix=plan['oracle_annotation_repair'];assert oldq['name']==newq['name']=='w1_h1_b27_t1'
                assert {k:v for k,v in oldq.items() if k not in ['sha256','statistics']}=={k:v for k,v in newq.items() if k not in ['sha256','statistics']}
                assert oldq['sha256']==fix['before_fixture_sha256'] and newq['sha256']==fix['after_fixture_sha256']
                assert newq['statistics']==dict(oldq['statistics'],status=[28,3,9,4,2,2,0],fetches=947,commits=30)
                evidence=json.loads((ROOT/fix['archive']).read_bytes())
                original=evidence['archived_sources'][oldq['fixture']]['utf8'].encode('utf-8')
                assert sha(original)==oldq['sha256']
                before=parse_frozen_fixture(original);after=parse_frozen_fixture((ROOT/newq['fixture']).read_bytes())
                assert len(before)==len(after)==48
                for number,(a,b) in enumerate(zip(before,after)):
                    assert a['inputs']==b['inputs'] and a['work'][:2]==b['work'][:2]
                    if number in [46,47]:
                        assert a['work']==[28,1,60,19,1,0,32] and b['work']==[28,1,1,0,0,0,0]
                        assert len(a['outputs'])==len(b['outputs'])==1 and int(b['outputs'][0],16)==int(a['outputs'][0],16)-256
                    else:assert a==b
            assert oldplan['source_hashes']==archive['original_source_sha256']
            for name,value in archive['archived_sources'].items():
                raw=value['utf8'].encode('utf-8')
                assert len(raw)==value['byte_count'] and sha(raw)==value['sha256']==oldplan['source_hashes'][name]
            for q in plan['profiles']:assert sha((ROOT/q['fixture']).read_bytes())==q['sha256']
            prior_attempts.append(dict(archive=item['archive'],archive_sha256=item['archive_sha256'],
                plan_sha256=item['plan_sha256'],receipt_sha256=item['receipt_sha256'],status=oldreport['status'],
                actual_records=len(oldreport['records']),not_run=oldplan['children']-len(oldreport['records'])))
        assert sha(receipt_path.read_bytes())==plan['repair_history'][-1]['receipt_sha256'],'current receipt must exactly match last archived failure'
    else:assert not repair,'repair requires exact existing archived failure'
    names=['version','core_syntax','example_syntax']+[q['name']+s for q in plan['profiles'] for s in ['_compile','_simulate']]+['reject_'+n[0] for n in plan['negative_parameters']]
    assert len(names)==plan['children']==21 and plan['timeout_seconds']==20
    assert plan['negative_parameters']==[list(q) for q in NEGATIVES]
    assert [(q['w'],q['h'],q['b'],q['t']) for q in plan['profiles']]==PROFILES
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';iv=str(suite/'bin/iverilog.exe');vv=str(suite/'bin/vvp.exe')
    env=dict(os.environ);env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','')
    report=dict(schema=1,baseline=BASELINE,status='RTL_CANDIDATE',hardware='HW_UNVERIFIED',plan_sha256=sha(plan_raw),
                source_sha256=dict(plan['source_hashes'],**{'TEST_PLAN.json':sha(plan_raw)}),profiles=plan['profiles'],records=[],
                planned_records=[dict(name=n,status='NOT_RUN') for n in names],prior_attempts=prior_attempts,bounded_finite_only=True)
    def save():(ROOT/'verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())
    def child(name,argv,negative=False):
        start=time.monotonic()
        try:
            cp=subprocess.run(argv,cwd=ROOT,env=env,capture_output=True,text=True,timeout=20,encoding='utf-8',errors='replace')
            good=cp.returncode!=0 and 'qoi_decoder_invalid_parameter__see_README' in cp.stderr if negative else cp.returncode==0
            if name.endswith('_simulate'):good=good and 'PASS W=' in cp.stdout
            rec=dict(name=name,argv=argv,timeout_seconds=20,exit_code=cp.returncode,stdout=cp.stdout,stderr=cp.stderr,
                     elapsed_seconds=round(time.monotonic()-start,6),status='PASS' if good else 'FAIL')
        except subprocess.TimeoutExpired as e:
            decode=lambda x:x.decode(errors='replace') if isinstance(x,bytes) else x or ''
            rec=dict(name=name,argv=argv,timeout_seconds=20,exit_code=None,stdout=decode(e.stdout),stderr=decode(e.stderr),
                     elapsed_seconds=round(time.monotonic()-start,6),status='TIMEOUT_TERMINAL')
        assert name==names[len(report['records'])]
        report['planned_records'][len(report['records'])]['status']=rec['status']
        report['records'].append(rec);save();print(name,rec['status'],rec['elapsed_seconds'],flush=True)
        if rec['status']!='PASS':report['status']=rec['status'];save();raise SystemExit('stopped; preserve evidence; timeout is terminal')
    child('version',[iv,'-V'])
    child('core_syntax',[iv,'-g2012','-Wall','-tnull','-s','qoi_decoder','-f','files.f'])
    child('example_syntax',[iv,'-g2012','-Wall','-tnull','-s','qoi_decoder_example','-f','example/files.f'])
    with tempfile.TemporaryDirectory(prefix='anscore_c20_qoi_') as temp:
        for q in plan['profiles']:
            assert sha((ROOT/q['fixture']).read_bytes())==q['sha256'];binary=str(Path(temp)/(q['name']+'.vvp'))
            argv=[iv,'-g2012','-Wall','-s','tb_qoi_decoder','-o',binary]
            for k,v in dict(MAX_WIDTH=q['w'],MAX_HEIGHT=q['h'],MAX_BYTES=q['b'],TAG_W=q['t'],FRAMES=q['statistics']['frames'],RESETS=len(q['reset_ids'])).items():argv+=['-P',f'tb_qoi_decoder.{k}={v}']
            child(q['name']+'_compile',argv+['rtl/qoi_decoder.sv','sim/tb_qoi_decoder.sv'])
            child(q['name']+'_simulate',[vv,binary,'+FIXTURE='+q['fixture']])
        for name,w,h,b,t in NEGATIVES:
            argv=[iv,'-g2012','-tnull','-s','qoi_decoder']
            for k,v in dict(MAX_WIDTH=w,MAX_HEIGHT=h,MAX_BYTES=b,TAG_W=t).items():argv+=['-P',f'qoi_decoder.{k}={v}']
            child('reject_'+name,argv+['rtl/qoi_decoder.sv'],True)
    assert len(report['records'])==plan['children'] and source_hashes()==plan['source_hashes']
    report['status']='UNIT_SIM_PASS';save();print('REPORT',sha((ROOT/'verification.json').read_bytes()))
if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--freeze',action='store_true');ap.add_argument('--run',action='store_true');ap.add_argument('--repair',action='store_true');args=ap.parse_args()
    if args.freeze==args.run:ap.error('choose exactly one of --freeze / --run')
    if args.repair and not args.run:ap.error('--repair requires --run')
    freeze() if args.freeze else run(args.repair)
