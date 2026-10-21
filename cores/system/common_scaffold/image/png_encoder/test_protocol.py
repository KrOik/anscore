"""Independent byte checks during recovery from all protocol/abort stages."""
import json,re,tempfile
from pathlib import Path
from run_tests import HERE,RTL,execute,hashes,png_oracle,inspect_actual
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0;reg[1:0]cfg_mode=0;
reg[23:0]s_pixel=0;reg s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
wire start_ready,s_ready,m_valid,m_sof,m_last,done_valid,done_error,busy;wire[7:0]m_data,error_code;wire[31:0]output_bytes;
png_encoder #(.WIDTH(4),.HEIGHT(3))dut(.*);
reg[7:0]gray[0:GLEN-1],rgb[0:RLEN-1];integer cyc=0,sent=0,got=0,j,k,bad=-1,healthy_frames=0;reg feeding=0,healthy=0,mode=0,pause_ce=0,pause_sink=0,stalled=0;reg[9:0]held;
wire[9:0]token={m_last,m_sof,m_data};
task tick;begin @(negedge clk);#1;end endtask
always @(negedge clk)begin
cyc=cyc+1;ce=!pause_ce&&cyc%11>1;m_ready=!pause_sink&&cyc%7<4;
s_valid=feeding&&sent<12&&cyc%5!=0;s_pixel=24'h102030+sent*24'h010203;
s_sof=sent==0;s_eol=sent%4==3;s_last=sent==11;
if(bad==0&&sent==0)s_sof=0;if(bad==1&&sent==2)s_sof=1;
if(bad==2&&sent==3)s_eol=0;if(bad==3&&sent==11)s_last=0;
if(bad==4&&sent==2)s_eol=1;if(bad==5&&sent==1)s_last=1;
if(cyc>500000)$fatal(1,"timeout %d %d %d",dut.state,sent,got);
end
always @(posedge clk)begin
if(!rst_n||abort)stalled=0;
else begin
if(stalled&&(!m_valid||token!==held))$fatal(1,"stable output");stalled=m_valid&&!(ce&&m_ready);held=token;
if(ce&&s_valid&&s_ready)sent=sent+1;
if(ce&&m_valid&&m_ready&&healthy)begin
if(m_data!==(mode?rgb[got]:gray[got])||m_sof!==(got==0)||m_last!==(got==(mode?RLEN:GLEN)-1))$fatal(1,"recovery byte %d",got);
got=got+1;
end
if(done_valid&&!done_error&&healthy&&(got!=(mode?RLEN:GLEN)||sent!=12))$fatal(1,"premature DONE");
end end
task start;input[1:0]m;input integer fault;input good;begin
feeding=0;healthy=good;mode=m==1;sent=0;got=0;bad=fault;cfg_mode=m;
start_valid=1;while(!start_ready)tick;@(posedge clk);#1;tick;start_valid=0;cfg_mode=3;feeding=1;
end endtask
task ack;input[7:0]code;begin
while(!done_valid)tick;feeding=0;
if(done_error!==(code!=0)||error_code!==code)$fatal(1,"done %h !=%h",error_code,code);
pause_ce=1;tick;abort=1;repeat(4)tick;if(!done_valid||error_code!==code)$fatal(1,"late abort DONE");abort=0;pause_ce=0;
repeat(7)tick;if(!done_valid||m_valid||error_code!==code)$fatal(1,"DONE hold");
done_ready=1;while(!ce)tick;@(posedge clk);#1;tick;done_ready=0;
end endtask
task recovery;begin
start(healthy_frames%2,-1,1);ack(0);
if(got!=(mode?RLEN:GLEN)||output_bytes!=(mode?RLEN:GLEN))$fatal(1,"recovery count");
healthy=0;healthy_frames=healthy_frames+1;
end endtask
initial begin
$readmemh("GRAYFILE",gray);$readmemh("RGBFILE",rgb);repeat(3)tick;rst_n=1;tick;
for(j=1;j<=15;j=j+1)begin
start(1,-1,0);while(dut.state!=j)tick;
pause_ce=1;ce=0;abort=1;#1;if(m_valid||s_ready||start_ready)$fatal(1,"abort gate");repeat(3)tick;
pause_ce=0;while(!ce)tick;@(posedge clk);#1;tick;abort=0;
ack(8'h93);recovery;
end
for(j=0;j<6;j=j+1)begin start(1,j,0);ack(8'h81);recovery;end
for(j=2;j<=3;j=j+1)begin start(j,-1,0);ack(8'h82);recovery;end
// The PNG final byte must be accepted before successful DONE.
start(1,-1,1);while(!(dut.state==15&&dut.index==3))tick;
pause_sink=1;m_ready=0;repeat(9)tick;if(done_valid||!m_valid||!m_last)$fatal(1,"last byte drain");pause_sink=0;ack(0);healthy=0;healthy_frames=healthy_frames+1;
// Reset with CE disabled, including a buffered multi-byte RGB pixel.
start(1,-1,0);while(!(dut.state==10&&dut.pixel_valid&&dut.channel==1))tick;
pause_ce=1;ce=0;rst_n=0;@(posedge clk);#1;if(m_valid||done_valid||busy)$fatal(1,"CE0 reset");tick;rst_n=1;pause_ce=0;feeding=0;recovery;
$display("PASS png_encoder protocol frames=%d",healthy_frames);$finish;
end endmodule
'''
def main():
 frozen=hashes();pixels=[0x102030+i*0x010203 for i in range(12)];expected=[png_oracle(pixels,4,3,m) for m in [0,1]]
 with tempfile.TemporaryDirectory(prefix='png_encoder_protocol_') as tmp:
  d=Path(tmp)
  for name,data in zip(['gray.hex','rgb.hex'],expected):(d/name).write_text('\n'.join(f'{v:02x}' for v in data)+'\n')
  replace={'GRAYFILE':(d/'gray.hex').as_posix(),'RGBFILE':(d/'rgb.hex').as_posix(),'GLEN':len(expected[0]),'RLEN':len(expected[1])}
  tb=re.sub(r'\b('+'|'.join(replace)+r')\b',lambda m:str(replace[m[0]]),TB);(d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],HERE,d/'compile.log');text=execute(['vvp',d/'a.vvp'],HERE,d/'sim.log');assert 'PASS png_encoder protocol' in text;print(text.strip())
 assert hashes()==frozen
 (HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,abort_states=list(range(1,16)),marker_errors=6,invalid_mode_errors=2,healthy_recovery_frames=25,healthy_pixels=300,reset_ce_disabled=True,final_byte_drain=True,runtime_gray_rgb_switch=True),indent=2)+'\n')
if __name__=='__main__':main()
