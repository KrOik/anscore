"""Independent SHT3x wire transcripts and Python engineering-unit oracle."""
import hashlib
import tempfile
from pathlib import Path
from tooling import PACKAGE, evidence_dir, execute, write_json


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def crc(word):
    value = 255
    for byte in word.to_bytes(2, 'big'):
        value ^= byte
        for _ in range(8):
            value = ((value << 1) ^ (49 if value & 128 else 0)) & 255
    return value


TB = r'''
`timescale 1ns/1ps
module tb;
reg clk=0;always #500 clk=~clk;
reg rst_n=0,ce=0,abort=0,req_valid=0,out_ready=0;
reg[6:0]req_address=0;reg[1:0]req_repeatability=0;
wire req_ready,out_valid,busy,scl_drive_low,sda_drive_low;
wire[3:0]out_error,out_phy_error;wire[1:0]out_crc_bad;
wire[15:0]out_temperature_raw,out_humidity_raw,out_read_attempts;
wire signed[18:0]out_temperature_mC;wire[16:0]out_humidity_mpercent;
reg slave_low=0;wire scl_in=!scl_drive_low,sda_in=!(sda_drive_low||slave_low);
sht3x_sensor #(.CLOCK_HZ(1000000),.HALF_PERIOD_CYCLES(@HALF@),
 .STRETCH_TIMEOUT_CYCLES(80),.WAIT_LOW_US(5),.WAIT_MEDIUM_US(7),
 .WAIT_HIGH_US(16),.RETRY_GAP_US(3),.READ_ATTEMPTS(3))dut(.*);
reg[7:0]bytes[0:53];reg[15:0]tv[0:8],hv[0:8];
reg signed[31:0]temperatures[0:8];reg[31:0]humidities[0:8];
integer starts=0,stops=0,txbytes=0,rxbytes=0,done_count=0;
task tick;begin @(negedge clk);#1;end endtask
task start_edge;begin : seek forever begin @(negedge sda_in);if(scl_in)begin starts=starts+1;disable seek;end end end endtask
task stop_edge;begin : seek forever begin @(posedge sda_in);if(scl_in)begin stops=stops+1;disable seek;end end end endtask
task accept_byte;input[7:0]expected;input ack;reg[7:0]got;integer b;begin
 got=0;for(b=0;b<8;b=b+1)begin @(posedge scl_in);got={got[6:0],sda_in};@(negedge scl_in);end
 if(got!==expected)$fatal(1,"transmitted byte %h expected %h",got,expected);
 txbytes=txbytes+1;slave_low=ack;@(posedge scl_in);@(negedge scl_in);slave_low=0;
end endtask
task send_byte;input[7:0]v;input last;integer b;begin
 for(b=7;b>=0;b=b-1)begin slave_low=!v[b];@(posedge scl_in);@(negedge scl_in);end
 slave_low=0;@(posedge scl_in);if(sda_in!==last)$fatal(1,"read ACK/NACK");
 @(negedge scl_in);rxbytes=rxbytes+1;
end endtask
integer s,j,p;reg[7:0]address_byte,command_byte;
initial begin
 $readmemh("bytes.hex",bytes);wait(rst_n);
 for(s=0;s<9;s=s+1)begin
  address_byte=(s%2)?8'h8a:8'h88;
  case(s%3)0:command_byte=8'h16;1:command_byte=8'h0b;2:command_byte=0;endcase
  start_edge;accept_byte(address_byte,1);accept_byte(8'h24,1);accept_byte(command_byte,1);stop_edge;
  // Zero, one, then two busy read-address NACKs; final permitted poll succeeds.
  for(p=0;p<s%3;p=p+1)begin start_edge;accept_byte(address_byte|1,0);stop_edge;end
  start_edge;accept_byte(address_byte|1,1);
  for(j=0;j<6;j=j+1)send_byte(bytes[6*s+j],j==5);
  stop_edge;done_count=done_count+1;
 end
end
integer k;reg[101:0]held;
initial begin
 $readmemh("t.hex",tv);$readmemh("h.hex",hv);
 $readmemh("temp.hex",temperatures);$readmemh("hum.hex",humidities);
 repeat(5)tick;rst_n=1;
 for(k=0;k<9;k=k+1)begin
  ce=1;req_address=(k%2)?7'h45:7'h44;req_repeatability=k%3;
  while(!req_ready)tick;
  req_valid=1;tick;req_valid=0;ce=0;req_address=0;req_repeatability=3;
  while(!out_valid)tick;
  if(out_error||out_phy_error||out_crc_bad||out_read_attempts!=k%3+1)$fatal(1,"status");
  if(out_temperature_raw!==tv[k]||out_humidity_raw!==hv[k])$fatal(1,"raw endian");
  if($signed(out_temperature_mC)!==temperatures[k]||out_humidity_mpercent!==humidities[k])$fatal(1,"unit oracle");
  held={out_error,out_phy_error,out_crc_bad,out_temperature_raw,out_humidity_raw,out_temperature_mC,out_humidity_mpercent,out_read_attempts};
  repeat(11)begin tick;if(!out_valid||{out_error,out_phy_error,out_crc_bad,out_temperature_raw,out_humidity_raw,out_temperature_mC,out_humidity_mpercent,out_read_attempts}!==held)$fatal(1,"held output");end
  out_ready=1;tick;out_ready=0;if(out_valid||busy)$fatal(1,"CE0 pop");
 end
 // Nine command transactions plus eighteen read-address polls:27 START/STOP.
 // Command bytes27 plus poll addresses18:45 transmitted,54 received bytes.
 if(done_count!=9||starts!=27||stops!=27||txbytes!=45||rxbytes!=54)$fatal(1,"transcript counts %0d %0d %0d %0d",starts,stops,txbytes,rxbytes);
 $display("PASS SHT3X INDEPENDENT HALF=@HALF@ conversions9 polls18 starts27 tx45 rx54");$finish;
end
initial begin #100000000;$fatal(1,"watchdog");end
endmodule
'''


