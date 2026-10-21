"""Actual color-frame RTL error/abort/lockout and disabled-CE reset recovery."""
from pathlib import Path
import sys,tempfile,json,hashlib,io
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
from test_jpeg_color_frame import SOURCES
from PIL import Image

TB=r"""
module tb;
localparam W=9,H=7,N=W*H;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,tv=0,tid=0,cv=0,start=0,abort_frame=0,sv=0,sof=0,eol=0,mr=0,dr=0,sampling=0;
reg [5:0] ti=0;reg [7:0] tq=8;reg [23:0] rgb=24'h808080;
reg [15:0] interval=1;
wire tr,cr,cd,cerr,str,sr,mv,ml,dv,busy;wire [7:0] md,error;
jpeg_color_frame #(.WIDTH(W),.HEIGHT(H)) dut(.clk(clk),.rst_n(rst_n),.ce(ce),.table_valid(tv),.table_ready(tr),.table_id(tid),.table_index(ti),.table_value(tq),.cfg_valid(cv),.cfg_ready(cr),.cfg_sampling_420(sampling),.cfg_restart_interval(interval),.cfg_done(cd),.cfg_error(cerr),.start_valid(start),.start_ready(str),.abort(abort_frame),.s_rgb(rgb),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),.m_data(md),.m_valid(mv),.m_last(ml),.m_ready(mr),.done_valid(dv),.done_ready(dr),.error_code(error),.busy(busy));
integer i,j,f,successes=0,case_id=0,cycles=0,bytes=0,lasts=0;
reg [31:0] rng=32'ha87452d1;reg random_enable=1,hold_output=0;
reg stalled=0,capture=0;reg [8:0] held;
always @(negedge clk)if(rst_n&&random_enable)begin
 rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};ce=rng[2:0]!=0;mr=hold_output?0:rng[6:3]!=0;
end
always @(posedge clk)begin
 cycles=cycles+1;if(cycles>3000000)$fatal(1,"global timeout");
 if(!rst_n||abort_frame)stalled=0;
 else begin
  if(stalled&&(!mv||{md,ml}!==held))$fatal(1,"output stability");stalled=mv&&(!ce||!mr);held={md,ml};
  if(ce&&mv&&mr&&capture)begin $fdisplay(f,"%02x",md);bytes=bytes+1;if(ml)lasts=lasts+1;end
 end
end
task tick;begin @(posedge clk);#1;@(negedge clk);#1;end endtask
task wait_enabled;begin while(!ce)tick;end endtask
task reset_disabled;begin
 random_enable=0;ce=0;mr=0;rst_n=0;tv=0;cv=0;start=0;abort_frame=0;sv=0;dr=0;tick;
 if(mv||dv||tr||cr||str||sr||busy||error)$fatal(1,"CE0 reset outputs");
 rst_n=1;tick;if(str||mv||dv)$fatal(1,"reset configuration");
 random_enable=1;tick;
end endtask
task configure;begin
 for(i=0;i<128;i=i+1)begin while(!tr)tick;tv=1;tid=i>=64;ti=i%64;tq=8;tick;tv=0;end
 while(!cr)tick;cv=1;tick;cv=0;while(!cd)tick;if(cerr)$fatal(1,"configure");tick;
end endtask
task start_frame;begin while(!str)tick;start=1;tick;start=0;end endtask
task send_pixel(input integer index,input badsof,badeol);begin
 while(!sr)tick;sv=1;sof=(index==0)^badsof;eol=(index%W==W-1)^badeol;tick;sv=0;
end endtask
task input_frame;begin for(j=0;j<N;j=j+1)send_pixel(j,0,0);end endtask
task held_terminal(input [7:0] expected);reg [7:0] saved;begin
 while(!dv)tick;
 if(error!==expected||mv||str||sr||cr||tr||!busy)$fatal(1,"terminal status");
 saved=error;
 cv=1;tv=1;start=1;sv=1;
 repeat(12)begin tick;if(!dv||error!==saved||mv||str||sr||cr||tr||!busy)$fatal(1,"held DONE/FAILED");end
 cv=0;tv=0;start=0;sv=0;
 wait_enabled;dr=1;tick;dr=0;
 if(expected!=0)begin
  if(dv||mv||str||sr||cr||tr||!busy||error!==saved)$fatal(1,"FAILED ACK lock");
  cv=1;tv=1;start=1;sv=1;
  repeat(15)begin tick;if(dv||mv||str||sr||cr||tr||!busy||error!==saved)$fatal(1,"lock persists");end
  cv=0;tv=0;start=0;sv=0;
 end else if(busy||dv||error!=0)$fatal(1,"success ACK");
end endtask
task success_frame;begin
 hold_output=0;capture=1;bytes=0;lasts=0;
 f=$fopen($sformatf("success_%0d.hex",successes),"w");start_frame;input_frame;
 while(!dv)tick;
 if(bytes<615||lasts!=1||error!=0)$fatal(1,"complete success file");
 capture=0;$fclose(f);held_terminal(0);successes=successes+1;
end endtask
task reset_and_success;begin reset_disabled;configure;success_frame;end endtask
initial begin
 @(negedge clk);tick;rst_n=1;tick;
 // Missing configuration is explicitly refused without emitting file bytes.
 wait_enabled;start=1;repeat(3)tick;start=0;if(str||mv||dv||busy)$fatal(1,"unconfigured start");
 configure;
 // Bad SOF at the first accepted pixel -> public raster failure 0x92.
 start_frame;send_pixel(0,1,0);held_terminal(8'h92);reset_and_success;
 // Bad EOL at the first accepted pixel -> same public raster failure.
 start_frame;send_pixel(0,0,1);held_terminal(8'h92);reset_and_success;
 // Abort a held header byte; no remaining header/entropy output is exposed.
 hold_output=1;start_frame;while(!mv)tick;wait_enabled;abort_frame=1;tick;abort_frame=0;held_terminal(8'h93);reset_and_success;
 // Abort while entropy is actually valid, after the header and raster capture.
 start_frame;input_frame;hold_output=1;while(!(dut.state==5&&mv))tick;wait_enabled;abort_frame=1;tick;abort_frame=0;held_terminal(8'h93);reset_and_success;
 // Disabled-CE reset while paired configuration is in flight.
 for(i=0;i<128;i=i+1)begin while(!tr)tick;tv=1;tid=i>=64;ti=i%64;tq=8;tick;tv=0;end
 while(!cr)tick;cv=1;tick;cv=0;repeat(9)tick;if(!busy)$fatal(1,"configuration stage not active");reset_and_success;
 // Disabled-CE reset on an actually held header output byte.
 hold_output=1;start_frame;while(!mv)tick;reset_and_success;
 // Disabled-CE reset during incomplete source raster capture.
 start_frame;send_pixel(0,0,0);send_pixel(1,0,0);reset_and_success;
 // Disabled-CE reset during DCT/entropy computation (after complete raster input).
 start_frame;input_frame;while(!dut.scan.dct.busy)tick;reset_and_success;
 // Disabled-CE reset with entropy output held valid.
 start_frame;input_frame;hold_output=1;while(!(dut.state==5&&mv))tick;reset_and_success;
 // Disabled-CE reset while EOI is held. Only EOI final byte has top m_last.
 start_frame;input_frame;while(dut.state!=7)tick;hold_output=1;while(!mv)tick;reset_and_success;
 // Disabled-CE reset during held successful DONE; reload then complete again.
 start_frame;input_frame;while(!dv)tick;reset_and_success;
 if(successes!=11)$fatal(1,"scenario count");
 $display("JPEG_COLOR_FRAME_ERRORS PASS failures=4 recovery_frames=%0d reset_stages=7",successes);$finish;
end
endmodule
"""

