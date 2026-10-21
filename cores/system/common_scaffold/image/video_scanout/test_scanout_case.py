from test_scanout import *
if __name__=='__main__':
 frozen=hashes();row=run(4,3);assert hashes()==frozen
 (HERE/'scanout_case_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,case=row),indent=2)+'\n')
