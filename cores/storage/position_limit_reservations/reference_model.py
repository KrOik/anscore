"""SPDX-License-Identifier: Apache-2.0. Independent arbitrary-precision model.

No RTL, runner or simulator imports. Open totals are recomputed from Python
ticket records rather than mirroring the RTL's cached account RAM fields.
"""
import random

U32=(1<<32)-1;U64=(1<<64)-1;LO=-(1<<63);HI=(1<<63)-1

def pack(values,widths):
    result=0
    for value,width in zip(values,widths):
        assert -(1<<(width-1))<=value<(1<<width),(value,width)
        result=(result<<width)|(value&((1<<width)-1))
    return result

class Ledger:
    def __init__(self,a,k,t):
        self.a=a;self.k=k;self.t=t;self.contexts={};self.tickets={};self.faulted=0
    def totals(self,context):
        return tuple(sum(q for aa,side,q in self.tickets.values() if aa==context and side==s) for s in (1,0))
    def apply(self,op,context,ticket,buy,quantity,position,lower,upper,tag):
        status=0;rc=rt=rb=rr=rp=rl=ru=bo=so=0
        if op==6:self.contexts.clear();self.tickets.clear();self.faulted=0
        elif op==7:self.faulted=1
        elif self.faulted:status=9
        elif op==2 and quantity==0:status=3
        elif op in (2,3,5):
            if ticket not in self.tickets:status=7
            else:
                aa,side,old=self.tickets[ticket]
                if op==2 and quantity>old:status=12
                else:
                    p,lo,hi=self.contexts[aa]
                    if op==2:
                        p+=quantity if side else -quantity
                        self.contexts[aa]=(p,lo,hi)
                        if quantity==old:del self.tickets[ticket]
                        else:self.tickets[ticket]=(aa,side,old-quantity)
                    elif op==3:del self.tickets[ticket]
                    rc=aa;rt=ticket;rb=side;rr=self.tickets[ticket][2] if ticket in self.tickets else 0
                    rp,rl,ru=self.contexts[aa];bo,so=self.totals(aa)
        elif context>=self.a:status=1
        elif op==1 and quantity==0:status=3
        elif op==0 and not lower<=position<=upper:status=8
        elif op!=0 and context not in self.contexts:status=2
        elif op==0:
            if any(self.totals(context)):status=10
            else:self.contexts[context]=(position,lower,upper);rc=context;rp=position;rl=lower;ru=upper
        elif op==4:rc=context;rp,rl,ru=self.contexts[context];bo,so=self.totals(context)
        elif op==1:
            p,lo,hi=self.contexts[context];b,s=self.totals(context)
            if ticket in self.tickets:status=4
            elif p+b+(quantity if buy else 0)>hi or p-s-(quantity if not buy else 0)<lo:status=5
            elif len(self.tickets)==self.k:status=6
            else:
                self.tickets[ticket]=(context,buy,quantity)
                rc=context;rt=ticket;rb=buy;rr=quantity;rp=p;rl=lo;ru=hi;bo,so=self.totals(context)
        for aa,(p,lo,hi) in self.contexts.items():
            b,s=self.totals(aa)
            assert LO<=lo<=p<=hi<=HI and lo<=p-s and p+b<=hi
            assert b<(1<<38) and s<(1<<38)
        assert len(self.tickets)<=self.k
        assert all(aa in self.contexts and side in (0,1) and 0<q<=U32 for aa,side,q in self.tickets.values())
        return pack([op,status,rc,rt,rb,rr,rp,rl,ru,bo,so,len(self.tickets),tag,self.faulted],
                    [3,4,32,64,1,32,64,64,64,38,38,32,self.t,1]),status

