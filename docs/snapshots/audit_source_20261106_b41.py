"""SPDX-License-Identifier: Apache-2.0. B41 source/evidence audit, no HDL/model imports."""
from pathlib import Path
import copy,hashlib,json,re,subprocess
ROOT=Path(__file__).resolve().parents[2]
BASE='31a83135a22f845d85840524986895217567625c'
PARENT='docs/snapshots/source_20261106_b40.json'
OLD='docs/snapshots/source_20261106_b40_structure.json'
NEW=[('cores/storage/trade_correction_ohlcv_state','trade_correction_ohlcv_state','itch_execution_statistics8','MEDIUM'),
 ('cores/signal_processing/phase_allan_variance','phase_allan_variance','trigger_phase_allan256','MEDIUM'),
 ('cores/image_processing/rgba_porter_duff','rgba_porter_duff','dual_indexed_porter_duff','HIGH at maximum composition'),
 ('cores/acceleration/signed8_global_average_pool','signed8_global_average_pool','pooled_int4_classifier','LOW core; MEDIUM composition')]
def sha(b):return hashlib.sha256(b).hexdigest()
def digest(p):return sha(p.read_bytes())
def git(*a,inp=None):return subprocess.run(['git',*a],cwd=ROOT,input=inp,capture_output=True,check=True,timeout=20).stdout
def ref(p,n):return ROOT/n if n.replace('\\','/').startswith('cores/') else p/n
def write(n,v):(ROOT/n).write_bytes((json.dumps(v,indent=2)+'\n').encode())
def inventory(p):
 return {f.relative_to(p).as_posix():digest(f) for f in sorted(p.rglob('*'))
  if f.is_file() and not set(f.relative_to(p).parts)&{'.build','.work','__pycache__'}}
def archived(p,rp,r,n):
 if n in r.get('archived_sources',{}):return ref(p,r['archived_sources'][n])
 if n in r.get('exact_checked_copies',{}):return rp.parent/r['exact_checked_copies'][n]
 return rp.parent/'sources'/n.replace('../','parent/')
