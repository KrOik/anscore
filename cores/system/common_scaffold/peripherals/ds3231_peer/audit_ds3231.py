"""Read-only source/evidence closure audit; no simulator, synthesis or hardware runs."""
from pathlib import Path
import json,hashlib,re,datetime
H=Path(__file__).resolve().parent;P=H.parents[1];O=P/'peripherals/ds3231_rtc'
E=P/'evidence/ds3231_independent_20261019T140022Z_ff6ecc03'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def main():
 freeze=read(O/'source_freeze.json');fs=sha(O/'source_freeze.json')
 assert len(freeze)==13
 for n,d in freeze.items():assert sha(O/n)==d,n
 dep=read(O/'dependency_sha256.json')
 for n,d in dep.items():assert sha(P/n)==d,n
 owner=read(O/'final_validation.json');assert owner['status']=='PASS' and owner['sources']==freeze and owner['dependency_sha256']==dep and owner['source_freeze_sha256']==fs
 bound={};counts={};log_hashes={};seen_labels=set()
 for name in ['case_evidence.json','transaction_evidence.json','error_evidence.json','protocol_evidence.json','parameter_evidence.json']:
  report=read(O/name);assert report['status']=='PASS' and report['sources']==freeze and report['dependency_sha256']==dep
  assert sha(O/name)==owner['evidence_sha256'][name]
  counts[name]=len(report['profiles']);bound['peripherals/ds3231_rtc/'+name]=sha(O/name)
  for row in report['profiles']:
   assert 'PASS' in row['output']
   if 'label' in row:
    assert row['label'] not in seen_labels,'duplicate simulation label'
    seen_labels.add(row['label']);log=O/('simulation_'+row['label']+'.log')
    actual=[x for x in log.read_text(encoding='utf-8').splitlines() if x];expected=[x for x in row['output'].splitlines() if x]
    assert actual==expected,(name,row['label'])
    log_hashes[log.relative_to(P).as_posix()]=sha(log)
 assert sum(counts.values())==53
 synth=read(O/'synthesis.json');assert synth['sources']==freeze and synth['dependency_sha256']==dep and synth['status']=='PASS' and sha(O/'synthesis.json')==owner['evidence_sha256']['synthesis.json']
 resources=[]
 for row in synth['profiles']:
  log=O/row['log_filename'];assert sha(log)==row['report_sha256'];out=log.read_text(encoding='utf-8');assert 'CHECK pass' in out and 'Found and reported 0 problems.' in out
  tail=out[out.rfind('=== ds3231_rtc ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',tail,re.M) if k not in ['wires','ports','cells','memories','processes']};assert cells==row['cells']
  lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0)
  dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k);bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
  assert (lut,dsp,bram)==(row['lut_class'],row['dsp'],row['bram9']) and 0<lut<=15000 and dsp<=4 and bram<=46
  resources.append(dict(parameters=row['parameters'],lut_class=lut,dsp=dsp,bram9=bram,log=log.relative_to(P).as_posix(),sha256=sha(log)))
 bound['peripherals/ds3231_rtc/synthesis.json']=sha(O/'synthesis.json')
 result=read(E/'results.json');assert result['status']=='PASS';rootsources={n.replace('\\','/'):d for n,d in result['sources'].items()};assert rootsources==dict({'peripherals/ds3231_rtc/ds3231_rtc.sv':freeze['ds3231_rtc.sv']},**dep)
 script=P/'integration/test_ds3231_independent.py';assert sha(script)==result['reviewer_script_sha256']
 independent={script.relative_to(P).as_posix():sha(script),(E/'results.json').relative_to(P).as_posix():sha(E/'results.json')}
 for half in [4,11]:
  for prefix in ['compile','simulation']:
   log=E/f'{prefix}_{half}.log';assert log.exists()
   if prefix=='simulation':assert f'PASS RTC_INDEPENDENT HALF={half} starts=37 stops=19 read=54' in log.read_text(encoding='utf-8')
   independent[log.relative_to(P).as_posix()]=sha(log)
 data=read(H/'datasheet_recheck.json');assert data['sha256']==read(O/'references.json')['sources'][0]['sha256']
 # Analytic comparison of the explicitly limited RTL leap/date formula to Gregorian.
 checked=0
 for year in range(2000,2200):
  for month in range(1,13):
   leap=year%4==0 and year!=2100;days=(29 if leap else 28) if month==2 else 30 if month in [4,6,9,11] else 31
   for day in range(0,33):
    try:datetime.date(year,month,day);legal=True
    except ValueError:legal=False
    assert legal==(1<=day<=days);checked+=1
 for n,d in freeze.items():assert sha(O/n)==d,n
 for n,d in dep.items():assert sha(P/n)==d,n
 report=dict(status='PASS',scope='Read-only independent audit of frozen RTL, shared-PHY dependencies, existing physical-pin simulation evidence and full synthesis reports; no duplicate tests or board run',source_freeze_sha256=fs,owner_frozen_inputs=freeze,dependency_sha256=dep,owner_report_sha256=bound,owner_profile_counts=counts,owner_simulation_log_sha256=log_hashes,independent_root_evidence_sha256=independent,resources=resources,datasheet_recheck_sha256=sha(H/'datasheet_recheck.json'),audit_script_sha256=sha(Path(__file__)),calendar_analytic_cases=checked,review=['START-latched DS3231 secondary buffers make each contiguous00..06 read coherent. The extra seconds reread is explicitly only a conservative cross-phase freshness guard, with bounded retries and documented60second alias limitation.','Gregorian validation agrees with datetime over2000..2199. Century mapping is an application epoch policy; documentation does not extend the chip automatic leap-year guarantee beyond its datasheet range.','12h AM/PM masks, reserved-bit/BCD rejection, SET snapshot/seconds-first write and raw OSF/alarm status policies match the documented limited transaction scope. SET timing within1second remains a declared integration constraint, not a silent guarantee.','Host command/result/done consumption is explicitly CE-qualified; physical shared-PHY progress is independent. NACK STOP and superseding physical errors are propagated. Shared PHY is referenced once through a package-relative dependency map.'],findings=[dict(status='RESOLVED',severity='low',blocking=False,kind='evidence_log_name_collision',previous_source_freeze_sha256='7a5b0dc92e64c5072a4c8f77ab1223cb76935f9455a3be1036cc961f84248386',description='Initial review found transaction/error suites sharing label12h_13 and one standalone log being overwritten.',resolution='Owner archived previous evidence and prefixed error-suite labels. This final audit requires globally unique labels and exact nonempty-line correspondence for every persisted simulation log, plus all refreshed source/report/dependency bindings. RTL and shared PHY remain identical to independently pin-tested sources.')],limitations=['Ideal digital pin models; no actual RTC, oscillator accuracy, electrical timing closure or combined-board fit validated.','Read status is a separate transaction from time shadow; external writers and full60second aliasing are outside the conservative freshness check.'])
 (H/'peer_review_ds3231.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print('PASS',len(freeze),sum(counts.values()),len(resources),sha(H/'peer_review_ds3231.json'))
if __name__=='__main__':main()
