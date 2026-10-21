"""Execute exact external-reference fixtures through RTL, with explicit boundary adaptation."""
import json,numpy as np,hashlib
from run_tests import HERE,run_case,oracle,hashes

def main():
 f=HERE/'reference_fixtures.mem';d=json.loads(f.read_text());rows=[]
 for case in d['cases']:
  a=np.array(case['cfa']);expect=np.array(case['reflect101_reference']);assert np.array_equal(oracle(a,case['pattern'],case['bits']),expect)
  row=run_case(case['name'],a,case['pattern'],case['bits']);row.update(native_default_boundary_error=case['native_reflect_max_error'],same_boundary_error=0);rows.append(row);print(row,flush=True)
 (HERE/'reference_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),fixture_sha256=hashlib.sha256(f.read_bytes()).hexdigest(),external_source_sha256=d['reference_source_sha256'],cases=rows),indent=2)+'\n')
if __name__=='__main__':main()
