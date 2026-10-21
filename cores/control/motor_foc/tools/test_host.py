"""Actual RTL numerical fixtures with a synthetic CSR lifecycle fault injector."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json
from motor_host import command,run_case
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
FIXTURE=ROOT/'artifacts/motor_foc_25k/csr_20261020T213959144452Z'
BUILD=0x123456789abcdef0

class Bus:
    def __init__(self,values,events,**faults):
        self.values=values.copy();self.events=events;self.faults=faults
        self.occupied=False;self.started=False;self.serial=0;self.reads={};self.config={}
    def access(self,a,v=None):
        self.events.append(('bus',a,v))
        if v is not None:
            if self.faults.get('transport') and a==0x60:raise OSError('injected bus failure')
            if a==16:
                if v==1:self.started=True;self.occupied=True;self.serial+=1
                elif v==2:
                    assert self.events[-2]==('save','SAVED'),'ACK before durable save'
                    self.occupied=False
                else:raise AssertionError('unrequested lifecycle mutation')
            else:self.config[a]=v
            return 0
        if a==0:return 0 if self.faults.get('magic') else 0x464f4331
        if a==8:return (BUILD&0xffffffff)^int(bool(self.faults.get('build')))
        if a==12:return BUILD>>32
        if a==4:
            if self.faults.get('stale'):return 3
            return 1 if self.faults.get('timeout') and self.started else 3 if self.occupied else 0
        if a==36:return self.serial+int(bool(self.faults.get('serial')) and self.started)
        if a==40:return 0 if self.faults.get('timestamp') else 100
        if a==44:return 0
        if a==20:return int(bool(self.faults.get('live_fault')))
        if a==24:return 0
        if 128<=a<=172:
            n=(a-128)//4;v=self.values[n]&0xffffffff
            self.reads[n]=self.reads.get(n,0)+1
            if self.faults.get('torn') and self.reads[n]>1 and n==4:v^=1
            if self.faults.get('bad_word') and n==4:return -1
            return v
        raise AssertionError(a)

def main():
    out=ROOT/'artifacts/motor_foc_25k'/datetime.now(timezone.utc).strftime('host_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    report=dict(status='FAIL',physical_measurement=False,fixture=str(FIXTURE.relative_to(ROOT)))
    try:
        summary=json.loads((FIXTURE/'summary.json').read_text());assert summary['status']=='PASS'
        for name,digest in summary['sources'].items():
            assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest,f'stale RTL fixture {name}'
        rows=[tuple(map(int,s.split()[1:])) for s in (FIXTURE/'run.log').read_text().splitlines() if s.startswith('CSRRES ')]
        assert len(rows)==36
        fixtures=[[v for n,k,v in rows if n==i] for i in range(3)]
        for i,(d,q) in enumerate([(0,0),(80,-60),(-40,60)]):
            events=[];bus=Bus(fixtures[i],events)
            save=lambda x:events.append(('save',x['status']))
            result=run_case(bus,command(sample_id=i,d=d,q=q),BUILD,save,ack_after_save=True)
            assert result['status']=='ACKNOWLEDGED' and not bus.occupied
            assert list(result['words'].values())==[v&0xffffffff for v in fixtures[i]]
            assert [bus.config[64+4*k] for k in range(15)]==command(sample_id=i,d=d,q=q)
            (out/f'case{i}.json').write_text(json.dumps(result,indent=2)+'\n')
        negatives=0
        for kind in ['magic','build','stale','transport','timeout','serial','timestamp','live_fault','torn','bad_word','wrong_id','terminal','duty','save']:
            events=[];values=fixtures[0].copy()
            if kind=='wrong_id':values[0]=999
            if kind=='terminal':values[1]=32
            if kind=='duty':values[8]=257
            bus=Bus(values,events,**{kind:True})
            def save(x):
                events.append(('save',x['status']))
                if kind=='save' and x['status']=='SAVED':raise OSError('disk write failure')
            try:run_case(bus,command(sample_id=0),BUILD,save,ack_after_save=True,max_polls=3)
            except (ValueError,TimeoutError,OSError):pass
            else:raise AssertionError('negative accepted '+kind)
            assert ('bus',16,2) not in events,'failure ACKed '+kind
            negatives+=1
        events=[];bus=Bus(fixtures[0],events)
        assert run_case(bus,command(sample_id=0),BUILD,lambda x:None)['status']=='SAVED' and bus.occupied
        for kw in [dict(ia=512),dict(mode=3),dict(dead=128),dict(sample_id=-1),dict(theta=True)]:
            try:command(sample_id=0,**kw) if 'sample_id' not in kw else command(**kw)
            except ValueError:negatives+=1
            else:raise AssertionError('invalid command accepted')
        report.update(status='PASS',numerical_cases=3,negative_guards=negatives,
            scope='actual RTL numerical fixture; lifecycle/build/serial/timestamp bus synthetic,not physical transport',
            sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__).resolve(),Path(__file__).with_name('motor_host.py'),FIXTURE/'summary.json',FIXTURE/'run.log']})
        print(f'PASS host:3 RTL numerical fixtures,{negatives}negative guards,save-before-ACK,default no ACK')
    except Exception as exc:report['reason']=str(exc);raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out))
if __name__=='__main__':main()
