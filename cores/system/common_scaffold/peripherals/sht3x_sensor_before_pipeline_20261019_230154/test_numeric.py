from run_tests import *
B=r"""module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=0,abort=0,req_valid=0,out_ready=0;reg[6:0]req_address=7'h44;reg[1:0]req_repeatability=0;wire req_ready,out_valid,busy,scl_drive_low,sda_drive_low;wire[3:0]out_error,out_phy_error;wire[1:0]out_crc_bad;wire[15:0]out_temperature_raw,out_humidity_raw,out_read_attempts;wire signed[18:0]out_temperature_mC;wire[16:0]out_humidity_mpercent;wire scl_in=1,sda_in=1;
sht3x_sensor dut(.*);
reg[17:0]te[0:65535],he[0:65535];reg[7:0]cex[0:65535];integer i;reg[33:0]tn,hn;
initial begin $readmemh("@T@",te);$readmemh("@H@",he);$readmemh("@C@",cex);
for(i=0;i<65536;i=i+1)begin tn=i*34'd175000+32767;hn=i*34'd100000+32767;
 if(dut.divide65535(tn)!==te[i]||dut.divide65535(hn)!==he[i]||dut.crc16(i[15:0])!==cex[i])$fatal(1,"oracle mismatch %0d",i);
end
$display("PASS SHT3X NUMERIC 65536 raw values both conversions and CRC8");$finish;end endmodule"""
def main():
 with tempfile.TemporaryDirectory(prefix='sht3x_numeric_') as td:
  p=Path(td)
  for name,values in [('t.hex',[(175000*i+32767)//65535 for i in range(65536)]),('h.hex',[(100000*i+32767)//65535 for i in range(65536)]),('c.hex',[crc(i) for i in range(65536)])]:(p/name).write_text('\n'.join(f'{v:x}' for v in values)+'\n',encoding='utf-8')
  tb=B.replace('@T@',(p/'t.hex').as_posix()).replace('@H@',(p/'h.hex').as_posix()).replace('@C@',(p/'c.hex').as_posix());(p/'tb.sv').write_text(tb,encoding='utf-8')
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',H/'sht3x_sensor.sv',PHY,p/'tb.sv'],p,H/'numeric_compile.log');out=execute(['vvp',p/'sim'],p,H/'numeric_simulation.log');assert 'PASS SHT3X NUMERIC' in out
 save('numeric_evidence.json',[dict(status='PASS',raw_values=65536,conversions=131072,crc_cases=65536,output=out)],'Independent Python //65535 round-half-up oracle verifies every raw input; RTL exact division helper and CRC function; full physical conversions separately tested')
 print(out)
if __name__=='__main__':main()
