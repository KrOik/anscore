// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_ipv4_lpm_forward;
 parameter integer N=3,T=8;
 localparam integer CW=(N>1?$clog2(N+1):1);
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,c_rsp_ready=0,p_valid=0,m_ready=0;
 wire c_ready,c_rsp_valid,p_ready,m_valid;
 reg [1:0] c_op=0;
 reg [31:0] c_prefix=0,c_length=0,c_next_hop=0;
 reg [7:0] c_port=0;
 reg [T-1:0] c_tag=0,p_tag=0;
 reg [159:0] p_header=0;
 reg [15:0] p_bytes=0;
 wire [1:0] c_status;
 wire c_found,c_inserted;
 wire [31:0] c_old_prefix,c_old_next_hop;
 wire [5:0] c_old_length;
 wire [7:0] c_old_port;
 wire [CW-1:0] c_count,m_count;
 wire [T-1:0] c_rsp_tag,m_tag;
 wire [2:0] m_error;
 wire [159:0] m_header;
 wire [31:0] m_next_hop,m_prefix;
 wire [7:0] m_port;
 wire [5:0] m_prefix_length;
 ipv4_lpm_forward #(.ROUTES(N),.TAG_W(T)) dut(.*);
 integer cycles=0,holds=0,preoffers=0,futures=0,future_configs=0,future_packets=0,resets=0,reset_cases=0,faults=0,priority_checks=0;
 integer cfg_accepts=0,packet_accepts=0,cfg_results=0,packet_results=0;
 integer vectors=0,vector_cfg=0,vector_packets=0,vector_resets=0;
 reg hc=0,hp=0,hr=0,hm=0;
 reg [511:0] last_c,last_p,last_r,last_m;
 wire [511:0] cp={c_op,c_prefix,c_length,c_next_hop,c_port,c_tag};
 wire [511:0] pp={p_header,p_bytes,p_tag};
 wire [511:0] rp={c_status,c_found,c_inserted,c_old_prefix,c_old_length,c_old_next_hop,c_old_port,c_count,c_rsp_tag};
 wire [511:0] mp={m_error,m_header,m_next_hop,m_prefix,m_port,m_prefix_length,m_count,m_tag};
 always @(posedge clk)begin
  cycles=cycles+1;if(cycles>500000)$fatal(1,"watchdog");
  if(rst)begin
   if(c_ready||p_ready||c_rsp_valid||m_valid)$fatal(1,"reset gating");
   hc=0;hp=0;hr=0;hm=0;
  end else begin
   if(hc&&(!c_valid||cp!==last_c))$fatal(1,"config source withdrew or changed");
   if(hp&&(!p_valid||pp!==last_p))$fatal(1,"packet source withdrew or changed");
   if(hr&&(!c_rsp_valid||rp!==last_r))$fatal(1,"config response changed while held");
   if(hm&&(!m_valid||mp!==last_m))$fatal(1,"packet result changed while held");
   hc=c_valid&&!c_ready;hp=p_valid&&!p_ready;hr=c_rsp_valid&&!c_rsp_ready;hm=m_valid&&!m_ready;
   last_c=cp;last_p=pp;last_r=rp;last_m=mp;
   if(hr||hm)holds=holds+1;if(hc||hp)preoffers=preoffers+1;
   if(c_valid&&c_ready)cfg_accepts=cfg_accepts+1;
   if(p_valid&&p_ready)packet_accepts=packet_accepts+1;
   if(c_rsp_valid&&c_rsp_ready)cfg_results=cfg_results+1;
   if(m_valid&&m_ready)packet_results=packet_results+1;
   if(c_valid&&c_ready&&p_valid&&p_ready)$fatal(1,"dual owner acceptance");
  end
 end
 integer kind,op,available,es,ef,ei,elen,ec;
 reg [31:0] key,len,tag,ep;
 reg [39:0] val,ev;
 reg [159:0] hin,eh;
 task automatic hard_reset;
  begin
   @(negedge clk);rst=1;c_valid=0;p_valid=0;c_rsp_ready=0;m_ready=0;
   repeat(2)@(posedge clk);
   @(negedge clk);rst=0;resets=resets+1;
   @(negedge clk);
  end
 endtask
 task automatic simultaneous_priority;
  begin
   // A real packet offer remains owned by its source through the admin reply.
   op=1;key=0;len=33;val=0;tag=5;es=3;ef=0;ei=0;ep=0;elen=0;ev=0;ec=1;
   @(negedge clk);
   c_op=op;c_prefix=key;c_length=len;c_next_hop=0;c_port=0;c_tag=tag;c_valid=1;
   p_header=0;p_bytes=0;p_tag=tag;p_valid=1;
   @(posedge clk);if(!c_ready||p_ready)$fatal(1,"admin priority");
   @(negedge clk);c_valid=0;
   finish_cfg(0);
   do @(posedge clk);while(!p_ready);
   @(negedge clk);p_valid=0;es=1;eh=0;
   finish_packet(0,0);priority_checks=priority_checks+1;
  end
 endtask
 task automatic offer_cfg;
  begin
   @(negedge clk);c_op=op;c_prefix=key;c_length=len;c_next_hop=val[31:0];
   c_port=val[39:32];c_tag=tag;c_valid=1;
   do @(posedge clk);while(!c_ready);
   @(negedge clk);c_valid=0;
  end
 endtask
 task automatic offer_packet;
  begin
   @(negedge clk);p_header=hin;p_bytes=available;p_tag=tag;p_valid=1;
   do @(posedge clk);while(!p_ready);
   @(negedge clk);p_valid=0;
  end
 endtask
 task automatic offer_future(input integer which);
  begin
   // Each future source stays offered through its actual later acceptance.
   if(which==1)begin
    c_op=1;c_prefix=32'haa55aa55;c_length=33;c_next_hop=0;c_port=0;c_tag={T{1'b1}};c_valid=1;
    if(c_ready)$fatal(1,"future config accepted before old result");
   end else begin
    p_header=0;p_bytes=0;p_tag={T{1'b1}};p_valid=1;
    if(p_ready)$fatal(1,"future packet accepted before old result");
   end
  end
 endtask
 task automatic finish_future(input integer which);
  begin
   if(which==1)begin
    do @(posedge clk);while(!c_ready);
    @(negedge clk);c_valid=0;
    while(!c_rsp_valid)@(negedge clk);
    if(c_status!==2'd3||c_found||c_inserted||c_old_prefix||c_old_length||c_old_next_hop||c_old_port||
       c_count!==ec[CW-1:0]||c_rsp_tag!=={T{1'b1}})$fatal(1,"future bad-length result");
    repeat(2)@(negedge clk);
    c_rsp_ready=1;@(posedge clk);@(negedge clk);c_rsp_ready=0;future_configs=future_configs+1;
   end else begin
    do @(posedge clk);while(!p_ready);
    @(negedge clk);p_valid=0;
    while(!m_valid)@(negedge clk);
    if(m_error!==3'd1||m_header!==160'd0||m_next_hop||m_port||m_prefix||m_prefix_length||
       m_count!==ec[CW-1:0]||m_tag!=={T{1'b1}})$fatal(1,"future format result");
    repeat(2)@(negedge clk);
    m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;future_packets=future_packets+1;
   end
   futures=futures+1;
  end
 endtask
 task automatic finish_cfg(input integer future);
  begin
   if(future)offer_future(future);
   while(!c_rsp_valid)@(negedge clk);
   if(c_status!==es[1:0]||c_found!==ef[0]||c_inserted!==ei[0]||c_old_prefix!==ep||
      c_old_length!==elen[5:0]||c_old_next_hop!==ev[31:0]||c_old_port!==ev[39:32]||
      c_count!==ec[CW-1:0]||c_rsp_tag!==tag[T-1:0])
    $fatal(1,"cfg mismatch vector=%0d status=%0d/%0d count=%0d/%0d",vectors,c_status,es,c_count,ec);
   repeat(4)begin @(negedge clk);if(future&&c_ready)$fatal(1,"future escaped held cfg");end
   c_rsp_ready=1;@(posedge clk);@(negedge clk);c_rsp_ready=0;
   if(future)finish_future(future);
  end
 endtask
 task automatic finish_packet(input integer future,input integer inject);
  begin
   if(future)offer_future(future);
   if(inject)begin
    while(!(dut.state==5&&dut.pair_index==0&&dut.sum_out_valid))@(negedge clk);
    force dut.sum_fault=1'b1;
    @(posedge clk);@(negedge clk);release dut.sum_fault;faults=faults+1;
   end
   while(!m_valid)@(negedge clk);
   if(m_error!==es[2:0]||m_header!==eh||m_prefix!==ep||m_prefix_length!==elen[5:0]||
      m_next_hop!==ev[31:0]||m_port!==ev[39:32]||m_count!==ec[CW-1:0]||m_tag!==tag[T-1:0])
    $fatal(1,"packet mismatch vector=%0d error=%0d/%0d header=%040h/%040h",vectors,m_error,es,m_header,eh);
   repeat(4)begin @(negedge clk);if(future&&c_ready)$fatal(1,"future escaped held packet");end
   m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;
   if(future)finish_future(future);
  end
 endtask
 // Independent straight word sum only for reset/recovery fixtures, not main goldens.
 function automatic [159:0] checksum_header(input [159:0] h);
  reg [159:0] z;reg [31:0] s;integer i;
  begin
   z=h;z[79:64]=0;s=0;
   for(i=0;i<10;i=i+1)s=s+z[159-16*i -:16];
   while(s>>16)s=(s&65535)+(s>>16);
   z[79:64]=~s[15:0];checksum_header=z;
  end
 endfunction
 task automatic seed_default;
  begin
   op=1;key=0;len=0;val=40'h0100000000;tag=7;es=0;ef=0;ei=1;ep=0;elen=0;ev=0;ec=1;
   offer_cfg();finish_cfg(0);
  end
 endtask
 task automatic setup_packet;
  reg [159:0] temp;
  begin
   hin=checksum_header(160'h450000140001000040110000c00002010a010203);
   available=20;tag=9;es=0;ep=0;elen=0;ev=40'h010a010203;ec=1;
   temp=hin;temp[95:88]=temp[95:88]-1'b1;eh=checksum_header(temp);
  end
 endtask
 task automatic reset_live_cases;
  integer phase;
  begin
   for(phase=0;phase<4;phase=phase+1)begin
    hard_reset();seed_default();
    if(phase==3)begin
     op=1;key=0;len=0;val=40'h0200000000;tag=3;offer_cfg();
     while(!c_rsp_valid)@(negedge clk);
     repeat(3)@(negedge clk);
    end else begin
     setup_packet();offer_packet();
     if(phase==0)while(!(dut.state==5&&dut.sum_out_valid))@(negedge clk);
     else if(phase==1)while(!(dut.state==7&&!dut.table_r_valid))@(negedge clk);
     else begin while(!m_valid)@(negedge clk);repeat(3)@(negedge clk);end
    end
    hard_reset();reset_cases=reset_cases+1;
    seed_default();setup_packet();offer_packet();finish_packet(0,0);
   end
  end
 endtask
 integer fd,total,index,got;reg [2047:0] filename;
 initial begin
  if(!$value$plusargs("vectors=%s",filename))$fatal(1,"vectors missing");
  hard_reset();fd=$fopen(filename,"r");if(!fd)$fatal(1,"vector file");
  got=$fscanf(fd,"%d\n",total);if(got!=1)$fatal(1,"vector header");
  for(index=0;index<total;index=index+1)begin
   got=$fscanf(fd,"%d %d %h %h %h %h %d %h %d %d %d %h %d %h %d %h\n",
    kind,op,key,len,val,tag,available,hin,es,ef,ei,ep,elen,ev,ec,eh);
   if(got!=16)$fatal(1,"malformed vector %0d fields=%0d",index,got);
   vectors=vectors+1;
   if(kind==0)begin vector_cfg=vector_cfg+1;offer_cfg();finish_cfg(index%3==2?0:index%3+1);end
   else if(kind==1||kind==3)begin vector_packets=vector_packets+1;offer_packet();finish_packet(index%3==2?0:index%3+1,kind==3);end
   else if(kind==2)begin vector_resets=vector_resets+1;hard_reset();end
   else $fatal(1,"kind");
  end
  $fclose(fd);reset_live_cases();simultaneous_priority();
  repeat(4)@(negedge clk);
  if(c_valid||p_valid||c_rsp_valid||m_valid||future_configs<10||future_packets<10||holds<100||preoffers<10||reset_cases!=4||faults!=1)
   $fatal(1,"coverage or outstanding ownership");
  $display("PASS ipv4_lpm_forward N=%0d T=%0d vectors=%0d vector_cfg=%0d vector_packets=%0d vector_resets=%0d faults=%0d futures=%0d future_configs=%0d future_packets=%0d holds=%0d preoffers=%0d resets=%0d reset_cases=%0d priority_checks=%0d cfg_accepts=%0d cfg_results=%0d packet_accepts=%0d packet_results=%0d cycles=%0d",
   N,T,vectors,vector_cfg,vector_packets,vector_resets,faults,futures,future_configs,future_packets,holds,preoffers,resets,reset_cases,priority_checks,cfg_accepts,cfg_results,packet_accepts,packet_results,cycles);
  $finish;
 end
endmodule
