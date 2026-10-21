"""Compile unchanged public reference tests against an isolated frozen case."""
from pathlib import Path
import hashlib, importlib, json, sys

HERE=Path(__file__).resolve().parent
COMMON=HERE.parents[2]
candidate=Path(sys.argv[1]).resolve()
runner_name=sys.argv[2]
sys.path.insert(0,str(COMMON/'signal_video'))
tests=importlib.import_module(runner_name)
original=tests.execute
output=candidate/('reference_'+runner_name)
output.mkdir(exist_ok=False)
def execute(command,cwd,log,**kwargs):
    command=[candidate/'source'/Path(str(p)).name
             if (candidate/'source'/Path(str(p)).name).is_file() else p for p in command]
    return original(command,cwd,output/Path(log).name,**kwargs)
tests.execute=execute
tests.evidence_dir=lambda label:output
tests.main()
(output/'actual_candidate_sources.json').write_text(json.dumps({
    'status':'PASS', 'runner':runner_name,
    'sources':{p.name:hashlib.sha256(p.read_bytes()).hexdigest()
               for p in (candidate/'source').glob('*.v')},
    'note':'Compile logs record source substitution; original oracle and TB unchanged.'
},indent=2)+'\n')
