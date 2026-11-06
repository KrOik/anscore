"""SPDX-License-Identifier: Apache-2.0. Independent retained Python records."""
import random
U32=(1<<32)-1;U64=(1<<64)-1
WIDTHS=[4,4,32,32,1,1,64,64,32,32,1,32,38,70,32,32,32,32,1]
def pack(values,t):
    result=0
    for value,width in zip(values,WIDTHS+[t]):
        assert 0<=value<1<<width
        result=(result<<width)|value
    return result
class Trades:
    def __init__(self,n):self.n=n;self.reset()
    def reset(self):self.rows={};self.fault=False
    def command(self,op,symbol,match,sequence,price,quantity,tag):
        status=0;trade=None;summary=None
        if op>6:status=7
        elif op==5:self.reset()
        elif op==6:self.fault=True
        elif self.fault:status=6
        elif op in [0,2] and quantity==0:status=1
        elif op==4:summary=symbol
        elif op==0:
            if match in self.rows:status=2
            elif len(self.rows)==self.n:status=3
            else:self.rows[match]=(symbol,sequence,price,quantity,True);trade=match;summary=symbol
        elif match not in self.rows:status=4
        elif op==3:trade=match
        elif not self.rows[match][4]:status=5
        else:
            s,seq,p,q,active=self.rows[match]
            self.rows[match]=(s,seq,price if op==2 else p,quantity if op==2 else q,op==2)
            trade=match;summary=s
        record=[0,0,0,0,0,0,0]
        if trade is not None:
            s,seq,p,q,active=self.rows[trade];record=[s,1,int(active),trade,seq,p,q]
        stats=[0,0,0,0,0,0,0,0]
        if summary is not None:
            ordered=sorted((seq,key,p,q) for key,(s,seq,p,q,active) in self.rows.items() if s==summary and active)
            prices=[r[2] for r in ordered]
            stats=[1,len(ordered),sum(r[3] for r in ordered),sum(r[2]*r[3] for r in ordered),
                prices[0] if prices else 0,max(prices,default=0),min(prices,default=0),prices[-1] if prices else 0]
            record[0]=summary
        return [op,status,len(self.rows),*record,*stats,int(self.fault),tag]
def vectors(n,t):
    model=Trades(n);rng=random.Random(41041+n);lines=[]
    counts=dict(commands=0,live_resets=0,adds=0,busts=0,corrections=0)
    counts.update({'status%d'%i:0 for i in range(9)})
    def cmd(op,symbol=0,match=0,sequence=0,price=0,quantity=0):
        tag=(counts['commands']*29+7)%2**t
        target=model.rows.get(match,(symbol,))[0] if op in [0,1,2,3] else symbol
        expected=model.command(op,symbol,match,sequence,price,quantity,tag)
        future=model.command(4,target,U64,U64,U32,U32,0)
        lines.append('0 '+' '.join(map(str,[op,symbol,match,sequence,price,quantity,tag]))+' '+format(pack(expected,t),'x')+' '+format(pack(future,t),'x')+' '+str(target)+'\n')
        counts['commands']+=1;counts['status%d'%expected[1]]+=1
        if expected[1]==0:
            for k,code in [('adds',0),('busts',1),('corrections',2)]:counts[k]+=int(op==code)
    def reset():lines.append('1\n');model.reset();counts['live_resets']+=1
    cmd(4);cmd(3,match=U64);cmd(1);cmd(2,quantity=0);cmd(15);cmd(5)
    for i in range(n):cmd(0,0,i if i<n-1 else U64,(U64-i)//2,U32 if i%2 else 0,U32)
    cmd(4);cmd(0,0,U64,U64,99,0);cmd(0,U32,U64,U64,99,1)
    cmd(0,0,123456,U64,99,1)
    cmd(2,U32,U64,0,7,1);cmd(3,match=U64);cmd(1,match=U64);cmd(4)
    cmd(0,0,U64,0,1,1);cmd(2,match=U64,price=1,quantity=2);cmd(1,match=U64);cmd(3,match=U64)
    cmd(5)
    # Equal sequence keys use complete match-id ordering for open/close.
    for i in range(n):cmd(0,U32,i,0,(i*19)%2**32,U32)
    cmd(4,U32)
    for i in range(n):cmd(2,0,i,U64,U32-i,U32)
    cmd(4,U32)
    for i in range(n):cmd(1,match=i)
    cmd(4,U32);cmd(0,1,999,0,1,1);cmd(5)
    for i in range(160):
        op=rng.choice([0,0,1,2,3,4,4,5,6,15]);key=rng.choice([0,U64,rng.randrange(n+3)])
        cmd(op,rng.choice([0,1,U32,0x80000000]),key,rng.getrandbits(64),rng.getrandbits(32),rng.choice([0,1,U32,rng.getrandbits(32)]))
        if i in [43,107]:reset()
    cmd(5);cmd(0,0,0,U64,U32,U32);cmd(6);cmd(15);cmd(4);cmd(5)
    reset();cmd(4)
    return ''.join(lines),counts
