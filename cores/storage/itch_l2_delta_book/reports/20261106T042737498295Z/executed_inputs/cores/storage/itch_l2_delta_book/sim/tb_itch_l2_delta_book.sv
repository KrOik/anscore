`timescale 1ns/1ps
module tb_itch_l2_delta_book;
 parameter N=7,T=8;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,r_ready=0;wire c_ready,r_valid,busy,faulted;
 reg [2:0] c_op=0;reg c_remove_valid=0,c_remove_sell=0,c_add_valid=0,c_add_sell=0;
 reg [31:0] c_remove_price=0,c_remove_quantity=0,c_add_price=0,c_add_quantity=0;
 reg [63:0] c_sequence=0;reg [T-1:0] c_tag=0;
 wire [2:0] r_op;wire [3:0] r_status;wire [63:0] r_sequence;wire [T-1:0] r_tag;
 wire r_found,r_bid_valid,r_ask_valid,r_bid_changed,r_ask_changed,r_crossed;
 wire [37:0] r_quantity,r_remove_before,r_remove_after,r_add_before,r_add_after,r_bid_quantity,r_ask_quantity;
 wire [31:0] r_bid_price,r_ask_price,r_bid_levels,r_ask_levels;
 itch_l2_delta_book #(.LEVELS(N),.TAG_W(T)) dut(.*);
 wire [471+T:0] payload={r_op,r_status,r_sequence,r_tag,r_found,r_quantity,r_remove_before,r_remove_after,r_add_before,r_add_after,
  r_bid_valid,r_bid_price,r_bid_quantity,r_ask_valid,r_ask_price,r_ask_quantity,r_bid_changed,r_ask_changed,r_bid_levels,r_ask_levels,r_crossed,faulted};
 reg [471+T:0] expected_payload,held;
 wire [198+T:0] source_payload={c_op,c_remove_valid,c_remove_sell,c_remove_price,c_remove_quantity,c_add_valid,c_add_sell,c_add_price,c_add_quantity,c_sequence,c_tag};
 reg [198+T:0] source_held;reg was_blocked=0;
 integer fd,rv,marker,phase,op,remv,rems,addv,adds,entries,i,j,seen[0:N-1],nsides[0:N-1];
 reg [31:0] remp,remq,addp,addq,nprices[0:N-1];reg [37:0] nquantities[0:N-1];
 reg [63:0] seq;reg [T-1:0] tag;reg [71:0] row;
 reg have=0,offered=0;integer cycles=0,commands=0,holds=0,preoffers=0,resets=0,matched,total;
 string vectors;
 always @(negedge clk)begin cycles=cycles+1;if(cycles>1500000)$fatal(1,"cycle watchdog");end
 always @(posedge clk)if(!rst)begin
  if(was_blocked && (!c_valid || source_payload!==source_held))$fatal(1,"source withdrew or changed blocked command");
  was_blocked=c_valid&&!c_ready;source_held=source_payload;
 end
 task reset_core;
  begin
   rst=1;c_valid=0;r_ready=0;offered=0;was_blocked=0;
   repeat(2)@(posedge clk);@(negedge clk);rst=0;resets=resets+1;
   @(posedge clk);if(!c_ready || r_valid || faulted || r_bid_valid || r_ask_valid || dut.live!=0)$fatal(1,"reset epoch");
  end
 endtask
 task load_record;
  begin
   rv=$fscanf(fd,"%d",marker);have=rv==1;
   if(have)begin
    if(marker==1)begin rv=$fscanf(fd,"%d",phase);if(rv!=1)$fatal(1,"reset record");end
    else if(marker!=0)$fatal(1,"marker");
    rv=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d",op,remv,rems,remp,remq,addv,adds,addp,addq,seq,tag);if(rv!=11)$fatal(1,"command record");
    if(marker==0)begin
     rv=$fscanf(fd,"%d %d",expected_payload,entries);if(rv!=2 || entries>N)$fatal(1,"expectation");
     for(j=0;j<entries;j=j+1)begin rv=$fscanf(fd,"%d %d %d",nsides[j],nprices[j],nquantities[j]);if(rv!=3)$fatal(1,"state record");end
    end
   end
  end
 endtask
 task offer_current;
  begin
   @(negedge clk);c_valid=1;c_op=op;c_remove_valid=remv;c_remove_sell=rems;c_remove_price=remp;c_remove_quantity=remq;
   c_add_valid=addv;c_add_sell=adds;c_add_price=addp;c_add_quantity=addq;c_sequence=seq;c_tag=tag;offered=1;
  end
 endtask
 task accept_current;
  begin
   if(!offered)offer_current();do @(posedge clk);while(!c_ready);
   @(negedge clk);c_valid=0;offered=0;
  end
 endtask
 task check_store;
  begin
   total=0;for(j=0;j<entries;j=j+1)seen[j]=0;
   for(i=0;i<N;i=i+1)if(dut.live[i])begin
    total=total+1;row=dut.storage.mem[i];matched=0;
    for(j=0;j<entries;j=j+1)if(nsides[j]==row[70] && nprices[j]==row[69:38])begin
     if(row[71]!==0 || row[37:0]!==nquantities[j])$fatal(1,"stored level value");seen[j]=seen[j]+1;matched=matched+1;
    end
    if(matched!=1)$fatal(1,"unexpected stored level");
   end
   if(total!=entries)$fatal(1,"live level count");
   for(j=0;j<entries;j=j+1)if(seen[j]!=1)$fatal(1,"missing or duplicate level");
  end
 endtask
 initial begin
  if(!$value$plusargs("vectors=%s",vectors))$fatal(1,"vectors required");fd=$fopen(vectors,"r");if(!fd)$fatal(1,"file missing");
  reset_core();load_record();
  while(have)begin
   accept_current();
   if(marker==1)begin
    if(phase==0)begin while(dut.state!=2)@(negedge clk);end
    else if(phase==1)begin while(dut.state!=(N==1?12:10))@(negedge clk);end
    else begin while(!r_valid)@(negedge clk);repeat(3)@(negedge clk);end
    reset_core();load_record();
   end else begin
    while(!r_valid)@(posedge clk);
    if(payload!==expected_payload)$fatal(1,"response %0d op%0d status%0d got%h expected%h",commands,r_op,r_status,payload,expected_payload);
    check_store();held=payload;
    repeat(3)begin @(posedge clk);if(!r_valid||payload!==held||c_ready)$fatal(1,"held response");holds=holds+1;end
    commands=commands+1;load_record();if(have && marker==0)begin offer_current();preoffers=preoffers+1;end
    repeat(3)begin @(posedge clk);if(!r_valid||payload!==held||c_ready)$fatal(1,"future offer corrupted response");holds=holds+1;end
    @(negedge clk);r_ready=1;@(posedge clk);@(negedge clk);r_ready=0;
   end
  end
  repeat(5)@(posedge clk);if(r_valid)$fatal(1,"trailing response");
  $display("PASS itch_l2_delta_book N=%0d T=%0d commands=%0d holds=%0d preoffers=%0d resets=%0d cycles=%0d",N,T,commands,holds,preoffers,resets,cycles);$finish;
 end
endmodule
