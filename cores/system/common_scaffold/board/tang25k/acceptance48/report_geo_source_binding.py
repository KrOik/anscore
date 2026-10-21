"""Bind production hashes to each elaborated DUT closure; expose redundant differences."""
from pathlib import Path
import hashlib,json,re,sys,tempfile
HERE=Path(__file__).resolve().parent
PACKAGE=HERE.parents[2];ROOT=PACKAGE.parents[1]
sys.path.insert(0,str(PACKAGE/'integration'))
from tooling import execute
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
production={}
for line in (PACKAGE/'rtl_functional_sources.f').read_text().splitlines():
 if line.strip() and not line.startswith('#'):
  p=ROOT/line.strip();production[p.name]=p
report={}
for name in ['rotate_v7','affine_v4','perspective_v4']:
 folder=HERE/'geo_mapping_optimized'/name
 info=json.loads((folder/'case.json').read_text())
 with tempfile.TemporaryDirectory(prefix='a48_geo_closure_') as temporary:
  net=Path(temporary)/'elaborated.il'
  source_names=info['sources']
  command='read_verilog -sv -I. '+' '.join(source_names)+'; hierarchy -check -top acceptance48_top; write_rtlil '+net.as_posix()
  execute(['yosys','-Q','-T','-p',command],folder,folder/'source_binding_hierarchy.log',timeout=180)
  used=set();attributes=[]
  for line in net.read_text().splitlines():
   if line.startswith('attribute '):attributes.append(line)
   elif line.startswith('module '):
    for attr in attributes:
     match=re.match(r'attribute \\src "([^"\n]+)"',attr)
     if match:
      for source in match.group(1).split('|'):
       match_source=re.match(r'(source/[^:]+\.v):',source)
       if match_source:used.add(Path(match_source.group(1)).name)
    attributes=[]
   elif not line.startswith(' '):attributes=[]
 rows=[]
 for rel in source_names:
  frozen=folder/rel;current=production.get(frozen.name)
  if current is None:continue
  rows.append({'file':str(current.relative_to(ROOT)),'candidate':rel,
   'instantiated':frozen.name in used,'candidate_sha256':sha(frozen),'production_sha256':sha(current),
   'equal':frozen.read_bytes()==current.read_bytes()})
 active=[r for r in rows if r['instantiated']]
 redundant_differences=[r for r in rows if not r['instantiated'] and not r['equal']]
 report[name]={'active_dut_source_binding':'PASS' if all(r['equal'] for r in active) else 'FAIL',
  'elaborated_source_files':sorted(used),'active_dut_sources':active,
  'redundant_source_differences':redundant_differences,
  'note':'Elaboration closure is conservative and includes instantiated runtime modes. This does not replace full-current-source frozen build/board proof.'}
path=HERE/'geo_mapping_optimized/current_production_source_binding.json'
path.write_text(json.dumps(report,indent=2)+'\n')
for name,data in report.items():print(name,data['active_dut_source_binding'],'active',len(data['active_dut_sources']),'redundant_differences',len(data['redundant_source_differences']))
if any(d['active_dut_source_binding']!='PASS' for d in report.values()):raise RuntimeError('active DUT source mismatch')
