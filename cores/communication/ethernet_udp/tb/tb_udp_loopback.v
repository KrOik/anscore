`timescale 1ns/1ps
module tb_udp_loopback;
 reg clk=0;always #10 clk=~clk;
 reg rst=0,cv=0,sv=0,keep=1,last=0,dr=0;
 reg[7:0] sd=0;reg[15:0] length=0;reg[95:0] user=0;
 wire cr,sr,dv;wire[7:0] md;wire[95:0] mu;wire[2:0] error;
 reg[31:0] rng=32'hda7b9e01;integer testcase=0,index=0,n,size;
 always @(negedge clk)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};end
 wire txen,tdone;wire[1:0] txd,terror;wire[95:0] tuser;
 wire[31:0] frames,bytes;
 rmii_udp_transmitter dut(clk,rst,cv,cr,48'h84ba591684c2,32'hc0a88901,16'd11452,16'd9000,
  length,16'h1234,user,sv,sr,sd,keep,last,txen,txd,dv,dr,error,tuser,frames,bytes);
 wire rv,rk,rl;wire[7:0] rd;wire[95:0] ru;wire[31:0] rip;
 wire[15:0] rp;wire[31:0] rg,rb,ro,rf,rbytes,ug,bh,bi,bu;
 reg rready=0;integer rx_packets=0,rx_index=0,expected_packets=0;
 reg[107:0] held;reg stalled=0;reg[63:0] previous_time=0;
 rmii_udp_receiver #(.MAC(48'h84ba591684c2),.IP(32'hc0a88901),.PORT(9000))
  receiver(clk,rst,txen,txd,rv,rready,rd,rk,rl,ru,rip,rp,rg,rb,ro,rf,rbytes,ug,bh,bi,bu);
 always @(negedge clk)rready=rng[2:0]!=0;
 always @(posedge clk)if(rst)begin
  if(stalled&&(!rv||{rd,rk,rl,ru}!==held))$fatal(1,"loopback output stall");
  stalled=rv&&!rready;held={rd,rk,rl,ru};
  if(rv&&rready)begin
   if(ru[31:0]!=rx_packets||rip!=32'hc0a8890f||rp!=11452)$fatal(1,"loopback source/sequence");
   if(rx_index==0)begin
    if(ru[95:32]<=previous_time)$fatal(1,"timestamp not monotonic");
    previous_time=ru[95:32];
   end
   $display("LOOP_BYTE packet=%0d index=%0d data=%0d keep=%0d last=%0d",rx_packets,rx_index,rd,rk,rl);
   if(rl)begin rx_packets=rx_packets+1;rx_index=0;end else rx_index=rx_index+1;
  end
 end
 task command(input integer len);
 begin
  @(negedge clk);length=len;user=testcase;cv=1;
  do @(posedge clk);while(!cr);
  @(negedge clk);cv=0;length=999;user=999;
 end endtask
 task beat(input[7:0] b,input bit k,input bit l);
 begin
  repeat(rng[1:0])@(negedge clk);
  @(negedge clk);sv=1;sd=b;keep=k;last=l;
  do @(posedge clk);while(!sr);
  @(negedge clk);sv=0;
 end endtask
 task completion(input[1:0] expected_error);
 begin
  wait(dv);if(expected_error==0)begin expected_packets=expected_packets+1;wait(rx_packets==expected_packets);if(tuser!=testcase)$fatal(1,"serializer completion");end
  if(error!==expected_error)$fatal(1,"TX error");
  repeat(7)begin @(negedge clk);if(!dv||error!==expected_error||cr||txen)$fatal(1,"TX held completion");end
  dr=1;@(negedge clk);dr=0;
 end endtask
 initial begin
  repeat(5)@(negedge clk);rst=1;
  for(testcase=0;testcase<6;testcase=testcase+1)begin
   case(testcase)0:size=0;1:size=1;2:size=2;3:size=7;4:size=63;5:size=1472;endcase
   command(size);
   for(n=0;n<size;n=n+1)beat((n*29+size)&255,1,n==size-1);
   completion(0);
  end
  command(1473);completion(1);
  command(2);beat(9,1,1);completion(2);
  command(1);beat(9,1,0);beat(0,1,1);completion(2);
  command(1);beat(9,0,1);completion(2);
  testcase=7;size=33;command(size);
  for(n=0;n<size;n=n+1)beat((n*29+size)&255,1,n==size-1);
  completion(0);
  if(rx_packets!=7||rg!=7||ug!=7||rb||ro||bh||bi||bu||frames!=7)$fatal(1,"loopback accounting");
  $display("PASS UDP loopback lengths/checksums/padding/stalls/inputerrors/heldcompletion");$finish;
 end
 initial begin #3000000;$fatal(1,"TX timeout");end
endmodule
