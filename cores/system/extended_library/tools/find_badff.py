import re
txt = open('build_oss/dump.il').read()
cells = re.split(r'\n  cell ', txt)
for c in cells[1:]:
    m = re.search(r'type \\(\S+)', c)
    typ = m.group(1) if m else '?'
    if 'ff' not in typ.lower():
        continue
    arst = re.search(r'parameter \\ARST_VALUE (\S+)', c)
    init = re.search(r'parameter \\INIT_VALUE (\S+)', c)
    src = re.search(r'attribute \\src "([^"]+)"', c)
    iv = init.group(1) if init else '0'
    # print any ff whose init has 1s, plus its arst
    if '1' in iv.split("'")[-1] or (arst and '1' in arst.group(1).split("'")[-1]):
        print(typ, 'INIT=', iv, 'ARST=', arst.group(1) if arst else 'none',
              'src=', src.group(1) if src else '?',
              '|', c.split('\n')[0][:60])
