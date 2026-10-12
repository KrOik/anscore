"""Independent scoreboards exercise native ports, resets and stalled transfers."""
import os
import json
import random
from collections import deque
import cocotb
from cocotb.triggers import Timer
from reference import calibration, fault, march_commands

PARAMS=json.loads(os.environ.get('SYS_PARAMS','{}'))
R=random.Random(0x250916)

def setv(d,**values):
    for k,v in values.items(): getattr(d,k).value=v
def val(d,k): return int(getattr(d,k).value)

async def step(d,**values):
    d.clk.value=0
    setv(d,**values)
    await Timer(5,unit='ns')
    # Sample before edge; returned handshakes are those consumed on this edge.
    old={s._name:int(s.value) for s in d if hasattr(s,'value') and getattr(s.value,'is_resolvable',False)}
    d.clk.value=1
    await Timer(5,unit='ns')
    return old

async def reset(d,**values):
    await step(d,rst_n=0,**values)
    await step(d,rst_n=0)
    await step(d,rst_n=1)

async def backpressure_isolator(d):
    await reset(d,s_data=0,s_valid=0,m_ready=0)
    q=deque(); sent=got=0; held=None
    for t in range(600):
        ready=int(t>20 and R.randrange(4)!=0)
        o=await step(d,s_valid=int(sent<200),s_data=sent*7919,m_ready=ready)
        if held is not None: assert o['m_valid'] and o['m_data']==held
        held=o['m_data'] if o['m_valid'] and not ready else None
        if o['s_valid'] and o['s_ready']: q.append(sent*7919); sent+=1
        if o['m_valid'] and ready: assert o['m_data']==q.popleft(); got+=1
        if t==19:
            a=val(d,'s_ready'); d.m_ready.value=1
            await Timer(1,unit='ns'); assert val(d,'s_ready')==a==0
        if got==200: break
    assert sent==got==200 and not q
    await reset(d,s_valid=0,m_ready=0); assert val(d,'m_valid')==0

async def frame_switch4(d):
    await reset(d,s_data=0,s_keep=0,s_last=0,s_valid=0,s_user=0,s_dest=0,m_ready=0)
    # Four sources contend, then each exercises every destination. Frame
    # lengths differ; source increments ONLY after acceptance.
    packets=[deque((dst,length) for dst,length in [(0,3)]+[(x,1+i%3) for x in range(4)]*4) for i in range(4)]
    beat=[0]*4; serial=[0]*4; expected=[deque() for _ in range(4)]
    locked=[None]*4; held=[None]*4; frames=0; count=0
    for t in range(1500):
        data=keep=last=valid=user=dest=0
        for i in range(4):
            if packets[i]:
                dst,n=packets[i][0]
                data|=((i<<28)|(serial[i]<<8)|beat[i])<<(32*i)
                keep|=(1+(beat[i]%15))<<(4*i); user|=(0x30+i)<<(8*i)
                valid|=1<<i; dest|=dst<<(2*i)
                last|=int(beat[i]==n-1)<<i
        mr=sum(int(t>15 and R.randrange(4)!=0)<<i for i in range(4))
        o=await step(d,s_data=data,s_keep=keep,s_last=last,s_valid=valid,s_user=user,s_dest=dest,m_ready=mr)
        for i in range(4):
            if valid>>i&1 and o['s_ready']>>i&1:
                dst,n=packets[i][0]; word=(data>>(32*i))&0xffffffff
                expected[dst].append((word,(keep>>(4*i))&15,(last>>i)&1,0x30+i))
                beat[i]+=1; count+=1
                if beat[i]==n: packets[i].popleft(); beat[i]=0; serial[i]+=1
        for j in range(4):
            item=((o['m_data']>>(32*j))&0xffffffff,(o['m_keep']>>(4*j))&15,(o['m_last']>>j)&1,(o['m_user']>>(8*j))&255)
            mv=o['m_valid']>>j&1
            if held[j] is not None: assert mv and item==held[j],('switch hold',j)
            held[j]=item if mv and not(mr>>j&1) else None
            if mv and mr>>j&1:
                assert expected[j] and item==expected[j].popleft(),('route',j,item)
                owner=item[0]>>28
                if locked[j] is None: locked[j]=owner
                assert owner==locked[j], 'interleaved frame'
                if item[2]: frames+=1; locked[j]=None
        if not any(packets) and not any(expected) and not o['m_valid']: break
    assert frames==68 and count>100 and val(d,'frames')==frames
    await reset(d,s_valid=0,m_ready=0); assert val(d,'m_valid')==0