def profile(sampling):
    with tempfile.TemporaryDirectory(prefix='jpeg_color_frame_errors_') as temporary:
        td=Path(temporary);tb=TB.replace('sampling=0;','sampling='+str(sampling)+';')
        (td/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],td,td/'compile.log')
        output=execute(['vvp',td/'sim'],td,td/'simulation.log',timeout=180)
        assert 'JPEG_COLOR_FRAME_ERRORS PASS' in output,output
        counts=[]
        for index in range(11):
            data=bytes(int(x,16) for x in (td/f'success_{index}.hex').read_text().splitlines())
            assert data.startswith(b'\xff\xd8') and data.endswith(b'\xff\xd9')
            image=Image.open(io.BytesIO(data));image.load()
            assert image.size==(9,7) and image.mode=='RGB'
            assert max(abs(c-128) for pixel in image.get_flattened_data() for c in pixel)<=1
            counts.append(len(data))
    print(output.strip());return dict(sampling='420' if sampling else '444',failed_cases=4,recovery_frames_pillow_decoded=11,file_bytes=counts)

def main():
    profiles=[profile(mode) for mode in (0,1)]
    evidence=dict(status='PASS',profiles=profiles,raster_error_code='92',abort_error_code='93',failed_cases=8,recovery_frames_pillow_decoded=22,reset_stages=['configuration','header held output','partial raster capture','DCT computation','entropy held output','EOI held output','successful DONE'],disabled_ce_reset=True,failed_ack_lock_until_reset=True,held_terminal_stability=True,source_sha256={str(p.relative_to(HERE.parents[1])):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES})
    (HERE/'errors_evidence.json').write_text(json.dumps(evidence,indent=2)+'\n',encoding='utf-8')
    print('22 real RTL recovery JPEG files decoded; temporary artifacts removed')
if __name__=='__main__':main()
