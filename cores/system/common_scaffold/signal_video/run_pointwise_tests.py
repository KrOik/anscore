"""Functional pointwise adapter regression with automatically removed binaries/fixtures."""
from pathlib import Path
import hashlib
import sys
import tempfile

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json
from pointwise_reference import fixtures


def main():
    evidence=evidence_dir('pointwise_adapters')
    sources=[HERE/'rtl'/f'{name}.v' for name in ['cip_image_pointwise_frame_ctrl',
        'cip_rgb_brightness_contrast','cip_image_invert','cip_image_brightness_contrast','cip_image_color_convert','cip_image_awb']]
    sources.extend([HERE.parent/'image/geometry/rtl/img_geo_pixel_invert.v',
                    HERE.parent/'image/isp/img_isp_colorspace.v',HERE/'sim/tb_cip_image_pointwise.v'])
    sources.extend(HERE.parent/'image/isp'/f'{name}.v' for name in
        ['img_isp_awb_auto','img_isp_awb_stats','img_isp_awb_autogain','img_isp_awb_gain'])
    tracked=[*sources,Path(__file__),HERE/'pointwise_reference.py']
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    cases=[]
    with tempfile.TemporaryDirectory(prefix='cip_pointwise_') as temporary:
        for kind in [0,1,2,3]:
            for width in [1,8,16,24,32]:
                label=f'kind{kind}_width{width}';folder=Path(temporary)/label;folder.mkdir()
                counts=fixtures(folder,width,kind);binary=folder/'test.vvp'
                execute(['iverilog','-g2012','-s','tb_cip_image_pointwise',
                    f'-Ptb_cip_image_pointwise.DW={width}',f'-Ptb_cip_image_pointwise.KIND={kind}',
                    '-o',binary,*sources],HERE,evidence/f'{label}_compile.log')
                output=execute(['vvp',binary,f'+folder={folder}',
                    *[f'+{k}={counts[k]}' for k in ['commands','inputs','outputs']]],
                    HERE,evidence/f'{label}_simulation.log')
                if f'POINTWISE PASS kind={kind} width={width}' not in output:
                    raise RuntimeError('functional marker missing')
                print(output.strip());cases.append(counts)
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):
        raise RuntimeError('source changed during test')
    write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'board':'not_run'})
    print(f'evidence={evidence}')


if __name__=='__main__':
    main()
