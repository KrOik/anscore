from pathlib import Path
import sys,importlib,json,hashlib
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[3]
sys.path.insert(0,str(COMMON/'signal_video'))
for name in ('run_edge_tests','run_window_filter_tests'):
    tests=importlib.import_module(name);original=tests.execute
    def execute(command,*args,**kwargs):
        command=[HERE/'cip_image_window_filter_frame.v' if Path(str(p)).name=='cip_image_window_filter_frame.v' else p for p in command]
        return original(command,*args,**kwargs)
    tests.execute=execute;tests.main()
(HERE/'window_counts_candidate_hash.json').write_text(json.dumps(dict(sha256=hashlib.sha256((HERE/'cip_image_window_filter_frame.v').read_bytes()).hexdigest()),indent=2)+'\n')
