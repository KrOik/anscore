from pathlib import Path
import json,hashlib,re
H=Path(__file__).resolve().parent;P=H.parents[1];O=P/'peripherals/sht3x_sensor';E=P/'evidence/sht3x_independent_20261019T150609Z_74b94103'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def lines(s):return [x for x in s.splitlines() if x]
def main():
 f=read(O/'source_freeze.json');fs=sha(O/'source_freeze.json');assert len(f)==16 and fs=='1f934f56d15995720da6e23199009462dd26efae104e2f0f98b4eda0431ca04c'
 dep=read(O/'dependencies.json')
 for n,d in f.items():assert sha(O/n)==d,n
 for n,d in dep.items():assert sha(P/n)==d,n
 owner=read(O/'final_validation.json');assert owner['status']=='PASS' and owner['sources']==f and owner['dependencies']==dep and owner['source_freeze_sha256']==fs
 for n,d in owner['additional_reports'].items():assert sha(O/n)==d,n
 bound={};loghash={};counts={};seen=set();resources=[]
 for name,d in owner['evidence'].items():
  report=read(O/name);assert sha(O/name)==d and report['status']=='PASS' and report['dependencies']==dep and report['sources']=={'sht3x_sensor.sv':f['sht3x_sensor.sv']}
  for n,v in report['sources'].items():assert sha(O/n)==v,n
  bound[name]=d;counts[name]=len(report['profiles'])
  for i,row in enumerate(report['profiles']):
   assert row['status']=='PASS'
   if name=='synthesis.json':
    log=O/row['log_filename'];assert sha(log)==row['report_sha256'];out=log.read_text(encoding='utf-8');assert 'CHECK pass' in out and 'Found and reported 0 problems.' in out
    tail=out[out.rfind('=== sht3x_sensor ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',tail,re.M) if k not in ['wires','ports','cells','memories','processes']};assert cells==row['cells']
    lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k);bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
    assert (lut,dsp,bram)==(row['lut_class'],row['dsp'],row['bram9']) and 0<lut<=15000 and dsp<=4 and bram<=46
    resources.append(dict(parameters=row['parameters'],lut_class=lut,dsp=dsp,bram9=bram,log_sha256=sha(log)))
   else:
    assert 'PASS' in row.get('output','PASS')
    if 'simulation_log' in row:
     log=O/row['simulation_log'];assert sha(log)==row['simulation_sha256']
    elif name=='protocol_evidence.json':log=O/f"protocol_{row['label']}_simulation.log"
    elif name=='parameter_evidence.json':log=O/f'param_{i}_simulation.log'
    elif name=='numeric_evidence.json':log=O/'numeric_simulation.log'
    elif name=='pipeline_evidence.json':log=O/(row['profile']+'_simulation.log')
    else:raise AssertionError(name)
    assert log.name not in seen;seen.add(log.name)
    if 'output' in row:assert lines(log.read_text(encoding='utf-8'))==lines(row['output']),log.name
    else:assert 'PASS SHT3X PIPELINE' in log.read_text(encoding='utf-8')
   loghash[log.relative_to(P).as_posix()]=sha(log)
 assert sum(v for n,v in counts.items() if n!='synthesis.json')==70 and len(resources)==3
 result=read(E/'results.json');assert result['status']=='PASS' and result['board_tested'] is False
 assert {n.replace('\\','/'):d for n,d in result['sources'].items()}==dict({'peripherals/sht3x_sensor/sht3x_sensor.sv':f['sht3x_sensor.sv']},**dep)
 script=P/'integration/test_sht3x_independent.py';assert sha(script)==result['script_sha256'];independent={script.relative_to(P).as_posix():sha(script),(E/'results.json').relative_to(P).as_posix():sha(E/'results.json')}
 for n,d in result['logs'].items():assert sha(E/n)==d;independent[(E/n).relative_to(P).as_posix()]=d
 for row in result['profiles']:
  assert row['status']=='PASS' and f"PASS SHT3X INDEPENDENT HALF={row['half']} conversions9 polls18 starts27 tx45 rx54" in row['output']
  assert lines((E/f"simulation_{row['half']}.log").read_text(encoding='utf-8'))==lines(row['output'])
 assert read(H/'datasheet_recheck.json')['sha256']==read(O/'references.json')['sources']['datasheet']['sha256']
 # Independently exhaustively check the RTL constant-divider identity against integer division.
 for raw in range(65536):
  for scale in [100000,175000]:
   n=raw*scale+32767;hi=n>>16;s=hi+(n&65535);q=hi+(3 if s>=196605 else 2 if s>=131070 else 1 if s>=65535 else 0);assert q==n//65535
 for n,d in f.items():assert sha(O/n)==d,n
 for n,d in dep.items():assert sha(P/n)==d,n
 report=dict(status='PASS',scope='Independent read-only audit of frozen SHT3x RTL, root independent physical-pin evidence, full owner logs and actual datasheet; no physical sensor/board run',source_freeze_sha256=fs,owner_frozen_inputs=f,dependencies=dep,owner_evidence_sha256=bound,owner_profile_counts=counts,full_log_sha256=loghash,independent_root_evidence_sha256=independent,datasheet_recheck_sha256=sha(H/'datasheet_recheck.json'),audit_script_sha256=sha(Path(__file__)),resources=resources,analytic_numeric_cases=131072,review=['Actual manufacturer-authored datasheet PDF fetched independently from documented distributor mirror; bytes/SHA match. Commands0x2416/240B/2400 select low/medium/high nonstretch single-shot. Default5/7/16ms waits cover specified measurement maxima; read-address NACK is followed by STOP/gap and bounded retry.','Root pin model independently defines SCL/SDA edge tasks and Python CRC polynomial0x31/initFF plus rational engineering-unit oracle; imports only tooling, no owner model/helper. All six command/address combinations, busy0/1/2 polling, endianness, ACK firstfive/NACK sixth byte, request snapshot and CE0 progress/output stall/pop are checked.','RTL request acceptance is CE/rst/abort qualified. Response ready/valid intentionally operates independently of CE. CRC failure retains raw data and separate two-bit CRC flags. Abort waits for PHY command completion before STOP; PHY faults retain distinct detail code.','Independent exhaustive Python evaluation confirms optimized divide65535 against exact integer division for both scales over all65536 raw values. Negative temperature range and humidity0..100000 fit declared widths.','All70 persisted simulation-profile outputs match distinct physical log paths; all additional report SHA values checked. Three complete synthesis reports independently recounted including shared PHY:1482/1537/1485 LUT-class,zero DSP/BRAM9.'],pipeline_review=['Five registered numerical stages MUL8/SUM/DIV_PRE/DIVIDE/OFFSET preserve exact round-half-up numerator decomposition: 8bit products175000*255 fit26bits and100000*255 fit25bits; merged products fit34bits and remainders19bits.18bit quotient and signed19bit temperature offset fit all declared extrema.', 'All conversion stages check abort before modifying next-stage or published outputs; reset clears every new register unconditionally. No PHY command remains pending after RSTOP before CRC/conversion. CE0 arithmetic proceeds and out_valid rises only after OFFSET or terminal abort/error.', 'Owner numeric test exercises actual registered pipeline for all65536 raw values after independent Python quotient/CRC generation, as well as helper identities;12 added tests cover abort/reset at CRC validation and each of five stages with CE0. Independent pin regressions re-executed unchanged Python oracle under new RTL.'],previous_peer_archive='archive_before_pipeline_87d8352f',findings=[],limitations=['Digital transaction models do not establish actual sensor electrical behavior, accuracy, timing closure or board integration.','Only single-shot nonstretch commands implemented; periodic mode/heater/alert/status functions are outside declared scope.','Custom shorter measurement waits require integration-specific justification; bounded read-address retries handle sensor busy but do not establish analog readiness.','Root first attempt contained incorrect expected transcript arithmetic, corrected to27START/STOP and45TX for nine conversions, with prior failed evidence retained.'])
 (H/'peer_review_sht3x.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print('PASS SHT3X PEER',counts,sha(H/'peer_review_sht3x.json'))
if __name__=='__main__':main()
