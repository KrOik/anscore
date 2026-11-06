"""SPDX-License-Identifier: Apache-2.0. Frozen finite source checks only."""
from pathlib import Path
import datetime,hashlib,importlib.util,json,os,shutil,subprocess,sys,time
ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2]
PROFILES=[(1,1),(8,8),(64,32)]
INPUTS=['rtl/itch_order_state.sv','reference_model.py','sim/tb_itch_order_state.sv','run_checks.py',
 'files.f','example/files.f','example/itch_receiver_state8.sv','sim/tb_itch_receiver_state8.sv',
 '../ram_hash_table/rtl/ram_hash_table.sv','../../communication/moldudp64_itch_rx/rtl/moldudp64_itch_rx.sv']
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
 if any((ROOT/'reports').glob('*/results.json')):
  print('Existing receipt: no automatic retry; retain and review it first.',file=sys.stderr);return 1
 stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
 out=ROOT/'reports'/stamp;out.mkdir(parents=True);archive=out/'executed_inputs';archive.mkdir()
 work=ROOT/'.work'/stamp;work.mkdir(parents=True)
 suite=REPO/'tools/oss-cad-suite/oss-cad-suite';suffix='.exe'if os.name=='nt'else''
 tools={n:suite/'bin'/(n+suffix)for n in['iverilog','vvp']}
 env=dict(os.environ);env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
 report=dict(schema='anscore-b36-finite-checks-v1',status='INCOMPLETE',checks=[],profiles=[],source_sha256={},archived_sources={},tools={},hard_seconds_per_child=20,
  synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',hardware='HW_UNVERIFIED')
 stopped=False
 def save():(out/'results.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())
 save()
 try:
  for name in INPUTS:
   source=(ROOT/name).resolve();target=archive/source.relative_to(REPO);target.parent.mkdir(parents=True,exist_ok=True)
   shutil.copyfile(source,target);report['source_sha256'][name]=digest(target);report['archived_sources'][name]=target.relative_to(ROOT).as_posix()
  for name,file in tools.items():report['tools'][name]=dict(path=str(file),sha256=digest(file))
  spec=importlib.util.spec_from_file_location('b36_oracle',ROOT/'reference_model.py');model=importlib.util.module_from_spec(spec);spec.loader.exec_module(model)
  for n,t in PROFILES:
   data,counts=model.vectors(n,t);label=f'n{n}_t{t}';file=out/(label+'.txt');file.write_bytes(data.encode('ascii'))
   report['profiles'].append(dict(label=label,orders=n,tag_w=t,counts=counts,vector=file.name,vector_sha256=digest(file)))
 except Exception as exc:report.update(status='NOT_RUN',preparation_error=repr(exc));save();return 1
 save()
 def run(name,args):
  nonlocal stopped
  if stopped:return False
  rec=dict(name=name,argv=list(map(str,args)),cwd=str(ROOT));start=time.monotonic();stdout=stderr=b''
  try:
   p=subprocess.Popen(rec['argv'],cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=os.name!='nt')
   try:
    stdout,stderr=p.communicate(timeout=20);rec.update(status='PASS'if p.returncode==0 else'FAIL',returncode=p.returncode)
   except subprocess.TimeoutExpired as exc:
    stdout,stderr=exc.stdout or b'',exc.stderr or b'';rec.update(status='TIMEOUT',returncode=None)
    try:
     if os.name=='nt':subprocess.run(['taskkill','/PID',str(p.pid),'/T','/F'],capture_output=True,timeout=5)
     else:
      import signal
      os.killpg(p.pid,signal.SIGKILL)
    except(OSError,subprocess.SubprocessError)as exc:stderr+=str(exc).encode()
    try:
     if p.poll()is None:p.kill()
     stdout,stderr=p.communicate(timeout=2)
    except(OSError,subprocess.SubprocessError)as exc:stderr+=str(exc).encode()
  except OSError as exc:rec.update(status='NOT_RUN',returncode=None);stderr=str(exc).encode()
  marker=b'PASS itch_receiver_state8'if name=='sim_example'else b'PASS itch_order_state'
  if name.startswith('sim_')and rec['status']=='PASS'and(marker not in stdout or b'$finish'not in stdout):rec['status']='FAIL_NO_MARKER'
  rec.update(seconds=round(time.monotonic()-start,4),stdout_sha256=hashlib.sha256(stdout).hexdigest(),stderr_sha256=hashlib.sha256(stderr).hexdigest())
  (out/(name+'.stdout.txt')).write_bytes(stdout);(out/(name+'.stderr.txt')).write_bytes(stderr)
  if '-o'in rec['argv']:
   image=Path(rec['argv'][rec['argv'].index('-o')+1])
   if image.is_file():rec.update(image=str(image.relative_to(ROOT)),image_sha256=digest(image))
  report['checks'].append(rec);save();print(name,rec['status'],flush=True)
  stopped=rec['status']!='PASS';return not stopped
 run('syntax_default',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','itch_order_state','-f','files.f'])
 run('syntax_limit',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','itch_order_state','-Pitch_order_state.ORDERS=64','-Pitch_order_state.TAG_W=32','-f','files.f'])
 run('syntax_example',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','itch_receiver_state8','-f','example/files.f'])
 for profile in report['profiles']:
  if stopped:break
  label=profile['label'];image=work/(label+'.vvp')
  if run('compile_'+label,[tools['iverilog'],'-g2012','-Wall','-s','tb_itch_order_state',f'-Ptb_itch_order_state.N={profile["orders"]}',f'-Ptb_itch_order_state.T={profile["tag_w"]}','-o',image,'-f','files.f','sim/tb_itch_order_state.sv']):run('sim_'+label,[tools['vvp'],image,'+vectors='+(out/profile['vector']).as_posix()])
 image=work/'example.vvp'
 if run('compile_example',[tools['iverilog'],'-g2012','-Wall','-s','tb_itch_receiver_state8','-o',image,'-f','example/files.f','sim/tb_itch_receiver_state8.sv']):run('sim_example',[tools['vvp'],image])
 expected=['syntax_default','syntax_limit','syntax_example']+[kind+p['label']for p in report['profiles']for kind in['compile_','sim_']]+['compile_example','sim_example']
 unchanged=all(digest(ROOT/name)==h for name,h in report['source_sha256'].items())
 ok=not stopped and unchanged and[c['name']for c in report['checks']]==expected
 report.update(sources_unchanged=unchanged,status='PASS'if ok else'INCOMPLETE')
 report['maturity']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']if ok else['RTL_CANDIDATE','HW_UNVERIFIED']
 save();print(out.relative_to(ROOT).as_posix(),flush=True);return 0 if ok else 1
if __name__=='__main__':sys.exit(main())
