// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_four_class_payload_tx;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,c_enable=1,r_ready=0,s_valid=0,s_last=0,a_ready=0,m_ready=0;
 reg [1:0] c_class=0,s_class=0;
 reg [15:0] c_capacity=0,c_rate=0,c_initial=0;
 reg [7:0] c_tag=0,s_tag=0;
 reg [31:0] s_data=0;
 reg [3:0] s_keep=0;
 wire c_ready,r_valid,s_ready,a_valid,m_valid,m_sop,m_last,faulted;
 wire [1:0] r_status;
 wire [2:0] a_status;
 wire [31:0] r_flow,a_flow,a_bytes,a_beats,m_flow,m_data;
 wire [7:0] r_tag,a_tag,m_tag;
 wire [3:0] m_keep;
 wire [15:0] m_length;
 four_class_payload_tx dut(.*);
 integer configurations=0,admissions=0,frames=0,output_beats=0,holds=0,resets=0;
 reg held=0;
 reg [93:0] held_output;
 wire [93:0] output_payload={m_flow,m_data,m_keep,m_sop,m_last,m_length,m_tag};
 always @(posedge clk)begin
  if(rst)begin
   held=0;
   #1;if(c_ready || r_valid || s_ready || a_valid || m_valid)$fatal(1,"example reset mask");
  end else begin
   if(faulted)$fatal(1,"example backend fault");
   if(held && (!m_valid || output_payload!==held_output))$fatal(1,"example held output changed");
   held=m_valid && !m_ready;held_output=output_payload;
   if(held)holds=holds+1;
  end
 end
 task reset_now;
 begin
  rst=1;c_valid=0;r_ready=0;s_valid=0;a_ready=0;m_ready=0;
  repeat(3)@(posedge clk);
  @(negedge clk);rst=0;resets=resets+1;@(negedge clk);
 end endtask
 task cfg(input integer flow,cap,status);
 integer count;
 begin
  @(negedge clk);c_valid=1;c_class=flow;c_capacity=cap;c_rate=0;c_initial=cap;c_tag=configurations+1;
  count=0;do begin @(posedge clk);count=count+1;if(count>4096)$fatal(1,"example config acceptance");end while(!c_ready);
  @(negedge clk);c_valid=0;count=0;
  while(!r_valid)begin @(negedge clk);count=count+1;if(count>4096)$fatal(1,"example config response");end
  repeat(3)begin
   if(!r_valid || r_status!==status || r_flow!==flow || r_tag!==configurations+1)$fatal(1,"example config fields");
   @(negedge clk);
  end
  r_ready=1;@(posedge clk);@(negedge clk);r_ready=0;configurations=configurations+1;
 end endtask
 task put(input integer flow,tag_value,input [31:0] value,input [3:0] keep,input integer tail);
 integer count;
 begin
  @(negedge clk);s_valid=1;s_class=flow;s_tag=tag_value;s_data=value;s_keep=keep;s_last=tail;
  count=0;do begin @(posedge clk);count=count+1;if(count>4096)$fatal(1,"example input bound");end while(!s_ready);
  @(negedge clk);s_valid=0;
 end endtask
 task admission(input integer status,flow,tag_value,nbytes,nbeats);
 integer count;
 begin
  count=0;while(!a_valid)begin @(negedge clk);count=count+1;if(count>4096)$fatal(1,"example admission wait");end
  repeat(3)begin
   if(!a_valid || a_status!==status || a_flow!==flow || a_tag!==tag_value || a_bytes!==nbytes || a_beats!==nbeats)$fatal(1,"example admission fields");
   @(negedge clk);
  end
  a_ready=1;@(posedge clk);@(negedge clk);a_ready=0;admissions=admissions+1;
 end endtask
 task receive(input integer flow,tag_value,nbytes,sop,tail,input [31:0] value,input [3:0] keep);
 integer count;
 begin
  count=0;while(!m_valid)begin @(negedge clk);count=count+1;if(count>4096)$fatal(1,"example output wait");end
  repeat(3)begin
   if(!m_valid || m_flow!==flow || m_tag!==tag_value || m_length!==nbytes ||
      m_sop!==sop[0] || m_last!==tail[0] || m_data!==value || m_keep!==keep)$fatal(1,"example output fields");
   @(negedge clk);
  end
  m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;
  output_beats=output_beats+1;if(tail)frames=frames+1;
 end endtask
 integer count;
 initial begin
  reset_now();
  put(2,11,32'h13579bdf,4'b1111,1);admission(5,2,11,4,1);
  repeat(8)begin @(negedge clk);if(m_valid)$fatal(1,"disabled example output");end
  cfg(0,0,2);cfg(0,16,0);cfg(1,16,0);
  put(0,21,32'h11223344,4'b0101,0);
  repeat(5)begin @(negedge clk);if(m_valid)$fatal(1,"example atomic publication");end
  put(3,99,32'haabbccdd,4'b1000,1);admission(0,0,21,3,2);
  put(1,22,32'h12345678,4'b1111,1);admission(0,1,22,4,1);
  if(dut.u_payload.u_shaper.tokens[0]!==16'd16)$fatal(1,"example prefetched packet charged early");
  receive(0,21,3,1,0,32'h11223344,4'b0101);
  if(dut.u_payload.u_shaper.tokens[0]!==16'd13)$fatal(1,"example SOP debit");
  receive(0,21,3,0,1,32'haabbccdd,4'b1000);
  if(dut.u_payload.u_shaper.tokens[0]!==16'd13)$fatal(1,"example LAST double debit");
  receive(1,22,4,1,1,32'h12345678,4'b1111);
  put(0,31,32'hdeadbeef,4'b1111,1);admission(0,0,31,4,1);
  count=0;while(!m_valid)begin @(negedge clk);count=count+1;if(count>4096)$fatal(1,"example canceled SOP wait");end
  if(!m_sop || dut.u_payload.u_shaper.tokens[0]!==16'd13)$fatal(1,"example canceled SOP predicate");
  reset_now();
  repeat(8)begin @(negedge clk);if(m_valid || a_valid || r_valid)$fatal(1,"example stale reset result");end
  cfg(2,16,0);put(2,41,32'h0badcafe,4'b0010,1);admission(0,2,41,1,1);
  receive(2,41,1,1,1,32'h0badcafe,4'b0010);
  repeat(8)begin @(negedge clk);if(m_valid || a_valid || r_valid)$fatal(1,"example trailing result");end
  $display("B48_A_EXAMPLE_PASS configurations=%0d admissions=%0d frames=%0d output_beats=%0d resets=%0d holds=%0d",configurations,admissions,frames,output_beats,resets,holds);
  $finish;
 end
 initial begin #1000000;$fatal(1,"example global watchdog");end
endmodule
