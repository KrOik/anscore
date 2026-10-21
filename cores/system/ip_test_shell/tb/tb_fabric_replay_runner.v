`timescale 1ns/1ps
module tb_fabric_replay_runner;
 reg clk=0,rst=0,start=0,read=0;
 always #5 clk=~clk;
 reg [31:0] seed=0,mask=0;
 reg [15:0] length=0;
 reg [8:0] addr=0;
 wire busy,done,error;
 wire [31:0] cycles,frames,bytes,crc;
 wire [9:0] count;
 wire [35:0] data;
 wire [7:0] probe;
 integer i,n,source,byte_offset,packet_count;
 reg [3:0] seen;
 fabric_replay_runner #(.TIMEOUT(20000)) dut(clk,rst,start,seed,mask,length,
 busy,done,error,cycles,frames,bytes,crc,count,read,addr,data,probe);
 task run_case;
  input [31:0] run_seed,run_mask;
  input [15:0] run_length;
  begin
   @(negedge clk); seed=run_seed; mask=run_mask; length=run_length; start=1;
   @(negedge clk); start=0;
   wait(done); #1;
   if(error||busy||frames!=4||bytes!=4*length||count!=4*((length+2)/3)) $fatal(1,"runner metrics");
   seen=0; packet_count=0; byte_offset=0;
   for(i=0;i<count;i=i+1) begin
    @(negedge clk); addr=i; read=1;
    @(posedge clk); #1;
    source=data[34:27];
    if(source>3||source!=packet_count||seen[source]) $fatal(1,"runner source order/interleaving");
    n=length-byte_offset; if(n>3) n=3;
    if(data[26:24]!==((1<<n)-1)||data[35]!==(byte_offset+n==length)) $fatal(1,"runner boundary");
    for(integer b=0;b<n;b=b+1)
     if(data[b*8+:8]!==((seed+source*73+byte_offset+b)&8'hff)) $fatal(1,"trace byte");
    if(data[35]) begin seen[source]=1; packet_count=packet_count+1; byte_offset=0; end
    else byte_offset=byte_offset+n;
   end
   @(negedge clk); read=0;
   if(seen!=15||packet_count!=4) $fatal(1,"missing packets");
   $display("PASS replay seed=%h length=%0d bytes=%0d trace=%0d cycles=%0d crc=%h",seed,length,bytes,count,cycles,crc);
  end
 endtask
 initial begin
  #1; rst=1; #1; rst=0;
  repeat(3) @(negedge clk); rst=1;
  run_case(32'h12,0,7);
  run_case(32'hbd,32'h33333333,63);
  run_case(32'hff,32'h55555555,256);
  @(negedge clk); length=0; start=1;
  @(negedge clk); start=0;
  if(!done||!error||busy) $fatal(1,"invalid length silently accepted");
  @(negedge clk); length=8; mask=32'hffffffff; start=1;
  @(negedge clk); start=0;
  wait(done); #1;
  if(!error||busy||cycles!=20000) $fatal(1,"timeout behavior");
  $display("PASS runner three runtime cases no reset plus invalid length and timeout");
  $finish;
 end
 initial begin #1000000; $fatal(1,"runner test timeout"); end
endmodule
