from pathlib import Path
import sys,json,hashlib
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[3]
sys.path.insert(0,str(COMMON/'signal_video'))
import run_framebuffer_tests as tests
original=tests.execute
def execute(command,*args,**kwargs):
    command=[HERE/'cip_image_framebuffer.v' if Path(str(p)).name=='cip_image_framebuffer.v' else p for p in command]
    return original(command,*args,**kwargs)
tests.execute=execute
tests.main()
(HERE/'framebuffer_candidate_hash.json').write_text(json.dumps(dict(sha256=hashlib.sha256((HERE/'cip_image_framebuffer.v').read_bytes()).hexdigest()),indent=2)+'\n')
