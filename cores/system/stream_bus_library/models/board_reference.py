"""Host-generated variable stimuli and independent expected raw response fields."""
import random
import sys
from pathlib import Path
from reference import calibration,fault

LEGACY=Path(__file__).resolve().parents[2]/'production_ip_25k'
sys.path.insert(0,str(LEGACY/'tools'))
import catalog
import golden
MASK192=(1<<192)-1

def row(a,b=0,c=0): return (a&0xffffffff)|((b&0xffffffff)<<32)|((c&0xffffffff)<<64)

def vectors(profile,core,seed):
    rng=random.Random(seed+7919*core+100003*profile)
    data=[]; expected=[]; mask=MASK192; extra={}
    if profile==8:
        values=[rng.randrange(-8388608,8388608) for _ in range(68)]
        for epoch in range(17):
            lanes=list(range(4)); rng.shuffle(lanes)
            data.extend(row(values[epoch*4+c],epoch,c) for c in lanes)
        for i in range(59,68):
            ch=i%4; gain=[8192,16384,-8192,32767][ch]; offset=[100,-100,0,500][ch]
            y,sat=calibration(values[i],gain,offset)
            expected.append(y|(ch<<24)|(sat<<26)|(i<<32)|(int(i==67)<<112)|(9<<128))
        mask=MASK192^(((1<<64)-1)<<48); extra={'timestamp_shift':48}
        return dict(name='acquisition_demo',rows=data,expected=expected,mask=mask,extra=extra)
    if profile:
        name=catalog.CORES[(profile-1)*8+core]['name']
        # Two sets of host-selected random inputs, plus fixed edge cases.
        base=golden.vectors(name,count=192)
        start=seed%max(1,len(base)-128)
        triplets=base[start:start+128]
        # Seeds alter VALUES as well as window; preserve command validity
        # constraints by drawing additional rows from the independent generator.
        rng.shuffle(triplets)
        state=0
        for a,b,c in triplets:
            r,x,f,state=golden.step(name,a,b,c,state)
            data.append(row(a,b,c)); expected.append(r|(x<<32)|(f<<64))
        return dict(name=name,rows=data,expected=expected,mask=mask,extra=extra)
    name=['frame_switch4','width_converter','packet_async_fifo','backpressure_isolator','axi_lite_interconnect',
          'bus_timeout_monitor','atomic_config','register_snapshot','timestamp64','frame_align4','trigger_window',
          'calibration24','march_controller','fault_injector','stream_metrics','capture_replay'][core]
    if core==0:
        for i in range(64):
            src=(i//2)%4; dst=(i//8)%4; last=i%2; a=rng.getrandbits(32); keep=i%16; user=i
            data.append(row(a,src|(dst<<2)|(last<<4),keep|(user<<8)))
            expected.append(a|(keep<<32)|(user<<36)|(dst<<44)|(last<<46))
    elif core==1:
        for i in range(64):
            a=rng.getrandbits(32); keep=i%16; last=int(i%5==4 or i==63); user=i
            data.append(row(a,keep|(last<<4),user))
            bs=[(a>>(8*j))&255 for j in range(4) if keep>>j&1] or [0]
            expected.extend(x|(int(keep!=0)<<32)|(user<<36)|(int(last and j==len(bs)-1)<<44) for j,x in enumerate(bs))
    elif core==2:
        drops=0
        for n in [3,16,19,7]:
            values=[rng.getrandbits(32) for _ in range(n)]
            data.extend(row(x,int(i==n-1)) for i,x in enumerate(values))
            if n>16: drops+=1
            else: expected.extend(x|(int(i==n-1)<<32)|(drops<<33) for i,x in enumerate(values))
    elif core in [3,14,15]:
        data=[rng.getrandbits(96) for _ in range(128)]; expected=data.copy()
    elif core==4:
        store=[0]*4
        for i in range(64):
            dst=i%5; address=(dst<<12)|(0x804 if i%7==0 else 4); write=int(i%3!=2); first=i%2
            value=rng.getrandbits(32); st=i%16
            data.append(row(address|(write<<16)|(5<<17)|(first<<20),value,st))
            resp=3 if dst==4 else (2 if address&0x800 else 0)
            if dst<4 and write:
                for k in range(4):
                    if st>>k&1: store[dst]=(store[dst]&~(255<<(8*k)))|(value&(255<<(8*k)))
            out=0 if dst==4 else store[dst]
            expected.append(out|(resp<<32)|(write<<34)|(address<<48))
    elif core==5:
        timeouts=overlaps=late=max_age=0
        for i in range(24):
            limit=[0,3,8,20][i%4]; delay=[2,3,10,25][(i//4)%4]; overlap=i%2
            data.append(row(overlap,limit,delay))
            timed=bool(limit and delay>=limit)
            timeouts+=int(timed); overlaps+=overlap; late+=int(timed); max_age=max(max_age,delay)
            expected.append(timeouts|(overlaps<<32)|(late<<64)|(max_age<<96))
    elif core==6:
        active=[0]*4
        for i in range(32):
            index=i%4; st=i%16; a=rng.getrandbits(32)
            data.append(row(a,index|(st<<4),i%7))
            for b in range(4):
                if st>>b&1: active[index]=(active[index]&~(255<<(8*b)))|(a&(255<<(8*b)))
            expected.append(sum(x<<(32*j) for j,x in enumerate(active))|((i+1)<<128))
    elif core==7:
        data=[rng.getrandbits(96) for _ in range(128)]; expected=data.copy(); mask=(1<<128)-1; extra={'timestamp_shift':128}
    elif core==8:
        for i in range(128):
            a=rng.getrandbits(32); b=i
            data.append(row(a,b)); expected.append(a|(b<<32))
        mask=(1<<48)-1; extra={'timestamp_shift':48}
    elif core==9:
        for epoch in range(24):
            values=[rng.getrandbits(32) for _ in range(4)]; lanes=list(range(4)); rng.shuffle(lanes)
            data.extend(row(values[c],epoch,c) for c in lanes)
            expected.append(sum(a<<(32*c) for c,a in enumerate(values))|(epoch<<128))
    elif core==10:
        trigger_index=59 if seed%2 else 2
        values=[rng.getrandbits(32) for _ in range(trigger_index+5)]
        data=[row(a,int(i==trigger_index)) for i,a in enumerate(values)]
        chosen=values[max(0,trigger_index-4):trigger_index+5]
        expected=[a|(int(i==len(chosen)-1)<<32)|(len(chosen)<<33) for i,a in enumerate(chosen)]
    elif core==11:
        for i in range(128):
            s=[-8388608,-1,0,8388607][i%4] if i<16 else rng.randrange(-8388608,8388608)
            g=[-32768,-1,16384,32767][i//4] if i<16 else rng.randrange(-32768,32768)
            off=rng.randrange(-8388608,8388608); ch=i%4
            data.append(row(s,(i<<16)|(g&65535),(off&0xffffff)|(ch<<24)))
            y,sat=calibration(s,g,off); expected.append(y|(ch<<24)|(sat<<26)|(i<<32))
    elif core==12:
        data=[row(i) for i in [0,1,2,4]]
        expected=[0,5|(3<<64)|(1<<70),1,1]
        mask=MASK192^(((1<<32)-1)<<32); extra={'march_cycles':True}
    elif core==13:
        phase=injections=0
        for i in range(128):
            a=rng.getrandbits(32); b=rng.getrandbits(32); mode=i%4; enable=int(i%7!=0); period=(i//24)%4
            data.append(row(a,b,mode|(enable<<2)|(period<<8)))
            y,inj,err=fault(a,b,mode,enable,phase); injections+=inj
            expected.append(y|(inj<<32)|(err<<33)|(injections<<64))
            phase=0 if period==0 or phase>=period-1 else phase+1
    return dict(name=name,rows=data,expected=expected,mask=mask,extra=extra)

def validate(case,actual):
    assert len(actual)==len(case['expected']), 'raw response count'
    mask=case['mask']
    for i,(a,e) in enumerate(zip(actual,case['expected'])):
        assert a&mask==e&mask,(case['name'],i,hex(a&mask),hex(e&mask))
    if 'timestamp_shift' in case['extra']:
        times=[(a>>case['extra']['timestamp_shift'])&((1<<64)-1) for a in actual]
        assert all(b>a for a,b in zip(times,times[1:])), 'timestamp monotonicity'
    if case['extra'].get('march_cycles'):
        times=[(a>>32)&0xffffffff for a in actual]
        assert times[0]>1000 and times[1]==times[0] and 0<times[2]<times[0] and times[3]>=128
