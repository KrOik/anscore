`timescale 1ns/1ps
module tb_watermark_event_merge;
 parameter F=4,D=128,T=8;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,r_ready=0;wire c_ready,r_valid,faulted,busy;
 reg [3:0] c_op;reg [31:0] c_feed;reg [63:0] c_time,c_sequence;reg [D-1:0] c_data;reg [T-1:0] c_tag;
 wire [3:0] r_op,r_status;wire [31:0] r_feed,r_blocked_feed,r_heads;
 wire [63:0] r_time,r_sequence,r_previous_time,r_previous_sequence,r_watermark;wire [D-1:0] r_data;wire [T-1:0] r_tag;
 wire r_head,r_closed,r_has_previous,r_has_watermark,r_end;
 watermark_event_merge #(.FEEDS(F),.DATA_W(D),.TAG_W(T)) dut(.*);
 localparam PW=4+4+32+32+64+64+D+T+4+64+64+64+32+2;
 wire [PW-1:0] payload={r_op,r_status,r_feed,r_blocked_feed,r_time,r_sequence,r_data,r_tag,r_head,r_closed,r_has_previous,r_has_watermark,r_previous_time,r_previous_sequence,r_watermark,r_heads,r_end,faulted};
 wire [3+32+64+64+D+T:0] source_payload={c_op,c_feed,c_time,c_sequence,c_data,c_tag};
 reg source_held=0;reg [3+32+64+64+D+T:0] source_saved;
 always @(posedge clk)begin
  if(rst)source_held<=0;
  else begin
   if(source_held && (!c_valid || source_payload!==source_saved))$fatal(1,"withdrawn/changed actual future source");
   source_held<=c_valid && !c_ready;if(c_valid && !c_ready)source_saved<=source_payload;
  end
 end
 integer fd,rv,marker,phase,op,feed,have,j,k,timeout,commands=0,holds=0,preoffers=0,future_gets=0,resets=0,cycles=0;
 reg [63:0] time_value,sequence_value;reg [D-1:0] data_value;reg [T-1:0] tag_value;
 reg [PW-1:0] expected,held;
 integer eh[0:F-1],ec[0:F-1],ep[0:F-1],ew[0:F-1];
 reg [63:0] et[0:F-1],es[0:F-1],wm[0:F-1],ht[0:F-1],hs[0:F-1];reg [D-1:0] hd[0:F-1];
 reg [160:0] row;integer seen[0:F-1];reg [31:0] id;
 string vector_file;
 task load_record;
  begin
   rv=$fscanf(fd,"%d",marker);have=rv==1;
   if(have)begin
    phase=0;if(marker==1)begin rv=$fscanf(fd,"%d",phase);if(rv!=1)$fatal(1,"reset phase");end
    else if(marker!=0)$fatal(1,"marker");
    rv=$fscanf(fd,"%d %d %d %d %d %d",op,feed,time_value,sequence_value,data_value,tag_value);if(rv!=6)$fatal(1,"command record");
    if(marker==0)begin
     rv=$fscanf(fd,"%d",expected);if(rv!=1)$fatal(1,"expected response");
     for(j=0;j<F;j=j+1)begin
      rv=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d",eh[j],ec[j],ep[j],ew[j],et[j],es[j],wm[j],ht[j],hs[j],hd[j]);if(rv!=10)$fatal(1,"state row");
     end
    end
   end
  end
 endtask
 task offer;
  begin c_op=op[3:0];c_feed=feed;c_time=time_value;c_sequence=sequence_value;c_data=data_value;c_tag=tag_value;c_valid=1;end
 endtask
 task reset_now;
  begin rst=1;c_valid=0;r_ready=0;@(posedge clk);@(negedge clk);rst=0;resets=resets+1;repeat(F+2)@(negedge clk);if(r_valid)$fatal(1,"stale reset result");end
 endtask
 task check_state;
  begin
   for(j=0;j<F;j=j+1)begin
    seen[j]=0;
    if(dut.heads[j]!==eh[j][0] || dut.closed[j]!==ec[j][0] || dut.previous_valid[j]!==ep[j][0] || dut.watermark_valid[j]!==ew[j][0])$fatal(1,"metadata flags cmd%0d feed%0d",commands,j);
    if(ep[j] && dut.feed_metadata.mem[j][191:64]!=={et[j],es[j]})$fatal(1,"previous record");
    if(ew[j] && dut.feed_metadata.mem[j][63:0]!==wm[j])$fatal(1,"watermark record");
    if(eh[j] && dut.head_payload.mem[j]!==hd[j])$fatal(1,"head payload");
   end
   for(j=0;j<F;j=j+1)begin
    row=dut.calendar.rows[j];
    if(row[160])begin
     id=row[159:128];if(id>=F)$fatal(1,"calendar ID");
     if(!eh[id] || seen[id] || row[127:64]!==ht[id] || row[63:0]!==hs[id])$fatal(1,"calendar logical head");seen[id]=1;
    end
   end
   for(j=0;j<F;j=j+1)if(seen[j]!=eh[j])$fatal(1,"missing calendar head");
  end
 endtask
 reg reached;
 initial begin
  if(!$value$plusargs("vectors=%s",vector_file))$fatal(1,"missing vectors");fd=$fopen(vector_file,"r");if(!fd)$fatal(1,"vectors open");
  @(negedge clk);reset_now();load_record();
  while(have)begin
   offer();timeout=0;
   begin:accept_command
    forever begin @(posedge clk);if(c_ready)disable accept_command;timeout=timeout+1;if(timeout>8*F+40)$fatal(1,"source acceptance timeout");end
   end
   @(negedge clk);c_valid=0;
   if(marker==1)begin
    reached=0;timeout=0;
    while(!reached)begin
     case(phase)
      1:reached=dut.state==4;
      2:reached=dut.state==6;
      3:reached=dut.state==9 && dut.backend_op==0 && dut.calendar.state==5;
      4:reached=dut.state==9 && dut.backend_op==3 && dut.bm_valid;
      5:reached=r_valid;
      default:$fatal(1,"bad live phase");
     endcase
     if(!reached)begin @(negedge clk);timeout=timeout+1;if(timeout>8*F+40)$fatal(1,"reset phase unreachable%0d",phase);end
    end
    reset_now();load_record();
   end else begin
    timeout=0;while(!r_valid)begin @(negedge clk);timeout=timeout+1;if(timeout>8*F+24)$fatal(1,"first response bound");end
    if(payload!==expected)$fatal(1,"response cmd%0d op%0d status%0d got%h expected%h",commands,r_op,r_status,payload,expected);
    check_state();held=payload;
    repeat(3)begin @(posedge clk);if(!r_valid || payload!==held || c_ready || !busy)$fatal(1,"held result");holds=holds+1;end
    @(negedge clk);commands=commands+1;load_record();
    if(have && marker==0)begin offer();preoffers=preoffers+1;if(op==4)future_gets=future_gets+1;end
    repeat(3)begin @(posedge clk);if(!r_valid || payload!==held || c_ready)$fatal(1,"actual future corrupted result");holds=holds+1;end
    @(negedge clk);r_ready=1;@(posedge clk);@(negedge clk);r_ready=0;
   end
  end
  repeat(4)@(posedge clk);if(r_valid)$fatal(1,"trailing result");$fclose(fd);
  if(future_gets<180)$fatal(1,"missing actual future GETs");
  $display("PASS watermark_event_merge F=%0d D=%0d T=%0d commands=%0d holds=%0d preoffers=%0d future_gets=%0d resets=%0d cycles=%0d",F,D,T,commands,holds,preoffers,future_gets,resets,cycles);$finish;
 end
 always @(posedge clk)begin cycles<=cycles+1;if(cycles>400000)$fatal(1,"whole TB watchdog");end
endmodule
