`timescale 1ns/1ps
module tb_itch_receiver_state8;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,rx_cfg_valid=0,s_valid=0,s_keep=1,s_last=0,c_valid=0,r_ready=0,p_ready=0;
 reg [79:0] rx_cfg_session="ANSCORE001";reg [63:0] rx_cfg_next=1;
 reg [7:0] s_data=0,s_tag=9,c_tag=3;reg [1:0] c_op=0;reg [15:0] c_locate=17;
 reg [63:0] c_stock="ANSCORE ",c_order=0;
 wire rx_cfg_ready,s_ready,c_ready,r_valid,r_admin,r_old_valid,r_old_sell,r_new_valid,r_new_sell,r_remove_valid,r_add_valid,configured,faulted,state_busy,rx_busy,p_valid,p_end;
 wire [7:0] r_op,r_tag,p_tag;wire [3:0] r_status,p_status;
 wire [63:0] r_request_order,r_sequence,r_old_order,r_new_order,p_sequence,p_next;
 wire [31:0] r_old_price,r_old_quantity,r_new_price,r_new_quantity,r_remove_quantity,r_count,r_bid_orders,r_ask_orders;
 wire [79:0] p_session;wire [15:0] p_messages,p_events;
 itch_receiver_state8 dut(.*);
 integer i,j,length,packets=0,results=0;reg [7:0] data[0:255];
 task byte_out(input [7:0] value,input last);
  begin
   @(negedge clk);s_data=value;s_last=last;s_valid=1;
   do @(posedge clk);while(!s_ready);
   @(negedge clk);s_valid=0;
  end
 endtask
 task packet(input [63:0] sequence_value,input [7:0] kind);
  reg [63:0] refid;
  begin
   for(i=0;i<256;i=i+1)data[i]=0;
   for(i=0;i<10;i=i+1)data[i]=rx_cfg_session[79-i*8-:8];
   for(i=0;i<8;i=i+1)data[10+i]=sequence_value[63-i*8-:8];data[19]=1;
   length=(kind=="A")?36:(kind=="C")?36:(kind=="U")?35:19;data[21]=length;
   data[22]=kind;data[24]=17;refid=(kind=="D")?64'hffffffffffffffff:64'd0;
   for(i=0;i<8;i=i+1)data[33+i]=refid[63-i*8-:8];
   if(kind=="A")begin
    data[41]="B";data[45]=10;
    for(i=0;i<8;i=i+1)data[46+i]=c_stock[63-i*8-:8];data[57]=123;
   end else if(kind=="C")begin data[44]=3;data[53]="N";data[56]=3;data[57]=231;end
   else if(kind=="U")begin for(i=0;i<8;i=i+1)data[41+i]=255;data[52]=12;data[55]=1;data[56]=200;end
   for(j=0;j<22+length;j=j+1)byte_out(data[j],j==21+length);
   packets=packets+1;
  end
 endtask
 task retire_result;
  begin repeat(3)@(posedge clk);@(negedge clk);r_ready=1;@(posedge clk);@(negedge clk);r_ready=0;results=results+1;end
 endtask
 task admin(input [1:0] operation);
  begin
   @(negedge clk);c_op=operation;c_valid=1;do @(posedge clk);while(!c_ready);
   @(negedge clk);c_valid=0;while(!r_valid)@(posedge clk);
   if(!r_admin||r_status!=0)$fatal(1,"admin failed");retire_result();
  end
 endtask
 task retire_packet(input [3:0] status,input [63:0] next_value,input integer event_count);
  begin
   while(!p_valid)@(posedge clk);
   if(p_status!=status || p_next!=next_value || p_events!=event_count || p_tag!=9)$fatal(1,"packet response");
   repeat(3)@(posedge clk);@(negedge clk);p_ready=1;@(posedge clk);@(negedge clk);p_ready=0;
  end
 endtask
 initial begin
  repeat(2)@(posedge clk);@(negedge clk);rst=0;admin(0);
  @(negedge clk);rx_cfg_valid=1;do @(posedge clk);while(!rx_cfg_ready);@(negedge clk);rx_cfg_valid=0;
  packet(1,"A");while(!r_valid)@(posedge clk);
  if(r_status!=0||!r_add_valid||r_new_quantity!=10||r_new_price!=123||r_count!=1)$fatal(1,"add");retire_result();retire_packet(0,2,1);
  packet(2,"C");while(!r_valid)@(posedge clk);
  if(r_status!=0||r_old_quantity!=10||r_new_quantity!=7||r_new_price!=123||r_remove_quantity!=3||r_add_valid)$fatal(1,"C changed book price");retire_result();retire_packet(0,3,1);
  packet(3,"U");while(!r_valid)@(posedge clk);
  if(r_status!=0||r_old_quantity!=7||r_old_price!=123||r_new_order!=64'hffffffffffffffff||r_new_quantity!=12||r_new_price!=456||r_new_sell||!r_remove_valid||!r_add_valid)$fatal(1,"replace");retire_result();retire_packet(0,4,1);
  packet(6,"D");while(!p_valid)@(posedge clk);
  if(p_status!=7||r_valid)$fatal(1,"gap leaked state event");
  // Real recovery controller action: parser completion does not clear/invalidate state automatically.
  admin(3);if(!faulted||r_count!=1)$fatal(1,"invalidate");retire_packet(7,4,0);
  packet(4,"D");while(!r_valid)@(posedge clk);
  if(r_status!=3||r_remove_valid||r_count!=1)$fatal(1,"faulted stream deadlocked or mutated");retire_result();retire_packet(0,5,1);
  admin(1);if(faulted||!configured||r_count!=0)$fatal(1,"clear recovery");
  @(negedge clk);rx_cfg_next=10;rx_cfg_valid=1;do @(posedge clk);while(!rx_cfg_ready);@(negedge clk);rx_cfg_valid=0;
  packet(10,"A");while(!r_valid)@(posedge clk);
  if(r_status!=0||!r_add_valid||r_count!=1||r_new_quantity!=10)$fatal(1,"fresh");retire_result();retire_packet(0,11,1);
  $display("PASS itch_receiver_state8 packets=%0d results=%0d",packets,results);$finish;
 end
 initial begin repeat(100000)@(posedge clk);$fatal(1,"bounded watchdog");end
endmodule
