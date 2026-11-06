"""SPDX-License-Identifier: Apache-2.0. B37 additive source integrity, no HDL."""
from pathlib import Path
import copy,hashlib,json,re,subprocess
ROOT=Path(__file__).resolve().parents[2]
BASE='46630205095a13ab95e1b5bebea0094c2a390390'
PARENT='docs/snapshots/source_20261106_b36.json'
OLD_AUDIT='docs/snapshots/source_20261106_b36_structure.json'
NEW=[('cores/storage/itch_l2_delta_book','itch_l2_delta_book','itch_order_bbo8'),
 ('cores/signal_processing/repeated_half_sync','repeated_half_sync','sync12_phase'),
 ('cores/image_processing/indexed_texture_sampler','indexed_texture_sampler','indexed_triangle_frame'),
 ('cores/acceleration/signed8_layer_norm','signed8_layer_norm','quantized_layer_norm')]
SUPPORT='cores/acceleration/stream_atan2/rtl/stream_atan2.sv'
ATTR='cores/acceleration/stream_atan2/rtl/.gitattributes'
SUPPORT_SHA='525dd5d06816b7120492dc50fd117f34e14027bf3ec2c811cb8dba77748d230a'
REPAIRED_TB='cores/signal_processing/repeated_half_sync/sim/tb_repeated_half_sync.sv'
def sha(raw):return hashlib.sha256(raw).hexdigest()
def hfile(path):return sha(path.read_bytes())
def ref(package,name):return ROOT/name if name.replace('\\','/').startswith('cores/') else package/name
def git(*args,inp=None):return subprocess.run(['git',*args],cwd=ROOT,input=inp,capture_output=True,check=True,timeout=20).stdout
def write(name,data):(ROOT/name).write_bytes((json.dumps(data,indent=2)+'\n').encode())
def files(package):return {p.relative_to(package).as_posix():hfile(p)for p in sorted(package.rglob('*'))
 if p.is_file() and not set(p.relative_to(package).parts)&{'.work','.build','__pycache__'}}
def archive_path(package,rp,r,name):
 if name in r.get('archived_sources',{}):return ref(package,r['archived_sources'][name])
 if name in r.get('exact_checked_copies',{}):return rp.parent/r['exact_checked_copies'][name]
 return rp.parent/'sources'/name.replace('../','parent/')
