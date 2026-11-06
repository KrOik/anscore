"""SPDX-License-Identifier: Apache-2.0. B40 additive source/evidence audit only."""
from pathlib import Path
import copy,hashlib,json,re,subprocess
ROOT=Path(__file__).resolve().parents[2]
BASE='a68ca46815777c15c638c42a03899c83385bf052'
PARENT='docs/snapshots/source_20261106_b39.json'
OLD='docs/snapshots/source_20261106_b39_structure.json'
NEW=[('cores/storage/multi_venue_quote_state','multi_venue_quote_state','dual_venue_l2_quote','MEDIUM'),
 ('cores/signal_processing/pulse_fraction_timing','pulse_fraction_timing','trigger_pulse256','MEDIUM'),
 ('cores/image_processing/chroma_median_suppress','chroma_median_suppress','rgb_chroma_clean','HIGH at maximum; MEDIUM default'),
 ('cores/acceleration/quantized_residual_add','quantized_residual_add','signed8_residual','LOW default; MEDIUM maximum')]

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

def verify_receipt(p,rp,plan_path,status,exceptions=(),aliases=None):
 r=json.loads(rp.read_bytes());plan=json.loads(plan_path.read_bytes())
 assert r['status']==status
 if status=='PASS':assert r.get('suite_complete',False)
 if 'plan_sha256' in r:assert r['plan_sha256']==digest(plan_path)
 elif plan_path.relative_to(p).as_posix() in r.get('source_sha256',{}):
  assert r['source_sha256'][plan_path.relative_to(p).as_posix()]==digest(plan_path)
 else:raise AssertionError('Receipt must bind the actual plan')
 if (rp.parent/'plan.json').exists():assert digest(rp.parent/'plan.json')==digest(plan_path)
 records=r.get('checks',r.get('records',[]));assert records
 order=plan.get('expected_checks',plan.get('expected_check_order',[x['name'] for x in plan.get('checks',[])]))
 assert [c['name'] for c in records]==(order if status=='PASS' else order[:len(records)])
 assert all(c['status']=='PASS' for c in (records if status=='PASS' else records[:-1]))
 if status=='FAIL':assert records[-1]['status']=='FAIL'
 if plan.get('checks'):
  for c,e in zip(records,plan['checks']):
   assert c['argv']==[a.replace('<stamp>',rp.parent.name) for a in e['argv']]
   assert c['cwd']==e['cwd'].replace('<stamp>',rp.parent.name)
   if c['status']=='PASS' and e.get('marker'):
    assert any(line.startswith(e['marker'].encode()) for line in (rp.parent/(c['name']+'.stdout.txt')).read_bytes().splitlines())
 differences=[]
 for n,h in r['source_sha256'].items():
  target=archived(p,rp,r,n)
  label=target.relative_to(ROOT).as_posix()
  if aliases and label in aliases:target=ref(p,aliases[label])
  assert digest(target)==h,(str(p),n,'archive')
  if digest(ref(p,n))!=h:differences.append(n)
 assert sorted(differences)==sorted(exceptions),(str(p),'current source exceptions',differences)
 for c in records:
  assert c.get('timeout_seconds',c.get('execution_deadline_seconds',20))<=20
  for stream in ['stdout','stderr']:
   assert digest(rp.parent/(c['name']+'.'+stream+'.txt'))==c[stream+'_sha256']
 for i,profile in enumerate(r.get('profiles',[])):
  if 'vector_sha256' in profile:assert digest(rp.parent/profile['vector'])==profile['vector_sha256']
  elif isinstance(profile.get('vectors_sha256'),dict):
   for n,h in profile['vectors_sha256'].items():assert digest(rp.parent/profile['name']/n)==h
  elif 'vectors_sha256' in profile:assert digest(rp.parent/('vectors%d.txt'%i))==profile['vectors_sha256']
 for n,h in r.get('example',{}).get('vectors_sha256',{}).items():assert digest(rp.parent/'example'/n)==h
 for n,h in r.get('reused_vectors',{}).items():assert digest(ref(p,n))==h
 assert len(r.get('tools',{}))==2
 for n,v in r.get('tools',{}).items():
  path,h=(v['path'],v['sha256']) if isinstance(v,dict) else (n,v)
  assert digest(Path(path))==h
 return r,records

