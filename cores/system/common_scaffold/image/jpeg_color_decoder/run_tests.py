"""Actual Pillow JPEG byte streams -> RTL RGB, independent entropy+IDCT oracle."""
from pathlib import Path
import sys,io,tempfile,json,hashlib
import numpy as np
from PIL import Image
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
from oracle import decode
RTL=HERE/'jpeg_color_decoder.sv'
def hashes():return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (RTL,HERE/'idct_coeff.hex')}
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_last=0,m_ready=0,done_ready=0;
reg[7:0]s_data=0;wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy;
wire[23:0]m_data;wire[7:0]error_code;wire[15:0]width,height;
jpeg_color_decoder #(.MAX_SIDE(32),.MAX_BYTES(8192)) dut(.*);
reg[7:0]filebytes[0:NN-1];integer i,cyc=0,got=0,rep,fd;reg[26:0]held;reg stalled=0;
wire[26:0]token={m_last,m_eol,m_sof,m_data};
always @(negedge clk)begin cyc=cyc+1;ce=cyc%13>1;m_ready=cyc%7<4;if(cyc>5000000)$fatal(1,"timeout state=%d pos=%d comp=%d block=%d",dut.state,dut.pos,dut.comp_idx,dut.block_idx);end
always @(posedge clk)if(rst_n)begin
 if(stalled&&(!m_valid||token!==held))$fatal(1,"output hold");
 stalled=m_valid&&!(ce&&m_ready);held=token;
 if(ce&&m_valid&&m_ready)begin
 if(m_sof!==(got%(WW*HH)==0)||m_eol!==((got%width)==width-1)||m_last!==(got%(WW*HH)==width*height-1))$fatal(1,"markers");
 $fdisplay(fd,"%h",m_data);got=got+1;end
end
 task tick;begin @(negedge clk);#1;end endtask
 initial begin $readmemh("INPUT",filebytes);fd=$fopen("OUTPUT","w");
 repeat(3)tick;rst_n=1;tick;
 for(rep=0;rep<2;rep=rep+1)begin
 start_valid=1;while(!start_ready)tick;@(posedge clk);#1;tick;start_valid=0;
 for(i=0;i<NN;i=i+1)begin s_data=filebytes[i];s_last=i==NN-1;s_valid=1;while(!s_ready&&!done_valid)tick;if(done_valid)i=NN;else begin @(posedge clk);#1;tick;end end
 s_valid=0;s_last=0;
 while(!done_valid)tick;
 if(done_error!==ERR)$fatal(1,"done error %h got %d expected ERR pos=%d",error_code,done_error,dut.pos);
 if(!ERR&&(got!=(rep+1)*WW*HH||width!=WW||height!=HH))$fatal(1,"geometry/count %d",got);
 repeat(7)tick;if(!done_valid||done_error!==ERR)$fatal(1,"done hold");
 done_ready=1;while(!ce)tick;@(posedge clk);#1;tick;done_ready=0;
 end
 $fclose(fd);$display("PASS jpeg_color");$finish;end
