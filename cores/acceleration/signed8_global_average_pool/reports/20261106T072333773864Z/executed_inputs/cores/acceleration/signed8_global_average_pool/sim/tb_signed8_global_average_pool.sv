// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_signed8_global_average_pool;
 parameter C=5,P=31,T=8,EX=0;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,cmd_valid=0,s_valid=0,s_last=0,m_ready=0,rsp_ready=0;
 reg [16:0]cmd_pixels=0;reg[15:0]cmd_channels=0;reg[T-1:0]cmd_tag=0;
 reg signed[7:0]s_data=0;
 wire cmd_ready,s_ready,m_valid,m_last,m_inexact,m_clip,rsp_valid,busy;
 wire signed[7:0]m_data;wire signed[23:0]m_sum;
 wire[15:0]m_channel,rsp_outputs;wire[T-1:0]m_tag,rsp_tag;
 wire[23:0]rsp_inputs;wire[1:0]rsp_error;wire[3:0]core_state;
 generate if(EX)begin:e
  pooled_int4_classifier #(.MAX_PIXELS(P),.TAG_W(T)) dut(
   .clk(clk),.rst(rst),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_pixels(cmd_pixels),.cmd_tag(cmd_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_last(s_last),
   .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_class(m_channel),.m_tag(m_tag),
   .m_last(m_last),.m_clip(m_clip),.m_inexact(m_inexact),
   .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_error(rsp_error),.rsp_tag(rsp_tag),.busy(busy));
  assign m_sum=0;assign rsp_inputs=0;assign rsp_outputs=0;assign core_state=dut.pool.state;
 end else begin:c
  signed8_global_average_pool #(.MAX_CHANNELS(C),.MAX_PIXELS(P),.TAG_W(T)) dut(
   .clk(clk),.rst(rst),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_pixels(cmd_pixels),.cmd_channels(cmd_channels),.cmd_tag(cmd_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_last(s_last),
   .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_sum(m_sum),.m_channel(m_channel),.m_tag(m_tag),
   .m_last(m_last),.m_inexact(m_inexact),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),
   .rsp_error(rsp_error),.rsp_outputs(rsp_outputs),.rsp_inputs(rsp_inputs),.rsp_tag(rsp_tag),.busy(busy));
  assign m_clip=0;assign core_state=dut.state;
 end endgenerate
 wire[T+50:0]payload={m_data,m_sum,m_channel,m_tag,m_last,m_inexact,m_clip};
 reg held=0;reg[T+50:0]held_data;
 integer cycles=0,outputs=0,inputs=0,frames=0,resets=0,holds=0,rsp_holds=0,iis=0;
 integer vec_outputs=0,vec_inputs=0,clips=0,inexact=0;
 integer mode=0,prev_input=-1;reg vector_phase=0;
 always @(posedge clk) begin
  cycles<=cycles+1;
  if(rst)held<=0;
  else begin
   if(held && (!m_valid || payload!==held_data))$fatal(1,"held payload changed");
   held<=m_valid&&!m_ready;held_data<=payload;
   if(m_valid&&!m_ready)holds<=holds+1;
   if(m_valid&&m_ready)begin
    outputs<=outputs+1;
    if(vector_phase)begin vec_outputs<=vec_outputs+1;clips<=clips+m_clip;inexact<=inexact+m_inexact;end
   end
   if(s_valid&&s_ready)begin
    inputs<=inputs+1;if(vector_phase)vec_inputs<=vec_inputs+1;
    if(mode==1 && prev_input>=0)begin
     if(cycles-prev_input!=2)$fatal(1,"input II got%0d want2",cycles-prev_input);
     iis<=iis+1;
    end
    prev_input<=cycles;
   end
  end
 end
 task reset_now;
  begin
   rst=1;cmd_valid=0;s_valid=0;m_ready=0;rsp_ready=0;mode=0;prev_input=-1;
   repeat(2)@(negedge clk);
   if(cmd_ready||s_ready||m_valid||rsp_valid)$fatal(1,"reset public gating");
   rst=0;resets=resets+1;@(negedge clk);
  end
 endtask
 task command(input integer p,ch,tag);
  integer k;
  begin
   cmd_pixels=p;cmd_channels=ch;cmd_tag=tag;cmd_valid=1;k=0;
   while(!cmd_ready)begin @(negedge clk);k=k+1;if(k>500)$fatal(1,"command deadline");end
   @(negedge clk);cmd_valid=0;prev_input=-1;
  end
 endtask
 task send_sample(input integer data,last,gap);
  integer k;
  begin
   repeat(gap)@(negedge clk);
   s_data=data;s_last=last;s_valid=1;k=0;
   while(!s_ready)begin @(negedge clk);k=k+1;if(k>500)$fatal(1,"input deadline");end
   if(m_valid||rsp_valid)$fatal(1,"result before acquisition completed");
   @(negedge clk);s_valid=0;
  end
 endtask
 task receive(input integer data,total,ine,clip,ch,last,tag);
  integer k;
  begin
   k=0;while(!m_valid)begin @(negedge clk);k=k+1;if(k>1000)$fatal(1,"output deadline");end
   if($signed(m_data)!==data || $signed(m_sum)!==total || m_inexact!==ine[0] ||
      m_clip!==clip[0] || m_channel!==ch[15:0] || m_last!==last[0] || m_tag!==tag[T-1:0])
    $fatal(1,"output got %0d sum%0d ine%b clip%b ch%0d last%b tag%0d want %0d sum%0d ine%0d clip%0d ch%0d tag%0d",
       $signed(m_data),$signed(m_sum),m_inexact,m_clip,m_channel,m_last,m_tag,data,total,ine,clip,ch,tag);
   repeat(3+(ch%3))begin
    if(cmd_ready||rsp_valid||s_ready)$fatal(1,"output ownership");@(negedge clk);
   end
   m_ready=1;@(negedge clk);m_ready=0;
  end
 endtask
 task completion(input integer error,ni,no,tag);
  integer k;reg[T+41:0]save_rsp;
  begin
   k=0;while(!rsp_valid)begin @(negedge clk);k=k+1;if(k>500)$fatal(1,"completion deadline");end
   if(rsp_error!==error[1:0] || rsp_tag!==tag[T-1:0] || (!EX&&(rsp_inputs!==ni[23:0] || rsp_outputs!==no[15:0])))
    $fatal(1,"completion got err%0d in%0d out%0d tag%0d want err%0d in%0d out%0d tag%0d",rsp_error,rsp_inputs,rsp_outputs,rsp_tag,error,ni,no,tag);
   save_rsp={rsp_error,rsp_inputs,rsp_outputs,rsp_tag};
   repeat(4)begin
    if(!rsp_valid || {rsp_error,rsp_inputs,rsp_outputs,rsp_tag}!==save_rsp || cmd_ready||s_ready||m_valid)
     $fatal(1,"completion hold");rsp_holds=rsp_holds+1;@(negedge clk);
   end
   rsp_ready=1;@(negedge clk);rsp_ready=0;
  end
 endtask
 task wait_state(input integer wanted);
  integer k;
  begin k=0;while(core_state!=wanted)begin @(negedge clk);k=k+1;if(k>500)$fatal(1,"state %0d deadline",wanted);end end
 endtask
 task reset_cut(input integer phase);
  integer i,ch;
  begin
   ch=EX?4:1;command(1,ch,1);
   if(phase==1)begin
    while(!s_ready)@(negedge clk);
    s_data=-128;s_last=(ch==1);s_valid=1;@(negedge clk);s_valid=0;wait_state(2);
   end else if(phase>=2)begin
    for(i=0;i<ch;i=i+1)send_sample(-128,i==ch-1,0);
    if(phase==2)wait_state(5);
    if(phase==3)begin while(!m_valid)@(negedge clk);repeat(3)@(negedge clk);end
    if(phase==4)begin
     if(EX)begin receive(-128,0,0,1,0,0,1);receive(0,0,0,0,1,1,1);end
     else receive(-128,-128,0,0,0,1,1);
     while(!rsp_valid)@(negedge clk);
    end
   end
   reset_now();
   command(1,ch,2);mode=0;
   for(i=0;i<ch;i=i+1)send_sample(3+i,i==ch-1,0);
   if(EX)begin receive(7,0,0,0,0,0,2);receive(-1,0,0,0,1,1,2);end
   else receive(3,3,0,0,0,1,2);
   completion(0,ch,EX?2:1,2);
  end
 endtask
 integer fd,rc,p,ch,tag,err,ni,no,v,last,total,ine,clip,j,phase;
 reg[7:0]op;reg[4095:0]path;
 initial begin
  if(!$value$plusargs("vectors=%s",path))$fatal(1,"vectors required");
  reset_now();vector_phase=1;
  fd=$fopen(path,"r");if(!fd)$fatal(1,"open vector");
  rc=$fscanf(fd,"%s",op);
  while(rc==1)begin
   if(op!="F")$fatal(1,"frame record");
   rc=$fscanf(fd,"%d%d%d%d%d%d%d",p,ch,tag,err,ni,no,mode);if(rc!=7)$fatal(1,"frame fields");
   command(p,ch,tag);frames=frames+1;
   for(j=0;j<ni;j=j+1)begin
    rc=$fscanf(fd,"%s%d%d",op,v,last);if(rc!=3||op!="S")$fatal(1,"sample record");
    send_sample(v,last,mode==1?0:j%3);
   end
   for(j=0;j<no;j=j+1)begin
    rc=$fscanf(fd,"%s%d%d%d%d",op,v,total,ine,clip);if(rc!=5||op!="O")$fatal(1,"output record");
    receive(v,total,ine,clip,j,j==no-1,tag);
   end
   completion(err,ni,no,tag);mode=0;
   rc=$fscanf(fd,"%s",op);
  end
  $fclose(fd);vector_phase=0;
  for(phase=0;phase<5;phase=phase+1)reset_cut(phase);
  $display("PASS signed8_global_average_pool C=%0d P=%0d T=%0d EX=%0d frames=%0d inputs=%0d outputs=%0d inexact=%0d clips=%0d iis=%0d holds=%0d rsp_holds=%0d resets=%0d",C,P,T,EX,frames,vec_inputs,vec_outputs,inexact,clips,iis,holds,rsp_holds,resets);
  $finish;
 end
 initial begin #18000000;$fatal(1,"global TB deadline");end
endmodule
