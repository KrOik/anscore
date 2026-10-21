import tempfile,json
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes
frozen=hashes();profiles=[]
for w,h in [(7,9),(16,16),(32,32)]:
 with tempfile.TemporaryDirectory(prefix='chamfer_synth_') as tmp:
  d=Path(tmp);(d/'run.ys').write_text('read_verilog -sv '+' '.join(p.as_posix() for p in SOURCES)+f'''
chparam -set WIDTH {w} -set HEIGHT {h} chamfer_match
synth_gowin -top chamfer_match -nodsp
check -assert
stat
''')
  result=execute(['yosys','-Q','-T','-s',d/'run.ys'],d,d/'yosys.log',timeout=300)
  row=dict(width=w,height=h,stat=result[result.rfind('=== chamfer_match ==='):].strip());profiles.append(row);print(row,flush=True)
assert frozen==hashes()
(HERE/'synthesis_result.json').write_text(json.dumps(dict(status='PASS',profiles=profiles,sources=frozen),indent=2)+'\n')
