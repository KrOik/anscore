from test_frame import *
from tooling import tool_env
import subprocess,shutil

def main():
 results=[]
 with tempfile.TemporaryDirectory(prefix='jpeg_boundaries_') as tmp:
  p=Path(tmp)
  for w,h in [(256,1),(1,256),(256,64)]:
   pixels=[(x*7+y*3)%256 for y in range(h) for x in range(w)]*2
   (p/'pixels.hex').write_text(''.join(f'{x:02x}\n' for x in pixels))
   (p/'tb.sv').write_text(TB.replace('WW',str(w)).replace('HH',str(h)).replace('RI','7'))
   label=f'boundary_{w}_{h}'
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,HERE/'jpeg_gray_encoder.sv',p/'tb.sv'],p,HERE/f'{label}_compile.log')
   out=execute(['vvp',p/'sim'],p,HERE/f'{label}_simulation.log',timeout=240);assert 'GRAY_FRAME PASS' in out
   _,tables=header_and_tables([128]*64)
   for f in range(2):
    data=bytes(int(x,16) for x in (p/f'frame{f}.hex').read_text().split());im=Image.open(io.BytesIO(data));im.load();assert im.size==(w,h)
    assert entropy_from_file(data)==expected_entropy(pixels[:w*h],w,h,7,tables)
    results.append(dict(width=w,height=h,frame=f,status='PASS'))
  for w,h in [(0,8),(8,0),(257,1),(1,257),(256,65)]:
   (p/'tb.sv').write_text(TB.replace('WW',str(w)).replace('HH',str(h)).replace('RI','0'))
   label=f'invalid_{w}_{h}'
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,HERE/'jpeg_gray_encoder.sv',p/'tb.sv'],p,HERE/f'{label}_compile.log')
   run=subprocess.run([shutil.which('vvp',path=tool_env()['PATH']),str(p/'sim')],cwd=p,env=tool_env(),capture_output=True,timeout=30)
   text=run.stdout.decode(errors='replace')+run.stderr.decode(errors='replace');(HERE/f'{label}_simulation.log').write_text(text)
   assert run.returncode and 'invalid grayscale JPEG geometry' in text
   results.append(dict(width=w,height=h,status='PASS_EXPECTED_REJECT'))
 (HERE/'boundary_result.json').write_text(json.dumps(dict(status='PASS',profiles=results),indent=2));print('PASS',len(results),'boundary cases')
if __name__=='__main__':main()
