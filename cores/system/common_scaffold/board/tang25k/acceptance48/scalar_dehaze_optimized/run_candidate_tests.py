from pathlib import Path
import sys,tempfile,json,hashlib
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[3];SV=COMMON/'signal_video'
sys.path.insert(0,str(SV));sys.path.insert(0,str(COMMON/'integration'))
from run_dehaze_adapters_tests import fixtures
from tooling import execute
def main():
    sources=[SV/'rtl'/f'cip_image_{n}.v' for n in ('dark_channel','transmission','recover','dehaze')]
    sources += [HERE/'cip_image_dehaze_scalar_frame.v',SV/'sim/tb_cip_image_dehaze_adapters.v',*sorted((COMMON/'image/dehaze').glob('*.v'))]
    sources=[HERE/p.name if p.name in ('img_dh_transmission.v','img_dh_restore.v') else p for p in sources]
    results=[]
    with tempfile.TemporaryDirectory(prefix='scalar_dehaze_mapping_') as temporary:
        for kind,name in enumerate(('dark_channel','transmission','recover','dehaze')):
            for width in ([16,24,32,8] if kind==1 else [24,32,16]):
                label=f'{name}_w{width}';folder=Path(temporary)/label;folder.mkdir()
                counts=fixtures(folder,kind,width)
                execute(['iverilog','-g2012','-s','tb_cip_image_dehaze_adapters',f'-DCORE=cip_image_{name}',f'-Ptb_cip_image_dehaze_adapters.DW={width}',f'-Ptb_cip_image_dehaze_adapters.KIND={kind}','-o',folder/'sim.vvp',*sources],HERE,HERE/f'{label}_compile.log')
                result=execute(['vvp',folder/'sim.vvp',f'+folder={folder}',f'+commands={counts["commands"]}',f'+pixels={counts["pixels"]}'],HERE,HERE/f'{label}_simulation.log')
                if 'DEHAZE_ADAPTER PASS' not in result:raise RuntimeError(result)
                print(result.strip(),flush=True);results.append(counts)
    (HERE/'regression_summary.json').write_text(json.dumps(dict(status='PASS',cases=results,sha256=hashlib.sha256((HERE/'cip_image_dehaze_scalar_frame.v').read_bytes()).hexdigest()),indent=2)+'\n')
if __name__=='__main__':main()
