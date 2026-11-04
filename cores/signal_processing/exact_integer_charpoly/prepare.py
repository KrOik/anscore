#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Freeze finite independent exact fixtures and every child before RTL exists."""
from hashlib import sha256
from math import factorial
from pathlib import Path
import json
import sys
sys.dont_write_bytecode = True
from oracle import certificates, matrix, principal_coefficients

ROOT = Path(__file__).resolve().parent
BASELINE = 'd35d71be3bfc76f272809ae250d19cba92dbb18c'
PROFILES = [(4,8,8),(1,2,1),(2,12,32),(3,5,3),(5,3,32),(8,12,8)]
STATES = ['IDLE','CAPTURE','ERROR_HOLD','BASE_READ','BASE_WRITE','G0','G1',
          'V_INIT_READ','V_INIT_WRITE','DOT_READ','DOT_LOAD','MUL_NARROW',
          'DOT_ACC','CONV_READ','CONV_LOAD','MUL_WIDE','CONV_ACC',
          'OUT_FETCH','OUT_HOLD']
EXTRA = [
 ('CAPTURE_MASKED','CAPTURE && count==0 && accepted_masked',1),
 ('CAPTURE_FIRST','CAPTURE && count==1 && !s_last',1),
 ('CAPTURE_FULL','CAPTURE && count==N*N && !s_last',1),
 ('CAPTURE_OVERFLOW','CAPTURE && count==N*N+1 && errors[1]',1),
 ('NARROW_FIRST','MUL_NARROW && mul_step==0',2),
 ('NARROW_MIDDLE','MUL_NARROW && mul_step==DATA_W/2',2),
 ('NARROW_LAST','MUL_NARROW && mul_step==DATA_W-1',2),
 ('WIDE_FIRST','MUL_WIDE && mul_step==0',2),
 ('WIDE_MIDDLE','MUL_WIDE && mul_step==COEFF_W/2',2),
 ('WIDE_LAST','MUL_WIDE && mul_step==COEFF_W-1',2),
 ('POWER_ACC_PREFIX','DOT_ACC && m==3 && power_mode && i==0 && j==1',3),
 ('R_ACC_PREFIX','DOT_ACC && m==3 && !power_mode && r==2 && j==1',3),
 ('VECTOR_SWAP_BEFORE','DOT_ACC && m==3 && power_mode && r==2 && i==1 && j==1 && vec_bank==0',3),
 ('VECTOR_SWAP_AFTER','DOT_READ && m==3 && !power_mode && r==3 && j==0 && vec_bank==1',3),
 ('COEFF_SWAP_BEFORE','CONV_ACC && m==2 && i==2 && j==1 && coeff_bank==0',2),
 ('COEFF_SWAP_AFTER','G0 && m==3 && coeff_bank==1',3),
 ('CONV_ACC_PREFIX','CONV_ACC && m==2 && i==1 && j==1',2),
 ('CONV_NONZERO_PREFIX','CONV_ACC && m==2 && i==1 && j==1 && dot_acc!=0',2),
 ('OUTPUT_FIRST','OUT_HOLD && i==0 && !m_ready',1),
 ('OUTPUT_MIDDLE','OUT_HOLD && i==N/2 && !m_ready',2),
 ('OUTPUT_LAST','OUT_HOLD && i==N && !m_ready',1),
 ('ERROR_SHORT','ERROR_HOLD && errors==1 && !m_ready',1),
 ('ERROR_OVERFLOW','ERROR_HOLD && errors==2 && !m_ready',1),
 ('ERROR_UPSTREAM','ERROR_HOLD && errors==4 && !m_ready',1),
 ('ERROR_SHORT_UPSTREAM','ERROR_HOLD && errors==5 && !m_ready',1),
 ('ERROR_OVERFLOW_UPSTREAM','ERROR_HOLD && errors==6 && !m_ready',1),
 ('ACTUAL_NEXT_COMPUTE','BASE_READ && s_valid && !s_ready && input_is_actual_fresh_first',1),
 ('ACTUAL_NEXT_OUTPUT','OUT_HOLD && s_valid && !s_ready && input_is_actual_fresh_first',1),
 ('OUTPUT_RETIRED_PREFIX','OUT_HOLD && i==1 && retired==1 && !m_ready',2),
 ('FINAL_COEFF_STORE','CONV_ACC && m==N && i==N && j==N-1',2),
 ('BASE_C0_WRITTEN','BASE_WRITE && coefficient_bank0_c0_owned',1),
 ('POWER_MUL_MIDDLE','MUL_NARROW && m==3 && power_mode && mul_step==DATA_W/2',3),
 ('FINAL_G_DOT_READ','DOT_READ && m==N && !power_mode && r==N && j==0',2),
 ('FINAL_WIDE_MUL_LAST','MUL_WIDE && m==N && i==N && j==N-1 && mul_step==COEFF_W-1',2),
 ('CONV_FIRST_ACC','CONV_ACC && m==2 && i==0 && j==0',2),
 ('CONV_LAST_ACC','CONV_ACC && m==N && i==N && j==N-1',2),
]
TARGETS = [(s,'state=='+str(i),2 if 5 <= i <= 16 else 1)
           for i,s in enumerate(STATES)] + EXTRA
