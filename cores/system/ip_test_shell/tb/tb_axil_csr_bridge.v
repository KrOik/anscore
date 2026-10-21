`timescale 1ns/1ps
module tb_axil_csr_bridge;
 reg clk=0,rst=0;
 always #5 clk=~clk;
 reg [7:0] aw=0,ar=0;
 reg av=0,wv=0,arv=0,br=0,rr=0;
 wire ary,wy,arry,bv,rv;
 reg [31:0] wd=0;
 reg [3:0] ws=0;
 wire [1:0] bp,rp;
 wire [31:0] rd;
 wire qv,qw,qr,pv,pe,pr;
 wire [7:0] qa;
 wire [31:0] qd,pd;
 wire [3:0] qs;
 wire csr_ready;
 reg gate=0;
 integer gate_count=0;
 reg held_request=0;
 reg [44:0] request_bits;
 always @(negedge clk) begin gate_count=gate_count+1; gate=(gate_count%13>7); end
 assign qr=csr_ready&&gate;
 always @(posedge clk) if(rst) begin
  if(held_request&&(!qv||{qw,qa,qd,qs}!==request_bits)) $fatal(1,"CSR request changed while stalled");
  held_request=qv&&!qr;
  request_bits={qw,qa,qd,qs};
 end else held_request=0;
 wire start;
 wire [2:0] page;
 wire [31:0] seed,mask;
 wire [15:0] length;
 integer writes=0,reads=0,i;
 reg [31:0] model=1;
 axil_csr_bridge bridge(clk,rst,aw,av,ary,wd,ws,wv,wy,bp,bv,br,
 ar,arv,arry,rd,rp,rv,rr,qv,qw,qa,qd,qs,qr,pv,pd,pe,pr);
 test_shell_csr csr(clk,rst,qv&&gate,qw,qa,qd,qs,csr_ready,pv,pd,pe,pr,
 1'b0,1'b0,1'b0,32'd21,32'd0,32'd99,start,page,seed,mask,length);
 task send_aw;
  input [7:0] a; input integer delay_cycles;
  begin
   repeat(delay_cycles) @(negedge clk);
   @(negedge clk); aw=a; av=1;
   @(posedge clk); while(!ary) @(posedge clk);
   #1; av=0;
  end
 endtask
 task send_w;
  input [31:0] d; input [3:0] s; input integer delay_cycles;
  begin
   repeat(delay_cycles) @(negedge clk);
   @(negedge clk); wd=d; ws=s; wv=1;
   @(posedge clk); while(!wy) @(posedge clk);
   #1; wv=0;
  end
 endtask
 task write_reg;
  input [7:0] a; input [31:0] d; input [3:0] s;
  input integer aw_delay,w_delay; input [1:0] expected_resp;
  begin
   fork send_aw(a,aw_delay); send_w(d,s,w_delay); join
   wait(bv); #1;
   repeat(7) begin
    @(posedge clk); #1;
    if(!bv||bp!==expected_resp) $fatal(1,"B response/stall");
   end
   @(negedge clk); br=1;
   @(posedge clk); #1; br=0;
   writes=writes+1;
  end
 endtask
 task read_reg;
  input [7:0] a; input [31:0] expected; input [1:0] expected_resp;
  begin
   @(negedge clk); ar=a; arv=1;
   @(posedge clk); while(!arry) @(posedge clk);
   #1; arv=0;
   wait(rv); #1;
   repeat(5) begin
    @(posedge clk); #1;
    if(!rv||rp!==expected_resp||rd!==expected) $fatal(1,"R response/stall addr=%h got=%h",a,rd);
   end
   @(negedge clk); rr=1;
   @(posedge clk); #1; rr=0;
   reads=reads+1;
  end
 endtask
 initial begin
  #1; rst=1; #1; rst=0;
  repeat(3) @(negedge clk); rst=1;
  for(i=0;i<32;i=i+1) begin
   // Simultaneous traffic; ID read is independent of the seed update order.
   fork
    write_reg(12,32'h819a0000+i,15,i%4,(i+2)%5,0);
    read_reg(0,32'h49503034,0);
   join
   read_reg(12,32'h819a0000+i,0);
  end
  write_reg(12,32'h12345678,5,0,6,0);
  read_reg(12,32'h81340078,0);
  write_reg(16,0,15,7,0,2);
  read_reg(16,16,0);
  read_reg(1,0,2);
  write_reg(0,0,15,1,0,2);
  // Incomplete AW must not modify CSR and must be discarded by reset.
  send_aw(12,0);
  #2; rst=0; #1;
  if(bv||rv||qv) $fatal(1,"reset pending response");
  repeat(3) @(negedge clk); rst=1;
  read_reg(12,1,0);
  $display("PASS AXIL bridge writes=%0d reads=%0d AW/W_reordering concurrent_RW stalled_responses errors reset",writes,reads);
  $finish;
 end
 initial begin #300000; $fatal(1,"AXIL timeout"); end
endmodule
