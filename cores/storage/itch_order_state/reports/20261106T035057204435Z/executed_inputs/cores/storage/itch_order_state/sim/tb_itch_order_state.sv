`timescale 1ns/1ps
module tb_itch_order_state;
 parameter N=8,T=8;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,e_valid=0,r_ready=0;
 reg [1:0] c_op=0;reg [15:0] c_locate=0,e_locate=0;
 reg [63:0] c_stock=0,c_order=0,e_order=0,e_new_order=0,e_stock=0,e_sequence=0;
 reg [T-1:0] c_tag=0,e_tag=0;reg [7:0] e_type=0;reg e_sell=0;
 reg [31:0] e_quantity=0,e_price=0;
 wire c_ready,e_ready,r_valid,r_admin,r_old_valid,r_old_sell,r_new_valid,r_new_sell,r_remove_valid,r_add_valid,configured,faulted,busy;
 wire [7:0] r_op;wire [3:0] r_status;wire [63:0] r_request_order,r_sequence,r_old_order,r_new_order;
 wire [T-1:0] r_tag;wire [31:0] r_old_price,r_old_quantity,r_new_price,r_new_quantity,r_remove_quantity,r_count,r_bid_orders,r_ask_orders;
 itch_order_state #(.ORDERS(N),.TAG_W(T)) dut(.*);
 wire [532+T:0] payload={r_admin,r_op,r_status,r_request_order,r_sequence,r_tag,r_old_valid,r_old_sell,r_old_order,r_old_price,r_old_quantity,r_new_valid,r_new_sell,r_new_order,r_new_price,r_new_quantity,r_remove_valid,r_remove_quantity,r_add_valid,r_count,r_bid_orders,r_ask_orders,configured,faulted};
 reg [532+T:0] expected_payload,held;
 integer fd,rv,op,phase,entries,k,i,s,j,live_count,matched;
 reg [63:0] ids[0:N-1];integer sides[0:N-1];reg [31:0] prices[0:N-1],quantities[0:N-1];
 integer seen[0:N-1];
 reg [127:0] actual;reg [1:0] slot;
 integer n_op,kind,loc,sellv;reg [63:0] stockv,idv,newv,seqv;reg [31:0] qtyv,pricev;reg [T-1:0] tagv;
 integer cycles=0,commands=0,resets=0,holds=0,preoffers=0;
 reg have=0,offered=0,chold=0,ehold=0;
 reg [2+16+64+64+T-1:0] c_held;
 reg [7+16+64+64+1+32+32+64+64+T:0] e_held;
 wire [2+16+64+64+T-1:0] c_payload={c_op,c_locate,c_stock,c_order,c_tag};
 wire [7+16+64+64+1+32+32+64+64+T:0] e_payload={e_type,e_locate,e_order,e_new_order,e_sell,e_quantity,e_price,e_stock,e_sequence,e_tag};
 string vectors;
 always @(negedge clk)begin cycles=cycles+1;if(cycles>1500000)$fatal(1,"bounded watchdog");end
 always @(posedge clk)if(!rst)begin
  if(chold && (!c_valid || c_payload!==c_held))$fatal(1,"admin source changed while blocked");
  if(ehold && (!e_valid || e_payload!==e_held))$fatal(1,"event source changed while blocked");
  chold=c_valid&&!c_ready;c_held=c_payload;ehold=e_valid&&!e_ready;e_held=e_payload;
 end
 task reset_core;
  begin
   @(negedge clk);rst=1;c_valid=0;e_valid=0;r_ready=0;chold=0;ehold=0;offered=0;
   repeat(2)@(posedge clk);@(negedge clk);rst=0;resets=resets+1;
   do @(posedge clk);while(!c_ready);
   if(configured||faulted||r_valid||r_count!=0)$fatal(1,"reset epoch");
  end
 endtask
 task load_record;
  begin
   rv=$fscanf(fd,"%d",op);have=rv==1;
   if(have)begin
    if(op==0)begin
     rv=$fscanf(fd,"%d %d %d %d %d",n_op,loc,stockv,idv,tagv);if(rv!=5)$fatal(1,"admin record");
    end else if(op==1 || op==2)begin
     if(op==2)begin rv=$fscanf(fd,"%d",phase);if(rv!=1)$fatal(1,"phase record");end
     rv=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d",kind,loc,idv,newv,sellv,qtyv,pricev,stockv,seqv,tagv);if(rv!=10)$fatal(1,"event record");
    end else $fatal(1,"bad opcode");
    if(op!=2)begin
     rv=$fscanf(fd,"%d %d",expected_payload,entries);if(rv!=2 || entries>N)$fatal(1,"expected record");
     for(k=0;k<entries;k=k+1)begin rv=$fscanf(fd,"%d %d %d %d",ids[k],sides[k],prices[k],quantities[k]);if(rv!=4)$fatal(1,"state record");end
    end
   end
  end
 endtask
 task offer_current;
  begin
   @(negedge clk);
   if(op==0)begin c_valid=1;c_op=n_op;c_locate=loc;c_stock=stockv;c_order=idv;c_tag=tagv;end
   else begin e_valid=1;e_type=kind;e_locate=loc;e_order=idv;e_new_order=newv;e_sell=sellv;e_quantity=qtyv;e_price=pricev;e_stock=stockv;e_sequence=seqv;e_tag=tagv;end
   offered=1;
  end
 endtask
 task accept_current;
  begin
   if(!offered)offer_current();
   if(op==0)begin do @(posedge clk);while(!c_ready);end
   else begin do @(posedge clk);while(!e_ready);end
   @(negedge clk);c_valid=0;e_valid=0;offered=0;
  end
 endtask
 task check_store;
  begin
   live_count=0;for(j=0;j<entries;j=j+1)seen[j]=0;
   for(s=0;s<2;s=s+1)for(i=0;i<N;i=i+1)begin
    if(s==0)begin slot=dut.sides[0].orders.slot_state[i];actual=dut.sides[0].orders.entries[i];end
    else begin slot=dut.sides[1].orders.slot_state[i];actual=dut.sides[1].orders.entries[i];end
    if(slot==1)begin
     live_count=live_count+1;matched=0;
     for(j=0;j<entries;j=j+1)if(ids[j]==actual[127:64] && sides[j]==s)begin
      if(actual[63:32]!==prices[j] || actual[31:0]!==quantities[j])$fatal(1,"stored order changed");matched=matched+1;seen[j]=seen[j]+1;
     end
     if(matched!=1)$fatal(1,"unexpected live order %h",actual);
    end
   end
   if(live_count!=entries)$fatal(1,"live state count");
   for(j=0;j<entries;j=j+1)if(seen[j]!=1)$fatal(1,"missing or duplicate live record");
  end
 endtask
 initial begin
  if(!$value$plusargs("vectors=%s",vectors))$fatal(1,"vectors required");
  fd=$fopen(vectors,"r");if(!fd)$fatal(1,"file missing");reset_core();load_record();
  while(have)begin
   accept_current();
   if(op==2)begin
    if(phase==0)begin do @(posedge clk);while(!(dut.phase==1 && dut.state==2));end
    else if(phase==1)begin do @(posedge clk);while(!(dut.phase==6 && dut.state==1));end
    else begin do @(posedge clk);while(!r_valid);repeat(4)@(posedge clk);end
    reset_core();load_record();
   end else begin
    while(!r_valid)@(posedge clk);
    if(payload!==expected_payload)$fatal(1,"response command%0d op%0d status%0d got%h expected%h",commands,r_op,r_status,payload,expected_payload);
    check_store();held=payload;
    repeat(3)begin @(posedge clk);if(!r_valid||payload!==held||c_ready||e_ready)$fatal(1,"held response");holds=holds+1;end
    commands=commands+1;load_record();
    if(have && op!=2)begin offer_current();preoffers=preoffers+1;end
    repeat(3)begin @(posedge clk);if(!r_valid||payload!==held||c_ready||e_ready)$fatal(1,"response changed by next offer");holds=holds+1;end
    @(negedge clk);r_ready=1;@(posedge clk);@(negedge clk);r_ready=0;
   end
  end
  repeat(8)@(posedge clk);if(r_valid||r_count>N)$fatal(1,"trailing state");
  $display("PASS itch_order_state N=%0d T=%0d commands=%0d holds=%0d preoffers=%0d resets=%0d cycles=%0d",N,T,commands,holds,preoffers,resets,cycles);$finish;
 end
endmodule
