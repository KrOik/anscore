from test_measurement import *
if __name__=='__main__':
 frozen=hashes();rows=[]
 rows.append(run('period_overflow16',[(1,40000),(0,40000),(1,12)],width=16))
 rows.append(run('segment_overflow16',[(1,70000),(0,20),(1,22),(0,31),(1,16)],width=16))
 rows.append(run('idle_overflow16',[(0,65600),(1,22),(0,31),(1,16)],width=16))
 rows.append(run('filter_max255',[(1,300),(0,400),(1,300),(0,500),(1,300)],filter_n=255))
 rows.append(run('filter_max65535',[(1,65540),(0,65542),(1,65545)],filter_n=65535,filter_width=16))
 rows.append(run('filter_one',[(1,1),(0,2),(1,2),(0,1),(1,3)],filter_n=1))
 assert any(e[1]&2 for r in rows[:3] for e in r['expected_events']) and hashes()==frozen
 (HERE/'boundary_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n')
