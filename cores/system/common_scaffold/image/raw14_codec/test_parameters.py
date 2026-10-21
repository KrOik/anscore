from run_tests import *
B=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=0;reg[@IW@-1:0]s_data=0;reg s_valid=0,s_sof=0,s_eol=0;wire s_ready;wire[@OW@-1:0]m_data;wire m_valid,m_sof,m_eol;reg m_ready=0,error_ready=0;wire protocol_error,error_valid;wire[7:0]error_code;wire[31:0]error_count;
raw14_@KIND@ #(.PIXEL_BITS(@BITS@))dut(.*);
 task tick;begin @(negedge clk);#1;end endtask
initial begin repeat(3)tick;rst_n=1;repeat(4)tick;
if(!error_valid||error_code!=1||error_count!=1||!protocol_error||s_ready||m_valid)$fatal(1,"parameter report at CE0");error_ready=1;repeat(4)tick;if(!error_valid)$fatal(1,"CE0errorack");ce=1;tick;if(error_valid)$fatal(1,"errorack");repeat(4)tick;if(error_valid||error_count!=1||s_ready)$fatal(1,"repeatedparametererror");
rst_n=0;tick;if(error_valid||m_valid||error_count!=0||protocol_error)$fatal(1,"resetstatus");$display("PASS RAW14 PARAM");$finish;end endmodule'''
def main():
 rows=[]
 for kind in ('pack','unpack'):
  iw,ow=(14,8) if kind=='pack' else (8,14)
  for bits in (0,13,15,32):
   tb=B.replace('@KIND@',kind).replace('@BITS@',str(bits)).replace('@IW@',str(iw)).replace('@OW@',str(ow))
   with tempfile.TemporaryDirectory(prefix='raw14_param_') as td:
    p=Path(td);(p/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',H/f'raw14_{kind}.sv',p/'tb.sv'],H,H/f'param_{kind}_{bits}_compile.log');out=execute(['vvp',p/'sim'],H,H/f'param_{kind}_{bits}_simulation.log');assert 'PASS RAW14 PARAM' in out
   rows.append(dict(module='raw14_'+kind,pixel_bits=bits,status='PASS'))
 (H/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',sources=SOURCES,profiles=rows),indent=2)+'\n');print('PASS8 RAW14 PARAM')
if __name__=='__main__':main()
