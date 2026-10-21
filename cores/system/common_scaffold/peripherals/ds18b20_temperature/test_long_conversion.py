from test_temperature import *
if __name__=='__main__':
 frozen=hashes();row=run('conversion_750ms',ready_us=750000,timeout=800000)
 assert hashes()==frozen
 (HERE/'long_conversion_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=[row]),indent=2)+'\n')
