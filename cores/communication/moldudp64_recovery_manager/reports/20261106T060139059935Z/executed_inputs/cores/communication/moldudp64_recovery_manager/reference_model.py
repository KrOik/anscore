"""SPDX-License-Identifier: Apache-2.0. Integer/dictionary specification; no RTL imports."""
import random
U64=(1<<64)-1
class Recovery:
    def __init__(self,contexts,maximum):self.contexts=contexts;self.maximum=maximum;self.rows={}
    def reset(self):self.rows.clear()
    def command(self,op,context,session,sequence,nxt,count,tag):
        status=0;emit=0;request=amount=0;snapshot=None
        if op>8:status=9
        elif op==8:self.rows.clear()
        elif context>=self.contexts:status=2
        elif op==6:self.rows.pop(context,None)
        elif op==0:
            self.rows[context]=dict(session=session,next=nxt,target=nxt,until=0,closed=0)
            snapshot=self.rows[context]
        elif context not in self.rows:status=1
        else:
            row=self.rows[context];snapshot=row
            if op==5:pass
            elif op==7:row.update(target=row['next'],until=0,closed=1)
            elif row['closed']:status=8
            elif op==1:
                end=sequence+(0 if count in [0,65535] else count)
                if end>U64:status=3
                elif end<=row['target']:status=5
                else:row['target']=end
            elif op==2:
                if nxt<row['next']:status=4
                elif nxt>row['next']:row.update(next=nxt,target=max(nxt,row['target']),until=0)
            elif op==3:
                if row['until']:status=6
                elif row['target']==row['next']:status=5
                else:
                    request=row['next'];amount=min(row['target']-request,self.maximum)
                    row['until']=request+amount;emit=1
            elif op==4:
                if not row['until']:status=7
                else:emit=1;request=row['next'];amount=row['until']-request
        row=snapshot or dict(session=0,next=0,target=0,until=0,closed=0)
        return [op,status,context,int(snapshot is not None),row['session'],row['next'],row['target'],
            int(bool(row['until'])),row['until'],row['closed'],emit,request,amount,tag]

def pack(values,tag_width):
    result=0
    for value,width in zip(values,[4,4,32,1,80,64,64,1,64,1,1,64,16,tag_width]):
        assert 0<=value<1<<width
        result=(result<<width)|value
    return result

def vectors(contexts,maximum,tag_width):
    model=Recovery(contexts,maximum);rng=random.Random(3947+contexts+maximum);lines=[]
    counts=dict(commands=0,live_resets=0,emits=0)
    counts.update({'status%d'%i:0 for i in range(10)})
    def cmd(op,ctx=0,session=0,seq=0,nxt=0,count=0):
        tag=(counts['commands']*59+3)%2**tag_width
        expected=model.command(op,ctx,session,seq,nxt,count,tag)
        future=model.command(5,0,0,0,0,0,0)
        lines.append('0 '+' '.join(map(str,[op,ctx,session,seq,nxt,count,tag]))+' '+format(pack(expected,tag_width),'x')+' '+format(pack(future,tag_width),'x')+'\n')
        counts['commands']+=1;counts['status%d'%expected[1]]+=1;counts['emits']+=expected[10]
    def reset():lines.append('1\n');model.reset();counts['live_resets']+=1
    cmd(5);cmd(15);cmd(0,contexts);cmd(3,0xffffffff);cmd(8,0xffffffff)
    for ctx in range(contexts):
        start=(1<<63)+ctx*131071 if ctx%2 else ctx*131071
        cmd(0,ctx,(1<<79)+ctx,start,nxt=start);cmd(3,ctx);cmd(4,ctx)
        cmd(1,ctx,seq=start+maximum+5,count=3);cmd(3,ctx);cmd(3,ctx);cmd(4,ctx)
        cmd(1,ctx,seq=start+maximum+20,count=0);cmd(3,ctx);cmd(4,ctx)
        cmd(2,ctx,nxt=start);cmd(2,ctx,nxt=start+1);cmd(3,ctx);cmd(4,ctx)
        cmd(2,ctx,nxt=start);cmd(2,ctx,nxt=start+maximum+20);cmd(3,ctx)
        cmd(1,ctx,seq=U64,count=1);cmd(1,ctx,seq=U64,count=65535);cmd(3,ctx);cmd(4,ctx)
        cmd(2,ctx,nxt=U64);cmd(3,ctx);cmd(7,ctx);cmd(1,ctx,seq=U64);cmd(4,ctx);cmd(5,ctx)
        cmd(0,ctx,session=ctx,nxt=U64);cmd(1,ctx,seq=U64,count=0);cmd(2,ctx,nxt=U64-1)
        cmd(6,ctx);cmd(5,ctx)
    # Independent random interleaving exercises ownership isolation and full high bits.
    for i in range(220):
        op=rng.randrange(16);ctx=rng.choice([rng.randrange(contexts),contexts,0x80000000,0xffffffff])
        seq=rng.choice([0,1,65535,1<<63,U64,U64-65534,rng.getrandbits(64)])
        cmd(op,ctx,rng.getrandbits(80),seq,rng.getrandbits(64),rng.choice([0,1,7,65534,65535]))
        if i in [64,154]:reset()
    cmd(8);cmd(0,contexts-1,session=(1<<80)-1,nxt=0);cmd(1,contexts-1,seq=1,count=0)
    cmd(3,contexts-1);cmd(4,contexts-1);reset();cmd(5,contexts-1)
    return ''.join(lines),counts
