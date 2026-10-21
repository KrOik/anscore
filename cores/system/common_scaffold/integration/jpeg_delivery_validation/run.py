"""Replay unchanged formal-API JPEG tests against an explicit versioned RTL map.
No baseline RTL or owner tests are edited. JSON map: package-relative RTL name
-> absolute versioned source path. All ten independent RELATIVE keys required.
"""
import argparse,datetime,hashlib,importlib.util,json,pathlib,sys,traceback
HERE=pathlib.Path(__file__).resolve().parent
PACKAGE=HERE.parents[1]
INTEGRATION=PACKAGE/'integration'
sys.path.insert(0,str(INTEGRATION))
import tooling

def sha(p): return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
def load(name,path):
 spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);sys.modules[name]=m;spec.loader.exec_module(m);return m

def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--sources',required=True,type=pathlib.Path);ap.add_argument('--output',required=True,type=pathlib.Path);ap.add_argument('--audit-only',action='store_true');a=ap.parse_args()
 out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
 inputs={};rows=[]
 def track(p):p=pathlib.Path(p).resolve();inputs[str(p)]=sha(p);return p
 track(__file__);track(a.sources)
 for p in INTEGRATION.glob('*.py'):track(p)
 owner=PACKAGE/'image/jpeg_gray_encoder'
 for p in owner.glob('test_*.py'):track(p)
 mapping=json.loads(a.sources.read_text(encoding='utf-8'))
 if 'files' in mapping:
  converted={}
  for row in mapping['files']:
   key=row['original'].replace('\\','/').removeprefix('cores/system/common_scaffold/')
   path=(a.sources.resolve().parent/row['delivery']).resolve()
   assert sha(path)==row['delivery_sha256'],'delivery manifest SHA mismatch'
   assert key not in converted,'duplicate delivery original'
   converted[key]=str(path)
  mapping=converted
 independent=load('jpeg_delivery_independent',INTEGRATION/'test_jpeg_gray_top_independent.py')
 assert set(mapping)==set(independent.RELATIVE),'exact production API RTL map required'
 mapping={n:track(pathlib.Path(p)) for n,p in mapping.items()}
 for n,p in mapping.items():
  assert p.is_absolute() and p.is_file()
  if n.endswith('jpeg_gray_encoder.sv'): assert 'module jpeg_gray_encoder' in p.read_text(encoding='utf-8')
 # Redirect owner HERE (outputs and wrapper RTL only) without changing scripts or TB.
 work=out/'owner';work.mkdir();top=mapping['image/jpeg_gray_encoder/jpeg_gray_encoder.sv']
 (work/'jpeg_gray_encoder.sv').write_bytes(top.read_bytes())
 frame=load('test_frame',owner/'test_frame.py');frame.HERE=work
 frame.SOURCES=[mapping[n] for n in independent.RELATIVE if not n.endswith('/jpeg_gray_encoder.sv')]
 tasks=[('test_frame',frame)]
 for name in ('test_errors','test_configuration','test_boundaries'):
  m=load(name,owner/(name+'.py'));m.HERE=work;m.SOURCES=frame.SOURCES;tasks.append((name,m))
 # Existing independent checker uses the same exact ten sources; redirect only
 # package lookup through a minimal path adapter, preserving TB/oracles/bounds.
 class Bundle:
  def __truediv__(self,name):return mapping[name]
 independent.PACKAGE=Bundle()
 independent.evidence_dir=lambda label:out/'independent'
 (out/'independent').mkdir()
 tasks.append(('independent_pillow_six_frames',independent))
 compile_inputs=[]
 # Imported entropy/header helpers are Python-only oracles. Their module main
 # functions are never invoked. Guard every executed HDL compile nonetheless.
 expected={str(p.resolve()) for p in mapping.values()}
 expected.remove(str(top.resolve()));expected.add(str((work/'jpeg_gray_encoder.sv').resolve()))
 def guarded_execute(argv,cwd,log,timeout=120):
  if str(argv[0])=='iverilog':
   rtl={str(pathlib.Path(p).resolve()) for p in argv[1:] if str(p).endswith(('.v','.sv')) and pathlib.Path(p).name!='tb.sv'}
   assert rtl in (expected,{str(p.resolve()) for p in mapping.values()}),'compile escaped frozen ten-source bundle'
   assert sha(work/'jpeg_gray_encoder.sv')==sha(top),'copied production top changed'
   compile_inputs.append(dict(log=str(log),rtl={p:sha(p) for p in sorted(rtl)}))
  return tooling.execute(argv,cwd,log,timeout=timeout)
 for _,m in tasks:m.execute=guarded_execute
 audit={name:dict(module_file=str(pathlib.Path(m.__file__).resolve()),sources=[str(p) for p in m.SOURCES] if hasattr(m,'SOURCES') else [str(mapping[n]) for n in m.RELATIVE]) for name,m in tasks}
 assert all(m.SOURCES==frame.SOURCES for _,m in tasks[:-1])
 (out/'dependency_audit.json').write_text(json.dumps(dict(status='STATIC_INPUT_AUDIT_PASS',tasks=audit,production_top_copy_sha256=sha(work/'jpeg_gray_encoder.sv'),note='Owner uses nine SOURCES plus exact copied tenth top; independent uses all ten mapped sources. Golden/oracle functions are unchanged.'),indent=2)+'\n',encoding='utf-8')
 if a.audit_only:return
 original_stdout=sys.stdout;original_stderr=sys.stderr
 try:
  for name,m in tasks:
   with (out/(name+'.log')).open('w',encoding='utf-8') as log:
    sys.stdout=sys.stderr=log
    try:m.main();rows.append(dict(test=name,status='PASS'))
    except Exception as exc:traceback.print_exc();rows.append(dict(test=name,status='FAIL',error=str(exc)))
    finally:sys.stdout=original_stdout;sys.stderr=original_stderr
   print(name,rows[-1]['status'],flush=True)
 finally:
  stable=all(sha(p)==v for p,v in inputs.items())
  result=dict(status='PASS' if stable and len(rows)==5 and all(r['status']=='PASS' for r in rows) else 'FAIL',source_map={n:dict(path=str(p),sha256=sha(p)) for n,p in mapping.items()},inputs=inputs,input_stability='PASS' if stable else 'FAIL',tests=rows,compile_inputs=compile_inputs,scope='Unchanged owner testbench/API and independent Pillow six-frame regression; no board/timing claim',logs={str(p.relative_to(out)):sha(p) for p in out.rglob('*.log')})
  (out/'results.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
 if result['status']!='PASS':raise SystemExit(1)
if __name__=='__main__':main()