async def width_converter(d):
    await reset(d,s_data=0,s_keep=0,s_user=0,s_last=0,s_valid=0,m_ready=0)
    mode=PARAMS.get('MODE',0); rows=[]; expected=[]
    if mode==0:
        for i in range(160):
            a=R.getrandbits(32); k=i%16; last=int(i%5==4); u=i&255
            rows.append((a,k,u,last))
            bs=[(a>>(8*j))&255 for j in range(4) if k>>j&1] or [0]
            expected.extend((b,int(k!=0),u,int(last and j==len(bs)-1)) for j,b in enumerate(bs))
    else:
        partial=[]; first=0
        for i in range(200):
            a=R.getrandbits(8); k=int(i%7!=0); last=int(i%9==8 or i==199); u=i&255
            rows.append((a,k,u,last))
            if not partial: first=u
            if k: partial.append(a)
            if len(partial)==4 or last:
                expected.append((sum(b<<(8*j) for j,b in enumerate(partial)),(1<<len(partial))-1,first,last))
                partial=[]
    sent=got=0; held=None
    for t in range(2200):
        row=rows[sent] if sent<len(rows) else (0,0,0,0)
        mr=int(t>10 and R.randrange(3)!=0)
        o=await step(d,s_valid=int(sent<len(rows)),s_data=row[0],s_keep=row[1],s_user=row[2],s_last=row[3],m_ready=mr)
        item=tuple(o[k] for k in ['m_data','m_keep','m_user','m_last'])
        if held is not None: assert o['m_valid'] and held==item
        held=item if o['m_valid'] and not mr else None
        if o['s_valid'] and o['s_ready']: sent+=1
        if o['m_valid'] and mr: assert item==expected[got],(mode,got,item,expected[got]); got+=1
        if sent==len(rows) and got==len(expected): break
    assert sent==len(rows) and got==len(expected)
    await reset(d,s_valid=0); assert val(d,'m_valid')==0

async def packet_async_fifo(d):
    # Event scheduler uses distinct rising edges, including 3:5 and 7:2 ratios.
    for sp,mp in [(3,5),(7,2)]:
        setv(d,s_clk=0,m_clk=0,rst_n=0,s_data=0,s_last=0,s_valid=0,m_ready=0)
        await Timer(20,unit='ns'); d.rst_n.value=1
        depth=PARAMS['DEPTH']; packets=[list(range(1,4)),list(range(100,100+depth)),list(range(200,200+depth+3)),[777]]
        p=idx=0; expect=deque(); got=[]; held=None; committed=False
        for t in range(1,3000):
            srise=t%sp==0; mrise=t%mp==0
            if p<len(packets):
                setv(d,s_valid=1,s_data=packets[p][idx],s_last=int(idx==len(packets[p])-1))
            else: d.s_valid.value=0
            d.m_ready.value=int(t>40 and t%11 not in (2,3,4))
            d.s_clk.value=0; d.m_clk.value=0
            await Timer(1,unit='ns')
            take=srise and val(d,'s_valid') and val(d,'s_ready')
            pop=mrise and val(d,'m_valid') and val(d,'m_ready')
            if mrise:
                item=(val(d,'m_data'),val(d,'m_last')) if val(d,'m_valid') else (0,0)
                if held is not None: assert val(d,'m_valid') and item==held
                held=item if val(d,'m_valid') and not val(d,'m_ready') else None
            if pop:
                assert expect and item==expect.popleft(),('CDC output',item)
                got.append(item[0])
            if take:
                idx+=1
                if idx==len(packets[p]):
                    if idx<=depth: expect.extend((x,int(j==idx-1)) for j,x in enumerate(packets[p]))
                    p+=1; idx=0
            if srise: d.s_clk.value=1
            if mrise: d.m_clk.value=1
            await Timer(1,unit='ns')
            if p==4 and not expect and len(got)==depth+4: break
        assert got==packets[0]+packets[1]+packets[3] and val(d,'dropped_packets')==1
        # Cancel an unfinished packet with common reset, then clocks recover.
        d.rst_n.value=0; await Timer(2,unit='ns'); assert val(d,'m_valid')==0

