"""SPDX-License-Identifier: Apache-2.0. Plain source dictionaries and min/max."""
import random
U32=(1<<32)-1;U38=(1<<38)-1;U64=(1<<64)-1
WIDTHS=[4,4,32,32,64,64,1,64,1,1,1,32,32,41,41,8,8,1,1]
def pack(values,t):
    result=0
    for value,w in zip(values,WIDTHS+[t]):
        assert 0<=value<1<<w
        result=(result<<w)|value
    return result
class Quotes:
    def __init__(self,symbols,venues):self.symbols=symbols;self.venues=venues;self.reset()
    def reset(self):self.sources={};self.rows={}
    def command(self,op,symbol,venue,epoch,sequence,bv,av,bp,ap,bq,aq,tag):
        status=0;previous=None;quote=False
        if op>5:status=9
        elif op==5:self.reset()
        elif op in [0,1]:
            if venue>=self.venues:status=2
            elif op==0:
                if venue in self.sources and epoch<=self.sources[venue][0]:status=5
                else:self.sources[venue]=(epoch,True)
            elif venue not in self.sources:status=3
            else:self.sources[venue]=(self.sources[venue][0],False)
        elif symbol>=self.symbols:status=1
        elif op==4:quote=True
        elif venue>=self.venues:status=2
        elif venue not in self.sources:status=3
        elif not self.sources[venue][1]:status=4
        elif epoch!=self.sources[venue][0]:status=5
        elif op==3 and ((bv and not bq)or(av and not aq)):status=7
        else:
            old=self.rows.get((symbol,venue))
            if old is not None and old[0]==epoch:previous=old[1]
            if previous is not None and sequence<=previous:status=6
            elif op==3:
                self.rows[symbol,venue]=(epoch,sequence,int(bv),int(av),bp if bv else 0,ap if av else 0,bq if bv else 0,aq if av else 0)
                quote=True
        bids=[];asks=[]
        if quote:
            for (sym,v),row in self.rows.items():
                if sym==symbol and self.sources.get(v)==(row[0],True):
                    if row[2]:bids.append((row[4],row[6],v))
                    if row[3]:asks.append((row[5],row[7],v))
        bid=max((p for p,q,v in bids),default=0);ask=min((p for p,q,v in asks),default=0)
        bidq=sum(q for p,q,v in bids if p==bid);askq=sum(q for p,q,v in asks if p==ask)
        bidmask=sum(1<<v for p,q,v in bids if p==bid);askmask=sum(1<<v for p,q,v in asks if p==ask)
        return [op,status,symbol,venue,epoch,sequence,int(previous is not None),previous or 0,
            int(quote),int(bool(bids)),int(bool(asks)),bid,ask,bidq,askq,bidmask,askmask,
            int(bool(bids and asks)and bid==ask),int(bool(bids and asks)and bid>ask),tag]

def vectors(symbols,venues,t):
    model=Quotes(symbols,venues);rng=random.Random(4007+symbols*venues);lines=[]
    counts=dict(commands=0,live_resets=0,updates=0);counts.update({'status%d'%i:0 for i in range(10)})
    def cmd(op,sym=0,v=0,epoch=0,seq=0,bv=0,av=0,bp=0,ap=0,bq=0,aq=0):
        tag=(counts['commands']*31+5)%2**t
        expected=model.command(op,sym,v,epoch,seq,bv,av,bp,ap,bq,aq,tag)
        fsym=sym if sym<symbols else 0
        future=model.command(4,fsym,U32,U64,U64,0,0,0,0,0,0,0)
        lines.append('0 '+' '.join(map(str,[op,sym,v,epoch,seq,bv,av,bp,ap,bq,aq,tag]))+' '+format(pack(expected,t),'x')+' '+format(pack(future,t),'x')+'\n')
        counts['commands']+=1;counts['status%d'%expected[1]]+=1;counts['updates']+=int(op==3 and expected[1]==0)
    def reset():lines.append('1\n');model.reset();counts['live_resets']+=1
    cmd(4);cmd(2);cmd(1);cmd(0,v=venues);cmd(3,sym=symbols);cmd(2,v=U32);cmd(15,sym=U32,v=U32);cmd(5,sym=U32,v=U32)
    for v in range(venues):cmd(0,sym=U32,v=v,epoch=100+v)
    for sym in range(symbols):
        for v in range(venues):
            cmd(3,sym,v,100+v,(1<<63)+sym*16+v,1,1,100+sym,105+sym,U38,U38)
        cmd(4,sym,v=U32,epoch=U64,seq=U64)
    for v in range(venues):
        old=(1<<63)+v
        cmd(2,v=v,epoch=100+v,seq=old)
        cmd(3,v=v,epoch=100+v,seq=old,bv=1,bq=0)
        cmd(2,v=v,epoch=100+v,seq=old+1,bv=1,bq=0)
        cmd(3,v=v,epoch=100+v,seq=old+1,bp=U32,ap=U32,bq=U38,aq=U38)
        cmd(3,v=v,epoch=100+v,seq=old+2,bv=1,av=1,bp=0,ap=U32,bq=1,aq=U38)
        cmd(1,sym=U32,v=v,epoch=U64,seq=U64);cmd(4)
        cmd(2,v=v,epoch=100+v,seq=U64);cmd(0,v=v,epoch=100+v)
        cmd(0,v=v,epoch=101+v);cmd(4)
        cmd(3,v=v,epoch=100+v,seq=U64,bv=1,bq=1)
        cmd(3,v=v,epoch=101+v,seq=0,bv=1,av=1,bp=U32,ap=0,bq=U38,aq=U38)
        cmd(3,v=v,epoch=101+v,seq=0,bv=1,bq=1)
    # Complete tie mask and 41-bit sums, locked then independently crossed sides.
    for v in range(venues):cmd(3,v=v,epoch=101+v,seq=1,bv=1,av=1,bp=U32,ap=U32,bq=U38,aq=U38)
    cmd(4);cmd(0,v=venues-1,epoch=U64-1);cmd(3,v=venues-1,epoch=U64-1,seq=U64,bv=1,av=1,bp=U32,ap=0,bq=1,aq=1)
    cmd(2,v=venues-1,epoch=U64-1,seq=U64);cmd(0,v=venues-1,epoch=U64);cmd(0,v=venues-1,epoch=0)
    cmd(3,v=venues-1,epoch=U64,seq=0,bv=1,bp=0,bq=1)
    for i in range(180):
        op=rng.choice([0,1,2,3,3,3,4,5,15]);sym=rng.choice([rng.randrange(symbols),symbols,U32,0x80000000])
        v=rng.choice([rng.randrange(venues),venues,U32]);e=rng.getrandbits(64);seq=rng.getrandbits(64)
        if v in model.sources and rng.randrange(3):e=model.sources[v][0]
        if sym<symbols and (sym,v)in model.rows and rng.randrange(2):seq=min(U64,model.rows[sym,v][1]+rng.randrange(3))
        cmd(op,sym,v,e,seq,rng.randrange(2),rng.randrange(2),rng.getrandbits(32),rng.getrandbits(32),rng.choice([0,1,U38,rng.getrandbits(38)]),rng.choice([0,1,U38,rng.getrandbits(38)]))
        if i in [57,123]:reset()
    cmd(5);cmd(0,v=venues-1,epoch=0);cmd(3,symbols-1,venues-1,0,0,1,1,0,U32,U38,U38)
    cmd(4,symbols-1);reset();cmd(4)
    return ''.join(lines),counts
