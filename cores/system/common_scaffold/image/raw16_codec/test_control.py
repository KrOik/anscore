from run_tests import *
B=r"""module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1;reg[@IW@-1:0]s_data=0;reg s_valid=0,s_sof=0,s_eol=0;wire s_ready;wire[@OW@-1:0]m_data;wire m_valid,m_sof,m_eol;reg m_ready=0,error_ready=0;wire protocol_error,error_valid;wire[7:0]error_code;wire[31:0]error_count;
raw16_@KIND@ #(.BIG_ENDIAN(@ENDIAN@))dut(.*);
task tick;begin @(negedge clk);#1;end endtask
task resetnow;begin rst_n=0;ce=0;s_valid=0;tick;if(m_valid||error_valid||error_count||protocol_error)$fatal(1,"resetclear");rst_n=1;ce=1;tick;end endtask
task send;input integer d,sof,eol;begin s_data=d;s_sof=sof;s_eol=eol;s_valid=1;while(!s_ready)tick;tick;s_valid=0;end endtask
initial begin repeat(3)tick;rst_n=1;tick;
@PARTIAL@
resetnow;@HEALTHY@
if(!m_valid)$fatal(1,"missing output");ce=0;m_ready=1;repeat(8)tick;if(!m_valid||m_data!=@FIRST@||!m_sof)$fatal(1,"CE0 held");resetnow;
m_ready=0;@HEALTHY@
if(!m_valid||m_data!=@FIRST@||!m_sof||m_eol!==@EOL@)$fatal(1,"healthy output");
repeat(3)tick;m_ready=1;tick;@SECOND@
if(m_valid||error_count||error_valid)$fatal(1,"healthy status");
resetnow;dut.error_count=32'hfffffffe;send(2,0,0);send(3,0,0);send(4,0,0);
if(error_count!=32'hffffffff||!error_valid||error_code!=4)$fatal(1,"saturation");
// Same-cycle ACK and natural newfault must retain a valid error.
error_ready=1;send(5,0,0);if(!error_valid||error_code!=4)$fatal(1,"ACK new error");s_valid=0;tick;if(error_valid)$fatal(1,"ack clear");
$display("PASS RAW16 CONTROL");$finish;end
initial begin #100000;$fatal(1,"watchdog");end endmodule"""
def main():
 rows=[]
 for endian in (0,1):
  for kind in ('pack','unpack'):
   iw,ow=(16,8) if kind=='pack' else (8,16)
   vals=dict(KIND=kind,ENDIAN=endian,IW=iw,OW=ow)
   if kind=='pack':vals.update(PARTIAL='send(16\'h1234,1,1);',HEALTHY='send(16\'h1234,1,1);',FIRST=0x12 if endian else 0x34,EOL="1'b0",SECOND=f'if(!m_valid||m_data!={0x34 if endian else 0x12}||m_sof||!m_eol)$fatal(1,"second byte");tick;')
   else:vals.update(PARTIAL='send(8\'h12,1,0);',HEALTHY='send(8\'h12,1,0);send(8\'h34,0,1);',FIRST=0x1234 if endian else 0x3412,EOL="1'b1",SECOND='')
   tb=B
   for k,v in vals.items():tb=tb.replace('@'+k+'@',str(v))
   with tempfile.TemporaryDirectory(prefix='raw16_control_') as td:
    p=Path(td);(p/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',H/f'raw16_{kind}.sv',p/'tb.sv'],H,H/f'control_{kind}_e{endian}_compile.log');out=execute(['vvp',p/'sim'],H,H/f'control_{kind}_e{endian}_simulation.log');assert 'PASS RAW16 CONTROL' in out
   rows.append(dict(module='raw16_'+kind,big_endian=endian,status='PASS'))
 (H/'control_evidence.json').write_text(json.dumps(dict(status='PASS',sources=SOURCES,scope='Partial unpack reset and held-output reset with CE0; healthy exact markers; saturating diagnostic count near max; ACK+newfault',profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
