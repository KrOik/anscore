"""SPDX-License-Identifier: Apache-2.0. Finite, deterministic transactions."""
from reference_model import Reassembly,make_header
import random
PROFILES=[(1,1,0),(37,8,0),(4096,32,0),(80,8,1)]
def vectors(n,t,ex):
    rng=random.Random(3901+n+ex);model=Reassembly(n);lines=[]
    counts=dict(commands=0,input_bytes=0,replay_bytes=0,complete=0,resets=0,header_rejects=0)
    counts.update({'status%d'%i:0 for i in range(9)})
    key=(0xc0a80101,0xc0a80102,0x1234,17)
    def reset():lines.append('1\n');model.reset();counts['resets']+=1
    def cmd(op=0,off=0,more=0,length=1,k=None,data=None,bad_at=None,mode=0):
        k=key if k is None else k;tag=(counts['commands']*29+7)%2**t
        valid_header=not(ex and op==0 and (mode in [1,2,4,5] or (mode==3 and (more or off))))
        start=off*8;stop=start+length
        # Decide whether the independently specified descriptor consumes bytes.
        rejected=(not valid_header or op!=0 or length<1 or stop>min(n,65515) or
          (more and length%8) or (model.key is not None and model.key!=k) or
          (model.key is not None and ((model.end is not None and
            (stop>model.end or (not more and stop!=model.end) or (more and stop>=model.end))) or
            (not more and model.data and stop<=max(model.data)))) or
          any(i in model.data for i in range(start,stop)))
        payload=[]
        if not rejected:
            raw=data if data is not None else [rng.randrange(256)for _ in range(length)]
            payload=[(v,int(i==length-1))for i,v in enumerate(raw)]
            if bad_at is not None:
                payload[bad_at]=(payload[bad_at][0],1-payload[bad_at][1]);payload=payload[:bad_at+1]
        response,pub=model.command(op,k,off,more,length,payload,not valid_header)
        # For maximum core profile, no full-capacity replay is generated.
        header=make_header(k,off,more,length,mode)if ex and length<=65515 else 0
        fields=[op,*k,off,more,length,tag,len(payload),*response,len(pub)]
        lines.append('0 '+' '.join(map(str,fields))+' '+format(header,'040x')+'\n')
        lines.extend('%d %d\n'%p for p in payload)
        lines.extend('%d\n'%v for v in pub)
        counts['commands']+=1;counts['input_bytes']+=len(payload);counts['replay_bytes']+=len(pub)
        counts['complete']+=response[1];counts['status%d'%response[0]]+=1
        counts['header_rejects']+=int(response[0]==8)
    cmd(2);cmd(3);cmd(1);cmd(length=0);cmd(length=n+1);cmd(off=8191,length=65515)
    cmd(more=1,length=1);cmd(length=1,data=[0]);cmd(length=1,data=[255]);cmd(2)
    # Every context field participates in foreign-key rejection.
    if n>=17:
        cmd(more=1,length=8,data=list(range(8)))
        for i in range(4):
            alt=list(key);alt[i]^=1;cmd(off=1,length=1,k=tuple(alt))
        cmd(more=1,length=8);cmd(off=0,length=7);cmd(off=1,length=1)
        cmd(2);cmd(1)
        # Last fragment first, holes, same-end conflicts, and MF at known end.
        cmd(off=2,length=1,data=[201]);cmd(off=1,length=1);cmd(off=1,more=1,length=8)
        cmd(off=2,more=1,length=8);cmd(off=0,more=1,length=8,data=list(range(8)))
        cmd(2)
        cmd(off=1,more=1,length=8,data=list(range(8,16)));cmd(2)
        # Late terminal contradicts already stored higher bytes.
        cmd(off=2,more=1,length=8);cmd(off=0,length=8);cmd(2);cmd(1)
        # Reverse fragments, then final contiguous completion.
        for _ in range(3):
            cmd(off=1,more=1,length=8);cmd(off=2,length=3);cmd(off=0,more=1,length=8)
        cmd(more=1,length=8,bad_at=0);cmd(2)
        cmd(length=3,bad_at=2);cmd(2);cmd(length=3)
        # Capacity-tail storage then FLUSH, covers partial last ownership block.
        off=(n-1)//8;cmd(off=off,length=n-off*8);cmd(2);cmd(1)
        for j in range(12):
            size=rng.randrange(1,6);cmd(off=1,length=size)
            cmd(off=0,more=1,length=8);cmd(2)
    else:
        cmd(length=1,bad_at=0);cmd(2);cmd(length=1)
    if ex:
        cmd(more=1,length=8)
        for mode in [1,2,3,4,5]:cmd(off=1,length=1,mode=mode)
        cmd(2);cmd(off=1,length=1)
        cmd(length=1,k=(0xffffffff,0xffffffff,65535,255),data=[255])
        cmd(length=1,k=(0,0,0,0),data=[0])
    # Explicit reset hides an incomplete context; recovery publishes new bytes.
    if n>=8:cmd(more=1,length=8)
    reset();cmd(2);cmd(length=1,data=[0x5a]);cmd(1)
    return ''.join(lines),counts
