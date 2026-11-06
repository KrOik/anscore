// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_ipv4_two_route_forwarder;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,p_valid=0,m_ready=0;
 wire p_ready,m_valid,initialized,boot_error;
 reg [159:0] p_header=0;
 reg [15:0] p_bytes=0;
 reg [7:0] p_tag=0;
 wire [2:0] m_error,m_count;
 wire [159:0] m_header;
 wire [31:0] m_next_hop,m_prefix;
 wire [7:0] m_port,m_tag;
 wire [5:0] m_prefix_length;
 ipv4_two_route_forwarder dut(.*);
 integer cycles=0,holds=0,preoffers=0,resets=0,vectors=0,vector_packets=0,outputs=0,accepted=0;
 reg hs=0,hm=0;reg [511:0] spast,mpast;
 wire [511:0] sp={p_header,p_bytes,p_tag};
 wire [511:0] mp={m_error,m_header,m_next_hop,m_prefix,m_port,m_prefix_length,m_count,m_tag};
 always @(posedge clk)begin
  cycles=cycles+1;if(cycles>50000)$fatal(1,"example watchdog");
  if(rst)begin
   hs=0;hm=0;if(p_ready||m_valid||initialized)$fatal(1,"example reset gating");
  end else begin
   if(boot_error)$fatal(1,"bootstrap error");
   if(hs&&(!p_valid||sp!==spast))$fatal(1,"example source changed while held");
   if(hm&&(!m_valid||mp!==mpast))$fatal(1,"example output changed while held");
   hs=p_valid&&!p_ready;hm=m_valid&&!m_ready;spast=sp;mpast=mp;
   if(hs)preoffers=preoffers+1;if(hm)holds=holds+1;
   if(p_valid&&p_ready)begin if(!initialized)$fatal(1,"accepted before boot fence");accepted=accepted+1;end
   if(m_valid&&m_ready)outputs=outputs+1;
  end
 end
 integer kind,op,available,es,ef,ei,elen,ec;
 reg [31:0] key,len,tag,ep;
 reg [39:0] val,ev;
 reg [159:0] hin,eh;
 task automatic reset_core;
  begin
   @(negedge clk);rst=1;p_valid=0;m_ready=0;
   repeat(2)@(posedge clk);@(negedge clk);rst=0;resets=resets+1;
  end
 endtask
 task automatic offer;
  begin
   @(negedge clk);p_header=hin;p_bytes=available;p_tag=tag;p_valid=1;
   do @(posedge clk);while(!p_ready);
   @(negedge clk);p_valid=0;
  end
 endtask
 task automatic finish_packet;
  begin
   while(!m_valid)@(negedge clk);
   if(m_error!==es[2:0]||m_header!==eh||m_next_hop!==ev[31:0]||m_port!==ev[39:32]||
      m_prefix!==ep||m_prefix_length!==elen[5:0]||m_count!==ec[2:0]||m_tag!==tag[7:0])
    $fatal(1,"example mismatch vector=%0d error=%0d/%0d",vectors,m_error,es);
   repeat(4)@(negedge clk);m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;
  end
 endtask
 integer fd,total,index,got,epoch;reg [2047:0] filename;
 initial begin
  if(!$value$plusargs("vectors=%s",filename))$fatal(1,"example vectors missing");
  for(epoch=0;epoch<2;epoch=epoch+1)begin
   reset_core();fd=$fopen(filename,"r");if(!fd)$fatal(1,"example vectors");
   got=$fscanf(fd,"%d\n",total);if(got!=1)$fatal(1,"example count");
   for(index=0;index<total;index=index+1)begin
    got=$fscanf(fd,"%d %d %h %h %h %h %d %h %d %d %d %h %d %h %d %h\n",
     kind,op,key,len,val,tag,available,hin,es,ef,ei,ep,elen,ev,ec,eh);
    if(got!=16||kind!=1)$fatal(1,"example vector shape");
    vectors=vectors+1;vector_packets=vector_packets+1;
    offer();finish_packet();
   end
   $fclose(fd);
  end
  // Cancel a real held result, then require the real routes to bootstrap again.
  offer();while(!m_valid)@(negedge clk);repeat(3)@(negedge clk);
  reset_core();offer();finish_packet();
  repeat(4)@(negedge clk);
  if(!initialized||m_valid||p_valid||preoffers<20||holds<100||resets!=3||accepted!=outputs+1)
   $fatal(1,"example coverage/outstanding");
  $display("PASS ipv4_two_route_forwarder vectors=%0d vector_cfg=0 vector_packets=%0d vector_resets=0 faults=0 epochs=2 resets=%0d cancelled=1 recovery=1 holds=%0d preoffers=%0d accepted=%0d outputs=%0d cycles=%0d",
   vectors,vector_packets,resets,holds,preoffers,accepted,outputs,cycles);
  $finish;
 end
endmodule
