"""Independent pin-only 8080 panel BFM, host scoreboard and RGB565 window chain."""
from pathlib import Path
import hashlib,json,os,shutil,subprocess,tempfile
HERE=Path(__file__).resolve().parent
SOURCE=HERE/'lcd8080_engine.sv'
def hashes(): return {SOURCE.name:hashlib.sha256(SOURCE.read_bytes()).hexdigest()}
def tool(n):
 local=HERE.parents[3]/'tools/oss-cad-suite/oss-cad-suite/bin'/(n+'.exe')
 if local.exists():return str(local)
 p=shutil.which(n)
 if p:return p
 roots=[Path('C:/oss-cad-suite/bin'),Path('D:/oss-cad-suite/bin'),Path('C:/tools/oss-cad-suite/bin')]
 for root in roots:
  for ext in ['.exe','.cmd','']:
   if (root/(n+ext)).exists():return str(root/(n+ext))
 raise RuntimeError('Missing '+n)
def execute(cmd,cwd,log,timeout=120):
 env=os.environ.copy();oss=HERE.parents[3]/'tools/oss-cad-suite/oss-cad-suite';env['PATH']=str(oss/'bin')+os.pathsep+str(oss/'lib')+os.pathsep+env.get('PATH','')
 r=subprocess.run([str(x) for x in cmd],cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout)
 log.write_text(r.stdout)
 if r.returncode: raise RuntimeError(r.stdout)
 return r.stdout
