// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_cyclic_gate_packet_scheduler;
 parameter integer QUEUES=4,DEPTH=4,SLOTS=4,TICK_W=16,DATA_W=32,TAG_W=8;
 reg clk=0;always #5 clk=~clk;
 reg  rst_n=0;
 reg  c_valid=0;
 wire  c_ready;
 reg [2:0] c_op=0;
 reg [31:0] c_queue=0;
 reg [31:0] c_slot=0;
 reg [TICK_W-1:0] c_duration=0;
 reg [TICK_W-1:0] c_cost=0;
 reg [QUEUES-1:0] c_mask=0;
 reg [DATA_W-1:0] c_data=0;
 reg [TAG_W-1:0] c_tag=0;
 reg  c_enable=0;
 wire  r_valid;
 reg  r_ready=0;
 wire [2:0] r_op;
 wire [3:0] r_status;
 wire [31:0] r_queue;
 wire [31:0] r_slot;
 wire [TAG_W-1:0] r_tag;
 wire [31:0] r_count;
 wire [TICK_W-1:0] r_head_cost;
 wire [DATA_W-1:0] r_head_data;
 wire [TAG_W-1:0] r_head_tag;
 wire [31:0] r_active_slot;
 wire [TICK_W-1:0] r_ticks_left;
 wire  r_running;
 wire  r_busy;
 reg  launch_accept=0;
 wire  launch;
 wire [31:0] launch_queue;
 wire [TICK_W-1:0] launch_cost;
 wire [DATA_W-1:0] launch_data;
 wire [TAG_W-1:0] launch_tag;
 wire [31:0] launch_slot;
 wire [TICK_W-1:0] launch_ticks_left;
 wire  running;
 wire [31:0] active_slot;
 wire [TICK_W-1:0] ticks_left;
 wire [TICK_W-1:0] service_left;
 wire [QUEUES-1:0] gate_mask;
 wire [QUEUES*((DEPTH<2)?1:$clog2(DEPTH+1))-1:0] levels;
 cyclic_gate_packet_scheduler #(.QUEUES(QUEUES),.DEPTH(DEPTH),.SLOTS(SLOTS),.TICK_W(TICK_W),.DATA_W(DATA_W),.TAG_W(TAG_W)) dut(.*);
 integer fd,rc,cycles=0,launches=0,holds=0,commands=0;
 reg [63:0] v[0:40];
 string vectors;
 initial begin
  if(!$value$plusargs("vectors=%s",vectors))$fatal(1,"missing vectors");
  fd=$fopen(vectors,"r");if(!fd)$fatal(1,"missing vector file");
  while(!$feof(fd))begin
   rc=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7],v[8],v[9],v[10],v[11],v[12],v[13],v[14],v[15],v[16],v[17],v[18],v[19],v[20],v[21],v[22],v[23],v[24],v[25],v[26],v[27],v[28],v[29],v[30],v[31],v[32],v[33],v[34],v[35],v[36],v[37],v[38],v[39],v[40]);
   if(rc!=41)$fatal(1,"bad vector fields %0d",rc);
   @(negedge clk);
   rst_n=v[0];
   c_valid=v[1];
   c_op=v[2];
   c_queue=v[3];
   c_slot=v[4];
   c_duration=v[5];
   c_mask=v[6];
   c_cost=v[7];
   c_data=v[8];
   c_tag=v[9];
   c_enable=v[10];
   r_ready=v[11];
   launch_accept=v[12];
   #1;
   if(c_ready!==v[13]||r_valid!==v[14]||launch!==v[28]||running!==v[35]||active_slot!==v[36]||ticks_left!==v[37]||service_left!==v[38]||gate_mask!==v[39]||levels!==v[40])
    $fatal(1,"cycle%0d control ready%0d/%0d rvalid%0d/%0d launch%0d/%0d slot%0d/%0d ticks%0d/%0d service%0d/%0d mask%h/%h levels%h/%h",cycles,c_ready,v[13],r_valid,v[14],launch,v[28],active_slot,v[36],ticks_left,v[37],service_left,v[38],gate_mask,v[39],levels,v[40]);
   if(r_valid && (r_op!==v[15]||r_status!==v[16]||r_queue!==v[17]||r_slot!==v[18]||r_tag!==v[19]||r_count!==v[20]||r_head_cost!==v[21]||r_head_data!==v[22]||r_head_tag!==v[23]||r_active_slot!==v[24]||r_ticks_left!==v[25]||r_running!==v[26]||r_busy!==v[27]))
    $fatal(1,"cycle%0d response op%0d status%0d/%0d queue%0d count%0d/%0d ticks%0d/%0d head%h/%h",cycles,r_op,r_status,v[16],r_queue,r_count,v[20],r_ticks_left,v[25],r_head_data,v[22]);
   if(launch && (launch_queue!==v[29]||launch_cost!==v[30]||launch_data!==v[31]||launch_tag!==v[32]||launch_slot!==v[33]||launch_ticks_left!==v[34]))$fatal(1,"cycle%0d launch payload",cycles);
   if(launch && (!launch_accept || !running || service_left!=0 || launch_cost==0 || launch_cost>ticks_left || !gate_mask[launch_queue]))$fatal(1,"illegal launch");
   if(r_valid&&!r_ready)holds=holds+1;
   if(launch)launches=launches+1;
   if(c_valid&&c_ready)commands=commands+1;
   @(posedge clk);cycles=cycles+1;
  end
  $fclose(fd);
  if(cycles<100||launches==0||holds==0||commands<20)$fatal(1,"vacuous coverage");
  $display("PASS cyclic_gate_packet_scheduler Q=%0d D=%0d S=%0d T=%0d W=%0d G=%0d cycles=%0d commands=%0d launches=%0d holds=%0d",QUEUES,DEPTH,SLOTS,TICK_W,DATA_W,TAG_W,cycles,commands,launches,holds);
  $finish;
 end
 initial begin #10000000;$fatal(1,"TB simulation-time watchdog");end
endmodule