async def atomic_config(d):
    await reset(d,write_valid=0,write_index=0,write_data=0,write_strb=0,commit_valid=0,apply_safe=0)
    shadow=[0]*4; version=0
    for n in range(30):
        i=n%4; a=R.getrandbits(32); st=n%16
        await step(d,write_valid=1,write_index=i,write_data=a,write_strb=st,commit_valid=1,apply_safe=0)
        for b in range(4):
            if st>>b&1: shadow[i]=(shadow[i]&~(255<<(8*b)))|(a&(255<<(8*b)))
        assert val(d,'pending') and not val(d,'write_ready') and not val(d,'commit_ready')
        prior=val(d,'active')
        for _ in range(3):
            await step(d,write_valid=1,write_data=0xffffffff,write_strb=15,commit_valid=1)
            assert val(d,'active')==prior
        await step(d,apply_safe=1)
        version+=1
        assert val(d,'active')==sum(x<<(32*j) for j,x in enumerate(shadow)) and val(d,'version')==version
        await step(d,write_valid=0,commit_valid=0,apply_safe=0)
    await step(d,write_valid=1,write_data=0x12345678,write_index=0,write_strb=15,commit_valid=1,apply_safe=1)
    assert val(d,'active')&0xffffffff==0x12345678 and not val(d,'pending') and val(d,'version')==31

async def register_snapshot(d):
    await reset(d,live=0,s_valid=0,m_ready=0)
    q=deque(); seq=0; held=None; now=1
    for t in range(200):
        live=R.getrandbits(128); sv=int(R.randrange(4)!=0); mr=int(t>8 and R.randrange(3)!=0)
        o=await step(d,live=live,s_valid=sv,m_ready=mr)
        item=(o['snapshot'],o['timestamp'],o['snapshot_id'])
        if held is not None: assert o['m_valid'] and item==held
        held=item if o['m_valid'] and not mr else None
        if o['m_valid'] and mr: assert item==q.popleft()
        if sv and o['s_ready']: seq+=1; q.append((live,now,seq))
        now+=1
    while q:
        o=await step(d,s_valid=0,m_ready=1)
        if o['m_valid']: assert (o['snapshot'],o['timestamp'],o['snapshot_id'])==q.popleft()

async def timestamp64(d):
    await reset(d,load_valid=0,load_time=0,s_data=0,s_tag=0,s_valid=0,m_ready=0)
    q=deque(); held=None; now=1
    for t in range(200):
        load=int(t in (0,30,100)); new=0xfffffffffffffffd if t==30 else 0x1234+t
        a=R.getrandbits(32); tag=t; sv=int(R.randrange(4)!=0); mr=int(t>8 and R.randrange(3)!=0)
        o=await step(d,load_valid=load,load_time=new,s_data=a,s_tag=tag,s_valid=sv,m_ready=mr)
        assert o['now']==now
        item=(o['m_data'],o['m_tag'],o['m_time'])
        if held is not None: assert o['m_valid'] and held==item
        held=item if o['m_valid'] and not mr else None
        if o['m_valid'] and mr: assert item==q.popleft()
        if sv and o['s_ready']: q.append((a,tag,now))
        now=new if load else (now+1)&((1<<64)-1)
    while q:
        o=await step(d,s_valid=0,m_ready=1,load_valid=0)
        if o['m_valid']: assert (o['m_data'],o['m_tag'],o['m_time'])==q.popleft()

