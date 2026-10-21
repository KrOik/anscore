"""Independent Pillow byte-stream JPEG decoder comparison (no RTL expectations generator)."""
from pathlib import Path
import sys,io,tempfile,json,hashlib
import numpy as np
from PIL import Image
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
RTL=HERE/'jpeg_gray_decoder.sv'
def hashes():return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (RTL,HERE/'idct_coeff.hex')}
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_last=0,m_ready=0,done_ready=0;
reg[7:0]s_data=0;wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy;
wire[7:0]m_data,error_code;wire[15:0]width,height;
jpeg_gray_decoder #(.MAX_SIDE(32),.MAX_BYTES(8192)) dut(.*);
reg[7:0]filebytes[0:NN-1];integer i,cyc=0,got=0,rep,fd;reg[10:0]held;reg stalled=0;
wire[10:0]token={m_last,m_eol,m_sof,m_data};
always @(negedge clk)begin cyc=cyc+1;ce=cyc%13>1;m_ready=cyc%7<4;if(cyc>4000000)$fatal(1,"timeout state=%d pos=%d k=%d",dut.state,dut.pos,dut.k);end
always @(posedge clk)if(rst_n)begin
 if(stalled&&(!m_valid||token!==held))$fatal(1,"output hold");
 stalled=m_valid&&!(ce&&m_ready);held=token;
 if(ce&&m_valid&&m_ready)begin
 if(m_sof!==(got%(WW*HH)==0)||m_eol!==((got%width)==width-1)||m_last!==(got%(WW*HH)==width*height-1))$fatal(1,"markers");
 $fdisplay(fd,"%d",m_data);got=got+1;end
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
 $fclose(fd);$display("PASS jpeg");$finish;end
endmodule
'''
def jpeg(a,quality,opt=False,**kw):
 b=io.BytesIO();Image.fromarray(a.astype('uint8'),'L').save(b,format='JPEG',quality=quality,optimize=opt,**kw);return b.getvalue()
def run_case(name,b,w,h,error=False,ideal=None):
 with tempfile.TemporaryDirectory(prefix='jpeg_gray_test_') as tmp:
  d=Path(tmp)
  payload=b
  base=TB
  if error:
   healthy=jpeg((np.arange(w*h).reshape(h,w)%256).astype('uint8'),81,opt=True)
   payload=b+healthy
   base=base.replace('filebytes[0:NN-1]',f'filebytes[0:{len(payload)-1}]').replace('rep<2','rep<3')
   base=base.replace('for(i=0;i<NN;i=i+1)begin s_data=filebytes[i];s_last=i==NN-1;',f'for(i=0;i<((rep==2)?{len(healthy)}:NN);i=i+1)begin s_data=filebytes[i+((rep==2)?NN:0)];s_last=i==((rep==2)?{len(healthy)}:NN)-1;')
   base=base.replace('(rep+1)*WW*HH','WW*HH').replace('if(done_error!==ERR)', 'if((rep<2)&&got!=0)$fatal(1,"error emitted pixels");if(done_error!==ERR)')
  (d/'input.hex').write_text('\n'.join(f'{v:02x}' for v in payload)+'\n')
  tb=base.replace('NN',str(len(b))).replace('WW',str(w)).replace('HH',str(h)).replace('ERR','(rep<2)' if error else '0').replace('INPUT',(d/'input.hex').as_posix()).replace('OUTPUT',(d/'output.txt').as_posix())
  (d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],HERE.parents[3],d/'compile.log')
  text=execute(['vvp',d/'a.vvp'],HERE.parents[3],d/'sim.log',timeout=180)
  assert 'PASS jpeg' in text,text
  actual=np.array([int(v) for v in (d/'output.txt').read_text().split()])
  row=dict(name=name,bytes=len(b),error_expected=error,simulation='PASS')
  if error:
   ref=np.asarray(Image.open(io.BytesIO(healthy))).ravel().astype(int)
   assert len(actual)==len(ref),(name,len(actual),len(ref))
   diff=np.abs(actual-ref);assert diff.max()<=2,(name,diff.max())
   row.update(healthy_recovery_pixels=len(ref),healthy_recovery_max_pillow_error=int(diff.max()))
  if not error:
   ref=np.asarray(Image.open(io.BytesIO(b))).ravel().astype(int)
   assert len(actual)==2*len(ref)
   dif=np.abs(actual-np.tile(ref,2));row.update(pixels=len(ref)*2,max_pillow_error=int(dif.max()),mean_pillow_error=float(dif.mean()))
   if ideal is None:assert dif.max()<=2,(name,dif.max(),actual[:64],ref[:64])
   else:
    delta=np.abs(actual-np.tile(np.asarray(ideal).ravel(),2));row['max_ideal_idct_error']=int(delta.max());assert delta.max()<=2,(name,delta.max())
  return row

def main():
 rng=np.random.default_rng(129);cases=[]
 patterns=[('constant',np.full((8,8),37),95),('gradient',np.arange(256).reshape(16,16),90),('random',rng.integers(0,256,(17,23)),75),('checker',np.indices((32,32)).sum(0)%2*255,100),('tiny',np.array([[0,255,30]]),20),('zero',np.zeros((8,8)),1)]
 for name,a,q in patterns:
  for opt in (False,True):
   b=jpeg(a,q,opt);row=run_case(name+('_opt' if opt else ''),b,a.shape[1],a.shape[0]);cases.append(row);print(row,flush=True)
 b=jpeg(rng.integers(0,256,(9,13)),80)
 errors=[('truncated',b[:-8]),('bad_soi',bytes([0])+b[1:]),('bad_eoi',b[:-1]+bytes([0])),('trailing',b+b'X'),('progressive',jpeg(np.zeros((8,8)),75,progressive=True)),('bad_quant',b.replace(bytes.fromhex('ffdb004300'),bytes.fromhex('ffdb004310'),1))]
 def patch(offset,value):return b[:offset]+bytes([value])+b[offset+1:]
 q=b.index(bytes.fromhex('ffdb'));h=b.index(bytes.fromhex('ffc4'));f=b.index(bytes.fromhex('ffc0'));z=b.index(bytes.fromhex('ffda'))
 errors += [('zero_quant',patch(q+5,0)),('bad_huffman_tree',patch(h+5,255)),('partial_quant',patch(q+3,66)),('partial_huffman',patch(h+3,18)),('bad_geometry',patch(f+6,0)),('multi_component',patch(f+9,3)),('bad_sampling',patch(f+11,0x22)),('bad_scan',patch(z+7,1)),('missing_table',patch(z+6,0x33)),('restart_unsupported',b[:2]+bytes.fromhex('ffdd00040001')+b[2:]),('capture_overflow',b'X'*8193),('empty_quant_after_tables',b[:z]+bytes.fromhex('ffdb0002')+b[z:]),('empty_huffman_after_tables',b[:z]+bytes.fromhex('ffc40002')+b[z:])]
 for name,data in errors:
  row=run_case(name,data,13,9,True);cases.append(row);print(row,flush=True)
 result=dict(status='PASS',sources=hashes(),reference='Pillow independent libjpeg decode',tolerance=2,cases=cases)
 (HERE/'evidence.json').write_text(json.dumps(result,indent=2)+'\n');print('PASS jpeg_gray_decoder',flush=True)
if __name__=='__main__':main()

