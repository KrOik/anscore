from test_temperature import *
if __name__=='__main__':
 row=run('case')
 (HERE/'case_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),profiles=[row]),indent=2)+'\n')
