from pathlib import Path
import hashlib,json,re
H=Path(__file__).resolve().parent;P=H.parents[1];O=P/'image/jpeg_gray_encoder';E=P/'evidence/jpeg_gray_top_independent_20261019T143656Z_71c953c0'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def main():
 f=read(O/'source_freeze.json');fs=sha(O/'source_freeze.json');assert fs=='62df2694026175203228b3e769d2f7ca85c843cc415adaf1fbc45edcbe71d003' and len(f)==12
 dep=read(O/'dependencies.json');assert len(dep)==12
 for n,d in f.items():assert sha(O/n)==d,n
 for n,d in dep.items():assert sha(P/n)==d,n
 owner=read(O/'final_validation.json');assert owner['status']=='PASS' and owner['sources']==f and owner['dependencies']==dep and owner['source_freeze_sha256']==fs and owner['board_tested'] is False
 logs={}
 for n,d in owner['additional_reports'].items():assert sha(O/n)==d,n;logs[n]=d
 bound={};counts={};seen=set();resources=[]
 for name,d in owner['evidence'].items():
  assert sha(O/name)==d;report=read(O/name);assert report['status']=='PASS';bound[name]=d;counts[name]=len(report['profiles'])
  for row in report['profiles']:
   if name=='synthesis.json':
    assert row['status']=='PASS' and report['full_hierarchy'] is True
    log=O/row['log_filename'];assert sha(log)==row['report_sha256'];out=log.read_text(encoding='utf-8');assert 'CHECK pass' in out and 'Found and reported 0 problems.' in out
    tail=out[out.rfind('=== jpeg_gray_encoder ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',tail,re.M) if k not in ['wires','ports','cells','memories','processes']};assert cells==row['cells']
    lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k);bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
    assert (lut,dsp,bram)==(row['lut_class'],row['dsp'],row['bram9']) and 0<lut<=15000 and dsp<=4 and bram<=46
    resources.append(dict(width=row['width'],height=row['height'],lut_class=lut,dsp=dsp,bram9=bram,log_sha256=sha(log)));continue
   assert row.get('status','PASS').startswith('PASS')
   if name=='frame_result.json':
    assert row['max_error']<=16;w,h=row['width'],row['height'];ri={(1,1):0,(8,8):0,(13,9):2,(16,16):1,(33,17):3}[(w,h)];label=f'frame_{w}_{h}_{ri}';marker='GRAY_FRAME PASS'
   elif name=='boundary_result.json':
    label=('invalid' if row['status']=='PASS_EXPECTED_REJECT' else 'boundary')+f"_{row['width']}_{row['height']}";marker='invalid grayscale JPEG geometry' if row['status']=='PASS_EXPECTED_REJECT' else 'GRAY_FRAME PASS'
   else:label=row['profile'];marker='ERROR_CASE PASS' if name=='error_result.json' else 'GRAY_FRAME PASS'
   log=O/(label+'_simulation.log');assert marker in log.read_text(encoding='utf-8'),log.name;seen.add(log.name)
 assert sum(v for n,v in counts.items() if n!='synthesis.json')==31 and len(resources)==3
 root=read(E/'results.json');assert root['status']=='PASS' and len(root['profiles'])==6 and root['board_tested'] is False
 expected={n:d for n,d in dep.items() if n.endswith(('.v','.sv'))};expected['image/jpeg_gray_encoder/jpeg_gray_encoder.sv']=f['jpeg_gray_encoder.sv'];assert root['sources']==expected
 script=P/'integration/test_jpeg_gray_top_independent.py';assert sha(script)==root['script_sha256'];independent={script.relative_to(P).as_posix():sha(script),(E/'results.json').relative_to(P).as_posix():sha(E/'results.json')}
 for n,d in root['logs'].items():assert sha(E/n)==d;independent[(E/n).relative_to(P).as_posix()]=d
 for row in root['profiles']:assert row['status']=='PASS' and row['max_error']<=6 and row['mean_error']<=2
 for geometry in ['1x1','13x9','16x16']:assert 'PASS JPEG GRAY TOP INDEPENDENT' in (E/f'simulation_{geometry}.log').read_text(encoding='utf-8')
 boundary=read(H/'boundary_evidence.json');assert boundary['status']=='PASS' and boundary['owner_frozen_inputs']==f and boundary['source_freeze_sha256']==fs and boundary['sources']==expected and boundary['decoded_pixels']==64 and boundary['dri']==4660
 assert sha(H/'test_config_boundaries.py')==boundary['script_sha256']
 for n,d in boundary['logs'].items():assert sha(H/n)==d
 assert 'PASS JPEG PEER CONFIG_RECOVERY' in (H/'simulation.log').read_text(encoding='utf-8')
 assert read(H/'reference_recheck.json')['sha256']==read(O/'references.json')['references'][0]['sha256']
 for n,d in f.items():assert sha(O/n)==d,n
 for n,d in dep.items():assert sha(P/n)==d,n
 report=dict(status='PASS',scope='Frozen full-hierarchy grayscale JPEG RTL/evidence audit plus independent configuration-boundary simulation and independently decoded outputs; no board/PNR claim',source_freeze_sha256=fs,owner_frozen_inputs=f,dependencies=dep,owner_report_sha256=bound,owner_profile_counts=counts,owner_log_sha256=logs,owner_functional_log_paths=sorted(seen),resources=resources,independent_root_evidence_sha256=independent,independent_peer_evidence_sha256={n:sha(H/n) for n in ['boundary_evidence.json','test_config_boundaries.py','reference_recheck.json']},audit_script_sha256=sha(Path(__file__)),findings=[],review=['Top reuses the nine existing RTL stages once each and introduces JFIF APP0 plus sequencing; all dependency source hashes match final freeze closure.31 owner profiles cover10q8 frames with independent entropy bytes, geometry extremes/rejects, atomic configuration and6 terminal-error/reset cases.','Root independent script imports tooling/hash only and defines its own driver and Pillow oracle. Six q1 decoded frames spanning1x1/13x9/16x16 verify CE/stall output stability, exact final marker count, two adjacent frames and extra-pixel refusal with predeclared max6/mean2 error bounds.','Peer new test covers missing-table first configuration, zero quant failure followed by repair without reset, competing cfg/table handshake suppression and restart-interval snapshot. A nonuniform natural-order1..64 table is checked against independently generated diagonal zigzag in DQT, DRI0x1234 is exact, and Pillow decodes all64 pixels of the8x8 frame as128.','Full flattened hierarchy synthesis logs contain CHECK pass/zero problems and independently recount5936/6077/5874 LUT-class,0DSP and2/2/18BRAM9 for8x8/13x9/256x64. Distributed RAM is charged four LUT perRAM16SDP4.','Actual libjpeg-turbo marker-writer reference independently downloaded and SHA matched; JFIF APP0 constants agree. Initial peer-only compile task-name keyword and delta-cycle sampling mistakes were corrected; initial failed text logs remain separately recorded, without RTL edits.'],limitations=['No board-visible JFIF delivery or place-and-route timing validated. Standalone synthesis fit is not a combined-board fit guarantee.','Scope is8bit baseline grayscale JFIF with default Huffman coding and geometry<=256 each axis,total<=16384 pixels. Color,progressive decode/encode and arbitrary Huffman tables are outside scope.','All streaming transfers are CE-qualified as documented; downstream must share CE. Lossy reconstructed pixels have bounded tested errors,not a universal formal image-error guarantee.'])
 (H/'peer_review_jpeg_gray_encoder.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print('PASS JPEG PEER',counts,sha(H/'peer_review_jpeg_gray_encoder.json'))
if __name__=='__main__':main()
