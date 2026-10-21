"""CCM legacy ABI functional tests; no persistent simulation binaries."""
from pathlib import Path
import hashlib
import sys
import tempfile

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json
from ccm_reference import fixtures


def main():
    evidence=evidence_dir('ccm_adapter')
    sources=[HERE/'rtl/cip_image_ccm.v',HERE/'rtl/cip_image_pointwise_frame_ctrl.v',
             HERE.parent/'image/isp/img_isp_ccm.v',HERE/'sim/tb_cip_image_ccm.v']
    tracked=[*sources,Path(__file__),HERE/'ccm_reference.py']
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    cases=[]
    with tempfile.TemporaryDirectory(prefix='cip_ccm_') as temporary:
        for width in [8,24,32]:
            folder=Path(temporary)/f'w{width}';folder.mkdir();counts=fixtures(folder,width)
            binary=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_cip_image_ccm',f'-Ptb_cip_image_ccm.DW={width}',
                     '-o',binary,*sources],HERE,evidence/f'w{width}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',
                *[f'+{k}={counts[k]}' for k in ['commands','inputs','outputs','coeffs']]],
                HERE,evidence/f'w{width}_simulation.log')
            if f'CCM_ADAPTER PASS width={width}' not in output:raise RuntimeError('missing functional marker')
            print(output.strip());cases.append(counts)
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):
        raise RuntimeError('source changed during test')
    write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'board':'not_run'})
    print(f'evidence={evidence}')


if __name__=='__main__':
    main()
