`timescale 1ns/1ps
module tb;
 parameter integer RAW_BITS=10;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,clk_en=0,s_valid=0,s_sof=0,s_eol=0;
 reg [RAW_BITS-1:0] s_data=0;
 wire s_ready,m_valid,m_sof,m_eol,protocol_error,error_pulse;
 wire [7:0] m_data;
 wire [1:0] error_code;
 wire link_ready,m_ready;
 reg link_gate=0,sink_ready=0;
 assign m_ready=link_ready && link_gate;
 wire u_valid,u_sof,u_eol,u_error;
 wire [RAW_BITS-1:0] u_data;
 img_csi2_raw_pack #(.RAW_BITS(RAW_BITS)) dut(.*);
 img_csi2_raw_unpack #(.RAW_BITS(RAW_BITS)) unpacker(
  .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.s_data(m_data),
  .s_valid(m_valid && link_gate),.s_ready(link_ready),.s_sof(m_sof),.s_eol(m_eol),
  .m_data(u_data),.m_valid(u_valid),.m_ready(sink_ready),.m_sof(u_sof),.m_eol(u_eol),
  .protocol_error(u_error),.error_pulse(),.error_code());
 `include "counts.vh"
 reg [9:0] expected_bytes[0:BYTE_COUNT-1];
 reg [RAW_BITS+1:0] expected_pixels[0:PIXEL_COUNT-1];
 reg [1:0] expected_errors[0:ERROR_COUNT-1];
 integer bytes_seen=0,pixels_seen=0,errors=0,fd,ret,value,sof,eol,cycles=0;
 reg randomize=1,checking=1;
 reg [31:0] rng=32'hb74c192e;
 always @(negedge clk) if(randomize) begin
  rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
  clk_en=rng[2:0]!=0;link_gate=rng[5:3]!=0;sink_ready=rng[8:6]!=0;
 end
 reg [10:0] held;
 reg [RAW_BITS+2:0] u_held;
 reg stalled,u_stalled;
 always @(posedge clk) begin
  if(rst_n && checking && clk_en) begin
   if(m_valid && m_ready) begin
    if(bytes_seen>=BYTE_COUNT || {m_sof,m_eol,m_data}!==expected_bytes[bytes_seen])
     $fatal(1,"byte %0d got %h expected %h",bytes_seen,{m_sof,m_eol,m_data},expected_bytes[bytes_seen]);
    bytes_seen=bytes_seen+1;
   end
   if(u_valid && sink_ready) begin
    if(pixels_seen>=PIXEL_COUNT || {u_sof,u_eol,u_data}!==expected_pixels[pixels_seen])
     $fatal(1,"roundtrip pixel %0d got %h expected %h",pixels_seen,{u_sof,u_eol,u_data},expected_pixels[pixels_seen]);
    pixels_seen=pixels_seen+1;
   end
  end
  held={m_valid,m_sof,m_eol,m_data};stalled=rst_n && m_valid && (!clk_en || !m_ready);
  u_held={u_valid,u_sof,u_eol,u_data};u_stalled=rst_n && u_valid && (!clk_en || !sink_ready);
  #1;
  if(stalled && held!=={m_valid,m_sof,m_eol,m_data}) $fatal(1,"pack output not stable");
  if(u_stalled && u_held!=={u_valid,u_sof,u_eol,u_data}) $fatal(1,"unpack output not stable");
  if(rst_n && checking && clk_en && error_pulse) begin
   if(errors>=ERROR_COUNT || error_code!==expected_errors[errors]) $fatal(1,"error sequence");
   errors=errors+1;
  end
  if(rst_n && checking && u_error) $fatal(1,"packer emitted malformed bytes");
 end
 task send(input [RAW_BITS-1:0] data,input bit fs,le);
 begin
  @(negedge clk);#1;s_data=data;s_sof=fs;s_eol=le;s_valid=1;
  do begin @(posedge clk);end while(!s_ready);
  @(negedge clk);#1;s_valid=0;
  repeat(rng[10:9]) begin @(negedge clk);#1;end
 end endtask
 task reset_dut;
 begin
  @(negedge clk);#1;rst_n=0;s_valid=0;
  #1;if(m_valid || u_valid || protocol_error || s_ready) $fatal(1,"reset abort");
  @(negedge clk);#1;rst_n=1;
 end endtask
 initial begin
  $readmemh("bytes.mem",expected_bytes);$readmemh("pixels.mem",expected_pixels);$readmemh("errors.mem",expected_errors);
  repeat(2) @(negedge clk);#1;rst_n=1;
  fd=$fopen("input.txt","r");if(!fd) $fatal(1,"input missing");
  while(!$feof(fd)) begin
   ret=$fscanf(fd,"%d %d %d\n",value,sof,eol);if(ret==3) send(value,sof,eol);
  end
  $fclose(fd);
  while(pixels_seen<PIXEL_COUNT && cycles<1000) begin @(posedge clk);cycles=cycles+1;end
  repeat(10) @(posedge clk);#2;
  if(pixels_seen!=PIXEL_COUNT || bytes_seen!=BYTE_COUNT || errors!=ERROR_COUNT || !protocol_error) $fatal(1,"wrong totals");
  checking=0;randomize=0;clk_en=1;link_gate=0;sink_ready=0;
  send(1,1,0);reset_dut();
  repeat(3) @(posedge clk);#1;if(m_valid) $fatal(1,"partial reset emitted");
  send(1,1,0);
  if(RAW_BITS==10) begin send(2,0,0);send(3,0,0);end
  send(4,0,1);
  if(!m_valid || !m_sof || s_ready) $fatal(1,"complete group not stalled");
  reset_dut();repeat(5) @(posedge clk);#1;
  if(m_valid || u_valid) $fatal(1,"complete reset emitted");
  $display("PACK RAW%0d PASS bytes=%0d pixels=%0d errors=%0d",RAW_BITS,bytes_seen,pixels_seen,errors);$finish;
 end
 initial begin #10000000;$fatal(1,"timeout");end
endmodule