def main():
 raw_parent=git('show',BASE+':'+PARENT);parent=json.loads(raw_parent)
 old=json.loads(git('show',BASE+':'+OLD_AUDIT));assert len(parent['packages'])==144
 snap=copy.deepcopy(parent);sources=set(old['canonical_source_paths'])|{SUPPORT}
 assert hfile(ROOT/SUPPORT)==SUPPORT_SHA
 assert (ROOT/ATTR).read_bytes()==b'/stream_atan2.sv -text\n'
 assert not git('ls-tree',BASE,'--',SUPPORT),'original helper was not tracked at baseline'
 support={SUPPORT:dict(sha256=SUPPORT_SHA,baseline_source_status='PREEXISTING_WORKTREE_NOT_TRACKED',
     reason='Actual phase dependency first committed/exported here; no inherited qualification claim'),
     ATTR:dict(sha256=hfile(ROOT/ATTR),reason='Scoped attribute preserves exact dependency bytes')}
 for n,entry in support.items():snap['support_files'][n]=entry['sha256'];snap['support_file_additions'][n]=entry
 summaries=[];total_pass=total_fail=total_sims=0;new_files={};receipt_changes=[]
 for path,top,example in NEW:
  p=ROOT/path;d=json.loads((p/'B37_DELIVERY.json').read_bytes());inventory=files(p)
  assert inventory['.gitattributes']==sha(b'* -text\n'),path
  assert 'HW_UNVERIFIED' in d.get('maturity',d.get('status',[])) or d.get('hardware')=='HW_UNVERIFIED',path
  for field in ['files','package_sha256','package_files','metadata_hashes','metadata_sha256','source_archive','numerical_vectors','raw_streams']:
   value=d.get(field,{})
   if isinstance(value,dict):
    for name,digest in value.items():assert hfile(ref(p,name))==digest,(path,field,name)
  for key in ['plan','approved_plan']:
   if key in d:assert hfile(ref(p,d[key]))==d['plan_sha256'],(path,key)
  for name,digest in d.get('current_executable_sources',{}).items():assert hfile(ref(p,name))==digest,(path,name)
  for m in d.get('source_mapping',[]):
   assert hfile(ref(p,m['source']))==m['sha256']==hfile(ref(p,m['exact_checked_copy'])),(path,m['source'])
  receipts=d['qualification_receipts'] if 'qualification_receipts' in d else [dict(receipt=d['receipt'],sha256=d['receipt_sha256'])]
  passed=failed=sims=0;receipt_summaries=[]
  for item in receipts:
   rp=ref(p,item['receipt']);r=json.loads(rp.read_bytes());assert hfile(rp)==item['sha256']
   records=r.get('checks',r.get('records',[]));assert records
   plan_name='REPAIR01_PLAN.json' if 'vectors_copied' in r else d.get('plan',d.get('approved_plan','PRECHECK_PLAN.json'))
   checked_plan=json.loads(ref(p,plan_name).read_bytes())
   order=checked_plan.get('expected_checks',checked_plan.get('expected_check_order',[x['name'] for x in checked_plan.get('checks',[])]))
   assert [x['name'] for x in records]==order,(path,'planned_check_order')
   for tool,value in r.get('tools',{}).items():
    tool_path,digest=(value['path'],value['sha256']) if isinstance(value,dict) else (tool,value)
    assert hfile(Path(tool_path))==digest,(path,'tool',tool_path)
   if checked_plan.get('checks'):
    stamp=rp.parent.name
    for record,planned in zip(records,checked_plan['checks']):
     assert record['argv']==[s.replace('<stamp>',stamp) for s in planned['argv']],(path,record['name'],'argv')
     assert record['cwd']==planned['cwd'].replace('<stamp>',stamp),(path,record['name'],'cwd')
     if planned.get('marker') and record['status']=='PASS':
      assert any(line.startswith(planned['marker'].encode()) for line in (rp.parent/(record['name']+'.stdout.txt')).read_bytes().splitlines())
   this_pass=sum(x['status']=='PASS'for x in records);this_fail=len(records)-this_pass
   assert this_fail==0 or (path.endswith('/repeated_half_sync') and this_fail==1 and
       records[-1]['name']=='sim3' and records[-1]['status']=='FAIL'),(path,item,records)
   assert r['status']=='PASS' or this_fail==1,(path,r['status'])
   this_sims=sum(x['status']=='PASS' and (x['name'].startswith('sim') or x['name']=='repair01_sim_example')for x in records)
   passed+=this_pass;failed+=this_fail;sims+=this_sims
   for name,digest in r['source_sha256'].items():
    archived=archive_path(p,rp,r,name);assert hfile(archived)==digest,(path,name,'archive')
    current=ref(p,name)
    if hfile(current)!=digest:
     assert current.resolve()==(ROOT/REPAIRED_TB).resolve() and this_fail==1,(path,name,'unreviewed_source_change')
     receipt_changes.append(dict(source=REPAIRED_TB,before_sha256=digest,after_sha256=hfile(current),
       before_archive=archived.relative_to(ROOT).as_posix(),classification='TESTBENCH_ONLY_EXPLICIT_REPAIR'))
   for record in records:
    for stream in ['stdout','stderr']:
     assert hfile(rp.parent/(record['name']+'.'+stream+'.txt'))==record[stream+'_sha256'],(path,record['name'],stream)
   for index,profile in enumerate(r.get('profiles',[])):
    if 'vector_sha256'in profile:assert hfile(rp.parent/profile['vector'])==profile['vector_sha256']
    elif isinstance(profile.get('vectors_sha256'),dict):
     for name,digest in profile['vectors_sha256'].items():assert hfile(rp.parent/profile['name']/name)==digest
    elif 'vectors_sha256'in profile:assert hfile(rp.parent/('vectors%d.txt'%index))==profile['vectors_sha256']
   for name,digest in r.get('example',{}).get('vectors_sha256',{}).items():assert hfile(rp.parent/'example'/name)==digest
   if 'vectors_copied' in r:
    assert path.endswith('/repeated_half_sync') and r['vectors_copied'] and r['numerical_preparation_calls']==0
    plan=json.loads((p/'REPAIR01_PLAN.json').read_bytes())
    assert r['vectors_sha256']==plan['vector_reuse']['sha256']==hfile(rp.parent/'vectors3.txt')==hfile(p/plan['vector_reuse']['first_attempt_path'])
    assert r['first_attempt_evidence_unchanged'] and r['check_sequence_matches']
    assert r['expected_checks']==plan['expected_checks']==['repair01_compile_example','repair01_sim_example']
    assert [x['name'] for x in records]==r['expected_checks'] and all(x['timeout_seconds']==20 for x in records)
   receipt_summaries.append(dict(path=rp.relative_to(ROOT).as_posix(),sha256=hfile(rp),
     status=r['status'],pass_children=this_pass,failed_children=this_fail,successful_simulations=this_sims))
  assert passed==d['effective_finite_checks'] and sims==d['successful_simulations'],(path,passed,sims)
  assert failed==d.get('historical_hdl_failures',0),(path,failed)
  risk=d.get('architecture_risk',d.get('resource_risk','UNKNOWN'));source_lists={}
  for fl in ['files.f','example/files.f']:
   resolved=[]
   for line in(p/fl).read_text().splitlines():
    line=line.split('#',1)[0].strip()
    if not line:continue
    assert not line.startswith('-'),(path,line)
    source=(p/line).resolve();canonical=source.relative_to(ROOT).as_posix()
    assert source.is_file() and source.suffix.lower()in ['.v','.sv']
    assert canonical in sources or canonical.startswith(path+'/'),canonical
    assert canonical not in resolved;resolved.append(canonical);sources.add(canonical)
   source_lists[fl]=resolved
  snap['packages'].append(dict(path=path,top=top,baseline_commit=BASE,evidence='B37_DELIVERY.json',
    evidence_kind='explicit_finite_rules',hardware_status='HW_UNVERIFIED',architecture_risk=risk,
    additional_source_lists=['example/files.f'],examples=[dict(file='example/'+example+'.sv',top=example)],sha256=inventory))
  summaries.append(dict(path=path,files=len(inventory),effective_checks=passed,historical_failed_children=failed,
    successful_simulations=sims,architecture_risk=risk,source_lists=source_lists,receipts=receipt_summaries))
  total_pass+=passed;total_fail+=failed;total_sims+=sims;new_files.update({path+'/'+n:h for n,h in inventory.items()})
 assert snap['packages'][:144]==parent['packages']
 old_paths=sorted(old['canonical_source_paths']);packed=git('cat-file','--batch',inp=''.join(BASE+':'+n+'\n'for n in old_paths).encode())
 contents={};offset=0
 for name in old_paths:
  end=packed.index(b'\n',offset);header=packed[offset:end].split();assert header[1]==b'blob',(name,header)
  size=int(header[2]);contents[name]=packed[end+1:end+1+size];offset=end+size+2
 for package in summaries:
  for names in package['source_lists'].values():
   for name in names:
    if name in contents:assert hfile(ROOT/name)==sha(contents[name]),('mature_dependency_changed',name)
 declarations={}
 for name in sorted(sources):
  raw=contents[name]if name in contents else(ROOT/name).read_bytes()
  code=re.sub(rb'/\*.*?\*/|//[^\n]*',b'',raw,flags=re.S)
  for module in re.findall(rb'\bmodule\s+(?:automatic\s+)?([A-Za-z_][\w$]*)',code):declarations.setdefault(module.decode(),[]).append(name)
 collisions={k:v for k,v in declarations.items()if len(v)>1};assert not collisions,collisions
 assert (total_pass,total_fail,total_sims)==(44,1,16)
 snap.update(date='2026-11-06',baseline_commit=BASE,batch_baseline_commit=BASE,
   source_freeze='B37 cumulative148 packages: wide L2 deltas/BBO, time-domain repeated-half sync, resident indexed texture renderer and signed8 LayerNorm.44 PASS children/16 successful sims, one retained historical phase-TB failure plus explicit2-child repair. No synthesis/PnR/STA/board/merged/inherited regression. Goal active.',
   previous_snapshot=PARENT,parent_snapshot=dict(path=PARENT,sha256=sha(raw_parent),worktree_sha256=hfile(ROOT/PARENT),hash_kind='committed_git_blob',commit=BASE),batch_support_file_additions=support)
 audit=dict(schema='anscore-b37-static-audit-v1',status='PASS',baseline_commit=BASE,packages=148,
   parent_snapshot_sha256=sha(raw_parent),inherited_package_objects_exact=144,new_packages=summaries,new_package_files=len(new_files),
   effective_finite_checks=total_pass,historical_failed_children=total_fail,successful_finite_simulations=total_sims,
   source_files=len(sources),module_declarations=sum(map(len,declarations.values())),canonical_source_paths=sorted(sources),
   new_support_sources=[SUPPORT],reviewed_harness_changes=receipt_changes,unresolved_module_collisions=collisions,
   scope='Additive exact evidence hashes and offline source closure; inherited declarations from committed baseline.',
   combined_compile='NOT_RUN',inherited_checker='NOT_RUN',synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN')
 write('docs/snapshots/source_20261106_b37.json',snap);write('docs/snapshots/source_20261106_b37_structure.json',audit)
 print(json.dumps({k:audit[k]for k in ['status','packages','new_package_files','effective_finite_checks','historical_failed_children','successful_finite_simulations','source_files','module_declarations']}))
if __name__=='__main__':main()
