from test_transactions import *
if __name__=='__main__':
 frozen=hashes();dep=dependency();row=run('case')
 assert hashes()==frozen and dependency()==dep
 (HERE/'case_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,dependency_sha256=dep,profiles=[row]),indent=2)+'\n',encoding='utf-8')
