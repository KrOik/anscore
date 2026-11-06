"""SPDX-License-Identifier: Apache-2.0. B39 additive static evidence/source audit."""
from pathlib import Path
import copy,hashlib,json,re,subprocess
ROOT=Path(__file__).resolve().parents[2]
BASE='1e9e9130cef71127d2c8d2762affe815b067b9f5'
PARENT='docs/snapshots/source_20261106_b38.json'
OLD_AUDIT='docs/snapshots/source_20261106_b38_structure.json'
NEW=[('cores/communication/moldudp64_recovery_manager','moldudp64_recovery_manager','recovering_itch_rx'),
 ('cores/signal_processing/burst_cfo_correct','burst_cfo_correct','burst64_cfo'),
 ('cores/image_processing/raw_green_equalize','raw_green_equalize','green_bayer_rgb'),
 ('cores/communication/ipv4_fragment_reassembly','ipv4_fragment_reassembly','ipv4_header_reassembly')]
SUPPORT='cores/acceleration/stream_sincos/rtl/stream_sincos.sv'
ATTR='cores/acceleration/stream_sincos/rtl/.gitattributes'
SUPPORT_SHA='b0945b83dded63e7eee0b3beb87c93bf4787f862273915f0f5193336efd8a2cf'

def sha(raw):return hashlib.sha256(raw).hexdigest()
def hfile(p):return sha(p.read_bytes())
def ref(package,name):return ROOT/name if name.replace('\\','/').startswith('cores/')else package/name
def git(*a,inp=None):return subprocess.run(['git',*a],cwd=ROOT,input=inp,capture_output=True,check=True,timeout=20).stdout
def write(name,data):(ROOT/name).write_bytes((json.dumps(data,indent=2)+'\n').encode())
def inventory(p):return {f.relative_to(p).as_posix():hfile(f)for f in sorted(p.rglob('*'))if f.is_file()and not set(f.relative_to(p).parts)&{'.work','.build','__pycache__'}}
def archive(package,rp,r,name):
 if name in r.get('archived_sources',{}):return ref(package,r['archived_sources'][name])
 if name in r.get('exact_checked_copies',{}):return rp.parent/r['exact_checked_copies'][name]
 return rp.parent/'sources'/name.replace('../','parent/')