def source_list(p,name):
 sources=[];headers=[];incdirs=[]
 for line in (p/name).read_text().splitlines():
  line=line.split('#',1)[0].strip()
  if not line:continue
  if line.startswith('+incdir+'):
   for d in line[len('+incdir+'):].split('+'):
    directory=(p/d).resolve();assert directory.is_dir() and directory.is_relative_to(ROOT);incdirs.append(directory)
   continue
  assert not line.startswith('-'),('Unexpected nested/unsupported option',name,line)
  q=(p/line).resolve();assert q.is_file() and q.is_relative_to(ROOT) and q.suffix.lower() in ['.v','.sv']
  n=q.relative_to(ROOT).as_posix();assert n not in sources;sources.append(n)
  for h in re.findall(rb'`include\s+"([^"]+)"',q.read_bytes()):
   options=[q.parent/h.decode(),*[d/h.decode() for d in incdirs]]
   found=next((x.resolve() for x in options if x.is_file()),None)
   assert found and found.is_relative_to(ROOT),(n,h)
   headers.append(found.relative_to(ROOT).as_posix())
 return sources,headers

def main():
 raw=git('show',BASE+':'+PARENT);parent=json.loads(raw);old=json.loads(git('show',BASE+':'+OLD))
 assert len(parent['packages'])==156
 snap=copy.deepcopy(parent);sources=set(old['canonical_source_paths']);summaries=[];new_files={}
 inherited=set(sources);canonical_base={};new_headers={};passes=failures=sims=0
 for path,top,example,risk in NEW:
  p=ROOT/path;d=json.loads((p/'B40_DELIVERY.json').read_bytes());inv=inventory(p)
  assert (p/'.gitattributes').read_bytes() in [b'* -text\n',b'* -text\r\n']
  names=[path+'/'+n for n in inv]
  attr=git('check-attr','-z','--stdin','text','filter','working-tree-encoding',inp=('\0'.join(names)+'\0').encode()).split(b'\0')
  assert attr[-1]==b'';attr=attr[:-1];assert len(attr)==len(names)*9
  for i in range(0,len(attr),3):
   n,key,value=attr[i:i+3]
   assert value==(b'unset' if key==b'text' else b'unspecified'),(n,key,value,'byte preservation')
  aliases=d.get('archive_path_aliases',{})
  if aliases:
   assert path=='cores/signal_processing/pulse_fraction_timing' and len(aliases)==2
   expected_old={path+'/reports/20261106T063315_715768Z/sources/.gitattributes',
    path+'/repairs/repair01/reports/20261106T063818_810437Z/sources/.gitattributes'}
   assert set(aliases)==expected_old
   for a,b in aliases.items():
    assert b==a+'.executed.txt' and not ref(p,a).exists()
    assert ref(p,b).read_bytes()==b'* text eol=lf\n'
  assert d.get('hardware')=='HW_UNVERIFIED' or 'HW_UNVERIFIED' in d.get('maturity',d.get('status',[]))
  for field in ['files','package_sha256','package_files','metadata_hashes','metadata_sha256','delivery_metadata_sha256','source_archive','numerical_vectors','raw_streams','formal_artifact_sha256']:
   mapping=d.get(field,{})
   if isinstance(mapping,dict):
    for n,h in mapping.items():
     if isinstance(h,str):assert digest(ref(p,n))==h,(path,field,n)
  for field in ['qualification','failure_archive','audit']:
   if field in d and field+'_sha256' in d:assert digest(ref(p,d[field]))==d[field+'_sha256']
  for n,h in d.get('current_executable_sources',d.get('current_source_sha256',d.get('frozen_source_sha256',{}))).items():assert digest(ref(p,n))==h
  for item in d.get('source_mapping',[]):
   a,b=(item['source'],item['exact_checked_copy']) if 'source' in item else (item['current'],item['archive'])
   if item.get('relation')=='METADATA_ONLY_PACKAGING_CHANGE':
    assert path=='cores/signal_processing/pulse_fraction_timing' and ref(p,a).resolve()==p/'.gitattributes'
    assert digest(ref(p,a))==item['current_sha256'] and digest(ref(p,b))==item['sha256']
    assert ref(p,a).read_bytes()==b'* -text\n' and ref(p,b).read_bytes()==b'* text eol=lf\n'
   else:assert digest(ref(p,a))==item['sha256']==digest(ref(p,b))
  plan_name=d.get('plan',d.get('approved_plan','PRECHECK_PLAN.json'))
  plan_path=ref(p,plan_name);assert digest(plan_path)==d.get('plan_sha256',d.get('executed_plan_sha256'))
  rp=ref(p,d['receipt']);assert digest(rp)==d['receipt_sha256']
  current_exceptions=d.get('current_source_exceptions',[])
  if current_exceptions:
   assert path=='cores/signal_processing/pulse_fraction_timing' and current_exceptions==['.gitattributes']
   assert d.get('post_qualification_metadata_changes')
  r,records=verify_receipt(p,rp,plan_path,'PASS',current_exceptions,aliases)
  if current_exceptions:
   changes=d['post_qualification_metadata_changes'];assert len(changes)==1
   change=changes[0];assert change['path']=='.gitattributes'
   assert change['before_sha256']==r['source_sha256']['.gitattributes']
   assert change['after_sha256']==digest(p/'.gitattributes')
   assert digest(ref(p,change['checked_archive']))==change['before_sha256']
   assert ref(p,change['checked_archive']).read_bytes()==b'* text eol=lf\n'
   assert (p/'.gitattributes').read_bytes()==b'* -text\n'
  images=next((d[k] for k in ['successful_vvps_to_remove','successful_vvp_images','successful_vvps_for_root_cleanup','verified_compiled_image_sha256'] if k in d),{})
  assert len(images)==sum(c['name'].startswith('sim') for c in records)
  for n,h in images.items():
   image=ref(p,n).resolve();assert digest(image)==h and image.is_relative_to(p)
   compiled=any(c['status']=='PASS' and '-o' in c['argv'] and Path(c['argv'][c['argv'].index('-o')+1]).resolve()==image for c in records)
   simulated=any(c['status']=='PASS' and c['name'].startswith('sim') and Path(c['argv'][1]).resolve()==image for c in records)
   assert compiled and simulated,(path,n,'successful image pair')
  prior=None;prior_pass=prior_sims=prior_fail=0
  if d.get('prior_evidence'):
   prior=d['prior_evidence'];pr=ref(p,prior['receipt']);pp=ref(p,prior['plan'])
   assert digest(pr)==prior['receipt_sha256'] and digest(pp)==prior['plan_sha256']
   old_r,old_records=verify_receipt(p,pr,pp,'FAIL',prior.get('current_source_exceptions',[]),aliases)
   if path=='cores/signal_processing/pulse_fraction_timing':
    iv=str(ROOT/'tools/oss-cad-suite/oss-cad-suite/bin/iverilog.exe')
    expected_prior=[('syntax_default',[iv,'-g2012','-Wall','-tnull','-s','pulse_fraction_timing','-f','files.f']),
     ('syntax_example',[iv,'-g2012','-Wall','-tnull','-s','trigger_pulse256','-f','example/files.f'])]
    assert [(c['name'],c['argv']) for c in old_records]==expected_prior
    assert all(c['cwd']==str(p) for c in old_records)
   prior_pass=sum(c['status']=='PASS' for c in old_records);prior_fail=sum(c['status']=='FAIL' for c in old_records)
   prior_sims=sum(c['status']=='PASS' and c['name'].startswith('sim') for c in old_records)
   assert (prior_pass,prior_fail,prior_sims)==(prior['passed_children'],prior['failed_children'],prior['successful_simulations'])
   failed_images=d.get('failed_vvps_to_retain',{})
   if prior.get('failure_kind')=='NO_IMAGE_SYNTAX_CHILD_FAILURE':
    failed=old_records[-1]
    assert prior_fail==1 and '-tnull' in failed['argv'] and '-o' not in failed['argv']
    assert not failed_images and not old_r.get('artifacts')
    assert (pr.parent/(failed['name']+'.stderr.txt')).stat().st_size>0
   else:
    assert len(failed_images)>=prior_fail
    for n,h in failed_images.items():assert digest(ref(p,n))==h
  lists={};headers=set()
  for name in ['files.f','example/files.f']:
   resolved,includes=source_list(p,name);lists[name]=resolved;sources.update(resolved);headers.update(includes)
  for n in set(sum(lists.values(),[]))-inherited:
   if n.startswith(path+'/'):continue
   base=git('show',BASE+':'+n);assert digest(ROOT/n)==sha(base)
   canonical_base[n]=dict(sha256=sha(base),baseline_commit=BASE,classification='TRACKED_SOURCE_FIRST_ADDED_TO_CUMULATIVE_CLOSURE')
  for n in headers:
   q=ROOT/n;base=git('show',BASE+':'+n);oid=git('rev-parse',BASE+':'+n).decode().strip()
   clean=git('hash-object','--path='+n,str(q)).decode().strip();assert clean==oid
   assert q.read_bytes().replace(b'\r\n',b'\n')==base
   entry=dict(sha256=sha(base),hash_kind='baseline_committed_git_blob',baseline_blob_oid=oid,baseline_commit=BASE,
    executed_worktree_sha256=digest(q),normalization='Only CRLF to LF; no content change',reason='Required offline include first added to cumulative support closure')
   new_headers[n]=entry;snap['support_files'][n]=sha(base);snap['support_file_additions'][n]=entry
  count_sims=sum(c['name'].startswith('sim') for c in records)
  passes+=len(records)+prior_pass;failures+=prior_fail;sims+=count_sims+prior_sims
  snap['packages'].append(dict(path=path,top=top,baseline_commit=BASE,evidence='B40_DELIVERY.json',
   evidence_kind='explicit_finite_checks_with_retained_history',hardware_status='HW_UNVERIFIED',architecture_risk=risk,
   additional_source_lists=['example/files.f'],examples=[dict(file='example/'+example+'.sv',top=example)],sha256=inv))
  summaries.append(dict(path=path,files=len(inv),effective_checks=len(records)+prior_pass,retained_failures=prior_fail,
   successful_simulations=count_sims+prior_sims,prior_evidence=prior,architecture_risk=risk,source_lists=lists,
   include_files=sorted(headers),receipt=dict(path=rp.relative_to(ROOT).as_posix(),sha256=digest(rp),status='PASS')))
  new_files.update({path+'/'+n:h for n,h in inv.items()})
 assert snap['packages'][:156]==parent['packages']
 baseline_sources=sorted(inherited|set(canonical_base))
 packed=git('cat-file','--batch',inp=''.join(BASE+':'+n+'\n' for n in baseline_sources).encode());contents={};offset=0
 for n in baseline_sources:
  end=packed.index(b'\n',offset);header=packed[offset:end].split();assert header[1]==b'blob'
  size=int(header[2]);contents[n]=packed[end+1:end+1+size];offset=end+size+2
  assert digest(ROOT/n)==sha(contents[n]),('Inherited canonical source changed',n)
 declarations={}
 for n in sorted(sources):
  code=re.sub(rb'/\*.*?\*/|//[^\n]*',b'',contents[n] if n in contents else (ROOT/n).read_bytes(),flags=re.S)
  for m in re.findall(rb'\bmodule\s+(?:automatic\s+)?([A-Za-z_][\w$]*)',code):declarations.setdefault(m.decode(),[]).append(n)
 collisions={n:p for n,p in declarations.items() if len(p)>1};assert not collisions
 assert (passes,failures,sims)==(43,1,16),(passes,failures,sims)
 snap.update(date='2026-11-06',baseline_commit=BASE,batch_baseline_commit=BASE,previous_snapshot=PARENT,
  source_freeze='B40 cumulative160 packages: multi-source BBO state, relative-height sampled pulse timing, luma-gated chroma median suppression and affine quantized residual fusion.43 PASS/1 retained syntax FAIL/16 successful simulations. Goal active; no synthesis/PnR/STA/board/PPA/inherited regression.',
  parent_snapshot=dict(path=PARENT,sha256=sha(raw),worktree_sha256=digest(ROOT/PARENT),hash_kind='committed_git_blob',commit=BASE),
  batch_canonical_base_sources=canonical_base,batch_support_file_additions=new_headers,
  baseline_text_normalizations=new_headers)
 audit=dict(schema='anscore-b40-static-audit-v1',status='PASS',baseline_commit=BASE,packages=160,
  parent_snapshot_sha256=sha(raw),inherited_package_objects_exact=156,new_packages=summaries,new_package_files=len(new_files),
  effective_finite_checks=passes,historical_failed_children=failures,total_hdl_children=passes+failures,successful_finite_simulations=sims,
  source_files=len(sources),module_declarations=sum(map(len,declarations.values())),canonical_source_paths=sorted(sources),
  new_canonical_base_sources=sorted(canonical_base),new_support_headers=new_headers,unresolved_module_collisions=collisions,
  scope='Read-only current/archive/plan/vector/raw/tool and successful image-pair verification, complete explicit source/include closure, immutable baseline canonical bytes, preserved inherited package objects. Only explicitly named nonfunctional packaging metadata exceptions. No checker/model imports or HDL execution.',
  combined_compile='NOT_RUN',inherited_checker='NOT_RUN',synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',ppa='NOT_RUN')
 write('docs/snapshots/source_20261106_b40.json',snap);write('docs/snapshots/source_20261106_b40_structure.json',audit)
 print(json.dumps({k:audit[k] for k in ['status','packages','new_package_files','effective_finite_checks','historical_failed_children','successful_finite_simulations','source_files','module_declarations']}))

if __name__=='__main__':main()
