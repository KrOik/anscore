"""Host vectors and strict raw report verification; no DUT-derived golden."""
import sys,struct,random
from pathlib import Path
HERE=Path(__file__).resolve().parent;LIB=HERE.parents[1]
sys.path.insert(0,str(LIB/'isp'));sys.path.insert(0,str(LIB/'dsp/dc/models'))
from csc_model import bit_exact
from dc_reference import FixedReference,Config

def make_packet(tag,config,words,stall=0):
    if not 1<=len(words)<=64 or not 0<=stall<=7: raise ValueError('capacity/stall')
    return b'BLK1'+struct.pack('<IIBB',tag,config,len(words),stall)+struct.pack('<'+'I'*len(words),*words)

def oracle(core,bits,config,words):
    if core==2:return list(words)
    if core==0:
        model=FixedReference(Config(('blocker','mean','baseline')[config&3],(config>>2)&65535,(config>>18)&15))
        answer=[]
        for w in words:
            x=w&65535;x=x-65536 if x&32768 else x
            y,b=model.step(x);answer.append(((b&65535)<<16)|(y&65535))
        return answer
    m=(1<<bits)-1;answer=[]
    for index,w in enumerate(words):
        p=((w>>(bits*2))&m,(w>>bits)&m,w&m)
        out=bit_exact(p,bits,('601','709')[(config>>1)&1],bool(config&1),('forward','inverse','gray')[config>>2])
        out=out+(0,)*(3-len(out));answer.append((int(index==0)<<31)|(int(index==len(words)-1)<<30)|(out[0]<<(bits*2))|(out[1]<<bits)|out[2])
    return answer

def verify(report,tag,config,words,core,bits,stall,latency=1):
    expected=oracle(core,bits,config,words)
    if len(report)!=20+4*len(words) or report[:4]!=b'RES1':raise AssertionError('report framing/count')
    rt,rc,n,flags,inc,outc,cycles=struct.unpack('<IIBBBBI',report[4:20])
    if (rt,rc,n,flags,inc,outc)!=(tag,config,len(words),0,len(words),len(words)):raise AssertionError('identity/flags/counters')
    # One elastic output stage, first accepted input at replay cycle zero.
    if not 1<=latency<=16:raise ValueError('latency')
    phase=0;sent=got=0;valid=[False]*latency;expected_cycles=0
    while got<len(words):
        ready=phase>=stall;advance=not valid[-1] or ready;accept=sent<len(words) and advance
        if valid[-1] and ready:got+=1
        if advance:valid=[accept]+valid[:-1]
        sent+=int(accept);phase=(phase+1)%8;expected_cycles+=1
    if cycles!=expected_cycles:raise AssertionError(('cycles',cycles,expected_cycles))
    actual=list(struct.unpack('<'+'I'*n,report[20:]))
    if actual!=expected:raise AssertionError(('numerical',actual,expected))
    return dict(status='PASS',count=n,cycles=cycles,tag=tag)

def cases(core,bits):
    rng=random.Random(268+core+bits)
    if core==2:
        return [(0x1D000000+i,0,[rng.getrandbits(32) for _ in range(64)],stall) for i,stall in enumerate((0,1,7,0,7))]
    configs=range(12) if core else [(mode|(65024<<2)|(lg<<18)) for mode,lg in ((0,4),(1,0),(1,3),(1,6),(2,4))]
    result=[]
    for i,c in enumerate(configs):
        n=1 if i==0 else 64
        if core: words=[rng.randrange(1<<(3*bits)) for _ in range(n)]
        else:words=[x&65535 for x in ([0,-32768,32767,1000]*16)[:n]]
        tag=0xBC000000+bits*256+i;stall=(0,1,7)[i%3]
        result.append((tag,c,words,stall))
    return result
