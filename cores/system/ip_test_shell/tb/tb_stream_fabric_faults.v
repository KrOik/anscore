`timescale 1ns/1ps
module tb_stream_fabric_faults;
 parameter S_HALF=5,M_HALF=7;
 reg sc=0,mc=0,rst=0;
 always #S_HALF sc=~sc;
 always #M_HALF mc=~mc;
 reg [127:0] sd=0;
 reg [15:0] sk=0;
 reg [31:0] su=0;
 reg [3:0] sl=0,sv=0;
 wire [3:0] sr;
 wire [23:0] md;
 wire [2:0] mk;
 wire [7:0] mu;
 wire ml,mv;
 reg mr=0;
 wire [31:0] frames,drops;
 integer received=0,offset=0,expected_user=2,expected_length=12;
 integer n;
 stream_fabric4 #(.FIFO_DEPTH(4)) dut(sc,mc,rst,sd,sk,su,sl,sv,sr,md,mk,mu,ml,mv,mr,frames,drops);
 task send_packet;
  input integer user_id,byte_length;
  integer i,j,k;
  begin
   for(i=0;i<byte_length;i=i+4) begin
    @(negedge sc);
    k=byte_length-i; if(k>4) k=4;
    sd=0; sk=(1<<k)-1; su=user_id; sl=(i+k==byte_length); sv=1;
    for(j=0;j<k;j=j+1) sd[j*8+:8]=(user_id*19+i+j)&255;
    @(posedge sc); while(!sr[0]) @(posedge sc);
    #1; sv=0;
   end
  end
 endtask
 always @(posedge mc) if(rst&&mv&&mr) begin
  if(mu!=expected_user) $fatal(1,"discarded/reset packet leaked: %d",mu);
  n=expected_length-offset; if(n>3) n=3;
  if(mk!==((1<<n)-1)||ml!==(offset+n==expected_length)) $fatal(1,"recovery boundary");
  for(integer b=0;b<n;b=b+1)
   if(md[b*8+:8]!==((expected_user*19+offset+b)&8'hff)) $fatal(1,"recovery data");
  offset=offset+n; received=received+1;
 end
 initial begin
  #1; rst=1; #1; rst=0;
  repeat(4) @(negedge sc); rst=1;
  send_packet(1,24); // Eight 24-bit words exceed four-word capacity.
  wait(drops==1&&frames==1);
  repeat(20) @(posedge mc);
  if(mv) $fatal(1,"partial oversize packet emitted");
  mr=1;
  send_packet(2,12); // Exactly fills FIFO; must not be discarded.
  wait(received==4);
  @(negedge mc); mr=0;
  send_packet(3,12);
  wait(mv);
  #2; rst=0; sv=0;
  #1; if(mv||frames||drops) $fatal(1,"reset failed to clear state");
  repeat(5) @(negedge sc);
  received=0; offset=0; expected_user=4; expected_length=7;
  #2; rst=1;
  repeat(10) @(negedge mc);
  if(mv) $fatal(1,"old packet survived reset");
  mr=1;
  send_packet(4,7);
  wait(received==3);
  #1;
  repeat(20) begin @(posedge mc); if(mv) $fatal(1,"trailing recovery output"); end
  if(frames!=1||drops!=0) $fatal(1,"post-reset metrics");
  $display("PASS fabric_faults oversize_atomic_drop exact_capacity stalled_reset recovery clocks=%0d/%0d",S_HALF,M_HALF);
  $finish;
 end
 initial begin #3000000; $fatal(1,"fault regression timeout"); end
endmodule
