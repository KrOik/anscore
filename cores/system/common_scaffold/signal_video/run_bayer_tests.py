"""Legacy RAW8/10/12 Bayer adapter regression; no persistent binaries/fixtures."""
from pathlib import Path
import hashlib
import sys
import tempfile

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json
from bayer_reference import fixtures


def main():
    evidence=evidence_dir('bayer_adapter')
    sources=[HERE/'rtl/cip_image_bayer_demosaic.v',HERE.parent/'image/pipelines/img_bayer_window_frontend_draft.v',
        HERE.parent/'image/window/img_window3x3_valid_draft.v',HERE.parent/'image/isp/img_isp_bayer_interpolate.v',
        HERE/'sim/tb_cip_image_bayer.v']
    tracked=[*sources,Path(__file__),HERE/'bayer_reference.py']
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    cases=[]
    with tempfile.TemporaryDirectory(prefix='cip_bayer_') as temporary:
        for width,raw_bits in [(24,8),(24,10),(24,12),(24,9),(8,8),(32,8)]:
            label=f'w{width}_raw{raw_bits}';folder=Path(temporary)/label;folder.mkdir()
            counts=fixtures(folder,width,raw_bits);binary=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_cip_image_bayer',f'-Ptb_cip_image_bayer.DW={width}',
                f'-Ptb_cip_image_bayer.RAW_BITS={raw_bits}','-o',binary,*sources],HERE,evidence/f'{label}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',
                *[f'+{k}={counts[k]}' for k in ['commands','inputs','outputs']]],
                HERE,evidence/f'{label}_simulation.log')
            if f'BAYER_ADAPTER PASS width={width} raw={raw_bits}' not in output:raise RuntimeError('missing functional marker')
            print(output.strip());cases.append(counts)
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):
        raise RuntimeError('source changed during test')
    write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'board':'not_run'})
    print(f'evidence={evidence}')


if __name__=='__main__':
    main()
