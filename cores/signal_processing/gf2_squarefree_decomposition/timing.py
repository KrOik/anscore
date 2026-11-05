"""Bounded reset-predicate and timing audit, explicitly NOT the numeric oracle.

The independent factorization certificate must be computed first. This scalar
schedule then checks its factors against the registered-state sequence. It is
used only for exact first-valid gaps and real, reachable reset predicates.
"""
from oracle import degree,derivative,square_root

IDLE,INITIALIZE,GCD_STEP,DIV_STEP,LAYER,HOLD=range(6)

def compute_bound(d):return d.bit_length()*(4*d+7)+d*(5*d+8)

def walk(certificate,d):
    s=dict(state=INITIALIZE,operation=0,f=(1<<d)|certificate['poly'],
           c=0,w=0,y=0,z=0,u=0,v=0,q=0,iteration=1,level=0,
           cycle=0,retired=0,base_cycle=0,compute_clocks=0)
    # Zero placeholders above are not reset assumptions. Only f/iteration/level
    # are live initially; selection masks never expose an uninitialized value.
    while s['state']!=IDLE:
        assert s['cycle']<=compute_bound(d)+d
        event=dict(s)
        event['last']=s['w']==s['c']==1
        if s['state']==HOLD:
            factor=dict(factor=s['z'],multiplicity=s['iteration']<<s['level'],degree=degree(s['z']))
            assert factor=={k:certificate['factors'][s['retired']][k] for k in ['factor','multiplicity','degree']}
            assert event['last']==(s['retired']==len(certificate['factors'])-1)
            event['gap']=s['cycle']-s['base_cycle']
        yield event
        state=s['state'];operation=s['operation'];u=s['u'];v=s['v']
        if state==INITIALIZE:
            s.update(u=s['f'],v=derivative(s['f']),operation=0,state=GCD_STEP)
        elif state==GCD_STEP:
            if v==0:
                if operation==0:s.update(c=u,u=s['f'],v=u,q=0,operation=0,state=DIV_STEP)
                else:s.update(y=u,u=s['w'],v=u,q=0,operation=1,state=DIV_STEP)
            elif u==0 or degree(u)<degree(v):s.update(u=v,v=u)
            else:s['u']=u^(v<<(degree(u)-degree(v)))
        elif state==DIV_STEP:
            assert v!=0
            if u==0 or degree(u)<degree(v):
                assert u==0,'every scheduled quotient must be exact'
                if operation==0:s.update(w=s['q'],state=LAYER)
                elif operation==1:s.update(z=s['q'],u=s['c'],v=s['y'],q=0,operation=2)
                else:
                    assert operation==2
                    s.update(c=s['q'],w=s['y'])
                    if s['z']!=1:s['state']=HOLD
                    else:s.update(iteration=s['iteration']+1,state=LAYER)
            else:
                shift=degree(u)-degree(v)
                s.update(u=u^(v<<shift),q=s['q']^(1<<shift))
        elif state==LAYER:
            if s['w']!=1:s.update(u=s['w'],v=s['c'],operation=1,state=GCD_STEP)
            elif s['c']!=1:s.update(f=square_root(s['c']),level=s['level']+1,iteration=1,state=INITIALIZE)
            else:raise AssertionError('nonempty command must finish through a last factor')
        else:
            assert state==HOLD
            s['retired']+=1;s['base_cycle']=s['cycle']+1
            if event['last']:s['state']=IDLE
            else:s.update(iteration=s['iteration']+1,state=LAYER)
        s['cycle']+=1
        if state!=HOLD:s['compute_clocks']+=1
        assert s['compute_clocks']<=compute_bound(d)
        assert 1<=s['iteration']<=d and 0<=s['level']<d.bit_length()
        assert all(0<=s[k]<1<<(d+1) for k in ['f','c','w','y','z','u','v','q'])
    assert s['retired']==len(certificate['factors'])

TARGETS=[
 'initial_load','initial_gcd','gcd_cancel_positive_shift','gcd_cancel_zero_shift',
 'gcd_swap_nonzero','gcd_swap_zero','gcd_terminal','initial_quotient_first',
 'factor_quotient_nonunit_divisor','pending_factor_c_quotient','first_root_transition',
 'deepest_root_transition','held_nonlast','actual_next_held','after_prefix_compute','held_last']

def target_flags(s,d):
    state=s['state'];u=s['u'];v=s['v']
    return [
      state==INITIALIZE and s['level']==0,
      state==GCD_STEP and s['operation']==0 and u==s['f'] and v==derivative(s['f']),
      state==GCD_STEP and bool(u) and bool(v) and degree(u)>degree(v),
      state==GCD_STEP and bool(u) and bool(v) and degree(u)==degree(v),
      state==GCD_STEP and bool(u) and bool(v) and degree(u)<degree(v),
      state==GCD_STEP and u==0 and v!=0,
      state==GCD_STEP and v==0,
      state==DIV_STEP and s['operation']==0 and s['q']==0,
      state==DIV_STEP and s['operation']==1 and v!=1 and s['q']==0,
      state==DIV_STEP and s['operation']==2 and s['z']>1 and s['q']==0,
      state==LAYER and s['w']==1 and s['c']>1 and s['level']==0,
      state==LAYER and s['w']==1 and s['c']>1 and s['level']==d.bit_length()-2,
      state==HOLD and not s['last'],
      state==HOLD and (d==1 or not s['last']),
      state==GCD_STEP and s['retired']>0,
      state==HOLD and s['last']]

def predicate(s):
    state=s['state']
    mask=(1 if state in [GCD_STEP,DIV_STEP] else 0)|(2 if state in [GCD_STEP,DIV_STEP] else 0)
    mask|=4 if state==DIV_STEP else 0
    mask|=8 if state in [LAYER,HOLD] else 0
    mask|=16 if state==HOLD or state==DIV_STEP and s['operation']==2 else 0
    mask|=32 if state==HOLD else 0
    return dict(mask=mask,**{k:s[k] for k in ['state','operation','iteration','level','u','v','q','c','w','z','retired','last']})
