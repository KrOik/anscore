"""Create a fresh fixture with all listed production RTL dependencies refreshed."""
from pathlib import Path
import json
import subprocess
import sys

HERE=Path(__file__).resolve().parent
PACKAGE=HERE.parents[2]
ROOT=PACKAGE.parents[1]

if __name__=='__main__':
    base=Path(sys.argv[1]).resolve()
    out=Path(sys.argv[2]).resolve()
    if not base.is_relative_to(HERE) or not out.is_relative_to(HERE):
        raise RuntimeError('fixtures must remain within acceptance48')
    production={}
    for line in (PACKAGE/'rtl_functional_sources.f').read_text().splitlines():
        if line.strip() and not line.startswith('#'):
            p=ROOT/line.strip()
            production[p.name]=p
    replacements=[]
    for name in json.loads((base/'case.json').read_text())['sources']:
        staged=base/name
        current=production.get(staged.name)
        if current and current.is_file() and staged.read_bytes()!=current.read_bytes():
            replacements.append(current)
    subprocess.run([sys.executable,'-B',str(HERE/'scalar_dehaze_optimized/stage_harness.py'),
                    str(base),str(out),*map(str,replacements)],check=True)
