from pathlib import Path
import json,hashlib,re
H=Path(__file__).resolve().parent;P=H.parents[1];O=P/'peripherals/camera_register_sequencer'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def main():
 f=read(O/'source_freeze.json');fs=sha(O/'source_freeze.json');assert len(f)==9
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
    tail=out[out.rfind('=== camera_register_sequencer ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',tail,re.M) if k not in ['wires','ports','cells','memories','processes']};assert cells==row['cells']
    lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k);bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
    assert (lut,dsp,bram)==(row['lut_class'],row['dsp'],row['bram9']) and 0<lut<=15000 and dsp<=4 and bram<=46
    resources.append(dict(parameters=row['parameters'],lut_class=lut,dsp=dsp,bram9=bram,log_sha256=sha(log)))
  assert len(report['profiles'])==(34 if name=='simulation.json' else 3)
 pin=read(H/'pin_evidence.json');assert pin['status']=='PASS' and pin['source_freeze_sha256']==fs and pin['owner_frozen_inputs']==f
 assert pin['dependencies']==dep
 assert sha(H/'test_camera_physical.py')==pin['script_sha256']
 independent={n:sha(H/n) for n in ['test_camera_physical.py','pin_evidence.json','datasheet_recheck.json']}
 for n,d in pin['logs'].items():assert sha(H/n)==d;independent[n]=d
 assert len(pin['profiles'])==6
 for row in pin['profiles']:
  assert row['status']=='PASS' and 'PASS CAMERA INDEPENDENT' in row['output']
  log=H/f"simulation_{row['label']}.log"
  assert [x for x in log.read_text(encoding='utf-8').splitlines() if x]==[x for x in row['output'].splitlines() if x]
 assert read(H/'datasheet_recheck.json')['sha256']==read(O/'references.json')['sccb_specification']['sha256']
 for n,d in f.items():assert sha(O/n)==d,n
 for n,d in dep.items():assert sha(P/n)==d,n
 result=dict(status='PASS',scope='Independent edge-level digital physical-pin simulation and read-only frozen evidence audit; no actual camera or board validation',source_freeze_sha256=fs,owner_frozen_inputs=f,dependency_sha256=dep,owner_report_sha256=bound,owner_simulation_profiles=34,owner_synthesis_profiles=3,owner_full_log_sha256=logs,independent_evidence_sha256=independent,audit_script_sha256=sha(Path(__file__)),resources=resources,review=['Independent actual SCCB specification PDF retrieval matches owner reference SHA. Narrow2wire profile explicitly ignores transmitted ninth DC high/low and releases final read NA, with STOP between pointer phase and read phase; original3wire SCCB_E and analog contention behavior are not claimed.','Independent6profiles use no owner model/helper; HALF4/13 times I2C8/I2C16/SCCB8 check exact byte ordering, repeated START versus STOP-separated read, mixed high/low DC, NACK full-descriptor retry, masked VERIFY mismatch retry then success, descriptor/start snapshots, CE0 physical progress and stable done backpressure,37cycle delay and END exactly at descriptor limit.','Full source/PHY dependency closure preserved before and after tests. All34 owner labels unique and actual simulation log SHA match; full synthesis reports independently recounted with shared PHY included.'],findings=[],limitations=['Ideal digital pin models; no actual image sensor, sensor initialization-table correctness, electrical timing closure or combined-board fit validated.','No absent-descriptor timeout: external provider must supply descriptors or reset. SCCB WRITE DC cannot establish target presence; sensor-ID readback required.','Retry suitable for idempotent register settings; side-effect register use requires integration review. Single-master, single-target open-drain profile only.'])
 (H/'peer_review_camera.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');print('PASS CAMERA PEER',fs,sha(H/'peer_review_camera.json'))
if __name__=='__main__':main()
