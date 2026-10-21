from run_tests import *
def main():
 rows=[]
 for phase in (1,4999,5001,9999):rows.append(case('phase_'+str(phase),gate=17,windows=20,phase_ps=phase,period_ps=73333))
 ns=[17,18,25,26,33,34];events=[(5000+(n-2)*10000-1,(i+1)%2) for i,n in enumerate(ns)]
 row=case('exact_gate_boundary',gate=8,windows=4,mode=2,events=events);assert row['window_counts']==[1,2,2,1];rows.append(row)
 rows.append(case('gate_one_II1',gate=1,windows=80,mode=2,count_w=8,gate_w=8,filter_w=1,host_always=True))
 rows.append(case('gate_one_stalls',gate=1,windows=80,mode=2,count_w=8,gate_w=8,filter_w=1))
 rows.append(case('gate8_max',gate=255,windows=3,count_w=8,gate_w=8,filter_w=1,mode=2))
 ev=[(100000+n*10000+113,(n+1)%2) for n in range(300)]
 row=case('counter8_overflow_recovery',gate=300,windows=3,count_w=8,gate_w=16,mode=2,events=ev,range_enable=True);assert row['window_counts'][0]>255 and row['window_counts'][2]==0;rows.append(row)
 rows.append(case('max_width48_filter16',count_w=48,gate_w=48,filter_w=16,filter_n=2,period_ps=93751))
 rows.append(case('filter16_max65535',gate=140000,windows=2,filter_w=16,filter_n=65535,events=[(100001,1),(700100001,0),(1400100001,1),(2100100001,0)],count_w=8))
 (H/'boundary_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),profiles=rows,scope='Asynchronous sub-clock phases, exact closing-window edge ownership, continuous gate1 with II1 production, max8bit gate255, actual8bit edge saturation/clear,48bit datapaths, actual65535sample filter threshold'),indent=2)+'\n')
if __name__=='__main__':main()
