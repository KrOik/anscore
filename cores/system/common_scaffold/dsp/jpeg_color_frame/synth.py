"""Full hierarchy isolated synthesis, gated by latest passing integration evidence."""
import hashlib
import json
from pathlib import Path
import re
import sys
import tempfile

HERE = Path(__file__).resolve().parent
PACKAGE = HERE.parents[1]
sys.path.insert(0, str(PACKAGE / 'integration'))
from test_jpeg_color_frame import SOURCES
from tooling import ROOT, execute


def main():
    folders = sorted((PACKAGE / 'evidence').glob('jpeg_color_frame_*'),
                     key=lambda p: p.stat().st_mtime)
    if not folders:
        raise RuntimeError('Run integration/test_jpeg_color_frame.py first')
    evidence = folders[-1] / 'results.json'
    result = json.loads(evidence.read_text())
    if result.get('status') != 'PASS':
        raise RuntimeError(f'Latest integration evidence is not PASS: {evidence}')
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in SOURCES}
    if result['sources'] != hashes:
        raise RuntimeError('RTL differs from latest passing integration evidence')
    results = []
    for width, height in ((16, 16), (33, 17)):
        label = f'{width}x{height}'
        with tempfile.TemporaryDirectory(prefix=f'jpeg_color_frame_synth_{label}_') as td:
            full_log = Path(td) / 'yosys.log'
            script = ('read_verilog -sv ' + ' '.join(p.as_posix() for p in SOURCES)
                      + f'; chparam -set WIDTH {width} -set HEIGHT {height} jpeg_color_frame'
                      + '; synth_gowin -top jpeg_color_frame -noalu -nodsp; check -assert; stat')
            text = execute(['yosys', '-p', script], td, full_log, timeout=600)
            hierarchy = text.rsplit('=== design hierarchy ===', 1)[1]
            cells = {name: int(n) for n, name in re.findall(
                r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$', hierarchy, re.M)}
            summary = dict(width=width, height=height, result='PASS', cells=cells,
                           lut=sum(cells.get(f'LUT{i}', 0) for i in range(1, 5)),
                           alu=cells.get('ALU', 0),
                           ff=sum(n for k, n in cells.items() if k.startswith('DFF')),
                           ram={k: n for k, n in cells.items()
                                if 'RAM' in k or 'ROM' in k or k.startswith(('SP', 'DP', 'SDP'))},
                           dsp={k: n for k, n in cells.items() if any(t in k for t in ('MULT', 'DSP', 'PADD'))})
            (HERE / f'synthesis_{label}.log').write_text(
                'Full hierarchy synthesis; CHECK -assert completed successfully.\n'
                'Flow: synth_gowin -noalu -nodsp; check -assert; stat\n'
                + hierarchy, encoding='utf-8')
            results.append(summary)
            print(json.dumps(summary), flush=True)
    if hashes != {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in SOURCES}:
        raise RuntimeError('RTL changed during synthesis; discard results and rerun')
    (HERE / 'synthesis.json').write_text(json.dumps(dict(
        result='PASS', integration_evidence=str(evidence.relative_to(ROOT)),
        flow='synth_gowin -noalu -nodsp; check -assert; stat', sources=hashes,
        results=results, board=False, pnr=False), indent=2) + '\n')


if __name__ == '__main__':
    main()
