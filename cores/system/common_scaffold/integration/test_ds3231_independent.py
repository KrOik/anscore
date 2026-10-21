"""Independent physical I2C transcript / Python calendar oracle for DS3231."""
import datetime
import hashlib
import tempfile
from pathlib import Path
from tooling import PACKAGE, evidence_dir, execute, write_json

TB = r'''
`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=0,start_valid=0,set_time=0,result_ready=0,done_ready=0;
reg[11:0]set_year=2112;reg[3:0]set_month=2;reg[5:0]set_day=29;
reg[2:0]set_weekday=3;reg[4:0]set_hour=23;reg[5:0]set_minute=58,set_second=57;
wire start_ready,result_valid,busy,done_valid;wire[3:0]error_code;
wire[11:0]year;wire[3:0]month;wire[5:0]day;wire[2:0]weekday;wire[4:0]hour;wire[5:0]minute,second;
wire[7:0]status_raw,retries;wire oscillator_stop,alarm1_flag,alarm2_flag,source_12h,source_century;
wire scl_drive_low,sda_drive_low;reg slave_low=0;
wire scl_in=!scl_drive_low,sda_in=!(sda_drive_low||slave_low);
ds3231_rtc #(.HALF_PERIOD_CYCLES(@HALF@),.STRETCH_TIMEOUT_CYCLES(80),.MAX_ROLLOVER_RETRIES(1))dut(.*);
integer starts=0,stops=0,reads=0,writes=0;
reg slave_done=0;reg[7:0]raw[0:@NRAW@-1];reg[63:0]expected[0:@NCASE@-1];
task tick;begin @(negedge clk);#1;end endtask
task await_start;begin : scan forever begin @(negedge sda_in);if(scl_in)begin starts=starts+1;disable scan;end end end endtask
task await_stop;begin : scan forever begin @(posedge sda_in);if(scl_in)begin stops=stops+1;disable scan;end end end endtask
task receive;input[7:0]want;reg[7:0]got;integer j;begin
 got=0;for(j=0;j<8;j=j+1)begin @(posedge scl_in);got={got[6:0],sda_in};@(negedge scl_in);end
 if(got!==want)$fatal(1,"wire write got%h want%h",got,want);writes=writes+1;
 slave_low=1;@(posedge scl_in);@(negedge scl_in);slave_low=0;
end endtask
task transmit;input[7:0]v;input last;integer j;begin
 for(j=7;j>=0;j=j-1)begin slave_low=!v[j];@(posedge scl_in);@(negedge scl_in);end
 slave_low=0;@(posedge scl_in);if(sda_in!==last)$fatal(1,"master ACK/NACK");@(negedge scl_in);reads=reads+1;
end endtask
task read_registers;input integer offset,n,pointer;integer j;begin
 await_start;receive(8'hd0);receive(pointer);await_start;receive(8'hd1);
 for(j=0;j<n;j=j+1)transmit(raw[offset+j],j==n-1);await_stop;
end endtask
task snapshot;input integer offset;begin
 read_registers(offset,7,0);read_registers(offset+7,1,15);read_registers(offset+8,1,0);
end endtask
integer k,j;
initial begin
 $readmemh("raw.hex",raw);wait(rst_n);
 for(k=0;k<@NCASE@;k=k+1)snapshot(k*9);
 // Read seconds 59, verification sees00: reread the whole calendar once.
 snapshot(@NCASE@*9);snapshot((@NCASE@+1)*9);
 // SET_TIME emits a single contiguous write; it must not touch control/status.
 await_start;receive(8'hd0);receive(0);
 receive(8'h57);receive(8'h58);receive(8'h23);receive(3);receive(8'h29);receive(8'h82);receive(8'h12);await_stop;
 slave_done=1;
end
task command;input wr;begin
 while(!start_ready)tick;set_time=wr;ce=1;start_valid=1;tick;start_valid=0;
end endtask
task complete;input[3:0]e;integer q;begin
 while(!done_valid)tick;if(error_code!==e)$fatal(1,"done got%0d expected%0d",error_code,e);
 ce=0;done_ready=1;for(q=0;q<7;q=q+1)begin tick;if(!done_valid||error_code!==e)$fatal(1,"held completion");end
 ce=1;tick;done_ready=0;
end endtask
task result;input[63:0]want;input[7:0]retry;reg[63:0]seen;integer q;begin
 while(!result_valid&&!done_valid)tick;if(!result_valid)$fatal(1,"missing result error=%0d",error_code);
 seen={20'b0,year,month,day,weekday,hour,minute,second,source_12h,source_century};
 if(seen!==want||retries!==retry||status_raw!==8'h83||!oscillator_stop||!alarm1_flag||!alarm2_flag)$fatal(1,"calendar got%h want%h retry%0d",seen,want,retries);
 ce=0;result_ready=1;
 for(q=0;q<17;q=q+1)begin tick;
  if(!result_valid||{20'b0,year,month,day,weekday,hour,minute,second,source_12h,source_century}!==want||done_valid)$fatal(1,"held result");
 end
 ce=1;tick;result_ready=0;complete(0);
end endtask
integer c,oldstarts;reg[63:0]roll_result;
initial begin
 $readmemh("expected.hex",expected);repeat(4)tick;rst_n=1;start_valid=1;
 repeat(10)tick;if(starts||busy||!start_ready)$fatal(1,"CE0 command accepted");start_valid=0;
 for(c=0;c<@NCASE@;c=c+1)begin command(0);result(expected[c],0);end
 command(0);result(@ROLL_RESULT@,1);
 command(1);
 // Descriptor must have latched even if all host fields subsequently change.
 set_year=2001;set_month=1;set_day=1;set_hour=0;set_minute=0;set_second=0;
 complete(0);
 oldstarts=starts;set_year=2100;set_month=2;set_day=29;command(1);complete(8);
 if(starts!=oldstarts)$fatal(1,"invalid Gregorian date touched bus");
 while(!slave_done)tick;
 if(starts!=(@NCASE@+2)*6+1||stops!=(@NCASE@+2)*3+1||reads!=(@NCASE@+2)*9)$fatal(1,"transcript totals");
 ce=0;rst_n=0;tick;if(result_valid||done_valid||scl_drive_low||sda_drive_low)$fatal(1,"reset outputs");
 $display("PASS RTC_INDEPENDENT HALF=@HALF@ starts=%0d stops=%0d read=%0d",starts,stops,reads);$finish;
end
initial begin #5000000;$fatal(1,"watchdog");end
endmodule
'''


