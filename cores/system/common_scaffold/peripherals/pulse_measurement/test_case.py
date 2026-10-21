from test_measurement import *
if __name__=='__main__':
 frozen=hashes();row=run('case',[(1,9),(0,14),(1,9)])
 assert row['expected_events']==[(1,0,9,14,23)] and hashes()==frozen
 (HERE/'case_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,case=row),indent=2)+'\n')
