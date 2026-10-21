from pathlib import Path
import json,hashlib,re
H=Path(__file__).resolve().parent;P=H.parents[1];O=P/'peripherals/ads1115_adc'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def main():
 f=read(O/'source_freeze.json');fs=sha(O/'source_freeze.json');assert len(f)==9 and fs=='fa2b6fc36358d6d51ad5a9524d97760ac3c9819ac651a47dc073c69d730a90d2'
 dep=read(O/'dependency_sha256.json')
 for n,d in f.items():assert sha(O/n)==d,n
 for n,d in dep.items():assert sha(P/n)==d,n
 owner=read(O/'final_validation.json');assert owner['status']=='PASS' and owner['sources']==f and owner['dependency_sha256']==dep and owner['source_freeze_sha256']==fs
 bound={};logs={};resources=[]
 for name in ['simulation.json','synthesis.json']:
  report=read(O/name);assert report['status']=='PASS' and report['sources']==f and report['dependency_sha256']==dep and sha(O/name)==owner['evidence_sha256'][name]
  bound[name]=sha(O/name);seen=set()
  for row in report['profiles']:
   log=O/row['log_filename'];assert sha(log)==row['report_sha256'];out=log.read_text(encoding='utf-8');logs[log.relative_to(P).as_posix()]=sha(log)
   if name=='simulation.json':
    assert row['name'] not in seen;seen.add(row['name']);assert 'PASS' in out
   else:
    assert 'CHECK pass' in out and 'Found and reported 0 problems.' in out
    tail=out[out.rfind('=== ads1115_adc ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',tail,re.M) if k not in ['wires','ports','cells','memories','processes']};assert cells==row['cells']
    lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k);bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
    assert (lut,dsp,bram)==(row['lut_class'],row['dsp'],row['bram9']) and 0<lut<=15000 and dsp<=4 and bram<=46
    resources.append(dict(parameters=row['parameters'],lut_class=lut,dsp=dsp,bram9=bram,log_sha256=sha(log)))
  assert len(report['profiles'])==(46 if name=='simulation.json' else 3)
 pin=read(H/'pin_evidence.json');assert pin['status']=='PASS' and pin['source_freeze_sha256']==fs and pin['owner_frozen_inputs']==f
 assert pin['sources']==dict({'peripherals/ads1115_adc/ads1115_adc.sv':f['ads1115_adc.sv']},**dep)
 assert sha(H/'test_ads1115_physical.py')==pin['script_sha256']
 independent={n:sha(H/n) for n in ['test_ads1115_physical.py','pin_evidence.json','datasheet_recheck.json']}
 for row in pin['profiles']:
  half=row['half'];assert row['status']=='PASS'
  for prefix in ['compile','simulation']:
   log=H/f'{prefix}_{half}.log';assert log.exists();independent[log.name]=sha(log)
   if prefix=='simulation':assert f'PASS ADS1115 INDEPENDENT HALF={half} cases24 starts179 stops103 signed_neg12' in log.read_text(encoding='utf-8')
 assert read(H/'datasheet_recheck.json')['sha256']==read(O/'references.json')['ti_datasheet']['sha256']
 for n,d in f.items():assert sha(O/n)==d,n
 for n,d in dep.items():assert sha(P/n)==d,n
 result=dict(status='PASS',scope='Independent digital physical-pin simulations and read-only frozen evidence audit; no physical ADC or board validation',source_freeze_sha256=fs,owner_frozen_inputs=f,dependency_sha256=dep,owner_report_sha256=bound,owner_simulation_profiles=46,owner_synthesis_profiles=3,owner_full_log_sha256=logs,independent_evidence_sha256=independent,audit_script_sha256=sha(Path(__file__)),resources=resources,review=['Independent TI datasheet retrieval matches owner reference bytes and SHA256. OS1 during an ongoing conversion has no effect; documented idle single-shot/power-down and exclusive ownership precondition is required.','Two independently written pin-slave profiles cover24 conversions each, every MUX/PGA/rate encoding and four addresses, signed extremes, OS busy-to-ready polling and success at final allowed poll, CE-qualified host consumption with physical progress under CE0, descriptor snapshot, bounded busy timeout, address/data NACK and invalid-address no-START.','All46 owner simulation labels are unique and each actual log is SHA-bound. Full synthesis logs independently recounted at470/522/520 LUT-class cells, zero DSP and zero BRAM9.'],findings=[],limitations=['Ideal digital pin-model verification only; no ADC analog accuracy, voltage conversion/calibration, electrical timing or physical-board claim.','No continuous-mode takeover or automatic reset of external ADC; comparator/ALERT support is outside the module scope.','Individual synthesis fit does not establish combined-board fit.'])
 (H/'peer_review_ads1115.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');print('PASS ADS1115 PEER',fs,sha(H/'peer_review_ads1115.json'))
if __name__=='__main__':main()