TB=r'''
`timescale 1ns/1ps
module tb;
localparam W=@WIDTH@;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,read_mode=0,data_mode=0;
wire start_ready,tx_ready,rx_valid,rx_last,busy,done_valid;
reg [15:0] count=0,cfg_setup=2,cfg_pulse=3,cfg_hold=2,cfg_turnaround=2;
reg [31:0] cfg_timeout=0;reg tx_valid=0;reg [W-1:0] tx_data=0;
reg rx_ready=0,abort=0,done_ready=0;
wire [W-1:0] rx_data,lcd_data_out;wire [7:0] error_code;
wire lcd_cs_n,lcd_rd_n,lcd_wr_n,lcd_rs,lcd_data_oe;
reg [W-1:0] panel_input=0;
lcd8080_engine #(.BUS_WIDTH(W)) d(.clk(clk),.rst_n(rst_n),.ce(ce),
.start_valid(start_valid),.start_ready(start_ready),.read_mode(read_mode),.data_mode(data_mode),.count(count),
.cfg_setup(cfg_setup),.cfg_pulse(cfg_pulse),.cfg_hold(cfg_hold),.cfg_turnaround(cfg_turnaround),.cfg_timeout(cfg_timeout),
.tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_data),.rx_valid(rx_valid),.rx_ready(rx_ready),.rx_data(rx_data),.rx_last(rx_last),
.abort(abort),.busy(busy),.done_valid(done_valid),.done_ready(done_ready),.error_code(error_code),
.lcd_cs_n(lcd_cs_n),.lcd_rd_n(lcd_rd_n),.lcd_wr_n(lcd_wr_n),.lcd_rs(lcd_rs),
.lcd_data_out(lcd_data_out),.lcd_data_oe(lcd_data_oe),.lcd_data_in(panel_input));
// The panel oracle never accesses DUT state/counters. Expectations describe bus transactions.
integer cycle=0,exp_count=0,observed=0,setup_seen=0,pulse_seen=0,hold_seen=0,gap_seen=100000;
integer es[0:20000],ep[0:20000],eh[0:20000],et[0:20000];
reg er[0:20000],ers[0:20000];reg [W-1:0] ed[0:20000];
reg selected=0,strobed=0,pulsed=0,was_strobe=0,ce_gaps=1,force_ce_off=0;
integer jobs=0,reads=0,writes=0,checks=0;
integer command=0,param_index=0,x_start=0,x_end=0,y_start=0,y_end=0,pixel_index=0;
integer byte_hi=0,byte_pending=0,frame_pixels=0,panel_word=0,expected_rgb=0;
reg [W-1:0] sampled_write;
reg stalled=0;reg [W:0] stalled_word;
always @(negedge clk) begin
 cycle=cycle+1;
 ce=force_ce_off?0:ce_gaps?((cycle%7)!=0&&(cycle%7)!=1):1;
 if(observed<exp_count)panel_input=ed[observed];else panel_input=0;
end
always @(posedge clk) if(rst_n) begin
 if(!lcd_rd_n&&!lcd_wr_n)$fatal(1,"RD WR overlap");
 if(lcd_cs_n) begin
  if(!lcd_rd_n||!lcd_wr_n||lcd_data_oe)$fatal(1,"idle/turn bus not released");
  if(selected) begin
   if(setup_seen!=es[observed]||pulse_seen!=ep[observed]||hold_seen!=eh[observed])
    $fatal(1,"pin durations beat%0d setup%0d/%0d pulse%0d/%0d hold%0d/%0d",observed,setup_seen,es[observed],pulse_seen,ep[observed],hold_seen,eh[observed]);
   if(!pulsed)$fatal(1,"selected cycle no strobe");
   if(er[observed])reads=reads+1;else begin
    writes=writes+1;
    // Minimal independent DCS panel: parse actual command/address/pixel bus data.
    if(!ers[observed])begin
     command=sampled_write&255;param_index=0;
     if(command=='h2c) begin
      if(x_start!=0||x_end!=7||y_start!=0||y_end!=5)$fatal(1,"DCS window address");
      pixel_index=0;byte_pending=0;
     end
    end else if(command=='h2a||command=='h2b)begin
     if(param_index>=4)$fatal(1,"too many address bytes");
     if(command=='h2a)begin
      if(param_index<2)x_start=((x_start<<8)|(sampled_write&255))&65535;
      else x_end=((x_end<<8)|(sampled_write&255))&65535;
     end else begin
      if(param_index<2)y_start=((y_start<<8)|(sampled_write&255))&65535;
      else y_end=((y_end<<8)|(sampled_write&255))&65535;
     end
     param_index=param_index+1;
    end else if(command=='h2c&&pixel_index<48)begin
     if(W==8&&!byte_pending)begin byte_hi=sampled_write;byte_pending=1;end
     else begin
      panel_word=W==8?(byte_hi<<8)|sampled_write:sampled_write;
      expected_rgb=((pixel_index*1301)^16'h5a69)&65535;
      if(panel_word!=expected_rgb)$fatal(1,"panel RGB565 pixel %0d",pixel_index);
      pixel_index=pixel_index+1;frame_pixels=frame_pixels+1;byte_pending=0;
     end
    end
   end
   observed=observed+1;selected=0;gap_seen=0;
  end
  gap_seen=gap_seen+1;
 end else begin
  if(observed>=exp_count)$fatal(1,"unexpected bus cycle");
  if(!selected) begin
   if(gap_seen<et[observed])$fatal(1,"turnaround too short");
   selected=1;setup_seen=0;pulse_seen=0;hold_seen=0;pulsed=0;
  end
  if(lcd_rs!==ers[observed]||lcd_data_oe!==!er[observed])$fatal(1,"RS or direction");
  if(!er[observed]&&lcd_data_out!==ed[observed])$fatal(1,"write pin mismatch beat%0d",observed);
  sampled_write=lcd_data_out;
  if(!lcd_rd_n||!lcd_wr_n) begin
   if((!lcd_rd_n)!==er[observed])$fatal(1,"wrong strobe");
   if(hold_seen!=0)$fatal(1,"strobe reassertion");
   pulsed=1;pulse_seen=pulse_seen+1;
  end else if(!pulsed)setup_seen=setup_seen+1;
  else hold_seen=hold_seen+1;
 end
 if(stalled&&(!rx_valid||{rx_last,rx_data}!==stalled_word))$fatal(1,"RX changed while host stalled");
 stalled=rx_valid&&!(ce&&rx_ready);
 stalled_word={rx_last,rx_data};
end else begin selected=0;stalled=0;gap_seen=100000;end
task expect_beat(input bit r,input bit rs,input integer word);
 begin er[exp_count]=r;ers[exp_count]=rs;ed[exp_count]=word;
 es[exp_count]=cfg_setup;ep[exp_count]=cfg_pulse;eh[exp_count]=cfg_hold;et[exp_count]=cfg_turnaround;exp_count=exp_count+1;end
endtask
task launch(input bit r,input bit rs,input integer n);
 begin
 @(negedge clk);#1;read_mode=r;data_mode=rs;count=n;start_valid=1;
 begin:accept_start
 forever begin @(posedge clk);if(ce&&start_ready)begin #1;disable accept_start;end end
 end
 @(negedge clk);#1;start_valid=0;jobs=jobs+1;
 end
endtask
task send_word(input integer word);
 begin
 @(negedge clk);#1;tx_data=word;tx_valid=1;
 begin:accepted_tx
 forever begin @(posedge clk);if(ce&&tx_ready)begin #1;disable accepted_tx;end end
 end
 @(negedge clk);#1;tx_valid=0;
 end
endtask
task get_word(input integer word,input bit last);
 begin
 wait(rx_valid);repeat(6)@(negedge clk);
 #1;if(rx_data!==(W'(word))||rx_last!==last)$fatal(1,"read sample or last mismatch");
 rx_ready=1;
 begin:accepted_rx
 forever begin @(posedge clk);if(ce&&rx_valid)begin #1;disable accepted_rx;end end
 end
 @(negedge clk);#1;rx_ready=0;
 end
endtask
task finish_job(input integer err);
 begin wait(done_valid);@(negedge clk);#1;
 if(error_code!==err||busy||!lcd_cs_n||lcd_data_oe)$fatal(1,"completion err%0d expected%0d",error_code,err);
 repeat(3)@(negedge clk);#1;if(!done_valid||error_code!==err)$fatal(1,"DONE not sticky");
 done_ready=1;
 begin:ack_done
 forever begin @(posedge clk);if(ce&&done_valid)begin #1;disable ack_done;end end
 end
 @(negedge clk);#1;done_ready=0;checks=checks+1;
 end
endtask
task write_job(input bit rs,input integer n,input integer base);
 integer k;
 begin for(k=0;k<n;k=k+1)expect_beat(0,rs,base+k);
 launch(0,rs,n);for(k=0;k<n;k=k+1)send_word(base+k);finish_job(0);end
endtask
integer i,j;
initial begin
 repeat(3)@(negedge clk);#1;rst_n=1;
 // Command, data and long bursts, minimum/unequal physical timing under CE gaps.
 write_job(0,1,'h11);write_job(1,7,'h39);
 cfg_setup=1;cfg_pulse=1;cfg_hold=1;cfg_turnaround=1;write_job(1,33,'h83);
 cfg_setup=3;cfg_pulse=5;cfg_hold=4;cfg_turnaround=6;
 for(i=0;i<11;i=i+1)expect_beat(1,1,'ha1+i);
 launch(1,1,11);for(i=0;i<11;i=i+1)get_word('ha1+i,i==10);finish_job(0);
 // Real DCS window command chain and RGB565 8x6 frame (MSB byte first on 8-bit bus).
 cfg_setup=2;cfg_pulse=3;cfg_hold=2;cfg_turnaround=2;
 write_job(0,1,'h2a);write_job(1,1,0);write_job(1,1,0);write_job(1,1,0);write_job(1,1,7);
 write_job(0,1,'h2b);write_job(1,1,0);write_job(1,1,0);write_job(1,1,0);write_job(1,1,5);
 write_job(0,1,'h2c);
 for(i=0;i<48;i=i+1)begin
  j=((i*1301)^16'h5a69)&65535;
  if(W==8)begin expect_beat(0,1,j>>8);expect_beat(0,1,j&255);end
  else expect_beat(0,1,j);
 end
 launch(0,1,W==8?96:48);
 for(i=0;i<48;i=i+1)begin
  j=((i*1301)^16'h5a69)&65535;
  if(W==8)begin send_word(j>>8);send_word(j&255);end else send_word(j);
 end
 finish_job(0);
 // No data before timeout; invalid runtime timing/count; no physical cycle.
 cfg_timeout=15;launch(0,1,1);finish_job(2);cfg_timeout=0;
 cfg_pulse=0;launch(0,1,1);finish_job(1);cfg_pulse=3;
 cfg_setup=0;launch(0,1,1);finish_job(1);cfg_setup=2;
 cfg_hold=0;launch(0,1,1);finish_job(1);cfg_hold=2;
 cfg_turnaround=0;launch(0,1,1);finish_job(1);cfg_turnaround=2;
 launch(0,1,0);finish_job(1);
 // Abort in the pulse: physical low width and hold finish, queued burst cancelled.
 cfg_pulse=12;expect_beat(0,1,'he7);launch(0,1,9);send_word('he7);
 wait(!lcd_wr_n);@(negedge clk);#1;abort=1;
 wait(ce);@(posedge clk);#1;@(negedge clk);#1;abort=0;finish_job(3);
 // Timeout occurring in active pulse cannot shorten physical waveform.
 cfg_timeout=8;cfg_pulse=15;expect_beat(1,0,'h91);launch(1,0,2);finish_job(2);cfg_timeout=0;
 // Exposed read token survives abort and timeout until host accepts it.
 cfg_timeout=0;cfg_pulse=2;expect_beat(1,1,'h79);launch(1,1,5);
 wait(rx_valid);@(negedge clk);#1;abort=1;
 begin:abort_accepted forever begin @(posedge clk);if(ce)begin #1;disable abort_accepted;end end end
 @(negedge clk);#1;abort=0;force_ce_off=1;rx_ready=1;
 repeat(8)@(negedge clk);#1;if(done_valid||!rx_valid||!busy)$fatal(1,"abort failed RX preservation");
 rx_ready=0;force_ce_off=0;get_word('h79,0);finish_job(3);
 cfg_timeout=60;expect_beat(1,0,'h48);launch(1,0,3);wait(rx_valid);
 repeat(80)@(negedge clk);#1;if(done_valid||!rx_valid||!busy)$fatal(1,"timeout failed RX preservation");
 get_word('h48,0);finish_job(2);cfg_timeout=0;
 // Normal read immediately after cancelled write/read proves turnaround and restart.
 cfg_pulse=2;expect_beat(1,0,'h6e);launch(1,0,1);get_word('h6e,1);finish_job(0);
 // CE=0 host requests must not launch or acknowledge; reset overrides CE.
 ce_gaps=0;@(negedge clk);#1;ce_gaps=0;ce=0;start_valid=1;
 repeat(4)begin @(posedge clk);#1;if(busy||!lcd_cs_n)$fatal(1,"CE-off start accepted");@(negedge clk);#1;ce=0;end
 start_valid=0;rst_n=0;@(posedge clk);#1;if(!start_ready||busy||rx_valid||done_valid)$fatal(1,"reset");
 @(negedge clk);#1;rst_n=1;ce=1;ce_gaps=1;
 write_job(1,1,'h47);
 @(negedge clk);#1;
 if(observed!=exp_count||frame_pixels!=48)$fatal(1,"missing physical cycles or RGB frame %0d/%0d pixels%0d",observed,exp_count,frame_pixels);
 $display("PASS LCD8080 width=%0d jobs=%0d checks=%0d writes=%0d reads=%0d beats=%0d RGB565=48 CEgaps=1",W,jobs,checks,writes,reads,observed);
 $finish;
end
initial begin #10000000;$fatal(1,"watchdog");end
endmodule
'''
def run_tb(label,tb,marker='PASS LCD8080'):
 with tempfile.TemporaryDirectory(prefix='lcd8080_',dir=os.environ.get('TEMP')) as td:
  p=Path(td);(p/'tb.sv').write_text(tb)
  execute([tool('iverilog'),'-g2012','-s','tb','-o',p/'sim',SOURCE,p/'tb.sv'],HERE,p/'compile.log')
  out=execute([tool('vvp'),p/'sim'],HERE,p/'run.log');(HERE/f'simulation_{label}.log').write_text(out)
  assert marker in out
  print(out,flush=True);return dict(profile=label,output=out)
def run(width):return run_tb(str(width),TB.replace('@WIDTH@',str(width)))
def main():
 frozen=hashes();rows=[run(w) for w in (8,16)];assert hashes()==frozen
 (HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
