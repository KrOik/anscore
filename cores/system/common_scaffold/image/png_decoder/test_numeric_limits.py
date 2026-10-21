"""Full RGB row width, exact compressed capacity, advertised window and static limits."""
from run_tests import H,RTL,ROOT,TB,execute,encode,run_case,chunk
from test_errors import unpack,repack
from test_deflate_limits import fixed_window
from pathlib import Path
import numpy as np,tempfile,re,json,hashlib,zlib

def reject(name,data,error,mw=256,mh=256,mc=8192):
 tb=TB.replace('ok=ce&&s_ready;','ok=ce&&s_ready||done_valid;').replace('send;end s_valid=0;', 'send;if(done_valid)i=NB;end s_valid=0;')
 tb=tb.replace('if(got>=NP||m_rgb!==expectation[got])','if(0)').replace('if(m_sof!==(got==0)||m_eol!==(got%WW==WW-1)||m_last!==(got==NP-1))','if(0)')
 tb=tb.replace('if(frame_error||error_code!=0||got!=NP||image_width!=WW||image_height!=HH)',f'if(!frame_error||error_code!={error})').replace('PASS PNG','PASS reject')
 for token,value in [('MW',mw),('MH',mh),('MC',mc),('WW',1),('HH',1),('NB',len(data)),('NP',1)]:tb=re.sub(r'\b'+token+r'\b',str(value),tb)
 with tempfile.TemporaryDirectory(prefix='png_boundary_error_') as td:
  d=Path(td)
  for token,values in [('SRC',data),('EXP',[0])]:
   p=d/(token+'.hex');p.write_text('\n'.join(f'{v:x}' for v in values)+'\n');tb=tb.replace('"'+token+'"','"'+p.as_posix()+'"')
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',str(d/'a.vvp'),str(RTL),str(d/'tb.sv')],ROOT,H/(name+'_compile.log'));text=execute(['vvp',str(d/'a.vvp')],ROOT,H/(name+'_simulation.log'),timeout=180);assert 'PASS reject' in text
 return {'name':name,'error':error}
def main():
 rng=np.random.default_rng(85);rows=[];errors=[]
 for shape,bpp,mc in [((1,256),3,4096),((256,1),1,4096),((19,214),1,4096),((81,100),1,8192)]:
  a=rng.integers(0,256,(*shape,bpp),dtype=np.uint8);data,expected,meta=encode(a,'stored',(0,1,2,3,4))
  row=run_case(f'limit_{shape[0]}x{shape[1]}_{bpp}_{mc}',data,expected,mw=256,mh=256,mc=mc);row.update(meta);rows.append(row)
  if shape in ((19,214),(81,100)):assert meta['compressed_bytes']==mc;row['exact_capacity']=mc
 # RGB optional PLTE and unknown ancillary are CRC-checked and safely ignored.
 a=rng.integers(0,256,(3,5,3),dtype=np.uint8);data,expected,_=encode(a,'fixed',(4,));parts=unpack(data)
 data=repack([parts[0],(b'PLTE',bytes([0,0,0,255,255,255])),(b'tEXt',b'author\0fixture'),*parts[1:]])
 rows.append(run_case('RGB_PLTE_ancillary',data,expected))
 # Next valid zlib stored stream exceeds the configured capacity by11 bytes.
 a=np.zeros((32,255,1),dtype=np.uint8);data,_,meta=encode(a,'stored');assert meta['compressed_bytes']==8203
 errors.append(reject('capacity_overflow',data,0x14))
 data,_=fixed_window();parts=unpack(data);packed=bytearray(parts[1][1]);packed[0]=8;packed[1]=next(f for f in range(32) if (0x800+f)%31==0)
 errors.append(reject('CINFO_window256_distance32768',repack([parts[0],(b'IDAT',packed),parts[-1]]),0x29))
 rejects=[]
 for params in ({'MAX_WIDTH':0},{'MAX_HEIGHT':257},{'MAX_COMPRESSED_BYTES':15},{'MAX_COMPRESSED_BYTES':8193}):
  with tempfile.TemporaryDirectory(prefix='png_parameter_') as td:
   d=Path(td);(d/'tb.sv').write_text('module tb;png_decoder #('+','.join('.%s(%d)'%(k,v) for k,v in params.items())+')dut();initial #2 $finish;endmodule')
   execute(['iverilog','-g2012','-s','tb','-o',str(d/'a.vvp'),str(RTL),str(d/'tb.sv')],ROOT,H/'parameter_compile.log')
   try:execute(['vvp',str(d/'a.vvp')],ROOT,H/'parameter_last_rejection.log');raise AssertionError('invalid parameters accepted')
   except RuntimeError:rejects.append(params)
 (H/'numeric_evidence.json').write_text(json.dumps({'result':'PASS','rtl_sha256':hashlib.sha256(RTL.read_bytes()).hexdigest(),'cases':rows,'malformed':errors,'invalid_static_parameters':rejects},indent=2)+'\n');print('PASS PNG numeric limits')
if __name__=='__main__':main()
