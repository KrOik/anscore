`timescale 1ns/1ps
module tb_itch_order_bbo8;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,e_valid=0,r_ready=0;
 reg [1:0] c_op=0;reg [15:0] c_locate=17,e_locate=17;reg [63:0] c_stock="ANSCORE ",c_order=0,e_stock="ANSCORE ";
 reg [7:0] c_tag=8'h81,e_tag=8'hff,e_type=0;reg [63:0] e_order=0,e_new_order=0,e_sequence=64'h8000000000000000;
 reg e_sell=0;reg [31:0] e_quantity=0,e_price=0;
 wire c_ready,e_ready,r_valid,r_admin,r_bid_valid,r_ask_valid,r_bid_changed,r_ask_changed,r_crossed,configured,faulted,busy;
 wire [7:0] r_op,r_tag;wire [3:0] r_state_status,r_l2_status;wire [63:0] r_order,r_sequence;
 wire [31:0] r_orders,r_bid_price,r_ask_price,r_bid_levels,r_ask_levels;wire [37:0] r_bid_quantity,r_ask_quantity;
 // Deliberately smaller L2 capacity naturally exercises aggregate failure
 // after successful upstream mutation, without force or internal fault injection.
 itch_order_bbo8 #(.L2_LEVELS(1)) dut(.*);
 wire [395:0] payload={r_admin,r_op,r_state_status,r_l2_status,r_order,r_sequence,r_tag,r_orders,
  r_bid_valid,r_bid_price,r_bid_quantity,r_ask_valid,r_ask_price,r_ask_quantity,r_bid_changed,r_ask_changed,
  r_bid_levels,r_ask_levels,r_crossed,configured,faulted};
 reg [395:0] held;integer results=0,i,found_old,found_new;reg [127:0] entry;
 task admin(input [1:0] op);
  begin
   @(negedge clk);c_op=op;c_valid=1;do @(posedge clk);while(!c_ready);
   @(negedge clk);c_valid=0;while(!r_valid)@(posedge clk);
   if(!r_admin||r_op!=op||r_order!=c_order||r_tag!=c_tag||r_sequence!=0)$fatal(1,"admin audit");
  end
 endtask
 task send_event(input [7:0] kind,input [63:0] id,newid,input side,input [31:0] qty,price);
  begin
   @(negedge clk);e_type=kind;e_order=id;e_new_order=newid;e_sell=side;e_quantity=qty;e_price=price;e_valid=1;
   do @(posedge clk);while(!e_ready);@(negedge clk);e_valid=0;while(!r_valid)@(posedge clk);
   if(r_admin||r_op!=kind||r_order!=id||r_tag!=e_tag||r_sequence!=e_sequence)$fatal(1,"event audit");
   e_sequence=e_sequence+1'b1;
  end
 endtask
 task check(input [3:0] ss,ls,input [31:0] orders,input bv,input [31:0] bp,input [37:0] bq,
            input av,input [31:0] ap,input [37:0] aq,input invalid);
  begin
   if({r_state_status,r_l2_status,r_orders,r_bid_valid,r_bid_price,r_bid_quantity,r_ask_valid,r_ask_price,r_ask_quantity,faulted}!==
      {ss,ls,orders,bv,bp,bq,av,ap,aq,invalid})$fatal(1,"result%0d state%0d l2%0d qty%0d/%0d",results,r_state_status,r_l2_status,r_bid_quantity,r_ask_quantity);
   if(!configured || r_bid_levels!=bv || r_ask_levels!=av || r_crossed!=(bv&&av&&bp>=ap))$fatal(1,"quote metadata");
   held=payload;repeat(4)begin @(posedge clk);if(!r_valid||payload!==held||c_ready||e_ready)$fatal(1,"held combined owner");end
   @(negedge clk);r_ready=1;@(posedge clk);@(negedge clk);r_ready=0;results=results+1;
  end
 endtask
 initial begin
  repeat(2)@(posedge clk);@(negedge clk);rst=0;
  admin(0);check(0,0,0,0,0,0,0,0,0,0);
  send_event("A",0,0,0,32'hffffffff,123);check(0,0,1,1,123,38'd4294967295,0,0,0,0);
  send_event("F",1,0,0,32'hffffffff,123);check(0,0,2,1,123,38'd8589934590,0,0,0,0);
  send_event("C",0,0,1,3,999);check(0,0,2,1,123,38'd8589934587,0,0,0,0);
  send_event("U",0,64'hffffffffffffffff,1,9,123);check(0,0,2,1,123,38'd4294967304,0,0,0,0);
  send_event("U",1,2,1,12,456);
  if(!dut.orders.faulted || !dut.levels.faulted)$fatal(1,"aggregate failure did not invalidate both epochs");
  found_old=0;found_new=0;
  for(i=0;i<8;i=i+1)if(dut.orders.sides[0].orders.slot_state[i]==1)begin
   entry=dut.orders.sides[0].orders.entries[i];
   if(entry=={64'hffffffffffffffff,32'd123,32'd9})found_old=found_old+1;
   if(entry=={64'd2,32'd456,32'd12})found_new=found_new+1;
  end
  if(found_old!=1||found_new!=1)$fatal(1,"upstream commit was falsely rolled back");
  check(0,4,2,1,123,38'd4294967304,0,0,0,1);
  send_event("D",64'hffffffffffffffff,0,0,0,0);check(3,0,2,1,123,38'd4294967304,0,0,0,1);
  c_order=2;admin(2);check(3,0,2,1,123,38'd4294967304,0,0,0,1);
  admin(1);check(0,0,0,0,0,0,0,0,0,0);
  send_event("F",3,0,1,32'hffffffff,456);check(0,0,1,0,0,0,1,456,38'd4294967295,0);
  admin(3);check(0,0,1,0,0,0,1,456,38'd4294967295,1);
  c_locate=9;c_stock="NEXT    ";admin(0);check(0,0,0,0,0,0,0,0,0,0);
  send_event("A",4,0,0,1,0);check(1,0,0,0,0,0,0,0,0,0);
  e_locate=9;e_stock="NEXT    ";send_event("A",4,0,0,1,0);check(0,0,1,1,0,1,0,0,0,0);
  send_event("D",999,0,0,0,0);check(6,0,1,1,0,1,0,0,0,1);
  admin(1);check(0,0,0,0,0,0,0,0,0,0);
  $display("PASS itch_order_bbo8 results=%0d aggregate_failures=1",results);$finish;
 end
 initial begin repeat(200000)@(posedge clk);$fatal(1,"bounded watchdog");end
endmodule
