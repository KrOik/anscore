from run_tests import *
B=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=0;reg[@IW@-1:0]s_data=0;reg s_valid=0,s_sof=0,s_eol=0;wire s_ready;wire[@OW@-1:0]m_data;wire m_valid,m_sof,m_eol;reg m_ready=0,error_ready=0;wire protocol_error,error_valid;wire[7:0]error_code;wire[31:0]error_count;
raw16_@KIND@ #(.PIXEL_BITS(@BITS@),.BIG_ENDIAN(@ENDIAN@))dut(.*);
 task tick;begin @(negedge clk);#1;end endtask
initial begin repeat(3)tick;rst_n=1;repeat(4)tick;
if(!error_valid||error_code!=1||error_count!=1||!protocol_error||s_ready||m_valid)$fatal(1,"parameter report at CE0");error_ready=1;repeat(4)tick;if(!error_valid)$fatal(1,"CE0errorack");ce=1;tick;if(error_valid)$fatal(1,"errorack");repeat(4)tick;if(error_valid||error_count!=1||s_ready)$fatal(1,"repeatedparametererror");
rst_n=0;tick;if(error_valid||m_valid||error_count!=0||protocol_error)$fatal(1,"resetstatus");$display("PASS RAW16 PARAM");$finish;end endmodule'''
def main():
 rows=[]
 for kind in ('pack','unpack'):
  iw,ow=(16,8) if kind=='pack' else (8,16)
  for bits,endian in ((0,0),(15,0),(17,0),(32,0),(16,-1),(16,2)):
   tb=B.replace('@KIND@',kind).replace('@BITS@',str(bits)).replace('@ENDIAN@',str(endian)).replace('@IW@',str(iw)).replace('@OW@',str(ow))
   with tempfile.TemporaryDirectory(prefix='raw16_param_') as td:
    p=Path(td);(p/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',H/f'raw16_{kind}.sv',p/'tb.sv'],H,H/f'param_{kind}_{bits}_{endian}_compile.log');out=execute(['vvp',p/'sim'],H,H/f'param_{kind}_{bits}_{endian}_simulation.log');assert 'PASS RAW16 PARAM' in out
   rows.append(dict(module='raw16_'+kind,pixel_bits=bits,big_endian=endian,status='PASS'))
 (H/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',sources=SOURCES,profiles=rows),indent=2)+'\n');print('PASS12 RAW16 PARAM')
if __name__=='__main__':main()
