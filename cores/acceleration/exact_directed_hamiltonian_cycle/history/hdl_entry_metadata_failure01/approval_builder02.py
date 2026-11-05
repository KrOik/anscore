from pathlib import Path
import json,hashlib
R=Path(__file__).resolve().parent.parent
P=R/'cores/acceleration/exact_directed_hamiltonian_cycle'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
D=R/'.git/b29-root-hdl-entry-metadata-failure01'
old=json.loads((D/'RECEIPT.json').read_bytes())
assert old['hdl_child_invocations']==0 and old['preparation_invocations_total']==1
assert {p.relative_to(P).as_posix():sha(p) for p in P.rglob('*') if p.is_file()}==old['preserved_original_package_files_sha256']
assert not (P/'evidence').exists() and not (R/'.git/b29-root-hdl-approval01.json').exists()
review=R/'.git/b29-c-root-actual-preparation-and-prehdl-review.json'
assert sha(review)=='c026609327f0ac4c12d072474c0d048d61ccfc654e39bf6e6181ae30dd8b46c9'
d=json.loads(review.read_bytes())
assert d['conclusion']=='PASS_ACTUAL_PREPARATION_AND_FIXED25_PREHDL_STATIC_REVIEW' and d['blocking_findings']==[]
assert d['bindings']['SOURCE_SEAL_sha256']==sha(P/'SOURCE_SEAL.json')=='c874702cc0517f5af948c8b02b570be3638e22c530dd341f6eb19ab83bca60d7'
repair=R/'.git/b29-c-root-hdl-entry-metadata-repair-review.json'
assert repair.is_file()
r=json.loads(repair.read_bytes());assert r['status']=='PASS_METADATA_ONLY_CORRECTION' and r['builder_sha256']==sha(Path(__file__)) and r['original_failure_receipt_sha256']==sha(D/'RECEIPT.json')
reviews={review.relative_to(R).as_posix():sha(review),'.git/b29-b-root-source-repair-preparation-review.json':'5d6d01a32f0a7ef06711a558da80f482ff36985665165535c37f799afdf3040a',repair.relative_to(R).as_posix():sha(repair)}
for n,h in reviews.items():assert sha(R/n)==h
ap={'stage':'hdl','approved_by':'root','approved_seal_sha256':sha(P/'SOURCE_SEAL.json'),'max_invocations':1,'hard_seconds_per_tree':20,'automatic_retry':False,'independent_reviews':reviews,'children':json.loads((P/'TEST_PLAN.json').read_bytes())['children'],'scope':'Only original fixed25 children; no prior HDL children launched. No model reexecution, automatic retry or expanded matrix.','prior_preapproval_metadata_failure_receipt_sha256':sha(D/'RECEIPT.json')}
p=R/'.git/b29-root-hdl-approval01.json'
with p.open('x',encoding='utf-8',newline='\n') as f:json.dump(ap,f,indent=2);f.write('\n')
print(json.dumps({'approval_sha256':sha(p),'HDL':'APPROVED_NOT_RUN','prior_hdl_children':0}))
