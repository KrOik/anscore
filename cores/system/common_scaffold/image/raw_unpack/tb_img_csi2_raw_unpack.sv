`timescale 1ns/1ps
module tb;
 parameter integer RAW_BITS=10;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,clk_en=0,s_valid=0,s_sof=0,s_eol=0,m_ready=0;
 reg [7:0] s_data=0;
 wire s_ready,m_valid,m_sof,m_eol,protocol_error,error_pulse;
 wire [RAW_BITS-1:0] m_data;
 wire [1:0] error_code;
 img_csi2_raw_unpack #(.RAW_BITS(RAW_BITS)) dut(.*);
 `include "counts.vh"
 reg [RAW_BITS+1:0] expected[0:EXPECTED_COUNT-1];
 reg [1:0] expected_error[0:ERROR_COUNT-1];
 integer received=0,errors=0,fd,ret,value,sof,eol,cycles=0;
 reg randomize=1,checking=1;
 reg [31:0] random_state=32'h7b19ce32;
 always @(negedge clk) if(randomize) begin
  random_state=random_state ^ (random_state<<13);
  random_state=random_state ^ (random_state>>17);
  random_state=random_state ^ (random_state<<5);
  clk_en=random_state[2:0]!=0;m_ready=random_state[5:3]!=0;
 end
 reg [RAW_BITS+2:0] held;
 reg stalled;
 always @(posedge clk) begin
  if(rst_n && checking && clk_en && m_valid && m_ready) begin
   if(received>=EXPECTED_COUNT) $fatal(1,"extra pixel");
   if({m_sof,m_eol,m_data}!==expected[received])
    $fatal(1,"pixel %0d got %h expected %h",received,{m_sof,m_eol,m_data},expected[received]);
   received=received+1;
  end
  held={m_valid,m_sof,m_eol,m_data};stalled=rst_n && m_valid && (!clk_en || !m_ready);
  #1;
  if(stalled && held!=={m_valid,m_sof,m_eol,m_data}) $fatal(1,"unstable paused output");
  if(rst_n && checking && clk_en && error_pulse) begin
   if(errors>=ERROR_COUNT || error_code!==expected_error[errors]) $fatal(1,"error sequence %0d code %0d",errors,error_code);
   errors=errors+1;
  end
 end
 task send(input [7:0] data,input bit fs,le);
 begin
  @(negedge clk);#1;s_data=data;s_sof=fs;s_eol=le;s_valid=1;
  do begin @(posedge clk); end while(!s_ready);
  @(negedge clk);#1;s_valid=0;
  repeat(random_state[8:7]) begin @(negedge clk);#1;end
 end endtask
 task reset_dut;
 begin
  @(negedge clk);#1;rst_n=0;s_valid=0;
  #1;if(m_valid || protocol_error || s_ready) $fatal(1,"reset did not abort");
  @(negedge clk);#1;rst_n=1;
 end endtask
 initial begin
  $readmemh("pixels.mem",expected);$readmemh("errors.mem",expected_error);
  repeat(2) @(negedge clk);#1;rst_n=1;
  fd=$fopen("input.txt","r");if(!fd) $fatal(1,"input missing");
  while(!$feof(fd)) begin
   ret=$fscanf(fd,"%d %d %d\n",value,sof,eol);
   if(ret==3) send(value,sof,eol);
  end
  $fclose(fd);
  while(received<EXPECTED_COUNT && cycles<1000) begin @(posedge clk);cycles=cycles+1;end
  repeat(10) @(posedge clk);#2;
  if(received!=EXPECTED_COUNT || errors!=ERROR_COUNT || !protocol_error) $fatal(1,"totals pixels %0d errors %0d",received,errors);
  // Reset discards partial groups, then discards a fully-buffered stalled group.
  checking=0;randomize=0;clk_en=1;m_ready=0;
  send(8'h12,1,0);reset_dut();
  repeat(3) @(posedge clk);#1;if(m_valid) $fatal(1,"partial reset emitted");
  send(8'hff,1,0);send(8'hff,0,0);
  if(RAW_BITS==10) begin send(8'hff,0,0);send(8'hff,0,0);end
  send(8'hff,0,1);
  if(!m_valid || !m_sof || s_ready) $fatal(1,"stalled complete group");
  reset_dut();
  repeat(5) @(posedge clk);#1;if(m_valid) $fatal(1,"complete reset emitted");
  $display("RAW%0d PASS pixels=%0d errors=%0d",RAW_BITS,received,errors);$finish;
 end
 initial begin #10000000;$fatal(1,"timeout");end
endmodule