async def calibration24(d):
    await reset(d,s_data=0,s_offset=0,s_gain=0,s_channel=0,s_tag=0,s_valid=0,m_ready=0)
    rows=[(s,g,o) for s in [-8388608,-1,0,1,8388607] for g in [-32768,-16384,-1,0,1,16384,32767] for o in [-8388608,0,8388607]]
    rows += [(R.randrange(-8388608,8388608),R.randrange(-32768,32768),R.randrange(-8388608,8388608)) for _ in range(300)]
    sent=got=0; q=deque(); held=None; cycles=0
    while cycles<16000 and got<len(rows):
        s,g,off=rows[sent] if sent<len(rows) else (0,0,0)
        mr=int(R.randrange(4)!=0)
        o=await step(d,s_data=s&0xffffff,s_gain=g&65535,s_offset=off&0xffffff,s_tag=sent,s_channel=sent%4,s_valid=int(sent<len(rows)),m_ready=mr)
        item=(o['m_data'],o['m_saturated'],o['m_tag'],o['m_channel'])
        if held is not None: assert o['m_valid'] and item==held
        held=item if o['m_valid'] and not mr else None
        if o['s_valid'] and o['s_ready']:
            y,sat=calibration(s,g,off); q.append((y,sat,sent,sent%4)); sent+=1
        if o['m_valid'] and mr: assert item==q.popleft(),(got,item); got+=1
        cycles+=1
    assert sent==got==len(rows)

