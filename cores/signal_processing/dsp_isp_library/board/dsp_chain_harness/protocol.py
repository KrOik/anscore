"""External sample protocol and independent DC -> statistics integer oracle."""
import random, struct, sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
LIB=HERE.parents[1]
sys.path.insert(0,str(HERE if (HERE/'dc_reference.py').exists() else LIB/'dsp/dc/models'))
from dc_reference import Config as DCConfig, FixedReference
sys.path.insert(0,str(HERE if (HERE/'reference.py').exists() else LIB/'dsp/statistics/models'))
from reference import Config as StatsConfig, IntegerModel, pack

def make_packet(tag,config,words,stall=0):
    if not 1<=len(words)<=64 or not 0<=stall<=7:raise ValueError('capacity/stall')
    if any(not -32768<=v<=32767 for v in words):raise ValueError('signed16')
    return b'DSC1'+struct.pack('<IIBB',tag,config,len(words),stall)+struct.pack('<'+'h'*len(words),*words)

def oracle(config,words):
    if config>>26:raise ValueError('reserved configuration bits')
    dc=FixedReference(DCConfig(('blocker','mean','baseline')[config&3],(config>>2)&65535,(config>>18)&15))
    stats=IntegerModel(StatsConfig(False,(config>>22)&15,0,0x10000000))
    return [pack(stats.step(dc.step(x)[0])) for x in words]

def expected_cycles(n,stall,dc_latency,stats_latency=1):
    if dc_latency not in (1,2):raise ValueError('qualified DC stage count must be 1 or 2')
    if not 1<=stats_latency<=17:raise ValueError('statistics latency')
    valid=[False]*(dc_latency+stats_latency);sent=got=cycles=0
    while got<n:
        ready=[False]*len(valid);sink=cycles%8>=stall
        for i in reversed(range(len(valid))):
            ready[i]=not valid[i] or (sink if i==len(valid)-1 else ready[i+1])
        if valid[-1] and sink:got+=1
        accept=sent<n and ready[0]
        valid=[(accept if i==0 else valid[i-1]) if ready[i] else valid[i] for i in range(len(valid))]
        sent+=int(accept);cycles+=1
    return cycles

def verify(report,tag,config,words,stall,dc_latency=1,stats_latency=1):
    if len(report)!=20+17*len(words) or report[:4]!=b'DST1':raise AssertionError('report framing/count')
    rt,rc,n,flags,inc,outc,cycles=struct.unpack('<IIBBBBI',report[4:20])
    if (rt,rc,n,flags,inc,outc)!=(tag,config,len(words),0,len(words),len(words)):raise AssertionError('identity/flags/counters')
    expected=oracle(config,words)
    actual=[(int.from_bytes(report[20+17*i:36+17*i],'little'),report[36+17*i]) for i in range(n)]
    if actual!=expected:raise AssertionError(('numerical',actual,expected))
    want=expected_cycles(n,stall,dc_latency,stats_latency)
    if cycles!=want:raise AssertionError(('cycles',cycles,want))
    return dict(status='PASS',tag=tag,count=n,cycles=cycles,latency=dc_latency+stats_latency,stall=stall)

def cases():
    rng=random.Random(65024);result=[]
    for lg in (0,4,6):
        for stall in (0,1,7):
            values=[0,-32768,32767,-1,1,1000,-1000]+[rng.randrange(-32768,32768) for _ in range(57)]
            result.append((0xDC570000+lg*16+stall,(65024<<2)|(4<<18)|(lg<<22),values,stall))
    result.append((0xDC570100,(65024<<2)|(4<<18),[-32768],0))
    return result