def prior_evidence(package,d):
 prior=d.get('prior_evidence')
 if not prior:return None
 rp=ref(package,prior['receipt']);assert hfile(rp)==prior['receipt_sha256']
 r=json.loads(rp.read_bytes());plan_path=ref(package,prior['plan'])
 assert hfile(plan_path)==prior['plan_sha256'];plan=json.loads(plan_path.read_bytes())
 assert r.get('plan_sha256',prior['plan_sha256'])==prior['plan_sha256']
 if 'plan_sha256'not in r:
  assert any(Path(n).name==Path(prior['plan']).name and h==prior['plan_sha256']for n,h in r['source_sha256'].items())
 if(rp.parent/'plan.json').is_file():assert hfile(rp.parent/'plan.json')==prior['plan_sha256']
 records=r.get('checks',r.get('records',[]))
 order=plan.get('expected_checks',plan.get('expected_check_order',[x['name']for x in plan.get('checks',[])]))
 assert [x['name']for x in records]==order[:len(records)]
 assert r['status']=='FAIL' and records[-1]['status']=='FAIL' and all(x['status']=='PASS'for x in records[:-1])
 passed=sum(x['status']=='PASS'for x in records);failed=sum(x['status']=='FAIL'for x in records)
 sims=sum(x['status']=='PASS'and x['name'].startswith('sim')for x in records)
 assert passed==prior['passed_children']and failed==prior['failed_children']and sims==prior['successful_simulations']
 if plan.get('checks'):
  for record,expected in zip(records,plan['checks']):
   stamp=rp.parent.name
   assert record['argv']==[x.replace('<stamp>',stamp)for x in expected['argv']]
   assert record['cwd']==expected['cwd'].replace('<stamp>',stamp)
   if record['status']=='PASS'and expected.get('marker'):
    assert any(line.startswith(expected['marker'].encode())for line in(rp.parent/(record['name']+'.stdout.txt')).read_bytes().splitlines())
 differences=[]
 for n,h in r['source_sha256'].items():
  assert hfile(archive(package,rp,r,n))==h,(str(package),n,'retained_archive')
  if hfile(ref(package,n))!=h:differences.append(n)
 allowed=prior.get('current_source_exceptions',[])
 assert sorted(differences)==sorted(allowed),(str(package),'prior_current_differences',differences,allowed)
 for c in records:
  for stream in ['stdout','stderr']:assert hfile(rp.parent/(c['name']+'.'+stream+'.txt'))==c[stream+'_sha256']
 for index,profile in enumerate(r.get('profiles',[])):
  if 'vector_sha256'in profile:assert hfile(rp.parent/profile['vector'])==profile['vector_sha256']
  elif isinstance(profile.get('vectors_sha256'),dict):
   for n,h in profile['vectors_sha256'].items():assert hfile(rp.parent/profile['name']/n)==h
  elif 'vectors_sha256'in profile:assert hfile(rp.parent/('vectors%d.txt'%index))==profile['vectors_sha256']
 for n,h in r.get('example',{}).get('vectors_sha256',{}).items():assert hfile(rp.parent/'example'/n)==h
 for tool,v in r.get('tools',{}).items():
  n,h=(v['path'],v['sha256'])if isinstance(v,dict)else(tool,v);assert hfile(Path(n))==h
 failed_images=dict(d.get('failed_vvps_to_retain',{}))
 if(package/'FAILURE_ARCHIVE.json').is_file():
  failure=json.loads((package/'FAILURE_ARCHIVE.json').read_bytes())
  if 'failed_image'in failure:
   name,h=failure['failed_image'],failure['failed_image_sha256']
   assert failed_images.get(name,h)==h;failed_images[name]=h
 assert len(failed_images)>=failed,'Every retained failure must bind its original image'
 for name,h in failed_images.items():assert hfile(ref(package,name))==h
 return dict(receipt=rp.relative_to(ROOT).as_posix(),sha256=hfile(rp),passed_children=passed,failed_children=failed,successful_simulations=sims,current_source_exceptions=differences,failed_images=failed_images)
