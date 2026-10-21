from pathlib import Path
import sys,tempfile,json,hashlib
H=Path(__file__).resolve().parent;sys.path.insert(0,str(H.parents[1]));from integration.tooling import execute
RTL=H/'onewire_rom_search.sv'
def crc(data):
 c=0
 for v in data:
  for b in range(8):c=(c>>1)^(0x8c if (c^(v>>b))&1 else 0)
 return c
def rom(v):
 b=v.to_bytes(7,'little');return int.from_bytes(b+bytes([crc(b)]),'little')
TB=r'''module tb;
localparam SCALE=(@CLK@/1000000<1?1:@CLK@/1000000);
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0,rom_ready=1,done_ready=0;
wire start_ready,ow_drive_low,rom_valid,rom_last,busy,done_valid,no_devices;wire[63:0]rom_data;wire[15:0]device_count;wire[7:0]error_code;
reg dev_low=0,read_low=0,stuck=0;wire ow_in=!(ow_drive_low||dev_low||read_low||stuck);
onewire_rom_search #(.CLK_HZ(@CLK@),.MAX_DEVICES(@MAX@),.TOTAL_TIMEOUT_US(@TIMEOUT@))dut(.*);
reg[63:0]roms[0:15];reg[15:0]alive=0;integer ndev=@COUNT@,expected_error=@ERROR@,expected_count=@OUTPUTS@;
integer age=-1,low_len=0,pres_age=-1,cmd_count=0,cmd_value=0,phase=0,bitpos=0,i,got=0,cycles=0,slots=0,resets=0,collision_positions=0;
reg prev_drive=0,seen[0:15];reg id,comp,chosen;reg[63:0]holdrom;reg holdlast,held=0;
always @(posedge clk)begin
 cycles=cycles+1;if(cycles>4000000)$fatal(1,"watchdog");
 if(rst_n)begin
 if(held&&(!rom_valid||rom_data!==holdrom||rom_last!==holdlast))$fatal(1,"output stall");
 held=rom_valid&&!(ce&&rom_ready);holdrom=rom_data;holdlast=rom_last;
 if(ce&&rom_valid&&rom_ready)begin
  if(@CHECK@)begin
   chosen=0;for(i=0;i<ndev;i=i+1)if(rom_data===roms[i]&&!seen[i])begin seen[i]=1;chosen=1;end
   if(!chosen)$fatal(1,"unexpected/duplicate ROM %h",rom_data);
  end
  got=got+1;
  if(expected_error==0&&rom_last!==(got==ndev))$fatal(1,"ROM last incorrect");
 end end else held=0;
end
// Device response starts at an exact physical delay from the master pin edge.
always @(posedge ow_drive_low)begin
 read_low<=0;
 if(cmd_count==8&&phase<2)begin
  id=1;comp=1;for(i=0;i<ndev;i=i+1)if(alive[i])begin id=id&roms[i][bitpos];comp=comp&!roms[i][bitpos];end
  read_low <= #(@DELAY@*SCALE*10) ((phase==0&&!id)||(phase==1&&!comp));
  read_low <= #(@RELEASE@*SCALE*10) 0;
 end
end
// Independent wired-AND multidrop sensor model, using only physical drive edges.
always @(negedge clk)begin
 if(!rst_n)begin prev_drive=0;age=-1;pres_age=-1;low_len=0;dev_low=0;end
 else begin
 if(ow_drive_low&&!prev_drive)begin age=0;low_len=0;slots=slots+1;end
 if(ow_drive_low)low_len=low_len+1;
 if(@STRICT@&&!ow_drive_low&&prev_drive&&low_len!=3*SCALE&&low_len!=6*SCALE&&low_len!=60*SCALE&&low_len!=480*SCALE)$fatal(1,"physical low duration %d scale %d",low_len,SCALE);
 if(!ow_drive_low&&prev_drive&&low_len>=400*SCALE)begin
  pres_age=0;age=-1;cmd_count=0;cmd_value=0;phase=0;bitpos=0;alive=(1<<ndev)-1;resets=resets+1;
 end
 dev_low=0;
 if(pres_age>=0)begin if(pres_age>=15*SCALE&&pres_age<150*SCALE&&ndev>0)dev_low=1;pres_age=pres_age+1;if(pres_age>480*SCALE)pres_age=-1;end
 if(age>=0)begin
  if(age==65*SCALE&&low_len<65*SCALE)begin
   chosen=low_len<30*SCALE;
   if(cmd_count<8)begin cmd_value=cmd_value|(chosen<<cmd_count);cmd_count=cmd_count+1;if(cmd_count==8&&cmd_value!=240)$fatal(1,"SearchROM command %h",cmd_value);end
   else if(phase==2)begin
    for(i=0;i<ndev;i=i+1)if(alive[i]&&roms[i][bitpos]!=chosen)alive[i]=0;
    bitpos=bitpos+1;phase=0;
   end else begin
    if(phase==0)begin id=1;comp=1;for(i=0;i<ndev;i=i+1)if(alive[i])begin id=id&roms[i][bitpos];comp=comp&!roms[i][bitpos];end if(!id&&!comp)collision_positions=collision_positions+1;end
    phase=phase+1;
   end
  end
  age=age+1;
 end
 prev_drive=ow_drive_low;
 end
end
 task tick;begin @(negedge clk);#2;end endtask
integer j;
initial begin @ROMS@
for(j=0;j<16;j=j+1)seen[j]=0;
repeat(5)tick;rst_n=1;repeat(5)tick;
@PRE@
start_valid=1;tick;start_valid=0;
@ACTION@
while(!done_valid)begin tick;@CE@ end
ce=1;
if(error_code!=expected_error||device_count!=expected_count||got!=expected_count||ow_drive_low)$fatal(1,"result error%0d expected%0d count%0d got%0d expected%0d",error_code,expected_error,device_count,got,expected_count);
if(expected_count==0&&ndev==0&&expected_error==0&&!no_devices)$fatal(1,"no-device flag");
repeat(8)tick;if(!done_valid)$fatal(1,"done hold");done_ready=1;tick;if(!start_ready)$fatal(1,"done ack");
$display("PASS ONEWIRE count=%0d devices=%0d error=%0d slots=%0d resets=%0d collisions=%0d",got,ndev,error_code,slots,resets,collision_positions);$finish;end
endmodule'''
def run(label,values,error=0,outputs=None,maxdev=16,action='',pre='',ce='',clock=1000000,timeout=2000000,check=1,delay=5,release=15):
 tb=TB
 pairs={'@RELEASE@':release,'@DELAY@':delay,'@STRICT@':int(error==0 and not action),'@CLK@':clock,'@MAX@':maxdev,'@TIMEOUT@':timeout,'@COUNT@':len(values),'@ERROR@':error,'@OUTPUTS@':len(values) if outputs is None else outputs,'@CHECK@':check,'@ROMS@':';'.join(f"roms[{i}]=64'h{v:016x}" for i,v in enumerate(values))+';','@PRE@':pre,'@ACTION@':action,'@CE@':ce}
 for a,b in pairs.items():tb=tb.replace(a,str(b))
 with tempfile.TemporaryDirectory(prefix='onewire_search_') as td:
  p=Path(td);(p/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',RTL,p/'tb.sv'],H,H/f'{label}_compile.log');out=execute(['vvp',p/'sim'],H,H/f'{label}_simulation.log');assert 'PASS ONEWIRE' in out
 print(label,out.splitlines()[0]);return dict(name=label,status='PASS',output=out)
def main():
 rows=[run('none',[]),run('single',[rom(0x123456789a28)]),run('multi',[rom(v) for v in [0x123456789a28,0x223456789a28,0x123456789b28,0x123456789a10]])]
 (H/'evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