def packed(date, weekday, twelve, century):
    # Explicit Python-side bit packing matches the declared binary result ports.
    value = 0
    for number, width in ((date.year, 12), (date.month, 4), (date.day, 6),
                          (weekday, 3), (date.hour, 5), (date.minute, 6),
                          (date.second, 6), (twelve, 1), (century, 1)):
        value = (value << width) | number
    return value


def main():
    base = PACKAGE/'peripherals/ds3231_rtc'
    sources = [base/'ds3231_rtc.sv', PACKAGE/'peripherals/i2c_eeprom/i2c_eeprom_phy.sv']
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    frozen = {str(p.relative_to(PACKAGE)): sha(p) for p in sources}
    bcd = lambda n: ((n//10)<<4) | n % 10
    cases = [(datetime.datetime(2000, 2, 29, 0, 1, 2), 1, 0x52),
             (datetime.datetime(2024, 12, 31, 12, 59, 59), 7, 0x72),
             (datetime.datetime(2100, 3, 1, 13, 0, 0), 2, 0x61),
             (datetime.datetime(2199, 12, 31, 23, 59, 58), 5, 0x23)]
    rollover = [(datetime.datetime(2099, 12, 31, 23, 59, 59), 4, 0x23),
                (datetime.datetime(2100, 1, 1, 0, 0, 0), 5, 0)]
    data, expected = [], []
    for index, (date, weekday, raw_hour) in enumerate(cases+rollover):
        data.extend([bcd(date.second), bcd(date.minute), raw_hour, weekday,
                     bcd(date.day), bcd(date.month) | (0x80 if date.year >= 2100 else 0),
                     bcd(date.year % 100), 0x83,
                     0 if index == len(cases) else bcd(date.second)])
        expected.append(packed(date, weekday, int(bool(raw_hour & 0x40)), int(date.year >= 2100)))
    folder = evidence_dir('ds3231_independent')
    for half in (4, 11):
        with tempfile.TemporaryDirectory(prefix='rtc_root_peer_') as tmp:
            p = Path(tmp)
            tb = TB
            values = dict(HALF=half, NRAW=len(data), NCASE=len(cases), ROLL_RESULT=f"64'h{expected[-1]:016x}")
            for name, value in values.items():
                tb = tb.replace('@'+name+'@', str(value))
            (p/'tb.sv').write_text(tb, encoding='utf-8')
            (p/'raw.hex').write_text('\n'.join(f'{v:02x}' for v in data), encoding='utf-8')
            (p/'expected.hex').write_text('\n'.join(f'{v:016x}' for v in expected[:len(cases)]), encoding='utf-8')
            execute(['iverilog', '-g2012', '-s', 'tb', '-o', p/'sim', *sources, p/'tb.sv'], p, folder/f'compile_{half}.log')
            out = execute(['vvp', p/'sim'], p, folder/f'simulation_{half}.log')
            assert 'PASS RTC_INDEPENDENT' in out
    assert frozen == {str(p.relative_to(PACKAGE)): sha(p) for p in sources}, 'sources changed during peer test'
    write_json(folder/'results.json', dict(status='PASS', sources=frozen,
        reviewer_script_sha256=sha(Path(__file__)), profiles=2, calendar_cases=len(cases),
        scope='Independent physical I2C script and Python datetime oracle, AM/PM/century/leap/calendar, retry across2099/2100, SET exact bytes, CE0 holding, invalid date no bus; no electrical or board claim'))
    print(folder)


if __name__ == '__main__':
    main()
