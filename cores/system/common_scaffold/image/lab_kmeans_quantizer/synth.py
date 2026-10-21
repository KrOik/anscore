"""Isolated complete Lab/K-means/RGB hardware hierarchy resource check."""
import hashlib
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from test_lab_kmeans_quantizer import LAB,SOURCES
from tooling import execute


def main():
    inputs=SOURCES+[LAB/'decode.mem',LAB/'nonlinear.mem']
    frozen={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    results=[]
    for w,h in ((7,5),(32,32)):
        with tempfile.TemporaryDirectory(prefix='lab_kmeans_synth_') as temporary:
            td=Path(temporary)
            for name in ('decode.mem','nonlinear.mem'):
                shutil.copyfile(LAB/name,td/name)
            script='read_verilog -sv '+' '.join(p.as_posix() for p in SOURCES)+'; '
            script+=f'chparam -set WIDTH {w} -set HEIGHT {h} lab_kmeans_quantizer; '
            script+='synth_gowin -top lab_kmeans_quantizer -noalu -nodsp; flatten; check -assert; stat'
            output=execute(['yosys','-p',script],td,td/'full.log',timeout=600)
            summary=output.rsplit('=== lab_kmeans_quantizer ===',1)[1]
            cells={name:int(count) for count,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',summary,re.M)}
            lut=sum(cells.get(f'LUT{k}',0) for k in range(1,5))
            dsp=sum(n for k,n in cells.items() if any(s in k for s in ('MULT','DSP','PADD')))
            assert lut and lut<=15000 and dsp<=4,(w,h,lut,dsp)
            result=dict(width=w,height=h,status='PASS',lut=lut,
                        mux=sum(n for k,n in cells.items() if k.startswith('MUX')),
                        ff=sum(n for k,n in cells.items() if k.startswith('DFF')),
                        ram={k:n for k,n in cells.items() if 'RAM' in k or k.startswith(('SP','DP','SDP'))},
                        dsp=dsp,cells=cells)
            (HERE/f'synthesis_{w}x{h}.log').write_text('Full hierarchy CHECK -assert PASS\n'+summary,encoding='utf-8')
            results.append(result)
            print(result,flush=True)
    assert frozen=={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    (HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',results=results,sources=frozen,
        flow='synth_gowin -noalu -nodsp; flatten; check -assert; stat',board=False,pnr=False),indent=2)+'\n',encoding='utf-8')


if __name__=='__main__':
    main()
