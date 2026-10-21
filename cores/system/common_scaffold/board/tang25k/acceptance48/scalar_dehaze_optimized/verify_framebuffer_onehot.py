from pathlib import Path
import sys
HERE=Path(__file__).resolve().parent
COMMON=HERE.parents[3]
sys.path.insert(0,str(COMMON/'signal_video'))
import run_framebuffer_tests as tests
original=tests.execute
candidate=HERE/(sys.argv[1] if len(sys.argv)>1 else 'framebuffer_onehot_v6')/'source/cip_image_framebuffer.v'
def execute(command,*args,**kwargs):
    command=[candidate if Path(str(p)).name=='cip_image_framebuffer.v' else p for p in command]
    return original(command,*args,**kwargs)
tests.execute=execute
tests.main()