def verify_receipt(p,rp,pp,status,exceptions=()):
 r=json.loads(rp.read_bytes());plan=json.loads(pp.read_bytes());assert r['status']==status
 if status=='PASS':assert r.get('suite_complete',False)
 if 'plan_sha256' in r:assert r['plan_sha256']==digest(pp)
 else:assert r['source_sha256'][pp.relative_to(p).as_posix()]==digest(pp)
 if (rp.parent/'plan.json').exists():assert digest(rp.parent/'plan.json')==digest(pp)
 records=r.get('checks',r.get('records',[]));assert records
 order=plan.get('expected_checks',plan.get('expected_check_order',[c['name'] for c in plan.get('checks',[])]))
 assert [c['name'] for c in records]==(order if status=='PASS' else order[:len(records)])
 assert all(c['status']=='PASS' for c in (records if status=='PASS' else records[:-1]))
 if status=='FAIL':assert records[-1]['status']=='FAIL'
 if plan.get('checks'):
  for c,e in zip(records,plan['checks']):
   assert c['argv']==[a.replace('<stamp>',rp.parent.name) for a in e['argv']]
   assert c['cwd']==e['cwd'].replace('<stamp>',rp.parent.name)
   if c['status']=='PASS' and e.get('marker'):
    assert any(x.startswith(e['marker'].encode()) for x in (rp.parent/(c['name']+'.stdout.txt')).read_bytes().splitlines())
 differences=[]
 for n,h in r['source_sha256'].items():
  assert digest(archived(p,rp,r,n))==h,(str(p),n,'archive')
  if digest(ref(p,n))!=h:differences.append(n)
 assert sorted(differences)==sorted(exceptions),(str(p),'source exceptions',differences)
 for c in records:
  assert c.get('timeout_seconds',c.get('execution_deadline_seconds',c.get('hard_seconds',20)))<=20
  for k,limit in [('cleanup_budget_seconds',7),('cleanup_seconds',7),('tree_kill_seconds',5),('tree_cleanup_seconds',5),('drain_seconds',2)]:
   if k in c:assert c[k]<=limit
  for stream in ['stdout','stderr']:assert digest(rp.parent/(c['name']+'.'+stream+'.txt'))==c[stream+'_sha256']
 for i,profile in enumerate(r.get('profiles',[])):
  if 'vector_sha256' in profile:assert digest(rp.parent/profile['vector'])==profile['vector_sha256']
  elif isinstance(profile.get('vectors_sha256'),dict):
   for n,h in profile['vectors_sha256'].items():assert digest(rp.parent/profile['name']/n)==h
  elif 'vectors_sha256' in profile:assert digest(rp.parent/('vectors%d.txt'%i))==profile['vectors_sha256']
  if 'preparation_sha256' in profile:assert digest(rp.parent/profile['preparation'])==profile['preparation_sha256']
  if i<len(plan.get('profiles',[])):
   expected=plan['profiles'][i]
   for k in ['vector_sha256','vector_bytes','counts','parameters']:
    if k in expected:assert profile[k]==expected[k]
 prep=r.get('preparations',[])
 if prep:
  assert len(prep)==len(plan['profiles'])==len(plan['preparations'])
  for c,e in zip(prep,plan['preparations']):
   assert c['name']==e['name'] and c['status']=='PASS' and c['timeout_seconds']<=20
   assert c['argv']==[a.replace('<stamp>',rp.parent.name) for a in e['argv']]
   assert c['cwd']==e['cwd']
   for stream in ['stdout','stderr']:assert digest(rp.parent/(c['name']+'.'+stream+'.txt'))==c[stream+'_sha256']
   assert sum(x.startswith(e['marker'].encode()) for x in (rp.parent/(c['name']+'.stdout.txt')).read_bytes().splitlines())==1
  for n,h in r['preparation_tools'].items():assert digest(Path(n))==h
 for n,h in r.get('example',{}).get('vectors_sha256',{}).items():assert digest(rp.parent/'example'/n)==h
 for n,h in r.get('reused_vectors',{}).items():assert digest(ref(p,n))==h
 assert len(r.get('tools',{}))==2
 for n,v in r['tools'].items():
  q,h=(v['path'],v['sha256']) if isinstance(v,dict) else (n,v)
  assert digest(Path(q))==h
 tool_paths={Path(v['path'] if isinstance(v,dict) else n).resolve() for n,v in r['tools'].items()}
 assert all(Path(c['argv'][0]).resolve() in tool_paths for c in records)
 return r,records
def source_list(p,name):
 sources=[];headers=[];dirs=[]
 for line in (p/name).read_text().splitlines():
  line=line.split('#',1)[0].strip()
  if not line:continue
  if line.startswith('+incdir+'):
   for d in line[8:].split('+'):
    q=(p/d).resolve();assert q.is_dir() and q.is_relative_to(ROOT);dirs.append(q)
   continue
  assert not line.startswith('-'),('Unsupported nested file list',name,line)
  q=(p/line).resolve();assert q.is_file() and q.is_relative_to(ROOT) and q.suffix in ['.v','.sv']
  n=q.relative_to(ROOT).as_posix();assert n not in sources;sources.append(n)
  for h in re.findall(rb'`include\s+"([^"]+)"',q.read_bytes()):
   found=next((x.resolve() for x in [q.parent/h.decode(),*[d/h.decode() for d in dirs]] if x.is_file()),None)
   assert found and found.is_relative_to(ROOT);headers.append(found.relative_to(ROOT).as_posix())
 return sources,headers
