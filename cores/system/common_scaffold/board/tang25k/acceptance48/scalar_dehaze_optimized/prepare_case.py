from pathlib import Path
import sys
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent))
import make_case as generate
original=generate.dependencies
def dependencies(name):
    return [HERE/p.name if p.name in ('cip_image_dehaze_scalar_frame.v','img_dh_transmission.v','img_dh_restore.v') else p for p in original(name)]
generate.dependencies=dependencies
generate.main()
