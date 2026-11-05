"""SPDX-License-Identifier: Apache-2.0. Finite convolution composition checks."""
from pathlib import Path
import datetime,hashlib,json,os,random,shutil,subprocess,sys,time
ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
PROFILES=[(1,3,3,1),(3,7,6,8),(8,16,12,16)]
INPUTS=['rtl/int4_conv3x3_frame.sv','sim/tb_int4_conv3x3_frame.sv','run_checks.py',
 'files.f','example/files.f','example/quantized_feature_map.sv',
 '../../system/common_scaffold/image/window/img_window3x3_valid_draft.v',
 '../int4_weight_matvec/rtl/deps/stream_requantize.v','../int4_weight_matvec/rtl/int4_weight_matvec.sv']
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def vectors(mc,mw,mh,tw):
 rng=random.Random(340000+mc*mw*mh);weights={};metadata={};lines=[];counts=dict(frames=0,outputs=0,configs=0,live_resets=0)
 def cfg(op,row=0,word=0,data=0,bias=0,scale=1,shift=0,zero=0):
  error=0
  if op==0:
   if row>=mc or word>=2:error=1
   else:weights[row,word]=data
  elif op==1:
   if row>=mc:error=1
   else:metadata[row]=(bias,scale,shift,zero)
  elif op==2:weights.clear();metadata.clear()
  else:error=2
  lines.append(f'0 {op} {row} {word} {data} {bias} {scale} {shift} {zero} {error}\n');counts['configs']+=1
 def frame(w,h,ch,z=128,pixels=None,marker=None):
  tag=counts['frames']%(1<<tw)
  if not(3<=w<=mw and 3<=h<=mh and 1<=ch<=mc):error=1
  elif any(r not in metadata or any((r,k) not in weights for k in range(2))for r in range(ch)):error=2
  else:error=0
  if pixels is None:pixels=[]if error else[rng.randrange(256)for _ in range(w*h)]
  assert len(pixels)==(0 if error else w*h)
  marks=[(int(i==0),int(i%w==w-1),int(i==w*h-1))for i in range(len(pixels))]
  if marker is not None:
   index,field=marker;record=list(marks[index]);record[field]^=1;marks[index]=tuple(record);error=3
  outputs=[]
  if pixels:
   for oy in range(h-2):
    for ox in range(w-2):
     for r in range(ch):
      bias,scale,shift,zero=metadata[r];acc=bias
      for ky in range(3):
       for kx in range(3):
        index=ky*3+kx;weight=(weights[r,index//8]>>(4*(index%8)))&15
        if weight>=8:weight-=16
        acc+=(pixels[(oy+ky)*w+ox+kx]-z)*weight
      p=acc*scale;q,rem=divmod(p,1<<shift)
      q+=int(2*rem>1<<shift or(2*rem==1<<shift and q%2));value=q+zero
      outputs.append((max(-128,min(127,value)),ox,oy,r,int(oy==0 and ox==0 and r==0),
       int(ox==w-3 and r==ch-1),int(oy==h-3 and ox==w-3 and r==ch-1),int(not -128<=value<=127),int(rem!=0),tag))
  lines.append(f'1 {w} {h} {ch} {z} {tag} {len(pixels)} {len(outputs)} {error}\n')
  lines.extend(f'{v} {a} {b} {c}\n'for v,(a,b,c)in zip(pixels,marks))
  lines.extend(' '.join(map(str,row))+'\n'for row in outputs)
  counts['frames']+=1;counts['outputs']+=len(outputs)
 def setup():
  for r in range(mc):
   data=[(r*7+i*3+8)%16 for i in range(9)]
   cfg(0,r,0,sum(v<<(i*4)for i,v in enumerate(data[:8])))
   cfg(0,r,1,0xfedcba90|data[8])
   cfg(1,r,bias=r*29-7,scale=r+1,shift=3+r%4,zero=r-3)
 frame(2,3,1);frame(mw+1,3,1);frame(3,mh+1,1);frame(3,3,0);frame(3,3,mc+1);frame(65535,65535,65535)
 frame(3,3,1)
 cfg(0,65535);cfg(0,0,2);cfg(1,65535);cfg(3)
 cfg(1,0);cfg(0,0,0,0);frame(3,3,1) # Missing final packed word, before pixel admission.
 cfg(0,0,1,0);frame(3,3,1,0,[0,1,2,3,4,5,6,7,255])
 # Single center impulse provides a hand-transparent spatial ordering anchor.
 cfg(0,0,0,1<<16);cfg(1,0)
 frame(mw,mh,1,128,[(i*17+3)%256 for i in range(mw*mh)])
 setup();frame(mw,mh,mc,123)
 for w,h in sorted(set([(3,3),(min(mw,4),min(mh,5)),(min(mw,7),min(mh,6))])):
  frame(w,h,mc,255);frame(w,h,1,0)
 for mark in [(0,0),(2,1),(0,2),(8,2)]:frame(3,3,mc,marker=mark)
 for bias,scale,shift,zero in[(1,1,1,1),(-1,1,1,-1),(3,1,1,1),(-3,1,1,-1),(2**31-1,65535,0,-128),(-2**31,65535,31,127),(17,0,31,127)]:
  cfg(1,0,bias=bias,scale=scale,shift=shift,zero=zero);frame(3,3,1,91,[91]*9)
 cfg(2);frame(3,3,mc)
 for phase in range(4):
  setup();lines.append(f'3 {phase}\n');counts['live_resets']+=1
  weights.clear();metadata.clear();frame(3,3,mc)
 setup();frame(3,3,mc)
 return ''.join(lines),counts

def main():
 stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
 out=ROOT/'reports'/stamp;out.mkdir(parents=True);archive=out/'executed_inputs';archive.mkdir()
 work=ROOT/'.work'/stamp;work.mkdir(parents=True)
 suite=REPO/'tools/oss-cad-suite/oss-cad-suite';suffix='.exe'if os.name=='nt'else''
 tools={n:suite/'bin'/(n+suffix)for n in['iverilog','vvp']}
 env=dict(os.environ);env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
 report=dict(schema='anscore-b34-finite-checks-v1',status='INCOMPLETE',checks=[],profiles=[],source_sha256={},archived_sources={},tools={},hard_seconds_per_child=20,
  synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',hardware='HW_UNVERIFIED')
 stopped=False
 def save():(out/'results.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())
 save()
 try:
  for name in INPUTS:
   file=(ROOT/name).resolve();target=archive/file.relative_to(REPO);target.parent.mkdir(parents=True,exist_ok=True)
   shutil.copyfile(file,target);report['source_sha256'][name]=digest(target);report['archived_sources'][name]=target.relative_to(ROOT).as_posix()
  for name,file in tools.items():report['tools'][name]=dict(path=str(file),sha256=digest(file))
  for mc,mw,mh,t in PROFILES:
   data,counts=vectors(mc,mw,mh,t);label=f'c{mc}_w{mw}_h{mh}_t{t}'
   file=out/(label+'.txt');file.write_bytes(data.encode('ascii'))
   report['profiles'].append(dict(label=label,channels=mc,width=mw,height=mh,tag_w=t,counts=counts,vector=file.name,vector_sha256=digest(file)))
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
  if name.startswith('sim_')and rec['status']=='PASS'and(b'PASS int4_conv3x3_frame'not in stdout or b'$finish'not in stdout):rec['status']='FAIL_NO_MARKER'
  rec.update(seconds=round(time.monotonic()-start,4),stdout_sha256=hashlib.sha256(stdout).hexdigest(),stderr_sha256=hashlib.sha256(stderr).hexdigest())
  (out/(name+'.stdout.txt')).write_bytes(stdout);(out/(name+'.stderr.txt')).write_bytes(stderr)
  if '-o'in rec['argv']:
   image=Path(rec['argv'][rec['argv'].index('-o')+1])
   if image.is_file():rec.update(image=str(image.relative_to(ROOT)),image_sha256=digest(image))
  report['checks'].append(rec);save();print(name,rec['status'],flush=True)
  stopped=rec['status']!='PASS';return not stopped
 run('syntax_default',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','int4_conv3x3_frame','-f','files.f'])
 run('syntax_limit',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','int4_conv3x3_frame','-Pint4_conv3x3_frame.MAX_CHANNELS=64','-Pint4_conv3x3_frame.MAX_WIDTH=1024','-Pint4_conv3x3_frame.MAX_HEIGHT=1024','-f','files.f'])
 run('syntax_example',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','quantized_feature_map','-f','example/files.f'])
 for p in report['profiles']:
  if stopped:break
  label=p['label'];image=work/(label+'.vvp')
  if run('compile_'+label,[tools['iverilog'],'-g2012','-Wall','-s','tb_int4_conv3x3_frame',f'-Ptb_int4_conv3x3_frame.MC={p["channels"]}',f'-Ptb_int4_conv3x3_frame.MW={p["width"]}',f'-Ptb_int4_conv3x3_frame.MH={p["height"]}',f'-Ptb_int4_conv3x3_frame.T={p["tag_w"]}','-o',image,'-f','files.f','sim/tb_int4_conv3x3_frame.sv']):run('sim_'+label,[tools['vvp'],image,'+vectors='+(out/p['vector']).as_posix()])
 expected=['syntax_default','syntax_limit','syntax_example']+[kind+p['label']for p in report['profiles']for kind in['compile_','sim_']]
 unchanged=all(digest(ROOT/p)==h for p,h in report['source_sha256'].items())
 ok=not stopped and unchanged and[c['name']for c in report['checks']]==expected
 report.update(sources_unchanged=unchanged,status='PASS'if ok else'INCOMPLETE')
 report['maturity']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']if ok else['RTL_CANDIDATE','HW_UNVERIFIED']
 save();print(out.relative_to(ROOT).as_posix(),flush=True);return 0 if ok else 1
if __name__=='__main__':sys.exit(main())
