from run_tests import *
TB='''module tb;reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=1,done_ready=0;reg[1:0]cfg_order=0;reg[SW-1:0]s_data=0;wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy;wire[7:0]error_code;wire[MW-1:0]m_data;NAME #(.WIDTH(WW),.HEIGHT(HH))dut(.*);initial begin #12;rst_n=1;#10;start_valid=1;#10;start_valid=0;#1;if(!done_valid||!done_error||error_code!=1||busy||s_ready||m_valid)$fatal(1,"param rejection");#30;if(!done_valid)$fatal(1,"donehold");$display("PASS PARAM");$finish;end endmodule'''
def main():
 before=hashes();rows=[]
 for pack in [True,False]:
  for w,h in [(0,1),(1,1),(3,2),(65536,1),(2,0),(2,65536)]:
   name='yuv422_byte_'+('packer' if pack else 'unpacker')
   with tempfile.TemporaryDirectory(prefix='yuv422_param_') as tmp:
    d=Path(tmp);tb=TB
    for k,v in dict(NAME=name,WW=w,HH=h,SW=32 if pack else 8,MW=8 if pack else 32).items():tb=tb.replace(k,str(v))
    (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a',*RTLS,d/'tb.sv'],HERE,d/'compile');out=execute(['vvp',d/'a'],HERE,d/'sim');assert 'PASS PARAM' in out
   rows.append(dict(module=name,width=w,height=h))
 assert hashes()==before;(HERE/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',sources=before,cases=rows),indent=2)+'\n');print('PASS YUV parameters')
if __name__=='__main__':main()
