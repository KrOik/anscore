from pathlib import Path
import json,hashlib,tempfile,sys
HERE=Path(__file__).resolve().parent;PACKAGE=HERE.parents[3]
sys.path.insert(0,str(PACKAGE/'integration'))
from tooling import execute
SOURCES=[HERE/'sensor_i2c_top.sv',HERE/'sensor_scripted_slave.sv',HERE/'sensor_uart_message.sv',PACKAGE/'peripherals/i2c_eeprom/i2c_eeprom_phy.sv',PACKAGE/'peripherals/ds3231_rtc/ds3231_rtc.sv',PACKAGE/'peripherals/ads1115_adc/ads1115_adc.sv',PACKAGE/'peripherals/sht3x_sensor/sht3x_sensor.sv']
def hashes():return {p.relative_to(PACKAGE).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
TB=r'''
`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;wire uart_tx,dbg_uart;
sensor_i2c_top #(.SENSOR(@SENSOR@),.CORRUPT(@CORRUPT@),.CLK_HZ(1000000),.BAUD(100000))dut(.clk(clk),.uart_rx_pin(1'b1),.uart_tx(uart_tx),.dbg_uart(dbg_uart));
reg[7:0]c;integer n,b;
initial begin #5000000;$fatal(1,"UART timeout");end
initial begin
 $write("UART ");
 for(n=0;n<@LENGTH@;n=n+1)begin
 @(negedge uart_tx);#150;
 for(b=0;b<8;b=b+1)begin c[b]=uart_tx;#100;end
 if(!uart_tx)$fatal(1,"bad UART stop");$write("%c",c);
 end
 if(dbg_uart!=@PASS@)$fatal(1,"debug result mismatch");
 $display("END_UART");$finish;
end
endmodule
'''
def main():
 before=hashes();rows=[]
 for sensor,name in enumerate(['DS3231','ADS1115','SHT3X']):
  for corrupt in [0,1]:
   expected=f'{"FAIL" if corrupt else "PASS"} {name} PINLOOP\r\n'
   tb=TB.replace('@SENSOR@',str(sensor)).replace('@CORRUPT@',str(corrupt)).replace('@LENGTH@',str(len(expected))).replace('@PASS@',str(1-corrupt))
   with tempfile.TemporaryDirectory(prefix='sensor_i2c_sim_') as tmp:
    p=Path(tmp);(p/'tb.sv').write_text(tb,encoding='utf-8');execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');out=execute(['vvp',p/'sim'],p,p/'run.log',timeout=60)
   # tooling normalizes newline; check exact payload including one line ending.
   normalized=out.replace('\r\n','\n').replace('\r','')
   assert 'UART '+expected.replace('\r','')+'END_UART\n' in normalized,out
   log=HERE/f'simulation_{sensor}_{corrupt}.log';log.write_text(out,encoding='utf-8');rows.append(dict(sensor=name,corrupt=corrupt,expected_uart=expected,log=log.name,sha256=hashlib.sha256(log.read_bytes()).hexdigest()));print(name,corrupt,'PASS',flush=True)
 assert before==hashes()
 (HERE/'simulation.json').write_text(json.dumps(dict(status='PASS',sources=before,profiles=rows,scope='Synthesizable internal scripted sensor pin loopback; no real sensor or board claim'),indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
