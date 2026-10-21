from test_timing import *
if __name__=='__main__':
 frozen=hashes();row=run((4,2,1,1,3,1,1,1,0,1));assert hashes()==frozen
 (HERE/'timing_case_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,case=row),indent=2)+'\n')