async def fault_injector(d):
    await reset(d,s_data=0,mask=0,mode=0,enable=0,period=0,s_valid=0,m_ready=0)
    q=deque(); phase=0; injections=0; held=None
    for t in range(400):
        data=R.getrandbits(32); mask=R.getrandbits(32); mode=t%4; enable=int(t%7!=0); period=(t//40)%5
        sv=int(t%5!=0); mr=int(t>10 and R.randrange(3)!=0)
        o=await step(d,s_data=data,mask=mask,mode=mode,enable=enable,period=period,s_valid=sv,m_ready=mr)
        item=(o['m_data'],o['m_injected'],o['m_error'])
        if held is not None: assert o['m_valid'] and item==held
        held=item if o['m_valid'] and not mr else None
        if o['m_valid'] and mr: assert item==q.popleft()
        if sv and o['s_ready']:
            f=fault(data,mask,mode,enable,phase); q.append(f); injections+=f[1]
            phase=0 if period==0 or phase>=period-1 else phase+1
        assert val(d,'injections')==injections
    while q:
        o=await step(d,s_valid=0,m_ready=1)
        if o['m_valid']: assert (o['m_data'],o['m_injected'],o['m_error'])==q.popleft()

async def bus_timeout_monitor(d):
    await reset(d,clear=0,req_valid=0,req_ready=1,rsp_valid=0,rsp_ready=1,limit_cycles=3)
    await step(d,req_valid=1); assert val(d,'outstanding')
    await step(d,req_valid=0); await step(d); assert not val(d,'timed_out')
    await step(d,rsp_valid=1); assert not val(d,'outstanding') and val(d,'timeouts')==0
    await step(d,req_valid=1,rsp_valid=0)
    await step(d,req_valid=1); assert val(d,'overlaps')==1
    await step(d,req_valid=0); await step(d)
    assert val(d,'timed_out') and val(d,'timeout_pulse') and val(d,'timeouts')==1
    await step(d); assert not val(d,'timeout_pulse') and val(d,'outstanding')
    await step(d,rsp_valid=1,req_valid=1); assert val(d,'outstanding') and val(d,'late_responses')==1 and val(d,'age')==0
    await step(d,req_valid=0,rsp_valid=0,limit_cycles=0)
    for _ in range(40): await step(d)
    assert val(d,'timeouts')==1 and not val(d,'timed_out')
    await step(d,rsp_valid=1); assert not val(d,'outstanding')
    await step(d,clear=1,req_valid=0,rsp_valid=0); assert val(d,'timeouts')==val(d,'overlaps')==val(d,'late_responses')==0

async def frame_align4(d):
    await reset(d,s_data=0,s_epoch=0,s_valid=0,timeout_cycles=0,m_ready=0)
    # Full frames with staggered lane arrival and future values held.
    for epoch in range(12):
        value=sum((epoch*100+i)<<(32*i) for i in range(4))
        await step(d,s_data=value,s_epoch=sum(epoch<<(32*i) for i in range(4)),s_valid=3,m_ready=1)
        assert not val(d,'m_valid')
        await step(d,s_valid=12)
        assert val(d,'m_valid') and val(d,'m_data')==value and val(d,'m_missing')==0 and val(d,'m_epoch')==epoch
        await step(d,s_valid=0)
    # Epoch12: stale lane0 gets discarded; lane1 at future14 cannot be accepted.
    await step(d,s_data=0x555<<64,s_epoch=11|(14<<32)|(12<<64)|(12<<96),s_valid=7,timeout_cycles=3,m_ready=0)
    assert val(d,'stale_samples')==1 and val(d,'s_ready')&2==0
    await step(d,s_valid=0); await step(d)
    assert val(d,'m_valid') and val(d,'m_epoch')==12 and val(d,'m_missing')==11 and val(d,'m_data')==0x555<<64
    held=val(d,'m_data')
    for _ in range(8):
        await step(d,s_valid=15,s_epoch=sum(13<<(32*i) for i in range(4)),s_data=0x123456789)
        assert val(d,'m_data')==held and val(d,'s_ready')==0
    await step(d,s_valid=0,m_ready=1)
    await step(d,s_valid=15,s_data=0xabcd,s_epoch=sum(13<<(32*i) for i in range(4)))
    assert val(d,'m_epoch')==13 and val(d,'m_missing')==0 and val(d,'m_data')==0xabcd

async def trigger_window(d):
    await reset(d,arm=0,s_data=0,s_trigger=0,s_valid=0,m_ready=0)
    pre=PARAMS.get('PRE',4); post=PARAMS.get('POST',4)
    for index in [0,2,43]:
        await step(d,arm=1); await step(d,arm=0)
        for i in range(index+post+1):
            o=await step(d,s_valid=1,s_data=0x1000+i,s_trigger=int(i==index))
            assert o['s_ready'] and not o['m_valid']
        want=list(range(0x1000+max(0,index-pre),0x1000+index+post+1)); got=[]; held=None
        for t in range(200):
            mr=int(t>5 and R.randrange(3)!=0)
            o=await step(d,s_valid=0,s_trigger=0,m_ready=mr)
            item=(o.get('m_data',0),o['m_last'])
            if held is not None: assert o['m_valid'] and item==held
            held=item if o['m_valid'] and not mr else None
            if o['m_valid'] and mr:
                assert item==(want[len(got)],int(len(got)==len(want)-1)); got.append(item[0])
            if len(got)==len(want): break
        assert got==want and val(d,'capture_length')==len(want) and val(d,'arm_ready')
        await step(d,m_ready=0)
    await step(d,arm=1,s_valid=0); await reset(d,arm=0,s_valid=0); assert val(d,'arm_ready')

async def stream_metrics(d):
    await reset(d,start=0,stop=0,in_valid=0,in_ready=0,out_valid=0,out_ready=0)
    await step(d,start=1); await step(d,start=0,in_valid=1,in_ready=1)
    await step(d,in_valid=1,in_ready=0,out_valid=1,out_ready=0)
    await step(d,in_valid=0,out_ready=1)
    assert val(d,'inputs')==val(d,'outputs')==1 and val(d,'latency_min')==val(d,'latency_max')==2
    await step(d,in_valid=1,in_ready=1,out_valid=1,out_ready=1)
    assert val(d,'latency_min')==0 and val(d,'latency_max')==2
    await step(d,stop=1,in_valid=0,out_valid=0)
    assert val(d,'cycles')==5 and val(d,'input_stalls')==val(d,'output_stalls')==1 and val(d,'max_output_gap')==1 and not val(d,'running')
    frozen=val(d,'cycles'); await step(d,stop=0); assert val(d,'cycles')==frozen
    await step(d,start=1)
    for _ in range(16): await step(d,start=0,in_valid=1,in_ready=1,out_valid=0)
    await step(d); assert val(d,'errors')==1
    # Full simultaneous replacement; no loss of older timestamps.
    await step(d,out_valid=1,out_ready=1); assert val(d,'errors')==1 and val(d,'latency_min')==17
    for _ in range(16): await step(d,in_valid=0)
    assert val(d,'outputs')==17 and val(d,'errors')==1
    await step(d); assert val(d,'errors')==2

async def march_controller(d):
    depth=PARAMS['DEPTH']; commands=march_commands(depth)
    for scenario in ['clean','corrupt','bus_error','timeout']:
        await reset(d,start=0,mem_ready=0,rsp_valid=0,mem_rdata=0,rsp_error=0)
        await step(d,start=1); memory=[0]*depth; got=[]; pending=None; index=0
        for t in range(2500):
            ready=int(scenario!='timeout' and t%4!=0)
            rv=int(pending is not None and t%3==0)
            o=await step(d,start=0,mem_ready=ready,rsp_valid=rv,mem_rdata=0 if pending is None else pending[0],rsp_error=int(scenario=='bus_error' and rv))
            if o['mem_valid'] and ready:
                w=bool(o['mem_write']); address=o['mem_address']; data=o['mem_wdata']
                cw,ca,cd,ce,phase=commands[index]
                assert (w,address,data if w else 0)==(cw,ca,cd),('March ordering',index)
                got.append((w,address,data)); index+=1
                if w: memory[address]=data
                response=memory[address]
                if scenario=='corrupt' and not w and address==3: response^=1
                pending=(response,)
            if rv and o['rsp_ready']: pending=None
            if val(d,'done'): break
        assert val(d,'done') and not val(d,'busy')
        if scenario=='clean': assert index==len(commands) and val(d,'errors')==0
        if scenario=='corrupt': assert index==len(commands) and val(d,'errors')==5 and val(d,'first_error_address')==3 and val(d,'first_error_phase')==1
        if scenario in ['timeout','bus_error']: assert val(d,'errors')==1 and val(d,'first_error_phase')==0

async def capture_replay(d):
    await reset(d,host_write=0,host_address=0,host_data=0,start=0,input_length=0,output_length=0,s_ready=0,m_data=0,m_valid=0,host_read=0,read_address=0)
    rows=[R.getrandbits(96) for _ in range(32)]
    for i,a in enumerate(rows): await step(d,host_write=1,host_address=i,host_data=a)
    for n,m in [(32,32),(17,6),(1,1)]:
        await step(d,host_write=0,start=1,input_length=n,output_length=m,s_ready=0,m_valid=0,host_read=0)
        sent=got=0; expected=[]; held=None; times=[]
        for t in range(120):
            sr=int(t%7 not in (1,2)) if n==17 else 1
            mv=int(got<m and sent>got and t%4!=0)
            out=(rows[got]<<96)|rows[got] if got<m else 0
            o=await step(d,start=0,s_ready=sr,m_valid=mv,m_data=out)
            if held is not None: assert o['s_valid'] and o['s_data']==held
            held=o['s_data'] if o['s_valid'] and not sr else None
            if o['s_valid'] and sr: assert o['s_data']==rows[sent]; sent+=1; times.append(t)
            if mv and o['m_ready']: expected.append(out); got+=1
            if val(d,'done'): break
        assert not val(d,'error') and sent==n and got==m and val(d,'issued')==n and val(d,'captured')==m
        if n==32: assert all(b-a==1 for a,b in zip(times,times[1:])), 'replay II not1'
        for i,x in enumerate(expected):
            await step(d,m_valid=0,host_read=1,read_address=i)
            assert val(d,'read_data')==x
    await step(d,host_read=0,start=1,input_length=33,output_length=1)
    assert val(d,'done') and val(d,'error') and not val(d,'active')
    await step(d,start=0); await step(d,start=1,input_length=1,output_length=1)
    for _ in range(130): await step(d,start=0,s_ready=0,m_valid=0)
    assert val(d,'done') and val(d,'error')
    await reset(d,start=0); assert not val(d,'active') and not val(d,'s_valid')

async def axi_lite_interconnect(d):
    defaults=dict(s_awaddr=0,s_awprot=0,s_awvalid=0,s_wdata=0,s_wstrb=0,s_wvalid=0,s_bready=0,
      s_araddr=0,s_arprot=0,s_arvalid=0,s_rready=0,m_awready=0,m_wready=0,m_bresp=0,m_bvalid=0,
      m_arready=0,m_rdata=0,m_rresp=0,m_rvalid=0)
    await reset(d,**defaults)
    for k in range(25):
        address=(k%5)*0x1000+0x1a4; dst=address>>12; unmapped=dst==4
        aw=w=ar=False; da=dw=dr=False; br=rr=False; bdone=rdone=False
        for t in range(100):
            # Alternating AW-first / W-first, concurrent independent read.
            av=int(not aw and t>=(0 if k%2 else 4)); wv=int(not w and t>=(4 if k%2 else 0)); arv=int(not ar)
            brv=int(da and dw); rrv=int(dr)
            o=await step(d,s_awaddr=address,s_awprot=5,s_awvalid=av,s_wdata=0x76540000+k,s_wstrb=k%16,s_wvalid=wv,
                  s_araddr=address,s_arprot=3,s_arvalid=arv,s_bready=int(t>20),s_rready=int(t>16),
                  m_awready=15 if t%3 else 0,m_wready=15 if t%4 else 0,m_bvalid=(1<<dst) if brv and not unmapped else 0,
                  m_bresp=sum((j%3)<<(2*j) for j in range(4)),m_arready=15 if t%3 else 0,
                  m_rvalid=(1<<dst) if rrv and not unmapped else 0,m_rdata=sum((0xabc000+j)<<(32*j) for j in range(4)),
                  m_rresp=sum((j%3)<<(2*j) for j in range(4)))
            if av and o['s_awready']: aw=True
            if wv and o['s_wready']: w=True
            if arv and o['s_arready']: ar=True
            if unmapped: assert o['m_awvalid']==o['m_wvalid']==o['m_arvalid']==0
            else:
                assert o['m_awvalid'] in (0,1<<dst) and o['m_wvalid'] in (0,1<<dst) and o['m_arvalid'] in (0,1<<dst)
                if o['m_awvalid'] and o['m_awready']:
                    assert (o['m_awaddr']>>(16*dst))&65535==0x1a4 and (o['m_awprot']>>(3*dst))&7==5; da=True
                if o['m_wvalid'] and o['m_wready']:
                    assert (o['m_wdata']>>(32*dst))&0xffffffff==0x76540000+k and (o['m_wstrb']>>(4*dst))&15==k%16; dw=True
                if o['m_arvalid'] and o['m_arready']: dr=True
            if o['s_bvalid']:
                assert o['s_bresp']==(3 if unmapped else dst%3)
                if o['s_bready']: bdone=True
            if o['s_rvalid']:
                assert o['s_rresp']==(3 if unmapped else dst%3) and o['s_rdata']==(0 if unmapped else 0xabc000+dst)
                if o['s_rready']: rdone=True
            if bdone and rdone: break
        assert bdone and rdone,(k,'AXI completion')
        await step(d,**defaults)
    await step(d,s_awvalid=1,s_awaddr=0x2000)
    await reset(d,**defaults)
    assert not val(d,'s_bvalid') and not val(d,'s_rvalid') and not val(d,'m_awvalid')

@cocotb.test()
async def native_regression(d):
    await globals()[os.environ['SYS_CORE']](d)
