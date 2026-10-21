from run_tests import *
from test_numeric import B

def main():
 rows=[]
 for target in [13,16,17,18,19,20]:
  for reset in [False,True]:
   label=f'pipeline_{target}_{"reset" if reset else "abort"}'
   decl=B[:B.index('reg[17:0]te')]
   body=f"""
initial begin repeat(3)@(negedge clk);rst_n=1;
@(negedge clk);dut.state=13;dut.out_temperature_raw=16'hbeef;dut.out_humidity_raw=16'hbeef;dut.temp_crc=8'h92;dut.humidity_crc=8'h92;
while(dut.state!={target})@(negedge clk);
"""
   if reset:body+='rst_n=0;@(negedge clk);if(out_valid||busy||out_temperature_mC||out_humidity_mpercent)$fatal(1,"pipeline reset");'
   else:body+='abort=1;@(negedge clk);abort=0;if(!out_valid||out_error!=7||out_temperature_mC||out_humidity_mpercent||out_temperature_raw!=16\'hbeef||out_crc_bad)$fatal(1,"pipeline abort");out_ready=1;@(negedge clk);if(out_valid)$fatal(1,"pipeline abort ack CE0");'
   tb=decl+body+'$display("PASS SHT3X PIPELINE");$finish;end endmodule'
   with tempfile.TemporaryDirectory(prefix='sht3x_pipeline_') as tmp:
    p=Path(tmp);(p/'tb.sv').write_text(tb)
    execute(['iverilog','-g2012','-s','tb','-o',p/'sim',H/'sht3x_sensor.sv',PHY,p/'tb.sv'],p,H/f'{label}_compile.log')
    out=execute(['vvp',p/'sim'],p,H/f'{label}_simulation.log');assert 'PASS SHT3X PIPELINE' in out
   rows.append(dict(profile=label,status='PASS'))
 save('pipeline_evidence.json',rows,'Abort and reset at CRC validation and each of five registered conversion stages; CE0 physical pipeline progresses and response ack independent CE; raw values retained on abort, no engineering validity')
 print('PASS',len(rows),'pipeline lifecycle profiles')
if __name__=='__main__':main()
