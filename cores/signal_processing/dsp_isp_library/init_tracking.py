"""One-time full-scope ledger creation; refuses to overwrite live tracking."""
import hashlib
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[2]
goal = root / 'goal.md'
text = goal.read_text(encoding='utf-8')
rows = []
for section, prefix in [('DSP', 'DSP'), ('ISP', 'ISP'), ('基础设施', 'INFRA')]:
    body = text.split('### ' + section + '\n', 1)[1].split('\n##', 1)[0]
    for number, requirement in re.findall(r'^(\d+)\. (.+)$', body, re.M):
        rows.append(dict(id=f'{prefix}-{int(number):02d}', requirement=requirement,
                         status='待盘点', configurations=[], reuse_candidates=[],
                         implementation=[], specification=[], float_model=[],
                         bit_exact_model=[], simulation=[], checker_negative=[],
                         synthesis=[], route_timing=[], board_injection=[],
                         board_capture=[], board_reprogram=[], production=[],
                         documentation=[], limitations=[]))
assert [sum(r['id'].startswith(p+'-') for r in rows)
        for p in ['DSP', 'ISP', 'INFRA']] == [16, 19, 7]
ledger = dict(contract='goal.md', contract_sha256=hashlib.sha256(goal.read_bytes()).hexdigest(),
              status='active', requirements=rows,
              integration_chains={'DSP': {'status': 'pending', 'evidence': []},
                                  'ISP': {'status': 'pending', 'evidence': []}})
out = Path(__file__).with_name('requirements.json')
with out.open('x', encoding='utf-8') as f:
    json.dump(ledger, f, ensure_ascii=False, indent=2)
    f.write('\n')
print('Initialized 42 full-scope requirements; all acceptance evidence pending.')