def main():
 raw=git('show',BASE+':'+PARENT);parent=json.loads(raw);old=json.loads(git('show',BASE+':'+OLD_AUDIT))
 assert len(parent['packages'])==152
 assert hfile(ROOT/SUPPORT)==SUPPORT_SHA and (ROOT/ATTR).read_bytes()==b'/stream_sincos.sv -text\n'
 assert not git('ls-tree',BASE,'--',SUPPORT)
 snap=copy.deepcopy(parent);sources=set(old['canonical_source_paths'])|{SUPPORT}
 support={SUPPORT:dict(sha256=SUPPORT_SHA,baseline_source_status='PREEXISTING_WORKTREE_NOT_TRACKED',reason='Existing original sine/cosine dependency first exported here; no inherited qualification claim'),
  ATTR:dict(sha256=hfile(ROOT/ATTR),reason='Scoped attribute preserves exact existing source bytes')}
 for n,e in support.items():snap['support_files'][n]=e['sha256'];snap['support_file_additions'][n]=e
 summaries=[];new_files={};passes=sims=failures=0;canonical_base={}
 for path,top,example in NEW:
  p=ROOT/path;d=json.loads((p/'B39_DELIVERY.json').read_bytes());inv=inventory(p)
  assert(p/'.gitattributes').read_bytes()in[b'* -text\n',b'* -text\r\n']
  assert 'HW_UNVERIFIED'in d.get('maturity',d.get('status',[]))or d.get('hardware')=='HW_UNVERIFIED'
  for field in ['files','package_sha256','package_files','metadata_hashes','metadata_sha256','source_archive','numerical_vectors','raw_streams','formal_artifact_sha256']:
   mapping=d.get(field,{})
   if isinstance(mapping,dict):
    for n,h in mapping.items():assert hfile(ref(p,n))==h,(path,field,n)
  for n,h in d.get('current_executable_sources',d.get('frozen_source_sha256',{})).items():assert hfile(ref(p,n))==h,(path,n)
  for m in d.get('source_mapping',[]):
   source,checked=(m['source'],m['exact_checked_copy'])if 'source'in m else(m['current'],m['archive'])
   assert hfile(ref(p,source))==m['sha256']==hfile(ref(p,checked)),(path,source)
  plan_name=d.get('plan',d.get('approved_plan','FINITE_PLAN.json'if 'executed_plan_sha256'in d else'PRECHECK_PLAN.json'));plan_path=ref(p,plan_name)
  plan_sha=d.get('plan_sha256',d.get('executed_plan_sha256'))
  assert hfile(plan_path)==plan_sha;plan=json.loads(plan_path.read_bytes())
  rp=ref(p,d['receipt']);assert hfile(rp)==d['receipt_sha256'];r=json.loads(rp.read_bytes())
  assert r.get('plan_sha256',plan_sha)==plan_sha
  if(rp.parent/'plan.json').is_file():assert hfile(rp.parent/'plan.json')==plan_sha
  records=r.get('checks',r.get('records',[]));assert records and r['status']=='PASS' and all(x['status']=='PASS'for x in records)
  order=plan.get('expected_checks',plan.get('expected_check_order',[x['name']for x in plan.get('checks',[])]))
  assert [x['name']for x in records]==order,(path,'check_order')
  for tool,value in r.get('tools',{}).items():
   name,h=(value['path'],value['sha256'])if isinstance(value,dict)else(tool,value)
   assert hfile(Path(name))==h,(path,'tool',name)
  if plan.get('checks'):
   for record,expected in zip(records,plan['checks']):
    stamp=rp.parent.name
    assert record['argv']==[x.replace('<stamp>',stamp)for x in expected['argv']],(path,record['name'],'argv')
    assert record['cwd']==expected['cwd'].replace('<stamp>',stamp)
    if expected.get('marker'):assert any(line.startswith(expected['marker'].encode())for line in(rp.parent/(record['name']+'.stdout.txt')).read_bytes().splitlines())
  for n,h in r['source_sha256'].items():assert hfile(ref(p,n))==h==hfile(archive(p,rp,r,n)),(path,n,'source_archive')
  for record in records:
   for stream in ['stdout','stderr']:assert hfile(rp.parent/(record['name']+'.'+stream+'.txt'))==record[stream+'_sha256']
  for index,profile in enumerate(r.get('profiles',[])):
   if 'vector_sha256'in profile:assert hfile(rp.parent/profile['vector'])==profile['vector_sha256']
   elif isinstance(profile.get('vectors_sha256'),dict):
    for n,h in profile['vectors_sha256'].items():assert hfile(rp.parent/profile['name']/n)==h
   elif 'vectors_sha256'in profile:assert hfile(rp.parent/('vectors%d.txt'%index))==profile['vectors_sha256']
  for n,h in r.get('example',{}).get('vectors_sha256',{}).items():assert hfile(rp.parent/'example'/n)==h
  successful_sims=sum(x['name'].startswith('sim')for x in records)
  assert len(records)==d.get('effective_finite_checks',d.get('finite_result',{}).get('children'))
  assert successful_sims==d.get('successful_simulations',d.get('finite_result',{}).get('simulations'))
  prior=prior_evidence(p,d);retained_pass=prior['passed_children']if prior else 0
  retained_sims=prior['successful_simulations']if prior else 0;retained_fail=prior['failed_children']if prior else 0
  assert retained_fail==d.get('historical_hdl_failures',0)
  if prior:
   assert len(records)+retained_pass==d['current_qualification_pass_children']
   assert successful_sims+retained_sims==d['current_qualification_successful_simulations']
  risk=d.get('architecture_risk',d.get('resource_risk','UNKNOWN'));lists={}
  for fl in ['files.f','example/files.f']:
   resolved=[]
   for line in(p/fl).read_text().splitlines():
    line=line.split('#',1)[0].strip()
    if not line:continue
    assert not line.startswith('-')
    source=(p/line).resolve();canonical=source.relative_to(ROOT).as_posix()
    assert source.is_file()and source.suffix.lower()in['.v','.sv']
    if canonical not in sources and not canonical.startswith(path+'/'):
     raw_base=git('show',BASE+':'+canonical);assert hfile(source)==sha(raw_base),canonical
     canonical_base[canonical]=dict(sha256=sha(raw_base),baseline_commit=BASE,classification='TRACKED_SOURCE_FIRST_ADDED_TO_CUMULATIVE_CLOSURE')
    assert canonical not in resolved;resolved.append(canonical);sources.add(canonical)
   lists[fl]=resolved
  snap['packages'].append(dict(path=path,top=top,baseline_commit=BASE,evidence='B39_DELIVERY.json',evidence_kind='explicit_finite_rules_with_retained_failure_history',hardware_status='HW_UNVERIFIED',architecture_risk=risk,
   additional_source_lists=['example/files.f'],examples=[dict(file='example/'+example+'.sv',top=example)],sha256=inv))
  summaries.append(dict(path=path,files=len(inv),effective_checks=len(records)+retained_pass,successful_simulations=successful_sims+retained_sims,retained_failures=retained_fail,prior_evidence=prior,architecture_risk=risk,source_lists=lists,
   receipt=dict(path=rp.relative_to(ROOT).as_posix(),sha256=hfile(rp),status=r['status'])))
  passes+=len(records)+retained_pass;sims+=successful_sims+retained_sims;failures+=retained_fail;new_files.update({path+'/'+n:h for n,h in inv.items()})
 assert snap['packages'][:152]==parent['packages']
 old_paths=sorted(set(old['canonical_source_paths'])|set(canonical_base))
 packed=git('cat-file','--batch',inp=''.join(BASE+':'+n+'\n'for n in old_paths).encode());contents={};offset=0
 for n in old_paths:
  end=packed.index(b'\n',offset);header=packed[offset:end].split();assert header[1]==b'blob'
  size=int(header[2]);contents[n]=packed[end+1:end+1+size];offset=end+size+2
  assert hfile(ROOT/n)==sha(contents[n]),('baseline_canonical_source_changed',n)
 declarations={}
 for n in sorted(sources):
  code=re.sub(rb'/\*.*?\*/|//[^\n]*',b'',contents[n]if n in contents else(ROOT/n).read_bytes(),flags=re.S)
  for module in re.findall(rb'\bmodule\s+(?:automatic\s+)?([A-Za-z_][\w$]*)',code):declarations.setdefault(module.decode(),[]).append(n)
 collisions={k:v for k,v in declarations.items()if len(v)>1};assert not collisions
 assert(passes,sims,failures)==(45,16,2)
 snap.update(date='2026-11-06',baseline_commit=BASE,batch_baseline_commit=BASE,previous_snapshot=PARENT,
  source_freeze='B39 cumulative156 packages: bounded IPv4 fragment payload reassembly, MoldUDP64 recovery requests, acquired burst CFO correction and local RAW green equalization.45 PASS children/2 retained FAIL/16 successful simulations; explicit finite verification-only repairs. No synthesis/PnR/STA/board/inherited regression. Goal active.',
  parent_snapshot=dict(path=PARENT,sha256=sha(raw),worktree_sha256=hfile(ROOT/PARENT),hash_kind='committed_git_blob',commit=BASE),batch_support_file_additions=support,
  batch_canonical_base_sources=canonical_base)
 audit=dict(schema='anscore-b39-static-audit-v1',status='PASS',baseline_commit=BASE,packages=156,parent_snapshot_sha256=sha(raw),inherited_package_objects_exact=152,
  new_packages=summaries,new_package_files=len(new_files),effective_finite_checks=passes,historical_failed_children=failures,successful_finite_simulations=sims,
  source_files=len(sources),module_declarations=sum(map(len,declarations.values())),canonical_source_paths=sorted(sources),new_support_sources=[SUPPORT],new_canonical_base_sources=sorted(canonical_base),unresolved_module_collisions=collisions,
  scope='Additive evidence hashes/offline source closure, planned argv where frozen, all inherited canonical source bytes and declarations from immutable baseline.',
  combined_compile='NOT_RUN',inherited_checker='NOT_RUN',synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN')
 write('docs/snapshots/source_20261106_b39.json',snap);write('docs/snapshots/source_20261106_b39_structure.json',audit)
 print(json.dumps({k:audit[k]for k in['status','packages','new_package_files','effective_finite_checks','successful_finite_simulations','source_files','module_declarations']}))
if __name__=='__main__':main()
