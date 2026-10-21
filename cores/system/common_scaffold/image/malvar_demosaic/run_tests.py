"""Independent 2D mathematical MHC kernels and REFLECT101 reference."""
from pathlib import Path
import hashlib,json,tempfile,sys,re
import numpy as np
from scipy.ndimage import convolve
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
RTL=HERE/'malvar_demosaic.sv'
PATTERNS=['RGGB','GRBG','GBRG','BGGR']
G=np.array([[0,0,-2,0,0],[0,0,4,0,0],[-2,4,8,4,-2],[0,0,4,0,0],[0,0,-2,0,0]],dtype=np.int64)
H=np.array([[0,0,1,0,0],[0,-2,0,-2,0],[-2,8,10,8,-2],[0,-2,0,-2,0],[0,0,1,0,0]],dtype=np.int64)
C=np.array([[0,0,-3,0,0],[0,4,0,4,0],[-3,0,12,0,-3],[0,4,0,4,0],[0,0,-3,0,0]],dtype=np.int64)
def hashes():return {RTL.name:hashlib.sha256(RTL.read_bytes()).hexdigest()}
def masks(shape,pattern):
 tile=np.array(list(pattern)).reshape(2,2);y,x=np.indices(shape);return tuple(tile[y%2,x%2]==c for c in 'RGB')
