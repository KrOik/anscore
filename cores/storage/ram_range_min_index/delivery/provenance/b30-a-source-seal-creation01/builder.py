"""Metadata-only A SOURCE_SEAL creation; no package imports or target evaluation."""
from pathlib import Path
import argparse,hashlib,json,sys
if sys.flags.optimize:raise RuntimeError('optimized Python forbidden')
R=Path(__file__).resolve().parent.parent;P=R/'cores/storage/ram_range_min_index'
A='474202814626d9cf7f9ad1dddc3a9e2802e6006557257bed6426816a116e143e'
S='8aff538286c1f53da328e77bc8559751cb98733f3cafdf9c36fc04539dff154a'
PP='28ad33540f2cce30461247d1d8b7d4f46727f4540ddaee713c489207c68c4fee'
E='603f9938d11b98cb73959d36376a322d3ee4d989b234a0e04a1e842be04ffee4'
PR='a9589c3e620b9480918e876b0abd9f6fe033c6ed20315079e81eebc078ba630c'
LK='374f12ede80955a1ceaee78b79a6339bdc42a29af5b2a409cb96a43c9b5db2db'
AH='78e5a053124d520d049596cac6f0e1de9cd84d49c4c8600097fafa8c1ceb9946'
OUT='fd48b55a7389e7fe08ad05e52eb4a55e03b3e9adcbdc22a2779245c6e61c7f75'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_bytes())
def write(p,d,exclusive=True):
 with p.open('x' if exclusive else 'w',encoding='utf-8',newline='\n') as f:f.write(json.dumps(d,indent=2)+'\n')
def local(base,n):
 assert n and not any(c in n for c in ('\\',':','\0','\r','\n'))
 p=(base/n).resolve();assert p.is_relative_to(base.resolve()) and not p.is_symlink();return p
