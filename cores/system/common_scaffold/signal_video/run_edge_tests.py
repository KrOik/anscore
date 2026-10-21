"""Sobel/Prewitt/Laplacian display and lossless signed-word adapter regression."""
from pathlib import Path
import hashlib
import sys
import tempfile

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json
from edge_reference import fixtures


def main():
    evidence=evidence_dir('edge_adapters')
    sources=[HERE/'rtl'/f'{name}.v' for name in ['cip_image_sobel','cip_image_prewitt',
        'cip_image_laplacian','cip_image_window_filter_frame']]
    sources.extend([HERE.parent/'image/window/img_window3x3_valid_draft.v',HERE/'sim/tb_cip_image_edge.v'])
    sources.extend(HERE.parent/'image/filters/rtl'/f'{name}.v' for name in ['img_filter_kernel3x3',
        'img_filter_stream_register','img_filter_mean9_rom','img_filter_median_sort3_segment',
        'img_edge_gradient3x3','img_edge_laplacian3x3'])
    tracked=[*sources,Path(__file__),HERE/'edge_reference.py']
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    cases=[]
    with tempfile.TemporaryDirectory(prefix='cip_edges_') as temporary:
        for operation in [0,1,2]:
            for width,shift in [(w,s) for w in [1,8,16,24,32] for s in [0,2]]+[(8,12)]:
                label=f'op{operation}_w{width}_s{shift}';folder=Path(temporary)/label;folder.mkdir()
                counts=fixtures(folder,width,operation,shift);binary=folder/'test.vvp'
                execute(['iverilog','-g2012','-s','tb_cip_image_edge',f'-Ptb_cip_image_edge.DW={width}',
                    f'-Ptb_cip_image_edge.OP={operation}',f'-Ptb_cip_image_edge.SHIFT={shift}',
                    '-o',binary,*sources],HERE,evidence/f'{label}_compile.log')
                output=execute(['vvp',binary,f'+folder={folder}',
                    *[f'+{k}={counts[k]}' for k in ['commands','inputs','outputs']]],HERE,evidence/f'{label}_simulation.log')
                if f'EDGE_ADAPTER PASS width={width} operation={operation} shift={shift}' not in output:raise RuntimeError('missing functional marker')
                print(output.strip());cases.append(counts)
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):
        raise RuntimeError('source changed during test')
    write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'board':'not_run'})
    print(f'evidence={evidence}')


if __name__=='__main__':
    main()
