from pathlib import Path
import sys
HERE=Path(__file__).resolve().parent
COMMON=HERE.parents[3]
sys.path.insert(0,str(COMMON/'signal_video'))
import run_background_tests as tests
original=tests.execute
def execute(command,*args,**kwargs):
    command=[HERE/'cip_image_background_model.v' if Path(str(p)).name=='cip_image_background_model.v' else p for p in command]
    return original(command,*args,**kwargs)
tests.execute=execute
tests.main()
