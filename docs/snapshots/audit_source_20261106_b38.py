"""SPDX-License-Identifier: Apache-2.0. B38 additive static evidence/source audit."""
from pathlib import Path
import copy,hashlib,json,re,subprocess
ROOT=Path(__file__).resolve().parents[2]
BASE='816d461b12fd402f6a146ca74c7491c7afbd3091'
PARENT='docs/snapshots/source_20261106_b37.json'
OLD_AUDIT='docs/snapshots/source_20261106_b37_structure.json'
NEW=[('cores/storage/pretrade_credit_ledger','pretrade_credit_ledger','credit_gated_ioc16'),
 ('cores/signal_processing/symbol_evm_measure','symbol_evm_measure','qam16_evm'),
 ('cores/image_processing/rgba_sprite_blit','rgba_sprite_blit','indexed_sprite_frame'),
 ('cores/acceleration/int4_reglu','int4_reglu','reglu32_input')]
SUPPORT='cores/acceleration/vector_l2sq/rtl/vector_l2sq.v'
ATTR='cores/acceleration/vector_l2sq/rtl/.gitattributes'
SUPPORT_SHA='3610f3442969eb00048b47fb7198e344f479c6e9ce5b75aabc48a4a76d7c71d9'
QAM='cores/acceleration/operator_library/rtl/acc_comm_qam16_llr.v'
QAM_SHA='cdfb31c6f29f08c175080bd6b4f738784b533fa8064da7471edfba9a47410a49'
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
def main():
 raw=git('show',BASE+':'+PARENT);parent=json.loads(raw);old=json.loads(git('show',BASE+':'+OLD_AUDIT))
 assert len(parent['packages'])==148
 assert hfile(ROOT/SUPPORT)==SUPPORT_SHA and (ROOT/ATTR).read_bytes()==b'/vector_l2sq.v -text\n'
 assert not git('ls-tree',BASE,'--',SUPPORT)
 assert hfile(ROOT/QAM)==QAM_SHA==sha(git('show',BASE+':'+QAM))
 snap=copy.deepcopy(parent);sources=set(old['canonical_source_paths'])|{SUPPORT,QAM}
 support={SUPPORT:dict(sha256=SUPPORT_SHA,baseline_source_status='PREEXISTING_WORKTREE_NOT_TRACKED',reason='Existing original vector distance dependency first exported here; no inherited qualification claim'),
  ATTR:dict(sha256=hfile(ROOT/ATTR),reason='Scoped attribute preserves exact existing source bytes')}
 for n,e in support.items():snap['support_files'][n]=e['sha256'];snap['support_file_additions'][n]=e
 summaries=[];new_files={};passes=sims=0
 for path,top,example in NEW:
  p=ROOT/path;d=json.loads((p/'B38_DELIVERY.json').read_bytes());inv=inventory(p)
  assert inv['.gitattributes']==sha(b'* -text\n')
  assert 'HW_UNVERIFIED'in d.get('maturity',d.get('status',[]))or d.get('hardware')=='HW_UNVERIFIED'
  assert d.get('historical_hdl_failures',0)==0
  for field in ['files','package_sha256','package_files','metadata_hashes','metadata_sha256','source_archive','numerical_vectors','raw_streams']:
   mapping=d.get(field,{})
   if isinstance(mapping,dict):
    for n,h in mapping.items():assert hfile(ref(p,n))==h,(path,field,n)
  for n,h in d.get('current_executable_sources',{}).items():assert hfile(ref(p,n))==h,(path,n)
  for m in d.get('source_mapping',[]):
   source,checked=(m['source'],m['exact_checked_copy'])if 'source'in m else(m['current'],m['archive'])
   assert hfile(ref(p,source))==m['sha256']==hfile(ref(p,checked)),(path,source)
  plan_name=d.get('plan',d.get('approved_plan','PRECHECK_PLAN.json'));plan_path=ref(p,plan_name)
  assert hfile(plan_path)==d['plan_sha256'];plan=json.loads(plan_path.read_bytes())
  rp=ref(p,d['receipt']);assert hfile(rp)==d['receipt_sha256'];r=json.loads(rp.read_bytes())
  assert r.get('plan_sha256',d['plan_sha256'])==d['plan_sha256']
  if(rp.parent/'plan.json').is_file():assert hfile(rp.parent/'plan.json')==d['plan_sha256']
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
  assert len(records)==d['effective_finite_checks']and successful_sims==d['successful_simulations']
  risk=d.get('architecture_risk',d.get('resource_risk','UNKNOWN'));lists={}
  for fl in ['files.f','example/files.f']:
   resolved=[]
   for line in(p/fl).read_text().splitlines():
    line=line.split('#',1)[0].strip()
    if not line:continue
    assert not line.startswith('-')
    source=(p/line).resolve();canonical=source.relative_to(ROOT).as_posix()
    assert source.is_file()and source.suffix.lower()in['.v','.sv']
    assert canonical in sources or canonical.startswith(path+'/'),canonical
    assert canonical not in resolved;resolved.append(canonical);sources.add(canonical)
   lists[fl]=resolved
  snap['packages'].append(dict(path=path,top=top,baseline_commit=BASE,evidence='B38_DELIVERY.json',evidence_kind='explicit_finite_rules',hardware_status='HW_UNVERIFIED',architecture_risk=risk,
   additional_source_lists=['example/files.f'],examples=[dict(file='example/'+example+'.sv',top=example)],sha256=inv))
  summaries.append(dict(path=path,files=len(inv),effective_checks=len(records),successful_simulations=successful_sims,architecture_risk=risk,source_lists=lists,
   receipt=dict(path=rp.relative_to(ROOT).as_posix(),sha256=hfile(rp),status=r['status'])))
  passes+=len(records);sims+=successful_sims;new_files.update({path+'/'+n:h for n,h in inv.items()})
 assert snap['packages'][:148]==parent['packages']
 old_paths=sorted(set(old['canonical_source_paths'])|{QAM})
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
 assert(passes,sims)==(43,16)
 snap.update(date='2026-11-06',baseline_commit=BASE,batch_baseline_commit=BASE,previous_snapshot=PARENT,
  source_freeze='B38 cumulative152 packages: ticket/account credit holds with IOC integration, symbol EVM squared, rectangle sprite alpha blit and resident INT4 ReGLU.43 PASS children/16 successful simulations; no retries/failures this batch. No synthesis/PnR/STA/board/inherited regression. Goal active.',
  parent_snapshot=dict(path=PARENT,sha256=sha(raw),worktree_sha256=hfile(ROOT/PARENT),hash_kind='committed_git_blob',commit=BASE),batch_support_file_additions=support,
  batch_canonical_base_sources={QAM:dict(sha256=QAM_SHA,baseline_commit=BASE,classification='TRACKED_SOURCE_FIRST_ADDED_TO_CUMULATIVE_CLOSURE')})
 audit=dict(schema='anscore-b38-static-audit-v1',status='PASS',baseline_commit=BASE,packages=152,parent_snapshot_sha256=sha(raw),inherited_package_objects_exact=148,
  new_packages=summaries,new_package_files=len(new_files),effective_finite_checks=passes,historical_failed_children=0,successful_finite_simulations=sims,
  source_files=len(sources),module_declarations=sum(map(len,declarations.values())),canonical_source_paths=sorted(sources),new_support_sources=[SUPPORT],new_canonical_base_sources=[QAM],unresolved_module_collisions=collisions,
  scope='Additive evidence hashes/offline source closure, planned argv where frozen, all inherited canonical source bytes and declarations from immutable baseline.',
  combined_compile='NOT_RUN',inherited_checker='NOT_RUN',synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN')
 write('docs/snapshots/source_20261106_b38.json',snap);write('docs/snapshots/source_20261106_b38_structure.json',audit)
 print(json.dumps({k:audit[k]for k in['status','packages','new_package_files','effective_finite_checks','successful_finite_simulations','source_files','module_declarations']}))
if __name__=='__main__':main()
