from pathlib import Path
import sys,tempfile,json,hashlib
HERE=Path(__file__).resolve().parent
COMMON=HERE.parents[4];DSP=COMMON/'dsp';SV=COMMON/'signal_video'
sys.path.insert(0,str(COMMON/'integration'));sys.path.insert(0,str(DSP));sys.path.insert(0,str(SV))
from tooling import execute
from resampler_reference import fixtures
adapter_fixtures=fixtures

def main():
    results=[]
    with tempfile.TemporaryDirectory(prefix='resampler_candidate_') as temporary:
        for kind in ('core','adapter'):
            for up,down,taps in [(1,1,1),(3,2,11),(2,5,13),(5,1,7),(1,4,9),(4,6,17),(7,3,3)]:
                label=f'{kind}_u{up}_d{down}_t{taps}';folder=Path(temporary)/label;folder.mkdir()
                counts=(fixtures if kind=='core' else adapter_fixtures)(folder,up,down,taps)
                top='tb_cip_dsp_resampler' if kind=='core' else 'tb_cip_resampler_stream'
                sources=[HERE/'cip_dsp_resampler.v']
                if kind=='adapter':sources.append(SV/'rtl/cip_resampler_stream.v')
                sources.append((DSP if kind=='core' else SV)/f'sim/{top}.v')
                execute(['iverilog','-g2012','-s',top,f'-P{top}.UP={up}',f'-P{top}.DOWN={down}',f'-P{top}.TAPS={taps}','-o',folder/'sim.vvp',*sources],HERE,HERE/f'{label}_compile.log')
                result=execute(['vvp',folder/'sim.vvp',f'+folder={folder}'],HERE,HERE/f'{label}_simulation.log')
                if 'PASS' not in result or f"outputs={counts['outputs']}" not in result:raise RuntimeError(result)
                print(result.strip(),flush=True);results.append(dict(kind=kind,up=up,down=down,taps=taps,**counts))
    (HERE/'regression_summary.json').write_text(json.dumps(dict(status='PASS',cases=results,sha256=hashlib.sha256((HERE/'cip_dsp_resampler.v').read_bytes()).hexdigest()),indent=2)+'\n')
if __name__=='__main__':main()