endmodule
'''
def jpeg(a,quality=85,opt=False,sampling=2,**kw):
 b=io.BytesIO();Image.fromarray(a.astype('uint8'),'RGB').save(b,format='JPEG',quality=quality,optimize=opt,subsampling=sampling,**kw);return b.getvalue()
def run_case(name,b,w,h,error=False,pillow_limit=6):
 with tempfile.TemporaryDirectory(prefix='jpeg_color_test_') as tmp:
  d=Path(tmp);payload=b;base=TB
  if error:
   healthy=jpeg(np.tile(np.arange(w*h).reshape(h,w,1)%256,(1,1,3)),81,True,2);payload=b+healthy
   base=base.replace('filebytes[0:NN-1]',f'filebytes[0:{len(payload)-1}]').replace('rep<2','rep<3')
   base=base.replace('for(i=0;i<NN;i=i+1)begin s_data=filebytes[i];s_last=i==NN-1;',f'for(i=0;i<((rep==2)?{len(healthy)}:NN);i=i+1)begin s_data=filebytes[i+((rep==2)?NN:0)];s_last=i==((rep==2)?{len(healthy)}:NN)-1;')
   base=base.replace('(rep+1)*WW*HH','WW*HH').replace('if(done_error!==ERR)', 'if((rep<2)&&got!=0)$fatal(1,"error emitted pixels");if(done_error!==ERR)')
  (d/'input.hex').write_text('\n'.join(f'{v:02x}' for v in payload)+'\n')
  tb=base.replace('NN',str(len(b))).replace('WW',str(w)).replace('HH',str(h)).replace('ERR','(rep<2)' if error else '0').replace('INPUT',(d/'input.hex').as_posix()).replace('OUTPUT',(d/'output.txt').as_posix())
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],HERE.parents[3],d/'compile.log')
  text=execute(['vvp',d/'a.vvp'],HERE.parents[3],d/'sim.log',timeout=240);assert 'PASS jpeg_color' in text
  packed=np.array([int(v,16) for v in (d/'output.txt').read_text().split()],dtype=np.uint32)
  actual=np.stack([(packed>>16)&255,(packed>>8)&255,packed&255],axis=-1).astype(int)
  row=dict(name=name,bytes=len(b),error_expected=error,simulation='PASS')
  use=healthy if error else b;ref,meta=decode(use);ref=ref.reshape(-1,3);reps=1 if error else 2
  assert len(actual)==reps*len(ref),(name,len(actual),reps*len(ref))
  delta=np.abs(actual-np.tile(ref,(reps,1)));row.update(pixels=len(actual),max_independent_error=int(delta.max()),independent_mae=float(delta.mean()),sampling=meta['sampling']);assert delta.max()<=5,(name,delta.max(),actual[:5],ref[:5])
  pillow=np.asarray(Image.open(io.BytesIO(use))).reshape(-1,3).astype(int);pd=np.abs(actual-np.tile(pillow,(reps,1)))
  row.update(max_pillow_error=int(pd.max()),p95_pillow_error=float(np.percentile(pd,95)),pillow_mae=float(pd.mean()))
  if pillow_limit is not None:assert pd.max()<=pillow_limit,(name,pd.max(),row)
  return row

def main():
 rng=np.random.default_rng(871);rows=[]
 patterns=[('solid',np.tile(np.array([210,35,90]),(8,8,1)),93,False),('gradient',np.stack([np.tile(np.arange(17)*15,(9,1)),np.tile((np.arange(9)*28)[:,None],(1,17)),np.full((9,17),87)],axis=-1),87,False),('random',rng.integers(0,256,(13,19,3)),75,True),('tiny',rng.integers(0,256,(3,5,3)),20,True)]
 for sampling in range(3):
  for name,a,q,opt in patterns:
   row=run_case(f'{name}_s{sampling}',jpeg(a,q,opt,sampling),a.shape[1],a.shape[0]);rows.append(row);print(row,flush=True)
 a=np.stack([np.indices((32,32)).sum(0)%2*255,np.tile(np.arange(32)*8,(32,1)),np.tile((np.arange(32)*8)[:,None],(1,32))],axis=-1)
 row=run_case('multi_mcu_32_q100',jpeg(a,100,True,2),32,32);rows.append(row);print(row,flush=True)
 b=jpeg(rng.integers(0,256,(9,13,3)),80,False,2);f=b.index(bytes.fromhex('ffc0'));s=b.index(bytes.fromhex('ffda'));q=b.index(bytes.fromhex('ffdb'));ht=b.index(bytes.fromhex('ffc4'))
 def patch(i,v):return b[:i]+bytes([v])+b[i+1:]
 for name,extra in [('dri_zero',bytes.fromhex('ffdd00040000')),('adobe_ycbcr',bytes.fromhex('ffee000e41646f626500640000000001'))]:
  row=run_case(name,b[:2]+extra+b[2:],13,9);rows.append(row);print(row,flush=True)
 errors=[('truncated',b[:-8]),('bad_soi',b'X'+b[1:]),('bad_eoi',b[:-1]+b'X'),('trailing',b+b'X'),('progressive',jpeg(np.zeros((8,8,3)),75,False,2,progressive=True)),('unsupported_sampling',patch(f+11,0x12)),('bad_component_id',patch(f+10,7)),('bad_scan_order',patch(s+5,2)),('missing_chroma_table',patch(s+8,0x33)),('zero_quant',patch(q+5,0)),('bad_huffman',patch(ht+5,255)),('restart',b[:2]+bytes.fromhex('ffdd00040001')+b[2:]),('empty_quant',b[:s]+bytes.fromhex('ffdb0002')+b[s:]),('empty_huffman',b[:s]+bytes.fromhex('ffc40002')+b[s:]),('overflow',b'X'*8193),('bad_dri_length',b[:2]+bytes.fromhex('ffdd000300')+b[2:]),('adobe_rgb_unsupported',b[:2]+bytes.fromhex('ffee000e41646f626500640000000000')+b[2:]),('adobe_truncated',b[:2]+bytes.fromhex('ffee000741646f6265')+b[2:])]
 for name,data in errors:
  row=run_case(name,data,13,9,True);rows.append(row);print(row,flush=True)
 (HERE/'evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),cases=rows,independent_oracle='independent entropy parser + float orthonormal IDCT + centered bilinear + float RGB',independent_tolerance=5,pillow_tolerance=6),indent=2)+'\n');print('PASS jpeg_color_decoder')
if __name__=='__main__':main()
