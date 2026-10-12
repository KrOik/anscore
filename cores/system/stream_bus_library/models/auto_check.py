"""Checks every raw UART record, source-loaded stimuli and actual clock metrics."""
from codec import crc8,status_fields,metric_fields
from board_reference import vectors,validate

def packets(data):
    rows=[]; pos=0
    while pos<len(data):
        assert data[pos:pos+2]==b'\x55\xaa',('auto frame alignment',pos,data[pos:pos+20].hex())
        frame=data[pos:pos+31]; assert len(frame)==31 and frame[3]==0 and crc8(frame[2:-1])==frame[-1],('auto CRC',pos)
        rows.append((frame[2],int.from_bytes(frame[4:6],'little'),int.from_bytes(frame[6:30],'little')))
        pos+=31
    return rows

def check(profile,frames,collect_failures=False):
    count=32 if profile==0 else (2 if profile==8 else 16)
    by_id={}; final=[]
    for cmd,address,raw in frames:
        if cmd==0x86: final.append((address,raw)); continue
        case,index=divmod(address,256); assert case<count
        record=by_id.setdefault(case,{'outputs':[]})
        if cmd==0x83:
            assert index==0 and 'status' not in record; record['status']=status_fields(raw)
        elif cmd==0x84:
            assert index==len(record['outputs']); record['outputs'].append(raw)
        elif cmd==0x85:
            assert index in [0,1] and 'metric'+str(index) not in record; record['metric'+str(index)]=raw
        else: raise AssertionError(('unknown auto command',cmd))
    assert len(final)==1 and final[0]==(profile,0x4155544f|(count<<32)),'auto final frame'
    assert len(by_id)==count,'missing auto cases'
    result=[]
    for i in range(count):
        core=i//2; seed=i%2+1; case=vectors(profile,core,seed); got=by_id[i]
        status=got['status']; actual=got['outputs']; model_error=None
        try: validate(case,actual)
        except AssertionError as e:
            if not collect_failures: raise
            model_error=str(e)
        assert status['done'] and not status['error'] and not status['active']
        assert status['issued']==len(case['rows']) and status['captured']==len(case['expected'])
        m=metric_fields(got['metric0'],got['metric1']); assert m['inputs']==status['issued'] and m['outputs']==status['captured']
        paired=1<=profile<=7 or (profile==0 and core in [3,7,8,11,13,14,15])
        if paired: assert m['errors']==0,(case['name'],m)
        full_rate=1<=profile<=7 or (profile==0 and core in [3,7,8,13,14,15])
        if full_rate and i%2==0: assert status['cycles']<=len(case['rows'])+4,(case['name'],'rate',status)
        result.append(dict(case_id=i,name=case['name'],core=core,seed=seed,stall=i%2,status=status,metrics=m,
            raw=[f'{a:048x}' for a in actual],model_check='FAIL' if model_error else 'PASS',model_error=model_error,
            measured_input_rate_mbeats=50*status['issued']/status['cycles'],
            measured_output_rate_mbeats=50*status['captured']/status['cycles'],
            latency_applicable=paired))
    return result
