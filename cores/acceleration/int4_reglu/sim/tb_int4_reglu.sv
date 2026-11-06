// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_int4_reglu;
 parameter H=3,C=9,T=8,EX=0;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,c_branch=0,c_rsp_ready=0,cmd_valid=0,s_valid=0,s_last=0,m_ready=0;
 reg [2:0] c_op=0;reg[15:0]c_row=0,c_word=0,cmd_hidden=0,cmd_cols=0;
 reg[31:0]c_weights=0;reg signed[31:0]c_bias=0,s_data=0;
 reg[15:0]c_scale=0;reg[4:0]c_shift=0,cmd_input_shift=0;reg signed[7:0]c_zero=0;
 reg[7:0]cmd_x_zero=128;reg[T-1:0]cmd_tag=0;
 wire c_ready,c_rsp_valid,cmd_ready,s_ready,m_valid,m_last,m_clip,m_inexact,m_project_clip,m_project_inexact,m_gate_closed,busy;
 wire[1:0]c_error;wire[2:0]m_error;wire signed[7:0]m_data;wire[15:0]m_index;wire[T-1:0]m_tag;
 wire m_input_clip,m_input_inexact;wire[3:0]core_state,child_state;wire prefix_pending;
 generate if(EX)begin:e
  reglu32_input #(.MAX_HIDDEN(H),.MAX_COLS(C),.TAG_W(T)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_op(c_op),.c_branch(c_branch),.c_row(c_row),.c_word(c_word),
   .c_weights(c_weights),.c_bias(c_bias),.c_scale(c_scale),.c_shift(c_shift),.c_zero(c_zero),.c_rsp_valid(c_rsp_valid),.c_rsp_ready(c_rsp_ready),.c_error(c_error),
   .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_hidden(cmd_hidden),.cmd_cols(cmd_cols),.cmd_input_shift(cmd_input_shift),.cmd_tag(cmd_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_last(s_last),.m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_index(m_index),.m_tag(m_tag),
   .m_last(m_last),.m_clip(m_clip),.m_inexact(m_inexact),.m_project_clip(m_project_clip),.m_project_inexact(m_project_inexact),.m_gate_closed(m_gate_closed),
   .m_input_clip(m_input_clip),.m_input_inexact(m_input_inexact),.m_error(m_error),.busy(busy));
  assign core_state=dut.core.state;assign child_state=dut.core.projections.state;assign prefix_pending=dut.pending;
 end else begin:p
  int4_reglu #(.MAX_HIDDEN(H),.MAX_COLS(C),.TAG_W(T)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_op(c_op),.c_branch(c_branch),.c_row(c_row),.c_word(c_word),
   .c_weights(c_weights),.c_bias(c_bias),.c_scale(c_scale),.c_shift(c_shift),.c_zero(c_zero),.c_rsp_valid(c_rsp_valid),.c_rsp_ready(c_rsp_ready),.c_error(c_error),
   .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_hidden(cmd_hidden),.cmd_cols(cmd_cols),.cmd_x_zero(cmd_x_zero),.cmd_tag(cmd_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data[7:0]),.s_last(s_last),.m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_index(m_index),.m_tag(m_tag),
   .m_last(m_last),.m_clip(m_clip),.m_inexact(m_inexact),.m_project_clip(m_project_clip),.m_project_inexact(m_project_inexact),.m_gate_closed(m_gate_closed),.m_error(m_error),.busy(busy));
  assign core_state=dut.state;assign child_state=dut.projections.state;assign prefix_pending=0;assign m_input_clip=0;assign m_input_inexact=0;
 end endgenerate
 wire[T+34:0]payload={m_data,m_index,m_tag,m_last,m_error,m_clip,m_inexact,m_project_clip,m_project_inexact,m_gate_closed,m_input_clip,m_input_inexact};
 reg held=0;reg[T+34:0]held_payload;
 integer holds=0,outputs=0,samples=0,configs=0,queries=0,resets=0,priorities=0,prefix_resets=0;
 always @(posedge clk)begin
  if(rst)held<=0;
  else begin
   if(held && (!m_valid || payload!==held_payload))$fatal(1,"held output changed");
   held<=m_valid && !m_ready;held_payload<=payload;
   if(m_valid && !m_ready)holds<=holds+1;
   if(m_valid && m_ready)outputs<=outputs+1;
   if(s_valid && s_ready)samples<=samples+1;
   if(c_valid && c_ready)configs<=configs+1;
   if(cmd_valid && cmd_ready)queries<=queries+1;
  end
 end
 task reset_now;
  begin
   rst=1;c_valid=0;cmd_valid=0;s_valid=0;m_ready=0;c_rsp_ready=0;
   repeat(2)@(negedge clk);
   if(m_valid || c_rsp_valid || s_ready || cmd_ready || c_ready)$fatal(1,"reset gates");
   rst=0;resets=resets+1;@(negedge clk);
   if(m_valid || c_rsp_valid || busy)$fatal(1,"reset ownership");
  end
 endtask
 task config_cmd(input integer op,row,branch,word,input reg[31:0]weights,input integer bias,scale,shift,zero,error);
  integer n;reg[1:0]held_error;
  begin
   @(negedge clk);c_op=op;c_row=row;c_branch=branch;c_word=word;c_weights=weights;c_bias=bias;c_scale=scale;c_shift=shift;c_zero=zero;c_valid=1;n=0;
   while(!c_ready)begin @(negedge clk);n=n+1;if(n>100)$fatal(1,"config ready");end
   @(negedge clk);c_valid=0;n=0;
   while(!c_rsp_valid)begin @(negedge clk);n=n+1;if(n>100)$fatal(1,"config response");end
   held_error=c_error;
   repeat(3)begin if(!c_rsp_valid || c_error!==held_error || c_ready || cmd_ready)$fatal(1,"config hold");@(negedge clk);end
   if(c_error!==error[1:0])$fatal(1,"config status got%0d want%0d",c_error,error);
   c_rsp_ready=1;@(negedge clk);c_rsp_ready=0;
  end
 endtask
 task command(input integer n,cols,xzero,tag,pre);
  integer k;
  begin
   @(negedge clk);cmd_hidden=n;cmd_cols=cols;cmd_x_zero=xzero;cmd_tag=tag;cmd_input_shift=pre;cmd_valid=1;k=0;
   while(!cmd_ready)begin @(negedge clk);k=k+1;if(k>100)$fatal(1,"command ready");end
   @(negedge clk);cmd_valid=0;
  end
 endtask
 task sample(input integer data,last);
  integer k;
  begin
   repeat(samples%3)@(negedge clk);s_data=data;s_last=last;s_valid=1;k=0;
   while(!s_ready)begin @(negedge clk);k=k+1;if(k>5000)$fatal(1,"sample ready");end
   @(negedge clk);s_valid=0;
  end
 endtask
 task expect_output(input integer data,index,last,error,clip,ine,pc,pi,closed,tag,ic,ii);
  integer k,j;
  begin
   k=0;while(!m_valid)begin @(negedge clk);k=k+1;if(k>5000)$fatal(1,"output deadline");end
   if($signed(m_data)!==data || m_index!==index[15:0] || m_last!==last[0] || m_error!==error[2:0] || m_clip!==clip[0] || m_inexact!==ine[0] ||
      m_project_clip!==pc[0] || m_project_inexact!==pi[0] || m_gate_closed!==closed[0] || m_tag!==tag[T-1:0] || m_input_clip!==ic[0] || m_input_inexact!==ii[0])
    $fatal(1,"output got d%0d i%0d last%0d err%0d flags%b%b%b%b%b in%b%b tag%0d; want d%0d i%0d err%0d flags%0d%0d%0d%0d%0d in%0d%0d tag%0d",$signed(m_data),m_index,m_last,m_error,m_clip,m_inexact,m_project_clip,m_project_inexact,m_gate_closed,m_input_clip,m_input_inexact,m_tag,data,index,error,clip,ine,pc,pi,closed,ic,ii,tag);
   for(j=0;j<3+(outputs%4);j=j+1)begin if(c_ready || cmd_ready)$fatal(1,"ownership while held");@(negedge clk);end
   m_ready=1;@(negedge clk);m_ready=0;
  end
 endtask
 task state_wait(input integer wanted,input integer child);
  integer k;
  begin k=0;while((child?child_state:core_state)!=wanted)begin @(negedge clk);k=k+1;if(k>10000)$fatal(1,"state deadline %0d child%0d",wanted,child);end end
 endtask
 task live_reset(input integer phase);
  integer i,n;
  begin
   n=C<3?C:3;
   if(phase==0)begin
    @(negedge clk);c_op=3;c_row=0;c_scale=1;c_shift=0;c_zero=0;c_valid=1;
    while(!c_ready)@(negedge clk);@(negedge clk);c_valid=0;
    while(!c_rsp_valid)@(negedge clk);
   end else begin
    command(1,n,128,1,0);
    if(phase==2)state_wait(4,0);
    if(phase>=3 && phase!=7)begin
     if(phase==3)begin if(n>1)sample(EX?0:128,0);end
     else begin
      for(i=0;i<n;i=i+1)sample(EX?0:128,i==n-1);
      if(phase==4)state_wait(6,1);
      if(phase==5)state_wait(7,0);
      if(phase==6)begin while(!m_valid)@(negedge clk);repeat(3)@(negedge clk);end
     end
    end
    if(phase==7)begin
     sample(0,n==1);
     if(!EX || !prefix_pending)$fatal(1,"prefix slot not occupied immediately before reset");
     prefix_resets=prefix_resets+1;
    end
   end
   reset_now();
  end
 endtask
 task priority_flow;
  integer k;
  begin
   @(negedge clk);c_op=3;c_row=0;c_scale=1;c_shift=0;c_zero=29;c_valid=1;
   cmd_hidden=1;cmd_cols=1;cmd_x_zero=128;cmd_tag=1;cmd_input_shift=0;cmd_valid=1;
   #1;
   if(!c_ready || cmd_ready)$fatal(1,"config priority");
   @(negedge clk);c_valid=0;
   while(!c_rsp_valid)@(negedge clk);
   repeat(4)begin if(cmd_ready)$fatal(1,"future command admitted early");@(negedge clk);end
   c_rsp_ready=1;@(negedge clk);c_rsp_ready=0;k=0;
   while(!cmd_ready)begin @(negedge clk);k=k+1;if(k>100)$fatal(1,"future command missing");end
   @(negedge clk);cmd_valid=0;sample(EX?0:128,1);
   while(!m_valid)@(negedge clk);
   c_op=3;c_row=0;c_scale=1;c_shift=0;c_zero=7;c_valid=1;
   repeat(4)begin if(c_ready)$fatal(1,"future configuration admitted early");@(negedge clk);end
   expect_output(35,0,1,0,0,0,0,0,0,1,0,0);
   while(!c_ready)@(negedge clk);@(negedge clk);c_valid=0;
   while(!c_rsp_valid)@(negedge clk);
   if(c_error!=0)$fatal(1,"future configuration failed");
   c_rsp_ready=1;@(negedge clk);c_rsp_ready=0;
   command(1,1,128,1,0);sample(EX?0:128,1);expect_output(13,0,1,0,0,0,0,0,0,1,0,0);priorities=priorities+1;
  end
 endtask
 integer fd,rc,op,a,b,d,e0,f,g,h,i,j,k,nin,nout,st,tag,pre,xzero,idx,lst,err,cl,ine,pc,pi,closed,ic,ii;
 reg[31:0]weights;reg[4095:0]path;
 initial begin
  repeat(3)@(negedge clk);reset_now();
  if(!$value$plusargs("vectors=%s",path))$fatal(1,"vectors required");fd=$fopen(path,"r");if(!fd)$fatal(1,"vectors open");
  while(!$feof(fd))begin
   rc=$fscanf(fd,"%d",op);
   if(rc==1)case(op)
    0:begin rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d",a,b,d,e0,weights,f,g,h,i,j);if(rc!=10)$fatal(1,"C parse");config_cmd(a,b,d,e0,weights,f,g,h,i,j);end
    1:begin
     rc=$fscanf(fd,"%d %d %d %d %d %d %d",a,b,xzero,tag,pre,nin,nout);if(rc!=7)$fatal(1,"Q parse");command(a,b,xzero,tag,pre);
     for(k=0;k<nin;k=k+1)begin rc=$fscanf(fd,"%d %d",a,b);if(rc!=2)$fatal(1,"S parse");sample(a,b);end
     for(k=0;k<nout;k=k+1)begin rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d",a,idx,lst,err,cl,ine,pc,pi,closed,st,ic,ii);if(rc!=12)$fatal(1,"O parse");expect_output(a,idx,lst,err,cl,ine,pc,pi,closed,st,ic,ii);end
    end
    2:begin rc=$fscanf(fd,"%d",a);if(rc!=1)$fatal(1,"R parse");live_reset(a);end
    3:priority_flow();
    default:$fatal(1,"bad vector op");
   endcase
  end
  $fclose(fd);repeat(5)@(negedge clk);if(m_valid || busy)$fatal(1,"extra output/ownership");
  $display("PASS int4_reglu H=%0d C=%0d T=%0d EX=%0d outputs=%0d samples=%0d configs=%0d queries=%0d holds=%0d resets=%0d priorities=%0d prefix_resets=%0d",H,C,T,EX,outputs,samples,configs,queries,holds,resets,priorities,prefix_resets);$finish;
 end
 initial begin #20000000;$fatal(1,"global bounded deadline");end
endmodule