def main():
 raw=git('show',BASE+':'+PARENT);parent=json.loads(raw);old=json.loads(git('show',BASE+':'+OLD))
 assert len(parent['packages'])==160
 snap=copy.deepcopy(parent);sources=set(old['canonical_source_paths']);inherited=set(sources)
 summaries=[];new_files={};canonical_base={};new_headers={};passes=failures=sims=0
 for path,top,example,risk in NEW:
  p=ROOT/path;d=json.loads((p/'B41_DELIVERY.json').read_bytes());inv=inventory(p)
  assert (p/'.gitattributes').read_bytes() in [b'* -text\n',b'* -text\r\n']
  names=[path+'/'+n for n in inv]
  attrs=git('check-attr','-z','--stdin','text','filter','working-tree-encoding',inp=('\0'.join(names)+'\0').encode()).split(b'\0')
  assert attrs.pop()==b'' and len(attrs)==len(names)*9
  for i in range(0,len(attrs),3):
   n,key,value=attrs[i:i+3];assert value==(b'unset' if key==b'text' else b'unspecified'),(n,key,value)
  assert d.get('hardware')=='HW_UNVERIFIED' or 'HW_UNVERIFIED' in d.get('maturity',d.get('status',[]))
  for field in ['files','package_sha256','package_files','metadata_hashes','metadata_sha256','delivery_metadata_sha256',
                'source_archive','numerical_vectors','raw_streams','formal_artifact_sha256','original_source_archive','original_numerical_vectors']:
   mapping=d.get(field,{})
   if isinstance(mapping,dict):
    for n,h in mapping.items():
     if isinstance(h,str):assert digest(ref(p,n))==h,(path,field,n)
  for field in ['qualification','failure_archive','audit','seal']:
   if field in d and field+'_sha256' in d:assert digest(ref(p,d[field]))==d[field+'_sha256']
  for n,h in d.get('current_executable_sources',d.get('current_source_sha256',d.get('frozen_source_sha256',{}))).items():assert digest(ref(p,n))==h
  for item in d.get('source_mapping',[]):
   a,b=(item['source'],item['exact_checked_copy']) if 'source' in item else (item['current'],item.get('archive',item.get('checked_archive')))
   assert digest(ref(p,a))==item['sha256']==digest(ref(p,b))
  pp=ref(p,d.get('plan',d.get('approved_plan','PRECHECK_PLAN.json')))
  assert digest(pp)==d.get('plan_sha256',d.get('executed_plan_sha256'))
  rp=ref(p,d['receipt']);assert digest(rp)==d['receipt_sha256']
  r,records=verify_receipt(p,rp,pp,'PASS')
  images=next((d[k] for k in ['successful_vvps_to_remove','successful_vvp_images','successful_vvps_for_root_cleanup','verified_compiled_image_sha256'] if k in d),{})
  assert len(images)==sum(c['name'].startswith('sim') for c in records)
  for n,h in images.items():
   q=ref(p,n).resolve();assert q.is_relative_to(p) and digest(q)==h
   assert any(c['status']=='PASS' and '-o' in c['argv'] and Path(c['argv'][c['argv'].index('-o')+1]).resolve()==q for c in records)
   assert any(c['status']=='PASS' and c['name'].startswith('sim') and Path(c['argv'][1]).resolve()==q for c in records)
  prior=d.get('prior_evidence');prior_pass=prior_fail=prior_sims=0
  if not prior and path=='cores/image_processing/rgba_porter_duff':
   history=d['prior_failures'];assert len(history)==1
   prior=dict(receipt=d['original_receipt'],receipt_sha256=d['original_receipt_sha256'],
    plan=d['original_plan'],plan_sha256=d['original_plan_sha256'],passed_children=history[0]['pass_children'],
    failed_children=history[0]['fail_children'],successful_simulations=0,
    current_source_exceptions=d['prior_current_source_exceptions'])
  if prior:
   pr=ref(p,prior['receipt']);old_pp=ref(p,prior['plan'])
   assert digest(pr)==prior['receipt_sha256'] and digest(old_pp)==prior['plan_sha256']
   old_r,old_records=verify_receipt(p,pr,old_pp,'FAIL',prior.get('current_source_exceptions',[]))
   expected_exceptions={'cores/storage/trade_correction_ohlcv_state':['example/itch_execution_statistics8.sv'],
                        'cores/image_processing/rgba_porter_duff':['rtl/rgba_porter_duff.sv']}
   assert prior['current_source_exceptions']==expected_exceptions[path]
   changed=expected_exceptions[path][0]
   before=archived(p,pr,old_r,changed).read_bytes();after=ref(p,changed).read_bytes()
   patch=(b'else if(phase==EVENT_TRADE&&ks!=0)isolate();',b'else if(phase==EVENT_TRADE&&ks!=0)begin capture_trade();isolate();end') if path.endswith('trade_correction_ohlcv_state') else (b'always @* begin',b'always_comb begin')
   assert before.count(patch[0])==1 and after==before.replace(patch[0],patch[1],1),('Only reviewed functional repair allowed',path)
   prior_pass=sum(c['status']=='PASS' for c in old_records);prior_fail=sum(c['status']=='FAIL' for c in old_records)
   prior_sims=sum(c['status']=='PASS' and c['name'].startswith('sim') for c in old_records)
   assert (prior_pass,prior_fail,prior_sims)==(prior['passed_children'],prior['failed_children'],prior['successful_simulations'])
   previous_images=d.get('prior_successful_vvp_images',{})
   assert len(previous_images)==prior_sims
   for n,h in previous_images.items():
    q=ref(p,n).resolve();assert q.is_relative_to(p) and digest(q)==h
    assert any(c['status']=='PASS' and '-o' in c['argv'] and Path(c['argv'][c['argv'].index('-o')+1]).resolve()==q for c in old_records)
    assert any(c['status']=='PASS' and c['name'].startswith('sim') and Path(c['argv'][1]).resolve()==q for c in old_records)
   failed=d.get('failed_vvps_to_retain',{})
   if prior.get('failure_kind')=='NO_IMAGE_SYNTAX_CHILD_FAILURE':
    assert '-tnull' in old_records[-1]['argv'] and '-o' not in old_records[-1]['argv'] and not failed
   else:
    assert len(failed)>=prior_fail
    for n,h in failed.items():
     q=ref(p,n).resolve();assert q.is_relative_to(p) and digest(q)==h
     assert any(c['status']!='PASS' and c['name'].startswith('sim') and Path(c['argv'][1]).resolve()==q for c in old_records)
  if path.endswith('trade_correction_ohlcv_state'):
   for q,h in [(ref(p,prior['plan']),d['reviewed_original_plan_sha256']),(pp,d['reviewed_repair_plan_sha256'])]:
    raw_plan=q.read_bytes();old_token=b'"source_review": "NO_BLOCKER_C_AND_ROOT"'
    assert raw_plan.count(old_token)==1 and sha(raw_plan.replace(old_token,b'"source_review": "PENDING_C_AND_ROOT"'))==h
  if path.endswith('signed8_global_average_pool'):
   qualification=json.loads(ref(p,d['qualification']).read_bytes());raw_plan=pp.read_bytes()
   assert raw_plan.count(b'"source_review": "NO_BLOCKER_A"')==1
   assert sha(raw_plan.replace(b'"source_review": "NO_BLOCKER_A"',b'"source_review": "PENDING_A"'))==qualification['reviewed_pending_plan_sha256']
  lists={};headers=set()
  for name in ['files.f','example/files.f']:
   resolved,inc=source_list(p,name);lists[name]=resolved;sources.update(resolved);headers.update(inc)
  for n in set(sum(lists.values(),[]))-inherited:
   if n.startswith(path+'/'):continue
   base=git('show',BASE+':'+n);assert digest(ROOT/n)==sha(base)
   canonical_base[n]=dict(sha256=sha(base),baseline_commit=BASE,classification='TRACKED_SOURCE_FIRST_ADDED_TO_CUMULATIVE_CLOSURE')
  for n in headers:
   base=git('show',BASE+':'+n);q=ROOT/n
   oid=git('rev-parse',BASE+':'+n).decode().strip();clean=git('hash-object','--path='+n,str(q)).decode().strip()
   assert clean==oid and q.read_bytes().replace(b'\r\n',b'\n')==base
   if n not in snap.get('support_files',{}):
    v=dict(sha256=sha(base),baseline_blob_oid=oid,executed_worktree_sha256=digest(q),baseline_commit=BASE,
     normalization='Only CRLF to LF; no content change')
    new_headers[n]=v;snap.setdefault('support_files',{})[n]=sha(base);snap.setdefault('support_file_additions',{})[n]=v
  count_sims=sum(c['name'].startswith('sim') for c in records)
  passes+=len(records)+prior_pass;failures+=prior_fail;sims+=count_sims+prior_sims
  snap['packages'].append(dict(path=path,top=top,baseline_commit=BASE,evidence='B41_DELIVERY.json',
   evidence_kind='explicit_finite_checks_with_retained_history',hardware_status='HW_UNVERIFIED',architecture_risk=risk,
   additional_source_lists=['example/files.f'],examples=[dict(file='example/'+example+'.sv',top=example)],sha256=inv))
  summaries.append(dict(path=path,files=len(inv),effective_checks=len(records)+prior_pass,retained_failures=prior_fail,
   successful_simulations=count_sims+prior_sims,prior_evidence=prior,architecture_risk=risk,source_lists=lists,
   include_files=sorted(headers),receipt=dict(path=rp.relative_to(ROOT).as_posix(),sha256=digest(rp),status='PASS')))
  new_files.update({path+'/'+n:h for n,h in inv.items()})
 assert snap['packages'][:160]==parent['packages']
 paths=sorted(inherited|set(canonical_base));packed=git('cat-file','--batch',inp=''.join(BASE+':'+n+'\n' for n in paths).encode())
 contents={};offset=0
 for n in paths:
  end=packed.index(b'\n',offset);header=packed[offset:end].split();assert header[1]==b'blob'
  size=int(header[2]);contents[n]=packed[end+1:end+1+size];offset=end+size+2
  assert digest(ROOT/n)==sha(contents[n]),('Canonical source changed',n)
 declarations={}
 for n in sorted(sources):
  code=re.sub(rb'/\*.*?\*/|//[^\n]*',b'',contents[n] if n in contents else (ROOT/n).read_bytes(),flags=re.S)
  for m in re.findall(rb'\bmodule\s+(?:automatic\s+)?([A-Za-z_][\w$]*)',code):declarations.setdefault(m.decode(),[]).append(n)
 collisions={n:p for n,p in declarations.items() if len(p)>1};assert not collisions
 assert (passes,failures,sims)==(46,2,16),(passes,failures,sims)
 freeze='B41 cumulative164 packages: correction-aware trade OHLCV, phase Allan variance, premultiplied Porter-Duff and signed8 global average pooling. Goal active; no synthesis/PnR/STA/board/PPA/inherited regression.'
 snap.update(date='2026-11-06',baseline_commit=BASE,batch_baseline_commit=BASE,previous_snapshot=PARENT,source_freeze=freeze,
  parent_snapshot=dict(path=PARENT,sha256=sha(raw),worktree_sha256=digest(ROOT/PARENT),hash_kind='committed_git_blob',commit=BASE),
  batch_canonical_base_sources=canonical_base,batch_support_file_additions=new_headers,baseline_text_normalizations=new_headers)
 audit=dict(schema='anscore-b41-static-audit-v1',status='PASS',baseline_commit=BASE,packages=164,
  parent_snapshot_sha256=sha(raw),inherited_package_objects_exact=160,new_packages=summaries,new_package_files=len(new_files),
  effective_finite_checks=passes,historical_failed_children=failures,total_hdl_children=passes+failures,successful_finite_simulations=sims,
  source_files=len(sources),module_declarations=sum(map(len,declarations.values())),canonical_source_paths=sorted(sources),
  new_canonical_base_sources=sorted(canonical_base),new_support_headers=new_headers,unresolved_module_collisions=collisions,
  scope='Read-only source/archive/plan/vector/raw/tool/image pairs and source/include closure; immutable inherited canonical bytes and package objects. No imports of qualification code or HDL execution.',
  combined_compile='NOT_RUN',inherited_checker='NOT_RUN',synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',ppa='NOT_RUN')
 write('docs/snapshots/source_20261106_b41.json',snap);write('docs/snapshots/source_20261106_b41_structure.json',audit)
 print(json.dumps({k:audit[k] for k in ['status','packages','new_package_files','effective_finite_checks','historical_failed_children','successful_finite_simulations','source_files','module_declarations']}))
if __name__=='__main__':main()