def main():
    folder = evidence_dir('sht3x_independent')
    paths = [PACKAGE / 'peripherals/sht3x_sensor/sht3x_sensor.sv',
             PACKAGE / 'peripherals/i2c_eeprom/i2c_eeprom_phy.sv']
    inputs = {str(p.relative_to(PACKAGE)): sha(p) for p in paths}
    values = [(0, 65535), (65535, 0), (32768, 32767), (0xbeef, 0x1234),
              (1, 65534), (65534, 1), (16852, 42107), (1000, 60000), (50000, 20000)]
    profiles = []
    for half in (4, 11):
        with tempfile.TemporaryDirectory(prefix='sht3x_independent_') as tmp:
            work = Path(tmp)
            vectors = {'t': [t for t, h in values], 'h': [h for t, h in values],
                       'temp': [((175000*t+32767)//65535-45000) & 0xffffffff for t, h in values],
                       'hum': [(100000*h+32767)//65535 for t, h in values],
                       'bytes': [b for t, h in values for b in
                                 (t >> 8, t & 255, crc(t), h >> 8, h & 255, crc(h))]}
            for name, data in vectors.items():
                (work / (name+'.hex')).write_text('\n'.join(f'{v:x}' for v in data)+'\n', encoding='utf-8')
            (work/'tb.sv').write_text(TB.replace('@HALF@', str(half)), encoding='utf-8')
            execute(['iverilog', '-g2012', '-s', 'tb', '-o', work/'sim', *paths, work/'tb.sv'],
                    work, folder/f'compile_{half}.log')
            output = execute(['vvp', work/'sim'], work, folder/f'simulation_{half}.log')
            if 'PASS SHT3X INDEPENDENT' not in output:
                raise RuntimeError('missing explicit success marker')
            profiles.append(dict(half=half, status='PASS', output=output))
    if inputs != {str(p.relative_to(PACKAGE)): sha(p) for p in paths}:
        raise RuntimeError('source changed during test')
    write_json(folder/'results.json', dict(status='PASS', sources=inputs,
        script_sha256=sha(Path(__file__)), profiles=profiles,
        logs={p.name: sha(p) for p in folder.glob('*.log')}, board_tested=False))
    print('PASS '+str(folder))


if __name__ == '__main__':
    main()