REJECTS = [('n0',0,8,8),('n9',9,8,8),('w1',4,1,8),
           ('w13',4,13,8),('t0',4,8,0),('t33',4,8,33)]


def encode(obj):
    return (json.dumps(obj,indent=2,sort_keys=True)+'\n').encode('utf-8')


def digest(raw): return sha256(raw).hexdigest()


def write(path, raw):
    p=ROOT/path
    assert not p.exists(), 'immutable preparation output already exists: '+str(p)
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_bytes(raw)
    return digest(raw)


def clog(x): return (x-1).bit_length()


def dimensions(n,w,t):
    work=n*(w-1)+(n+1)*clog(n)+3
    coeff=n*(w-1)+clog(factorial(n)+1)+1
    pn=(n*(n-1)//2)**2
    pw=n*(n+1)*(n+5)//6-2
    compute=n*(n+1)+pn*(w+3)+pw*(coeff+3)
    ram=n*n*w+2*n*work+(n+1)*work+2*(n+1)*coeff
    scalar=6*work+3*coeff+w+t+4*clog(n+1)+clog(n*n+2)+max(1,clog(coeff))+12
    return dict(WORK_W=work,COEFF_W=coeff,narrow_products=pn,wide_products=pw,
                multiplier_bit_steps=pn*w+pw*coeff,compute_cycles=compute,
                first_valid_cycles=compute+1,last_retire_cycles=compute+2*(n+1),
                logical_RAM_bits=ram,planned_scalar_bits=scalar)


def corpus(n,w):
    x=1<<(w-1); lo=-x; hi=x-1
    a=lambda fn:tuple(tuple(fn(i,j) for j in range(n)) for i in range(n))
    dense=a(lambda i,j:((17*i+29*j+11*i*j+7)*13)%(2*x)-x)
    jordan=a(lambda i,j:int(i==j or j==i+1))
    sources=[('zero',a(lambda i,j:0)),('identity',a(lambda i,j:int(i==j))),
       ('negative_identity',a(lambda i,j:-int(i==j))),
       ('minimum_diagonal',a(lambda i,j:lo if i==j else 0)),
       ('maximum_diagonal',a(lambda i,j:hi if i==j else 0)),
       ('maximum_dense',a(lambda i,j:hi)),('minimum_dense',a(lambda i,j:lo)),
       ('upper_extrema',a(lambda i,j:(lo if (i+j)%2 else hi) if j>=i else 0)),
       ('weighted_cycle',a(lambda i,j:(lo if i%2 else hi) if j==(i+1)%n else 0)),
       ('jordan_repeated',jordan),
       ('rank_deficient',a(lambda i,j:((j*3+1)%(2*x))-x)),('dense_signed',dense),
       ('transpose',tuple(zip(*dense))),
       ('permutation_similarity',a(lambda i,j:dense[n-1-i][n-1-j])),
       ('negative_jordan',tuple(tuple(-v for v in row) for row in jordan)),
       ('block_diagonal',a(lambda i,j:dense[i][j] if (i<n//2)==(j<n//2) else 0))]
    assert len(sources)==16
    assert principal_coefficients(matrix(sources[12][1]))==principal_coefficients(dense)
    assert principal_coefficients(matrix(sources[13][1]))==principal_coefficients(dense)
    assert principal_coefficients(matrix(sources[14][1]))==tuple((-1)**i*v for i,v in enumerate(principal_coefficients(jordan)))
    split=n//2
    if split:
        left=tuple(tuple(dense[i][j] for j in range(split)) for i in range(split))
        right=tuple(tuple(dense[i][j] for j in range(split,n)) for i in range(split,n))
        lc,rc=principal_coefficients(left),principal_coefficients(right)
        product=[sum(lc[j]*rc[i-j] for j in range(len(lc)) if 0<=i-j<len(rc)) for i in range(n+1)]
        assert tuple(product)==principal_coefficients(matrix(sources[15][1]))
    return sources


def describe(tokens,n,w,t,label,complete=True):
    tokens=[list(token) for token in tokens]
    values=[token[0] for token in tokens if token[1]]
    assert all(-(1<<(w-1))<=v<(1<<(w-1)) for v in values)
    assert not complete or (tokens and tokens[-1][2] and not any(x[2] for x in tokens[:-1]))
    errors=int(complete and len(values)<n*n)+2*int(len(values)>n*n)+4*int(any(x[3] for x in tokens))
    tag=tokens[0][4] if tokens else 0
    out=[]; cert=None; a=None; cycles=0
    if complete:
        if errors:
            out=[dict(data=0,index=0,keep=0,last=1,errors=errors,tag=tag)]
        else:
            a=matrix([values[i*n:(i+1)*n] for i in range(n)])
            cert=json.loads(json.dumps(certificates(a)))
            bound=dimensions(n,w,t)
            work,coeff=bound['WORK_W'],bound['COEFF_W']
            assert all(-(1<<(coeff-1))<=v<(1<<(coeff-1)) for v in cert['coefficients'])
            for stage in cert['stages']:
                assert all(abs(v)<(1<<(work-1)) for v in stage['g'])
                assert all(abs(v)<(1<<(work-1)) for row in stage['vectors'] for v in row)
            out=[dict(data=v,index=i,keep=1,last=int(i==n),errors=0,tag=tag)
                 for i,v in enumerate(cert['coefficients'])]
            cycles=bound['compute_cycles']
    return dict(label=label,complete=complete,tokens=tokens,outputs=out,errors=errors,
                count=min(n*n+1,len(values)),tag=tag,compute_cycles=cycles,
                matrix=a,certificate=cert)


def frame(values,n,w,t,serial,label,style=0,upstream=False):
    tag=((serial*37)^0xB25)&((1<<t)-1); later=tag^((1<<t)-1)
    lo=-(1<<(w-1)); hi=(1<<(w-1))-1; tokens=[]
    def token(value,keep,last=0,bad=0):
        tokens.append([value,keep,last,bad,tag if not tokens else later])
    if style&1: token(lo,0,bad=int(upstream))
    for i,value in enumerate(values):
        if style&2 and i%3==0: token(hi,0)
        token(value,1,bad=int(upstream and not(style&1) and i==0))
    if not tokens or style&4: token(hi,0,bad=int(upstream and not values))
    if upstream and not any(x[3] for x in tokens): tokens[-1][3]=1
    tokens[-1][2]=1
    return describe(tokens,n,w,t,label)


def main_frames(n,w,t):
    result=[]
    for serial,(name,a) in enumerate(corpus(n,w)):
        result.append(frame([v for row in a for v in row],n,w,t,serial,name,serial%8))
    lo=-(1<<(w-1)); full=[lo]*(n*n)
    extras=[('short',full[:-1],0,False),('overflow',full+[lo],0,False),
       ('upstream_kept',full,0,True),('upstream_masked',full,1,True),
       ('short_upstream',full[:-1],5,True),('overflow_upstream',full+[lo],3,True),
       ('all_masked',[],5,False),('leading_mask_first_tag',full,1,False),
       ('masked_last',full,4,False),('interleaved_masks',full,2,False),
       ('long_hold_gaps',full,7,False),('later_tags_ignored',full,3,False)]
    for serial,(name,values,style,bad) in enumerate(extras,16):
        result.append(frame(values,n,w,t,serial,name,style,bad))
    assert len(result)==28
    assert sorted(set(c['errors'] for c in result))==[0,1,2,4,5,6]
    return result


def case_text(case):
    cert=case['certificate']; stages=[] if cert is None else cert['stages']
    lines=[' '.join(map(str,[len(case['tokens']),len(case['outputs']),case['errors'],
                            case['tag'],case['compute_cycles'],case['count'],int(case['complete']),len(stages)]))]
    lines+=[' '.join(map(str,row)) for row in case['tokens']]
    lines+=[' '.join(str(row[k]) for k in ('data','index','keep','last','errors','tag')) for row in case['outputs']]
    for s in stages:
        lines.append(str(s['m']))
        lines.append(' '.join(map(str,s['coefficients'])))
        lines.append(' '.join(map(str,s['g'])))
        lines.append(str(len(s['vectors'])))
        lines+=[' '.join(map(str,row)) for row in s['vectors']]
    return lines


def reset_owner(target,n,w,t):
    lo=-(1<<(w-1)); values=[lo]*(n*n)
    name=TARGETS[target][0]
    if name in ('IDLE','CAPTURE','CAPTURE_MASKED','CAPTURE_FIRST','CAPTURE_FULL','CAPTURE_OVERFLOW'):
        amount={'IDLE':0,'CAPTURE':0,'CAPTURE_MASKED':0,'CAPTURE_FIRST':1,
                'CAPTURE_FULL':n*n,'CAPTURE_OVERFLOW':n*n+1}[name]
        tokens=[] if name=='IDLE' else frame([lo]*amount,n,w,t,700,name,1)['tokens']
        for token in tokens: token[2]=0
        return describe(tokens,n,w,t,name,False)
    if name in ('ERROR_HOLD','ERROR_SHORT','ERROR_OVERFLOW','ERROR_UPSTREAM','ERROR_SHORT_UPSTREAM','ERROR_OVERFLOW_UPSTREAM'):
        short=name in ('ERROR_SHORT','ERROR_SHORT_UPSTREAM')
        over=name in ('ERROR_OVERFLOW','ERROR_OVERFLOW_UPSTREAM')
        bad=name in ('ERROR_HOLD','ERROR_UPSTREAM','ERROR_SHORT_UPSTREAM','ERROR_OVERFLOW_UPSTREAM')
        return frame(values[:-1] if short else values+[lo] if over else values,n,w,t,700,name,5,bad)
    return frame(values,n,w,t,700,name,1)


def command(name,argv,expected='PASS'):
    return dict(name=name,argv=argv,expected=expected,timeout_seconds=20)


def main():
    assert not (ROOT/'rtl').exists() and not (ROOT/'sim').exists(), 'no original HDL may precede this freeze'
    assert not (ROOT/'TEST_PLAN.json').exists()
    profiles=[]; fixture_count=0; main_count=0; outputs=0; queued=0; resets=0; fresh_outputs=0
    children=[command('fixture_oracles',['python','-B','oracle.py','--verify-plan','TEST_PLAN.json']),
              command('tool_version',['iverilog','-V']),
              command('core_lint',['iverilog','-g2012','-Wall','-tnull','-s','exact_integer_charpoly','rtl/exact_integer_charpoly.sv']),
              command('example_lint',['iverilog','-g2012','-Wall','-tnull','-s','charpoly4','rtl/exact_integer_charpoly.sv','example/charpoly4.sv'])]
    targets={str(i):dict(name=name,predicate=pred,minimum_N=minn) for i,(name,pred,minn) in enumerate(TARGETS)}
    for pi,(n,w,t) in enumerate(PROFILES):
        dims=dimensions(n,w,t); p=dict(name='p'+str(pi),N=n,DATA_W=w,TAG_W=t,**dims,main=[],resets=[],excluded_reset_targets={})
        frames=main_frames(n,w,t); group_size=1 if n==8 else 4
        binary='{TMP}/p'+str(pi)+'.vvp'
        cycle_limit=2*dims['compute_cycles']+20*n*n+20*(n+1)+2000
        children.append(command(p['name']+'_compile',['iverilog','-g2012','-Wall','-s','tb_exact_integer_charpoly','-o',binary,
            '-Ptb_exact_integer_charpoly.N='+str(n),'-Ptb_exact_integer_charpoly.W='+str(w),'-Ptb_exact_integer_charpoly.T='+str(t),
            '-Ptb_exact_integer_charpoly.CYCLE_LIMIT='+str(cycle_limit*group_size),'rtl/exact_integer_charpoly.sv','sim/tb_exact_integer_charpoly.sv']))
        for first in range(0,len(frames),group_size):
            block=frames[first:first+group_size]; name=p['name']+'_main_'+str(first//group_size).zfill(3)
            obj=dict(kind='main',profile=p['name'],frames=block,queued=len(block)-1,
                     source_stalls='one bubble before accepted token index 2 mod 5',
                     output_stalls='every output held two full clocks before retirement',
                     next_offer='hold actual next frame first token immediately after previous LAST acceptance' if len(block)>1 else 'none: single complete frame')
            jp='fixtures/'+name+'.json'; tp='fixtures/'+name+'.txt'
            js=write(jp,encode(obj)); ts=write(tp,('\n'.join(['0 '+str(len(block))]+[line for c in block for line in case_text(c)])+'\n').encode('ascii'))
            group=dict(name=name,json=jp,text=tp,json_sha256=js,text_sha256=ts,frames=len(block),
                       outputs=sum(len(c['outputs']) for c in block),queued=len(block)-1,
                       compute_cycles=sum(c['compute_cycles'] for c in block),cycle_limit=cycle_limit*len(block))
            p['main'].append(group); fixture_count+=1; main_count+=len(block); outputs+=group['outputs']; queued+=group['queued']
            children.append(command(name,['vvp',binary,'+INPUT='+tp]))
        hi=(1<<(w-1))-1; lo=-(1<<(w-1))
        fresh_values=[(hi if i%2==0 else lo) if i==j else 0 for i in range(n) for j in range(n)]
        fresh=frame(fresh_values,n,w,t,701,'fresh_complete_all_coefficients',7)
        for target,(name,pred,minn) in enumerate(TARGETS):
            if n<minn:
                p['excluded_reset_targets'][str(target)]=('N1 uses direct two-coefficient base path; no iterative Berkowitz state, multiplier, or interior output' if n==1 else 'N2 has d=1 only; no vector-power multiplication/swap, stage3, or d>=2 dot prefix')
                continue
            owner=reset_owner(target,n,w,t); label=p['name']+'_reset_'+str(target).zfill(3)
            actual=name in ('ACTUAL_NEXT_COMPUTE','ACTUAL_NEXT_OUTPUT')
            retired= n//2 if name=='OUTPUT_MIDDLE' else n if name=='OUTPUT_LAST' else 1 if name=='OUTPUT_RETIRED_PREFIX' else 0
            obj=dict(kind='reset',profile=p['name'],target=target,target_name=name,predicate=pred,
                     observation='sample exact pre-execution state at falling edge; record counters/banks/step and all prior retired outputs; assert reset before next rising edge',
                     owner=owner,fresh=fresh,owner_outputs_retired_before_reset=retired,
                     actual_next_offer=actual,next_offer=fresh['tokens'][0] if actual else None,
                     reset_cycles=3,reset_offer=fresh['tokens'][0] if actual else [lo,1,1,1,0],
                     required='immediate ready/valid gating, no reset-high acceptance, no canceled output, full fresh frame and every fresh coefficient with stable metadata')
            jp='fixtures/'+label+'.json'; tp='fixtures/'+label+'.txt'
            js=write(jp,encode(obj)); ts=write(tp,('\n'.join(['1 '+str(target)]+case_text(owner)+case_text(fresh))+'\n').encode('ascii'))
            group=dict(name=label,target=target,json=jp,text=tp,json_sha256=js,text_sha256=ts,
                       frames=1,resets=1,outputs=len(fresh['outputs']),owner_prefix_outputs=retired,
                       actual_next_offer=int(actual),cycle_limit=cycle_limit)
            p['resets'].append(group); fixture_count+=1; resets+=1; fresh_outputs+=len(fresh['outputs'])
            children.append(command(label,['vvp',binary,'+INPUT='+tp]))
        p['main_frames']=sum(g['frames'] for g in p['main']); p['main_outputs']=sum(g['outputs'] for g in p['main'])
        p['main_queued']=sum(g['queued'] for g in p['main']); p['reset_count']=len(p['resets'])
        p['fresh_frames']=len(p['resets']); p['fresh_outputs']=sum(g['outputs'] for g in p['resets'])
        p['cycle_limit']=cycle_limit*group_size
        assert n!=8 or all(g['frames']==1 and g['queued']==0 for g in p['main'])
        profiles.append(p)
    for name,n,w,t in REJECTS:
        children.append(command('reject_'+name,['iverilog','-g2012','-tnull','-s','exact_integer_charpoly',
          '-Pexact_integer_charpoly.N='+str(n),'-Pexact_integer_charpoly.DATA_W='+str(w),
          '-Pexact_integer_charpoly.TAG_W='+str(t),'rtl/exact_integer_charpoly.sv'],'REJECT_INVALID_PARAMETERS_MARKER'))
    plan=dict(schema=1,baseline=BASELINE,frozen_before_rtl=True,phase='COMPLETE_FIXTURE_ORACLE_CHILD_FREEZE_BEFORE_RTL',
      profiles=profiles,states={str(i):s for i,s in enumerate(STATES)},reset_targets=targets,
      children=children,rejections=[dict(name=k,N=n,DATA_W=w,TAG_W=t) for k,n,w,t in REJECTS],
      timeout_seconds=20,timeout_terminal=True,no_adaptive_splits=True,
      failure_policy='each subprocess hard timeout20s; timeout terminal without retry/split/reduced workload; ordinary failed attempt archive exact sources/fixtures/children/stdout/stderr/exit/time/artifacts before any fix; no replacement of frozen stimuli',
      oracle='primary every principal minor by signed permutation expansion; secondary Fraction Newton from independently exponentiated full matrix powers; CH full matrix zero certificate; all trailing charpolys independently by principal minors; g/v certificates by full matrix binary powers',
      input='exactly N*N kept signed scalars row-major; keep0 payload ignored but LAST/bad controls active; first accepted beat tag; later tags ignored; saturating count N*N+1; overflow payload never overwrites A; drain until LAST',
      errors={'SHORT':1,'OVERFLOW':2,'UPSTREAM':4},
      output='success coefficients c0=1 through cN, index, keep1, LAST only cN, errors0 and first tag; error one zero-data index0 keep0 LAST1 summary with sticky errors; single owner until final retirement, no same-edge fallthrough',
      reset='sync high; immediate combinational ready/valid gating; no payload RAM reset; each reset covers observed predicate, full fresh input and every fresh coefficient; exclusions explicit and never aliased',
      stalls='one input bubble before token index2 mod5; every output held2 cycles; multi-frame nonmax jobs hold actual next first token immediately after owner LAST; maximum main jobs exactly one complete frame; two actual-next reset probes per profile',
      numeric={'WORK_W':'N*(DATA_W-1)+(N+1)*ceil(log2(N))+3','COEFF_W':'N*(DATA_W-1)+ceil(log2(N!+1))+1',
       'vector':'d=m-1; |B^t C|<=d^t X^(t+1); individual signed products<=d^t X^(t+2); every dot prefix<=d^(t+1) X^(t+2)',
       'g':'g0=1; |g1|<=X; |g_r|<=d^(r-1)X^r',
       'convolution':'|q_j|<=d!/(d-j)! X^j<=d^j X^j; each full signed g_(i-j)*q_j<=d^i X^i; any prefix<=m*d^i X^i<=Q=N^(N+1)X^N<=2^(WORK_W-3)',
       'coefficient_store':'only completed coefficient narrows; |c_i|<=choose(N,i)*i!*X^i<=N!*X^N; N1 negative minimum input fits COEFF_W',
       'shift_add':'magnitude product P<=Q; partial add sum<=P; while factor remains nonzero highest pending bit h>=t implies shifted a*2^t<=a*2^h<=P; freeze shift after last nonzero factor bit, fixed steps continue; no discarded significant product bits or signed-min negation'},
      architecture={'banks':'A N*N*DATA_W; two V N*WORK_W; G (N+1)*WORK_W; two Q (N+1)*COEFF_W; all synchronous single read OR write port; no reset payload',
       'port_schedule':'capture A write only; BASE_READ A read+Q0[0]write; BASE_WRITE Q0[1]write; G0 A read+G[0]write; G1 G[1]write; V_INIT_READ A read/V_INIT_WRITE V0 write; DOT_READ A+Vsource read/DOT_ACC G or Vdest write; CONV_READ G+Qsource read/CONV_ACC Qdest write; OUT_FETCH Qfinal read; HOLD no memory operations',
       'ownership':'V source read/target complete write then swap; all G written before convolution; Q source read/target complete write then swap; no uninitialized range read; output Q read-q held during stalls',
       'true_multiplier':'one magnitude WORK_W x COEFF_W shift/add engine, DATA_W steps for DATA_W x WORK_W vector products, COEFF_W steps for convolution; default8x41/34x41, maximum12x118/105x118',
       'arithmetic':'one shared WORK_W add for MUL/ACC phases plus one WORK_W and one COEFF_W unary sign/magnitude path; R dot accumulates negative products directly; no production data multiply/divide primitive',
       'scalar_formula':'6*WORK_W+3*COEFF_W+DATA_W+TAG_W+4*clog2(N+1)+clog2(N*N+2)+max(1,clog2(COEFF_W))+12',
       'compute_formula':'N*(N+1)+(N*(N-1)/2)^2*(DATA_W+3)+(N*(N+1)*(N+5)/6-2)*(COEFF_W+3)',
       'physical_risk':'six small wide banks may map to LUTRAM/flops or fragmented BRAM; 118-bit add/sign path timing unmeasured; no physical or DSP utilization claim'},
      upstream={'release':'SymPy1.14.0 installed distribution, metadata/release and RECORD bytes verified without import',
       'dense_py_sha256':'4587688151de599a1e3bde0e6a5d667f5b09be3f899b24bf6da462f3e77d466b',
       'dense_py_bytes':23217,'dense_py_lines':824,'dense_fully_read':True,
       'license_sha256':'07a5e9819f727b4986ad2829c7a29a6320d42575f720eb24d71b7fef573a0286','license_bytes':7885,'license_lines':153,'license_fully_read':True,
       'provenance_limit':'dense fixed by installed release+RECORD+hash, not independently freshly remote-commit hashed; determinant.py and LICENSE match prior verified commit16fa855354eb7bcabd3fe10993841e03b1382692; no copied/executed upstream production dependency',
       'dispatch':'determinant._charpoly -> DomainMatrix.charpoly -> SCC block factors -> charpoly_base density sparse/dense selection -> charpoly_berk -> rep.charpoly; complete DDM.charpoly calls complete dense.ddm_berk/ddm_imatmul read in full dense file'},
      exclusions=['RTL before fixture review approval','HDL execution before source freeze','synthesis','PnR','STA','board','expanded regression','inherited matrices'],
      preparation_sha256=digest(Path(__file__).read_bytes()),oracle_sha256=digest((ROOT/'oracle.py').read_bytes()),
      totals=dict(profiles=len(profiles),fixtures=fixture_count,fixture_files=2*fixture_count,main_frames=main_count,
        main_outputs=outputs,main_queued=queued,reset_count=resets,fresh_frames=resets,fresh_outputs=fresh_outputs,
        simulations=fixture_count,expected_rejects=len(REJECTS),children=len(children)))
    assert len({c['name'] for c in children})==len(children)
    plan_hash=write('TEST_PLAN.json',encode(plan))
    files={f.relative_to(ROOT.parent.parent.parent).as_posix():digest(f.read_bytes()) for f in ROOT.rglob('*') if f.is_file()}
    owned=ROOT.parent.parent.parent/'.git/anscore-b25-b-owned.json'
    owned.write_bytes(encode(dict(owner='B',stage='COMPLETE_FIXTURE_ONLY_FREEZE_NO_RTL_NO_HDL',files_sha256=files)))
    print(json.dumps(dict(status='FIXTURES_FROZEN_NO_RTL',plan_sha256=plan_hash,**plan['totals']),sort_keys=True))


if __name__=='__main__': main()
