import os
import cocotb
from native_tests import step,reset
from board_reference import vectors,validate

@cocotb.test()
async def raw_native_profiles(d):
    p=int(os.environ.get('SYS_PROFILE','0'))
    for core in range(16 if p==0 else (1 if p==8 else 8)):
        for seed,stall in [(1,0),(2,1)]:
            await reset(d,selected=core,q_data=0,q_valid=0,r_ready=0)
            # Arm and empty pipeline initialization.
            await step(d); await step(d)
            case=vectors(p,core,seed); sent=0; got=[]; held=None; input_times=[]
            for t in range(15000):
                rr=int(not stall or t%8 not in (3,4))
                o=await step(d,q_valid=int(sent<len(case['rows'])),q_data=case['rows'][sent] if sent<len(case['rows']) else 0,r_ready=rr)
                if held is not None: assert o['r_valid'] and o['r_data']==held
                held=o.get('r_data') if o['r_valid'] and not rr else None
                if o['q_valid'] and o['q_ready']: sent+=1; input_times.append(t)
                if o['r_valid'] and rr: got.append(o['r_data'])
                if len(got)==len(case['expected']) and sent==len(case['rows']): break
            assert sent==len(case['rows']) and len(got)==len(case['expected']),(case['name'],'completion',sent,len(got))
            validate(case,got)
            if not stall and (1<=p<=7 or (p==0 and core in [3,7,8,13,14,15])):
                assert all(b-a==1 for a,b in zip(input_times,input_times[1:])),(case['name'],'II1')
            await step(d,q_valid=0,r_ready=1); o=await step(d)
            assert not o['r_valid'],'extra output'
            d._log.info('ADAPTER PASS %s seed=%d stall=%d inputs=%d outputs=%d clocks=%d',case['name'],seed,stall,sent,len(got),t+1)
