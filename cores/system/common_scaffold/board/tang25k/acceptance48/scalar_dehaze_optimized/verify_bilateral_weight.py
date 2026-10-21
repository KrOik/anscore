from pathlib import Path
import sys
HERE=Path(__file__).resolve().parent
COMMON=HERE.parents[3]
sys.path.insert(0,str(COMMON/'signal_video'))
import run_bilateral_tests as tests
original=tests.execute
candidate=HERE/(sys.argv[1] if len(sys.argv)>1 else 'bilateral_weight_v3')/'source/img_filter_bilateral3x3.v'
def execute(command,*args,**kwargs):
    command=[candidate if Path(str(p)).name=='img_filter_bilateral3x3.v' else p for p in command]
    return original(command,*args,**kwargs)
tests.execute=execute
tests.main()
