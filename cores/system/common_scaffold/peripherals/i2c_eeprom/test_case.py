from test_transactions import *
if __name__=='__main__':
 frozen=hashes();row=run('case',address=3,length=2)
 assert hashes()==frozen
 (HERE/'case_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=[row]),indent=2)+'\n',encoding='utf-8')
