// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_winograd;
 parameter integer MAX_ROWS=3,TAG_W=17,WRAPPED=0;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,c_rsp_ready=0,cmd_valid=0,s_valid=0,rsp_ready=0;
 reg [1:0] c_op=0;
 reg [15:0] c_row=0;
 reg [3:0] c_tap=0;
 reg signed [3:0] c_weight=0;
 reg signed [31:0] c_bias=0;
 reg [15:0] c_scale=0;
 reg [5:0] c_shift=0;
 reg signed [7:0] c_zero=0;
 reg [15:0] cmd_rows=0;
 reg [7:0] cmd_x_zero=0,s_data=0;
 reg [TAG_W-1:0] cmd_tag=0;
 reg s_last=0,m_ready=0;
 wire c_ready,c_rsp_valid,cmd_ready,s_ready,m_valid,m_last,rsp_valid,busy;
 wire [1:0] c_error,rsp_error,m_pixel;
 wire [15:0] m_row,m_scale;
 wire [4:0] m_shift,state_view;
 wire signed [7:0] m_zero,m_data;
 wire signed [32:0] m_acc;
 wire [TAG_W-1:0] m_tag,rsp_tag;
 wire [8:0] rsp_outputs;
 wire m_clip,m_inexact;
 wire [1:0] identity_low;
 generate if(WRAPPED) begin: wrapped
  winograd_requantize #(.MAX_ROWS(MAX_ROWS),.TAG_W(TAG_W)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_op(c_op),
   .c_row(c_row),.c_tap(c_tap),.c_weight(c_weight),.c_bias(c_bias),
   .c_scale(c_scale),.c_shift(c_shift),.c_zero(c_zero),.c_rsp_valid(c_rsp_valid),
   .c_rsp_ready(c_rsp_ready),.c_error(c_error),.cmd_valid(cmd_valid),
   .cmd_ready(cmd_ready),.cmd_rows(cmd_rows),.cmd_x_zero(cmd_x_zero),.cmd_tag(cmd_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_last(s_last),
   .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_row(m_row),
   .m_pixel(m_pixel),.m_tag(m_tag),.m_last(m_last),.m_clip(m_clip),.m_inexact(m_inexact),
   .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_error(rsp_error),
   .rsp_outputs(rsp_outputs),.rsp_tag(rsp_tag),.busy(busy)
  );
  assign m_acc=0;assign m_scale=0;assign m_shift=0;assign m_zero=0;
  assign state_view=dut.tile.state;assign identity_low=dut.tile.y4[1:0];
 end else begin: raw
  int4_winograd_tile #(.MAX_ROWS(MAX_ROWS),.TAG_W(TAG_W)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_op(c_op),
   .c_row(c_row),.c_tap(c_tap),.c_weight(c_weight),.c_bias(c_bias),
   .c_scale(c_scale),.c_shift(c_shift),.c_zero(c_zero),.c_rsp_valid(c_rsp_valid),
   .c_rsp_ready(c_rsp_ready),.c_error(c_error),.cmd_valid(cmd_valid),
   .cmd_ready(cmd_ready),.cmd_rows(cmd_rows),.cmd_x_zero(cmd_x_zero),.cmd_tag(cmd_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_last(s_last),
   .m_valid(m_valid),.m_ready(m_ready),.m_acc(m_acc),.m_row(m_row),
   .m_pixel(m_pixel),.m_scale(m_scale),.m_shift(m_shift),.m_zero(m_zero),
   .m_tag(m_tag),.m_last(m_last),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),
   .rsp_error(rsp_error),.rsp_outputs(rsp_outputs),.rsp_tag(rsp_tag),.busy(busy)
  );
  assign m_data=0;assign m_clip=0;assign m_inexact=0;
  assign state_view=dut.state;assign identity_low=dut.y4[1:0];
 end endgenerate

 integer cycles=0,ready_mode=2;
 reg [31:0] lfsr=32'hf2050a39;
 always @(negedge clk) begin
  lfsr={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
  case(ready_mode)
   0:m_ready=0;
   1:m_ready=1;
   default:m_ready=lfsr[0] || lfsr[3];
  endcase
 end
 wire [255:0] out_signature={m_acc,m_row,m_pixel,m_scale,m_shift,m_zero,
                              m_tag,m_last,m_data,m_clip,m_inexact};
 wire [127:0] rsp_signature={rsp_error,rsp_outputs,rsp_tag};
 reg held_output=0,held_response=0,held_config=0;
 reg [255:0] saved_output;
 reg [127:0] saved_response;
 reg [1:0] saved_config;
 reg checking=0;
 integer expected_count=0,out_index=0,expected_error=0;
 reg [TAG_W-1:0] expected_tag=0;
 reg signed [63:0] expected[0:255][0:10];
 integer checked_outputs=0,checked_commands=0,reset_cases=0,config_checks=0;
 always @(posedge clk) begin
  cycles<=cycles+1;
  if(cycles>200000) $fatal(1,"watchdog");
  if(rst) begin held_output<=0;held_response<=0;held_config<=0;end
  else begin
   if(held_output && (!m_valid || out_signature!==saved_output))
    $fatal(1,"output changed under backpressure");
   if(held_response && (!rsp_valid || rsp_signature!==saved_response))
    $fatal(1,"response changed under backpressure");
   if(held_config && (!c_rsp_valid || c_error!==saved_config))
    $fatal(1,"config reply changed under backpressure");
   held_output<=m_valid && !m_ready;saved_output<=out_signature;
   held_response<=rsp_valid && !rsp_ready;saved_response<=rsp_signature;
   held_config<=c_rsp_valid && !c_rsp_ready;saved_config<=c_error;
   if(state_view==14 && identity_low!==2'd0) $fatal(1,"Winograd divide is not exact");
   if(checking && rsp_valid) begin
    if(out_index!=expected_count) $fatal(1,"response overtook public output");
    if(rsp_error!==expected_error[1:0] || rsp_outputs!==expected_count[8:0] || rsp_tag!==expected_tag)
     $fatal(1,"response mismatch err=%0d/%0d count=%0d/%0d tag=%h/%h",
            rsp_error,expected_error,rsp_outputs,expected_count,rsp_tag,expected_tag);
   end
   if(checking && m_valid && m_ready) begin
    if(out_index>=expected_count) $fatal(1,"unexpected output");
    if(m_row!==expected[out_index][0] || m_pixel!==expected[out_index][1] ||
       m_tag!==expected[out_index][6] || m_last!==expected[out_index][7])
     $fatal(1,"output metadata mismatch index=%0d",out_index);
    if(WRAPPED) begin
     if($signed(m_data)!==expected[out_index][8] || m_clip!==expected[out_index][9] ||
        m_inexact!==expected[out_index][10])
      $fatal(1,"requant mismatch index=%0d data=%0d/%0d clip=%b/%0d inexact=%b/%0d",
             out_index,$signed(m_data),expected[out_index][8],m_clip,expected[out_index][9],
             m_inexact,expected[out_index][10]);
    end else begin
     if($signed(m_acc)!==expected[out_index][2] || m_scale!==expected[out_index][3] ||
        m_shift!==expected[out_index][4] || $signed(m_zero)!==expected[out_index][5])
      $fatal(1,"raw mismatch index=%0d acc=%0d/%0d",out_index,$signed(m_acc),expected[out_index][2]);
    end
    out_index<=out_index+1;checked_outputs<=checked_outputs+1;
   end
  end
 end

 integer fd,nread,i,k,kind,tail;
 reg signed [63:0] fields[0:11];
 reg [7:0] samples[0:15];reg lasts[0:15];
 string vector_path;
 task automatic read_record;
  begin
   nread=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d",
    fields[0],fields[1],fields[2],fields[3],fields[4],fields[5],
    fields[6],fields[7],fields[8],fields[9],fields[10],fields[11]);
   if(nread!=12) $fatal(1,"bad vector record fields=%0d",nread);
  end
 endtask
 task automatic arm(input integer nr,input integer xz,input [TAG_W-1:0] tag_in);
  begin
   @(negedge clk);cmd_rows=nr;cmd_x_zero=xz;cmd_tag=tag_in;cmd_valid=1;
   do @(posedge clk);while(!cmd_ready);
   @(negedge clk);cmd_valid=0;cmd_rows=16'hffff;cmd_x_zero=~xz;cmd_tag=~tag_in;
  end
 endtask
 task automatic send_sample(input [7:0] data_in,input last_in,input integer gap);
  begin
   repeat(gap) @(negedge clk);
   @(negedge clk);s_data=data_in;s_last=last_in;s_valid=1;
   do @(posedge clk);while(!s_ready);
   @(negedge clk);s_valid=0;s_data=~data_in;s_last=~last_in;
  end
 endtask
 task automatic finish_response;
  begin
   while(!rsp_valid) @(negedge clk);
   repeat(3) @(negedge clk);
   if(c_ready || cmd_ready || s_ready) $fatal(1,"ownership escaped held response");
   rsp_ready=1;
   @(posedge clk);
   @(negedge clk);rsp_ready=0;checking=0;checked_commands=checked_commands+1;
  end
 endtask
 task automatic config_record;
  reg [1:0] wanted;
  begin
   wanted=fields[9];
   @(negedge clk);
   c_valid=1;c_op=fields[1];c_row=fields[2];c_tap=fields[3];
   c_weight=fields[4];c_bias=fields[5];c_scale=fields[6];c_shift=fields[7];c_zero=fields[8];
   do @(posedge clk);while(!c_ready);
   @(negedge clk);c_valid=0;
   c_op=~c_op;c_row=~c_row;c_tap=~c_tap;c_weight=~c_weight;
   c_bias=~c_bias;c_scale=~c_scale;c_shift=~c_shift;c_zero=~c_zero;
   while(!c_rsp_valid) @(negedge clk);
   repeat(3) @(negedge clk);
   if(c_error!==wanted || cmd_ready || c_ready) $fatal(1,"config response or lock mismatch");
   c_rsp_ready=1;@(posedge clk);@(negedge clk);c_rsp_ready=0;
   config_checks=config_checks+1;
  end
 endtask
 task automatic transaction_record;
  integer nr,xz,ns,j;
  reg [TAG_W-1:0] tag_in;
  begin
   nr=fields[1];xz=fields[2];tag_in=fields[3];expected_error=fields[4];
   expected_count=fields[5];ns=fields[6];expected_tag=tag_in;out_index=0;
   if(expected_count<0 || expected_count>256 || (ns!=0 && ns!=16)) $fatal(1,"bad transaction length");
   for(j=0;j<expected_count;j=j+1) begin
    read_record();if(fields[0]!=2) $fatal(1,"expected output record");
    for(k=0;k<11;k=k+1) expected[j][k]=fields[k+1];
   end
   for(j=0;j<ns;j=j+1) begin
    read_record();if(fields[0]!=3) $fatal(1,"expected sample record");
    samples[j]=fields[1];lasts[j]=fields[2];
   end
   checking=1;arm(nr,xz,tag_in);
   for(j=0;j<ns;j=j+1) send_sample(samples[j],lasts[j],j%3);
   finish_response();
  end
 endtask
 task automatic arbitration_case;
  begin
   expected_count=0;expected_error=1;expected_tag={TAG_W{1'b1}};out_index=0;checking=1;
   @(negedge clk);c_valid=1;c_op=3;cmd_valid=1;cmd_rows=0;cmd_tag=expected_tag;
   @(posedge clk);
   if(!c_ready || cmd_ready) $fatal(1,"config did not win idle arbitration");
   @(negedge clk);c_valid=0;
   repeat(3) begin @(negedge clk);if(cmd_ready) $fatal(1,"command escaped config reply");end
   if(!c_rsp_valid || c_error!=0) $fatal(1,"arbitration config reply");
   c_rsp_ready=1;@(posedge clk);@(negedge clk);c_rsp_ready=0;
   @(posedge clk);if(!cmd_ready) $fatal(1,"held command not accepted after reply");
   @(negedge clk);cmd_valid=0;
   finish_response();
  end
 endtask
 task automatic reset_case(input integer target);
  integer j;
  begin
   checking=0;ready_mode=(target==15 || target==30) ? 0 : 1;
   if(target==1 || target==2) begin
    @(negedge clk);c_op=target==1 ? 0 : 2;c_row=0;c_tap=0;c_weight=-8;c_valid=1;
    do @(posedge clk);while(!c_ready);
    @(negedge clk);c_valid=0;
   end else begin
    arm(1,128,{TAG_W{1'b1}});
    for(j=0;j<(target==7 ? 5 : 16);j=j+1) send_sample(j*13,j==15,0);
   end
   if(target==30) begin while(!m_valid) @(negedge clk);end
   else if(target==16) begin while(!rsp_valid) @(negedge clk);end
   else begin while(state_view!=target) @(negedge clk);end
   if(target==16 || target==30 || (target==15 && !WRAPPED))
    repeat(3) @(negedge clk);
   // Assert on the observed falling-edge boundary, before the target state's
   // next active edge. Do not advance a single-cycle target before reset.
   rst=1;c_valid=0;cmd_valid=0;s_valid=0;c_rsp_ready=0;rsp_ready=0;
   repeat(2) @(posedge clk);
   @(negedge clk);rst=0;ready_mode=2;
   repeat(6) begin
    @(negedge clk);
    if(m_valid || rsp_valid || c_rsp_valid || !c_ready || !cmd_ready)
     $fatal(1,"stale work after reset target=%0d",target);
   end
   reset_cases=reset_cases+1;
  end
 endtask
 initial begin
  if(!$value$plusargs("VECTORS=%s",vector_path)) $fatal(1,"missing VECTORS path");
  fd=$fopen(vector_path,"r");if(!fd) $fatal(1,"cannot open vectors");
  repeat(3) @(posedge clk);@(negedge clk);rst=0;
  kind=0;
  while(kind!=9) begin
   read_record();kind=fields[0];
   case(kind)
    0:config_record();
    1:transaction_record();
    4:arbitration_case();
    5:reset_case(fields[1]);
    9:begin end
    default:$fatal(1,"unexpected vector opcode=%0d",kind);
   endcase
  end
  tail=$fgetc(fd);
  while(tail!=-1) begin
   if(tail!=9 && tail!=10 && tail!=13 && tail!=32) $fatal(1,"trailing vector content");
   tail=$fgetc(fd);
  end
  $fclose(fd);
  repeat(5) @(negedge clk);
  if(m_valid || rsp_valid || c_rsp_valid || busy) $fatal(1,"not drained");
  $display("PASS winograd MAX_ROWS=%0d TAG_W=%0d WRAPPED=%0d commands=%0d outputs=%0d resets=%0d configs=%0d cycles=%0d",
           MAX_ROWS,TAG_W,WRAPPED,checked_commands,checked_outputs,reset_cases,config_checks,cycles);
  $finish;
 end
endmodule
