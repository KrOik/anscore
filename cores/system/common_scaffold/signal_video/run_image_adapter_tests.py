"""Bounded image ABI tests, retaining logs only, not simulation executables."""
from pathlib import Path
import hashlib
import sys
import tempfile

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json
from image_threshold_reference import fixtures

def main():
    evidence=evidence_dir('image_adapters')
    root=HERE.parents[2]
    sources=[HERE/'rtl/cip_image_threshold.v',HERE/'rtl/cip_image_threshold_fixed.v',
             HERE/'sim/tb_cip_image_threshold.v']
    sources += [root/line.strip() for line in (HERE.parent/'image/rtl_sources.f').read_text().splitlines()
                if line.strip() and not line.startswith('#')]
    tracked=[*sources,HERE/'sim/tb_cip_image_threshold_modes.v',Path(__file__),HERE/'image_threshold_reference.py']
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    cases=[]
    with tempfile.TemporaryDirectory(prefix='cip_image_adapter_') as temporary:
        for width in [1,8,16,24,32]:
            binary=Path(temporary)/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_cip_image_threshold',
                     f'-Ptb_cip_image_threshold.DW={width}','-o',binary,*sources],
                    HERE,evidence/f'width{width}_compile.log')
            output=execute(['vvp',binary],HERE,evidence/f'width{width}_simulation.log')
            if f'THRESHOLD_ADAPTER PASS width={width}' not in output:
                raise RuntimeError('missing functional success marker')
            print(output.strip())
            cases.append({'width':width,'status':'PASS'})
            folder=Path(temporary)/f'modes{width}';folder.mkdir()
            counts=fixtures(folder,width)
            execute(['iverilog','-g2012','-s','tb_cip_image_threshold_modes',
                     f'-Ptb_cip_image_threshold_modes.DW={width}','-o',binary,*sources,
                     HERE/'sim/tb_cip_image_threshold_modes.v'],HERE,evidence/f'width{width}_modes_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',
                            *[f'+{k}={counts[k]}' for k in ['commands','inputs','outputs']]],
                           HERE,evidence/f'width{width}_modes_simulation.log')
            if f'THRESHOLD_MODES PASS width={width}' not in output:
                raise RuntimeError('missing mode dispatcher success marker')
            print(output.strip());cases[-1]['modes']=counts
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):
        raise RuntimeError('source changed during test')
    write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,
        'scope':'fixed/Otsu/adaptive mean/adaptive Gaussian frame ABI','board':'not_run'})
    print(f'evidence={evidence}')

if __name__=='__main__':
    main()