def oracle(cfa,pattern,bits):
 cfa=np.asarray(cfa,dtype=np.int64);r,g,b=masks(cfa.shape,PATTERNS[pattern]);R=np.zeros_like(cfa);B=np.zeros_like(cfa);Gg=np.where(g,cfa,convolve(cfa,G,mode='mirror')//16)
 # Keep exact signed numerator through quantization; tie behavior is explicit.
 kg=convolve(cfa,G,mode='mirror');kh=convolve(cfa,H,mode='mirror');kv=convolve(cfa,H.T,mode='mirror');kc=convolve(cfa,C,mode='mirror')
 y,x=np.indices(cfa.shape);redrow=(y%2)==(pattern//2)
 R=np.where(r,cfa*16,np.where(b,kc,np.where(redrow,kh,kv)))
 B=np.where(b,cfa*16,np.where(r,kc,np.where(redrow,kv,kh)))
 Gn=np.where(g,cfa*16,kg)
 return np.clip((np.stack([R,Gn,B],axis=-1)+8)//16,0,(1<<bits)-1).astype(np.int64)
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
reg[1:0]cfg_pattern=PP;reg[B-1:0]s_data=0;wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy;
wire[3*B-1:0]m_data;wire[7:0]error_code;
malvar_demosaic #(.WIDTH(WW),.HEIGHT(HH),.BITS(B)) dut(.*);
reg[B-1:0]pixels[0:NN-1];reg[3*B-1:0]expected[0:NN-1];integer cyc=0,i,rep,got=0;reg[3*B+2:0]held;reg stalled=0;
wire[3*B+2:0]token={m_last,m_eol,m_sof,m_data};
always @(negedge clk)begin cyc=cyc+1;ce=cyc%13>1;m_ready=cyc%7<4;if(cyc>1000000)$fatal(1,"timeout %d",dut.state);end
always @(posedge clk)if(rst_n)begin
 if(!abort&&stalled&&(!m_valid||token!==held))$fatal(1,"hold");stalled=!abort&&m_valid&&!(ce&&m_ready);held=token;
 if(ce&&m_valid&&m_ready)begin if(got>=2*NN||m_data!==expected[got%NN])$fatal(1,"pixel %d got %h expect %h",got,m_data,expected[got%NN]);
 if(m_sof!==(got%NN==0)||m_eol!==((got%WW)==WW-1)||m_last!==(got%NN==NN-1))$fatal(1,"markers");got=got+1;end end
 task tick;begin @(negedge clk);#1;end endtask
 initial begin $readmemh("PIXFILE",pixels);$readmemh("EXPFILE",expected);repeat(3)tick;rst_n=1;tick;
 for(rep=0;rep<2;rep=rep+1)begin cfg_pattern=PP;start_valid=1;while(!start_ready)tick;@(posedge clk);#1;tick;start_valid=0;cfg_pattern=(PP+1)%4;
 for(i=0;i<NN;i=i+1)begin s_data=pixels[i];s_sof=i==0;s_eol=i%WW==WW-1;s_last=i==NN-1;s_valid=1;while(!s_ready)tick;@(posedge clk);#1;tick;end
 s_valid=0;while(!done_valid)tick;if(done_error||got!=(rep+1)*NN)$fatal(1,"done %h count%d",error_code,got);
 repeat(7)tick;if(!done_valid||done_error)$fatal(1,"done hold");done_ready=1;while(!ce)tick;@(posedge clk);#1;tick;done_ready=0;end
 $display("PASS malvar_demosaic");$finish;end
endmodule
'''
def run_case(name,cfa,pattern,bits):
 cfa=np.asarray(cfa,dtype=np.int64);h,w=cfa.shape;expected=oracle(cfa,pattern,bits);packed=(expected[:,:,0]<<(2*bits))|(expected[:,:,1]<<bits)|expected[:,:,2]
 with tempfile.TemporaryDirectory(prefix='mhc_') as tmp:
  d=Path(tmp);(d/'pix.hex').write_text('\n'.join(f'{v:x}' for v in cfa.ravel())+'\n');(d/'exp.hex').write_text('\n'.join(f'{v:x}' for v in packed.ravel())+'\n');tb=TB
  for a,b in [('PIXFILE',(d/'pix.hex').as_posix()),('EXPFILE',(d/'exp.hex').as_posix()),('PP',str(pattern)),('WW',str(w)),('HH',str(h)),('NN',str(w*h)),('B',str(bits))]:tb=re.sub(r'\b'+a+r'\b',lambda m:b,tb)
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],HERE.parents[3],d/'compile.log');text=execute(['vvp',d/'a.vvp'],HERE.parents[3],d/'sim.log');assert 'PASS malvar_demosaic' in text
 return dict(name=name,bits=bits,pattern=PATTERNS[pattern],geometry=[w,h],pixels=2*w*h,oracle_error=0)
def main():
 rng=np.random.default_rng(489);rows=[]
 for bits in [8,10,12]:
  peak=(1<<bits)-1
  for pat in range(4):
   pulse=np.zeros((7,9),dtype=int);pulse[3,4]=peak;pulse[0,0]=peak
   y,x=np.indices((9,11));rgb=np.stack([x*peak//10,y*peak//8,(x+y)*peak//18],axis=-1);ms=masks((9,11),PATTERNS[pat]);cfa=sum(rgb[:,:,ch]*ms[ch] for ch in range(3))
   for name,a in [('constant',np.full((6,8),peak//3)),('impulse',pulse),('colour_scene',cfa),('random',rng.integers(0,peak+1,(5,7)))]:
    row=run_case(name,a,pat,bits);rows.append(row);print(row,flush=True)
 for h,w in [(1,1),(1,2),(2,1),(1,7),(7,1),(2,2),(2,9),(9,2),(24,32)]:
  for pat in range(4):
   row=run_case('thin_or_default',rng.integers(0,256,(h,w)),pat,8);rows.append(row);print(row,flush=True)
 fixtures=json.loads((HERE/'reference_fixtures.mem').read_text())
 for case in fixtures['cases']:
  a=np.array(case['cfa']);actual=oracle(a,case['pattern'],case['bits']);assert np.array_equal(actual,np.array(case['reflect101_reference'])),case['name']
 (HERE/'evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),cases=rows,reference_fixture_sha256=hashlib.sha256((HERE/'reference_fixtures.mem').read_bytes()).hexdigest(),reference_source_sha256=fixtures['reference_source_sha256']),indent=2)+'\n')
if __name__=='__main__':main()
