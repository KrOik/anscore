from run_tests import *
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1;reg[@IW@-1:0]s_data=0;reg s_valid=0,s_sof=0,s_eol=0;wire s_ready;wire[@OW@-1:0]m_data;wire m_valid,m_sof,m_eol;reg m_ready=0,error_ready=0;wire protocol_error,error_valid;wire[7:0]error_code;wire[31:0]error_count;
raw14_@KIND@ dut(.*);
reg[15:0]inputs[0:@NI@-1],outputs[0:@NO@-1];integer i;
 task tick;begin @(negedge clk);#1;end endtask
 task resetnow;begin rst_n=0;ce=0;tick;if(m_valid||error_valid||error_count||protocol_error)$fatal(1,"resetclear");rst_n=1;ce=1;tick;end endtask
 task send;input integer n;begin s_data=inputs[n][@IW@-1:0];s_sof=n==0;s_eol=n==@NI@-1;s_valid=1;while(!s_ready)tick;tick;s_valid=0;end endtask
initial begin
$readmemh("@INPUTS@",inputs);$readmemh("@OUTPUTS@",outputs);repeat(3)tick;rst_n=1;tick;
for(i=0;i<2;i=i+1)send(i);resetnow; // partial group must disappear
for(i=0;i<@NI@;i=i+1)send(i);
if(!m_valid)$fatal(1,"no group");ce=0;m_ready=1;repeat(8)tick;
if(!m_valid||m_data!=outputs[0])$fatal(1,"CE0held");resetnow; // exposed output reset
m_ready=0;for(i=0;i<@NI@;i=i+1)send(i);
for(i=0;i<@NO@;i=i+1)begin
if(!m_valid||m_data!=outputs[i]||m_sof!==(i==0)||m_eol!==(i==@NO@-1))$fatal(1,"healthy reset output");
repeat(3)tick;m_ready=1;tick;m_ready=0;end
if(m_valid||error_valid||error_count)$fatal(1,"healthy status");
// Deposit only diagnostic counter near saturation; payload/framing remain natural.
dut.error_count=32'hfffffffe;s_valid=1;s_sof=0;s_eol=0;s_data=0;
// Locked stream permits group data; reset parser first without changing the counter seed.
s_valid=0;rst_n=0;tick;rst_n=1;tick;dut.error_count=32'hfffffffe;s_valid=1;
repeat(3)tick;s_valid=0;
if(error_count!=32'hffffffff||!error_valid||error_code!=4)$fatal(1,"saturation");
$display("PASS RAW14 CONTROL partialreset heldreset CE0 healthy saturation");$finish;end
initial begin #100000;$fatal(1,"watchdog");end endmodule'''
def main():
 rows=[];pixels=[1,0x156,0x2aab,0x3fff];bytevals=[0,5,0xaa,0xff,0x81,0xb5,0xfe]
 for kind in ('pack','unpack'):
  inv,outv,iw,ow=(pixels,bytevals,14,8) if kind=='pack' else (bytevals,pixels,8,14)
  with tempfile.TemporaryDirectory(prefix='raw14_control_') as td:
   p=Path(td);(p/'in.hex').write_text('\n'.join(f'{v:04x}' for v in inv));(p/'out.hex').write_text('\n'.join(f'{v:04x}' for v in outv));tb=TB
   for k,v in dict(KIND=kind,IW=iw,OW=ow,NI=len(inv),NO=len(outv),INPUTS=(p/'in.hex').as_posix(),OUTPUTS=(p/'out.hex').as_posix()).items():tb=tb.replace('@'+k+'@',str(v))
   (p/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',H/f'raw14_{kind}.sv',p/'tb.sv'],H,H/f'control_{kind}_compile.log');out=execute(['vvp',p/'sim'],H,H/f'control_{kind}_simulation.log');assert 'PASS RAW14 CONTROL' in out;print(out);rows.append(dict(module='raw14_'+kind,status='PASS',output=out))
 (H/'control_evidence.json').write_text(json.dumps(dict(status='PASS',sources=SOURCES,scope='Partial input and held output synchronous reset; CE0 physical hold; mature fixture after reset; diagnostic counter deposited FFFFFFFE then3natural missingSOF faults saturate FFFFFFFF',profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