def inventory(p):return {f.relative_to(p).as_posix():sha(f) for f in p.rglob('*') if f.is_file()}
def main(ap,expected):
 assert sha(Path(__file__))==expected
 ap=ap.resolve();assert ap.is_relative_to(R/'.git');approval=read(ap);H=sha(ap)
 required=dict(schema='anscore-b30-a-source-seal-metadata-approval-v1',approved_by='root',builder_sha256=expected,
  author_sha256=A,author_seal_sha256=S,preparation_plan_sha256=PP,preparation_evidence_sha256=E,
  prepared_receipt_sha256=PR,prepared_lock_sha256=LK,preparation_approval_sha256=AH,outer_receipt_sha256=OUT,
  max_invocations=1,model_calls=0,tool_children=0,automatic_retry=False)
 assert all(approval.get(k)==v for k,v in required.items());reviews=approval['independent_reviews'];assert len(reviews)>=2
 for n,h in reviews.items():assert local(R,n).is_relative_to(R/'.git') and sha(local(R,n))==h
 baseline=inventory(P);assert len(baseline)==257 and not (P/'SOURCE_SEAL.json').exists()
 assert sha(P/'AUTHOR_INPUTS.json')==A and sha(P/'AUTHOR_SEAL.json')==S and sha(P/'PREPARATION_PLAN.json')==PP
 assert sha(P/'preparation_evidence/receipt.json')==E and sha(P/'prepared/receipt.json')==PR and sha(P/'prepared/LOCK.json')==LK
 original=R/'.git/b30-a-prepare01-approval.json';assert sha(original)==AH
 outer=R/'.git/b30-a-preparation-outer-execution01';assert sha(outer/'receipt.json')==OUT
 author=read(P/'AUTHOR_INPUTS.json');seal=read(P/'AUTHOR_SEAL.json');evidence=read(P/'preparation_evidence/receipt.json')
 prepared=read(P/'prepared/receipt.json');lock=read(P/'prepared/LOCK.json');outer_receipt=read(outer/'receipt.json')
 assert seal['sources']=={**author['sources'],'AUTHOR_INPUTS.json':A}
 own={**seal['sources'],'AUTHOR_SEAL.json':S};assert len(own)==26
 for n,h in own.items():assert sha(local(P,n))==h
 assert outer_receipt['status']=='PASS_PREPARATION_ONCE_FULL_RUNTIME_OUTER_JOB20' and outer_receipt['approval_sha256']==AH
 child=outer_receipt['child'];assert child['exit_code']==0 and not child['timed_out'] and child['launch_error'] is None
 assert child['elapsed_seconds']<20 and child['supervision']==dict(pid=child['supervision']['pid'],contained_before_resume=True,job_closed=True)
 for n,h in outer_receipt['retained_inputs_sha256'].items():assert sha(local(outer,n))==h
 assert evidence['status']=='PREPARATION_PASS' and evidence['returncode']==0 and not evidence['timed_out'] and evidence['failure'] is None
 assert evidence['elapsed_seconds']<20 and evidence['process_tree_cleanup']['windows_kill_on_close_job_closed'] is True
 for name,want in [('stdout',b'PASS PREPARATION FIXED_PROGRAMS\r\n'),('stderr',b'')]:
  p=local(P,evidence[name+'_file']);assert p.read_bytes()==want and sha(p)==evidence[name+'_sha256'] and p.stat().st_size==evidence[name+'_bytes']
 assert evidence['prepared_receipt_sha256']==PR and evidence['prepared_lock_sha256']==LK
 assert prepared['status']=='PREPARED_FIXED_FINITE' and prepared['preparation_invocations']==1 and prepared['automatic_retry'] is False and prepared['input_expansion'] is False
 assert lock['status']=='STARTED_ONCE'
 identities=dict(author_sha256=A,author_seal_sha256=S,preparation_plan_sha256=PP,approval_path=str(original),approval_sha256=AH)
 for record in (evidence,prepared,lock):
  assert all(record[k]==v for k,v in identities.items())
  for k in ('execution_context','argv','working_directory','executed_sources_sha256'):assert record[k]==evidence[k]
 context=evidence['execution_context'];assert context==read(original)['execution_context']
 assert evidence['argv']==[s.replace('{APPROVAL_SHA256}',AH) for s in context['preparation_argv_template']]
 assert evidence['working_directory']==context['preparation_cwd']
 assert evidence['executed_sources_sha256']=={n:author['sources'][n] for n in ('prepare.py','oracle.py')}
 copies={'cores/storage/ram_range_min_index/'+n:h for n,h in own.items()};copies.update(author['external_sources']);copies[author['baseline_manifest']]=author['baseline_manifest_sha256']
 assert len(copies)==28 and evidence['tested_copies_sha256']==copies==context['tested_copies_sha256']
 assert inventory(P/'preparation_evidence/sources')==copies
 for n,h in copies.items():assert sha(local(R,n))==h
 fixture_map=prepared['files_sha256'];assert len(fixture_map)==198
 assert inventory(P/'prepared')=={**{n.removeprefix('prepared/'):h for n,h in fixture_map.items()},'receipt.json':PR,'LOCK.json':LK}
 for n,h in fixture_map.items():assert n.startswith('prepared/fixtures/') and sha(local(P,n))==h
 prepared_map={**fixture_map,'prepared/receipt.json':PR,'prepared/LOCK.json':LK};sources={**own,**prepared_map};assert len(sources)==226
 preparation={**identities,'prepared_receipt_sha256':PR,'preparation_evidence_receipt_sha256':E,'prepared_lock_sha256':LK,
  'execution_context':context,'argv':evidence['argv'],'working_directory':evidence['working_directory']}
 document=dict(schema='b30-a-source-seal-v2',status='FROZEN_NOT_EXECUTION_APPROVAL',author_sha256=A,author_seal_sha256=S,
  sources=sources,external_sources=author['external_sources'],preparation=preparation,test_plan_sha256=sha(P/'TEST_PLAN.json'),
  toolchain_sha256=sha(P/'TOOLCHAIN.json'),children=read(P/'TEST_PLAN.json')['children'],hardware='HW_UNVERIFIED',
  root_metadata_only_creation=dict(builder_sha256=expected,approval_sha256=H,independent_reviews=reviews,model_calls=0,tool_children=0))
 assert len(document['children'])==25 and inventory(P)==baseline and sha(ap)==H and sha(Path(__file__))==expected
 out=R/'.git/b30-a-source-seal-creation01';assert not out.exists();out.mkdir()
 write(out/'LOCK.json',dict(status='STARTED_ONCE',approval_sha256=H,builder_sha256=expected))
 try:
  for name,p in [('builder.py',Path(__file__)),('approval.json',ap)]:
   with (out/name).open('xb') as f:f.write(p.read_bytes())
  write(P/'SOURCE_SEAL.json',document)
  assert inventory(P)=={**baseline,'SOURCE_SEAL.json':sha(P/'SOURCE_SEAL.json')} and read(P/'SOURCE_SEAL.json')==document
  write(out/'receipt.json',dict(status='PASS_METADATA_ONLY_SOURCE_SEAL_CREATED',source_seal_sha256=sha(P/'SOURCE_SEAL.json'),approval_sha256=H,builder_sha256=expected,model_calls=0,tool_children=0))
  print('PASS A_METADATA_ONLY_SOURCE_SEAL '+sha(P/'SOURCE_SEAL.json'));return 0
 except Exception as error:
  write(out/'receipt.json',dict(status='FAILED_STOPPED_NO_RETRY',error=repr(error),files_sha256=inventory(P),model_calls=0,tool_children=0))
  raise
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--approval',type=Path,required=True);p.add_argument('--approved-builder',required=True)
 a=p.parse_args();raise SystemExit(main(a.approval,a.approved_builder))