def vectors(a,k,t):
    model=Ledger(a,k,t);lines=[];serial=0;previous_normal=False;rng=random.Random(420000+a*100+k)
    counts=dict(commands=0,statuses={},live_resets=0,future_queries=0)
    def emit(op=4,aa=0,tk=0,buy=1,q=0,p=0,lo=LO,hi=HI):
        nonlocal serial,previous_normal
        tag=((1<<(t-1))|serial)&((1<<t)-1);serial+=1
        expected,status=model.apply(op,aa,tk,buy,q,p,lo,hi,tag)
        lines.append('0 '+' '.join(map(str,[op,aa,tk,buy,q,p,lo,hi,tag]))+'\n')
        lines.append(f'{expected} {len(model.contexts)} {len(model.tickets)}\n')
        for ctx,(pos,lower,upper) in sorted(model.contexts.items()):
            b,s=model.totals(ctx);lines.append(f'{ctx} {pos} {lower} {upper} {b} {s}\n')
        for ticket,(ctx,side,remaining) in sorted(model.tickets.items()):lines.append(f'{ticket} {ctx} {side} {remaining}\n')
        counts['commands']+=1;counts['statuses'][str(status)]=counts['statuses'].get(str(status),0)+1
        if previous_normal and op==4:counts['future_queries']+=1
        previous_normal=True
    def cfg(aa=0,p=0,lo=LO,hi=HI):emit(0,aa,p=p,lo=lo,hi=hi)
    def res(tk=0,q=1,buy=1,aa=0):emit(1,aa,tk,buy,q)
    def fill(tk=0,q=1):emit(2,U32,tk,0,q,HI,HI,LO)
    def cancel(tk=0):emit(3,U32,tk,0,U32,HI,HI,LO)
    def get(tk=0):emit(5,U32,tk,0,U32,HI,HI,LO)
    def clear():emit(6,U32,U64,0,U32,HI,HI,LO)
    emit();get();cancel();fill(q=0);fill();cfg(U32);emit(4,1<<31);res(aa=U32,q=0);res(q=0);res()
    cfg(p=0,lo=1,hi=-1);cfg(p=HI,lo=LO,hi=HI-1);cfg();res(q=0)
    res(0,7);cfg(p=1);get();fill(q=8);fill(q=0);fill(q=3);get();emit();cancel();get();cancel();emit()
    # Endpoints remain distinct: opposing outstanding orders cannot fund each other.
    clear();cfg(lo=-5,hi=5);res(0,5,1);res(U64,6,0);res(U64,5,0);res(2,1,1);res(3,1,0)
    fill(0,2);emit();get(U64);cancel(U64);cancel(0);emit();cfg(p=-3,lo=-5,hi=5)
    # Every signed64 endpoint, including fills through zero and exact extreme.
    clear();cfg(p=HI-2);res(0,3);res(0,2);fill(0,1);cancel(0);res(U64,1);fill(U64,1);emit();res(0,1)
    res(0,U32,0);fill(0,U32);emit();cfg(p=LO+2);res(0,3,0);res(0,2,0);fill(0,2);emit();res(U64,1,0)
    res(U64,1,1);fill(U64,1);emit();clear()
    for aa in range(a):cfg(aa)
    keys=[0]+[(1<<63)+i for i in range(1,k)]
    # Maximum aggregate is 64*(2^32-1), exercising all 38 accumulator bits.
    for i,tk in enumerate(keys):res(tk,U32,1,0)
    emit();res(keys[-1],1,0,a-1);res(U64,1);get(keys[k//2]);fill(keys[k//2],U32-1);get(keys[k//2]);fill(keys[k//2],1)
    res(U64,U32,0,a-1);get(U64);cancel(U64);cancel(U64);cfg(0,p=1)
    for tk in keys:cancel(tk)
    cfg(0,p=1);emit();clear()
    # Global ticket identity and context-independent cancellation/fill fields.
    for aa in range(a):cfg(aa,lo=-20,hi=20)
    res(U64,9,0,a-1);res(U64,1,1,0);fill(U64,4);get(U64);cancel(U64);emit(4,a-1)
    res(17,1);emit(7);get(17);fill(17);cfg();emit(7);clear();get(17)
    for aa in range(a):cfg(aa,lo=-40,hi=40)
    for _ in range(180):
        kind=rng.randrange(8);aa=rng.choice([rng.randrange(a),a,U32])
        tk=rng.choice(list(model.tickets)) if model.tickets and rng.randrange(2)==0 else rng.choice([0,U64,rng.getrandbits(64)])
        q=rng.choice([0,1,2,7,U32]);side=rng.randrange(2)
        if kind<=1:res(tk,q,side,aa)
        elif kind==2:fill(tk,q)
        elif kind==3:cancel(tk)
        elif kind==4:get(tk)
        elif kind==5:cfg(aa,rng.choice([LO,HI,-8,0,8]),rng.choice([LO,-10,0]),rng.choice([0,10,HI]))
        elif kind==6:emit(4,aa)
        else:res(tk,1,side,0)
        emit(4,0)  # Actual distinct future GET_CONTEXT while the prior response is held.
    clear()
    for phase in range(5):
        cfg(lo=-100,hi=100)
        if phase in (1,3,4):res(0,7)
        args=[0,0,0,1,0,0,-90,90] if phase==0 else ([5,U32,0,0,0,0,0,0] if phase==1 else
             ([1,0,U64,1,7,0,0,0] if phase==2 else ([2,U32,0,0,3,0,0,0] if phase==3 else [3,U32,0,0,0,0,0,0])))
        lines.append('1 '+str(phase)+' '+' '.join(map(str,args))+f' {(1<<t)-1}\n')
        counts['live_resets']+=1;model=Ledger(a,k,t);previous_normal=False
        emit();get(0);get(U64);cfg();res(U64,U32);get(U64);fill(U64,U32);emit();clear()
    counts['expected_preoffers']=counts['commands']-counts['live_resets']-1
    assert all(str(s) in counts['statuses'] for s in list(range(11))+[12]),counts
    return ''.join(lines),counts
