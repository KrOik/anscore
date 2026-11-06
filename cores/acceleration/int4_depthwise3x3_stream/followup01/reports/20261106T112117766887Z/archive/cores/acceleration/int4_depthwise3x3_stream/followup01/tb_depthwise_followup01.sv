`timescale 1ns/1ps
module tb_depthwise;
 parameter C=3,W=7,H=5,T=8,RGB=0;
 localparam MAXS=W*H*C;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,c_rsp_ready=0,cmd_valid=0,s_valid=0,m_ready=0,rsp_ready=0;
 reg [1:0] c_op=0;
 reg [31:0] c_channel=0,c_word=0,c_weights=0,c_bias=0;
 reg [15:0] c_scale=1;reg [4:0] c_shift=0;reg [7:0] c_zero=0;
 reg [31:0] cmd_width=3,cmd_height=3,cmd_channels=1;
 reg [7:0] cmd_x_zero=0;reg [T-1:0] cmd_tag=0;
 reg [23:0] s_data=0;reg s_sof=0,s_eol=0,s_last=0;
 wire c_ready,c_rsp_valid,cmd_ready,s_ready,m_valid,rsp_valid;
 wire [1:0] c_rsp_error;wire [2:0] rsp_error;
 wire [23:0] m_data;wire [2:0] m_clip,m_inexact;
 wire [31:0] m_x,m_y,m_channel,rsp_count;
 wire m_sof,m_eol,m_last;wire [T-1:0] m_tag,rsp_tag;
 wire [4:0] debug_state;
 generate if(RGB)begin: g_rgb
  rgb_depthwise_filter #(.MAX_WIDTH(W),.MAX_HEIGHT(H),.TAG_W(T)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_op(c_op),.c_channel(c_channel),
   .c_word(c_word),.c_weights(c_weights),.c_bias(c_bias),.c_scale(c_scale),.c_shift(c_shift),.c_zero(c_zero),
   .c_rsp_valid(c_rsp_valid),.c_rsp_ready(c_rsp_ready),.c_rsp_error(c_rsp_error),
   .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_width(cmd_width),.cmd_height(cmd_height),
   .cmd_x_zero(cmd_x_zero),.cmd_tag(cmd_tag),.s_valid(s_valid),.s_ready(s_ready),.s_rgb(s_data),
   .s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),.m_valid(m_valid),.m_ready(m_ready),.m_rgb(m_data),
   .m_clip(m_clip),.m_inexact(m_inexact),.m_x(m_x),.m_y(m_y),.m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),.m_tag(m_tag),
   .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_error(rsp_error),.rsp_pixels(rsp_count),.rsp_tag(rsp_tag));
  assign m_channel=0;assign debug_state=dut.core.state;
 end else begin: g_core
  wire [7:0] scalar;wire clip,inexact;
  int4_depthwise3x3_stream #(.MAX_CHANNELS(C),.MAX_WIDTH(W),.MAX_HEIGHT(H),.TAG_W(T)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_op(c_op),.c_channel(c_channel),
   .c_word(c_word),.c_weights(c_weights),.c_bias(c_bias),.c_scale(c_scale),.c_shift(c_shift),.c_zero(c_zero),
   .c_rsp_valid(c_rsp_valid),.c_rsp_ready(c_rsp_ready),.c_rsp_error(c_rsp_error),
   .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_width(cmd_width),.cmd_height(cmd_height),.cmd_channels(cmd_channels),
   .cmd_x_zero(cmd_x_zero),.cmd_tag(cmd_tag),.s_valid(s_valid),.s_ready(s_ready),.s_data(s_data[7:0]),
   .s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),.m_valid(m_valid),.m_ready(m_ready),.m_data(scalar),
   .m_clip(clip),.m_inexact(inexact),.m_x(m_x),.m_y(m_y),.m_channel(m_channel),
   .m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),.m_tag(m_tag),
   .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_error(rsp_error),.rsp_outputs(rsp_count),.rsp_tag(rsp_tag));
  assign m_data={16'b0,scalar};assign m_clip={2'b0,clip};assign m_inexact={2'b0,inexact};
  assign debug_state=dut.state;
 end endgenerate
 integer cycles=0,holds=0,cfg_holds=0,done_holds=0,preoffers=0;
 integer inputs=0,outputs=0,frames=0,reset_phases=0,faults=0;
 integer ready_mode=0,token_stall=0;
 reg checking=0;
 reg [23:0] expected_data[0:MAXS-1];
 reg [2:0] expected_clip[0:MAXS-1],expected_inexact[0:MAXS-1];
 integer ex[0:MAXS-1],ey[0:MAXS-1],ec[0:MAXS-1];
 reg eso[0:MAXS-1],eeol[0:MAXS-1],elast[0:MAXS-1];
 reg [7:0] image[0:MAXS-1];
 integer output_index=0,expected_count=0;
 reg [T-1:0] expected_tag;
 reg held=0;reg [24+3+3+32+32+32+3+T-1:0] held_payload;
 wire [24+3+3+32+32+32+3+T-1:0] payload={m_data,m_clip,m_inexact,m_x,m_y,m_channel,m_sof,m_eol,m_last,m_tag};
 always @(negedge clk)begin
  if(rst || ready_mode==0)begin m_ready=0;token_stall=0;end
  else if(ready_mode==2)begin m_ready=1;token_stall=0;end
  else if(!m_valid)begin m_ready=0;token_stall=0;end
  else if(token_stall<3)begin m_ready=0;token_stall=token_stall+1;end
  else m_ready=(cycles%11>=4 && cycles%7!=0);
 end
 always @(posedge clk)begin
  cycles=cycles+1;
  if(cycles>1000000)$fatal(1,"finite watchdog");
  if(rst)held=0;
  else begin
   if(held && (!m_valid || payload!==held_payload))$fatal(1,"unstable held output");
   held=m_valid && !m_ready;
   if(held)begin held_payload=payload;holds=holds+1;end
   if(m_valid && m_ready && checking)begin
    if(output_index>=expected_count)$fatal(1,"extra output");
    if(m_data!==expected_data[output_index] || m_clip!==expected_clip[output_index] ||
       m_inexact!==expected_inexact[output_index] || m_x!==ex[output_index] || m_y!==ey[output_index] ||
       m_channel!==(RGB?0:ec[output_index]) || m_sof!==eso[output_index] ||
       m_eol!==eeol[output_index] || m_last!==elast[output_index] || m_tag!==expected_tag)
     $fatal(1,"numeric/metadata output %0d got=%h exp=%h x=%0d y=%0d c=%0d clip=%h/%h inexact=%h/%h",
       output_index,m_data,expected_data[output_index],m_x,m_y,m_channel,m_clip,expected_clip[output_index],m_inexact,expected_inexact[output_index]);
    output_index=output_index+1;outputs=outputs+1;
   end
  end
 end
 task reset_now;
 begin
  @(negedge clk);rst=1;c_valid=0;cmd_valid=0;s_valid=0;rsp_ready=0;c_rsp_ready=0;checking=0;ready_mode=0;
  repeat(3)@(posedge clk);
  @(negedge clk);rst=0;
  @(posedge clk);if(m_valid || rsp_valid || c_rsp_valid)$fatal(1,"reset ownership");
 end
 endtask
 task send_config(input integer op,ch,wordno,input reg[31:0] w,b,input integer sc,sh,z,err);
 integer j;reg [1:0] saved;
 begin
  @(negedge clk);c_op=op;c_channel=ch;c_word=wordno;c_weights=w;c_bias=b;c_scale=sc;c_shift=sh;c_zero=z;c_valid=1;c_rsp_ready=0;
  @(posedge clk);while(!c_ready)@(posedge clk);
  @(negedge clk);c_valid=0;
  @(posedge clk);while(!c_rsp_valid)@(posedge clk);
  saved=c_rsp_error;if(saved!==err[1:0])$fatal(1,"send_config error got=%0d expected=%0d",saved,err);
  repeat(3)begin @(posedge clk);if(!c_rsp_valid || c_rsp_error!==saved || cmd_ready || c_ready)$fatal(1,"send_config hold");cfg_holds=cfg_holds+1;end
  @(negedge clk);c_rsp_ready=1;
  @(posedge clk);@(negedge clk);c_rsp_ready=0;
 end
 endtask
 task command(input integer ww,hh,cc,xz,tg);
 begin
  @(negedge clk);cmd_width=ww;cmd_height=hh;cmd_channels=cc;cmd_x_zero=xz;cmd_tag=tg;cmd_valid=1;
  @(posedge clk);while(!cmd_ready)@(posedge clk);
  @(negedge clk);cmd_valid=0;
 end
 endtask
 task completion(input integer err,count,tg,offer);
 integer j;reg [T-1:0] saved_tag;
 begin
  @(posedge clk);while(!rsp_valid)@(posedge clk);
  if(rsp_error!==err[2:0] || rsp_count!==count || rsp_tag!==T'(tg))
   $fatal(1,"completion got err=%0d count=%0d tag=%h expected %0d %0d %0d",rsp_error,rsp_count,rsp_tag,err,count,tg);
  if(offer)begin
   @(negedge clk);cmd_valid=1;cmd_width=32'h80000003;cmd_height=3;cmd_channels=1;cmd_tag=~T'(tg);
  end
  repeat(4)begin
   @(posedge clk);
   if(!rsp_valid || rsp_error!==err[2:0] || rsp_count!==count || rsp_tag!==T'(tg) || cmd_ready || c_ready)
    $fatal(1,"done ownership");
   done_holds=done_holds+1;if(offer)preoffers=preoffers+1;
  end
  @(negedge clk);rsp_ready=1;
  @(posedge clk);if(cmd_ready)$fatal(1,"accepted on prior completion retirement");
  @(negedge clk);rsp_ready=0;
  if(offer)begin
   // The future transaction remains asserted until its actual acceptance.
   @(posedge clk);while(!cmd_ready)@(posedge clk);
   saved_tag=cmd_tag;
   @(negedge clk);cmd_valid=0;
   @(posedge clk);while(!rsp_valid)@(posedge clk);
   if(rsp_error!==1 || rsp_count!==0 || rsp_tag!==saved_tag)$fatal(1,"future tag/error");
   @(negedge clk);rsp_ready=1;
   @(posedge clk);@(negedge clk);rsp_ready=0;
  end
 end
 endtask
 task send_scalar(input reg[23:0] value,input integer sof,eol,last);
 begin
  repeat(cycles%3)@(negedge clk);
  @(negedge clk);s_data=value;s_sof=sof;s_eol=eol;s_last=last;s_valid=1;
  @(posedge clk);while(!s_ready)@(posedge clk);
  if(checking)inputs=inputs+1;
  @(negedge clk);s_valid=0;
 end
 endtask
 task identity_config(input integer cc);
 integer k;
 begin
  for(k=0;k<cc;k=k+1)begin
   send_config(0,k,0,32'h00010000,0,0,0,0,0);send_config(0,k,1,0,0,0,0,0,0);send_config(1,k,0,0,0,1,0,0,0);
  end
 end
 endtask
 integer f,fd,nframes,n,w,h,cc,xz,tg,bad,ni,no,k,a;
 integer sc,sh,z,d,cl,ix,xx,yy,ch,so,eo,la,unit_no,phase;
 reg [31:0] w0,w1,bias;reg[7:0] zz;
 reg [23:0] grouped;reg[2:0] grouped_cl,grouped_ix;
 reg [2047:0] filename;
 initial begin
  if(!$value$plusargs("vectors=%s",filename))$fatal(1,"missing vectors");
  fd=$fopen(filename,"r");if(!fd)$fatal(1,"vector open");
  reset_now;
  // Simultaneous offers: configuration wins and owns its held response. The
  // command source keeps valid asserted until the later actual acceptance.
  @(negedge clk);c_valid=1;c_op=3;cmd_valid=1;cmd_width=2;cmd_height=3;cmd_channels=1;cmd_tag=31;
  @(posedge clk);if(!c_ready || cmd_ready)$fatal(1,"configuration priority");
  @(negedge clk);c_valid=0;
  @(posedge clk);while(!c_rsp_valid)@(posedge clk);
  repeat(3)begin @(posedge clk);if(cmd_ready || c_rsp_error!==2)$fatal(1,"priority response hold");end
  @(negedge clk);c_rsp_ready=1;
  @(posedge clk);if(cmd_ready)$fatal(1,"priority owner retirement");
  @(negedge clk);c_rsp_ready=0;
  @(posedge clk);while(!cmd_ready)@(posedge clk);
  @(negedge clk);cmd_valid=0;
  completion(1,0,31,0);
  command(3,3,RGB?3:1,0,7);completion(2,0,7,0);
  command(32'h80000003,3,1,0,9);completion(1,0,9,0);
  // Full-width bad send_config indexes/opcodes preserve valid configuration.
  send_config(0,32'h80000000,0,0,0,0,0,0,1);
  send_config(0,0,32'h80000001,0,0,0,0,0,1);send_config(3,0,0,0,0,0,0,0,2);
  // First word and metadata alone must not qualify a channel.
  send_config(0,0,0,32'h00010000,0,0,0,0,0);send_config(1,0,0,0,0,1,0,0,0);
  command(3,3,RGB?3:1,0,13);completion(2,0,13,0);
  send_config(2,0,0,0,0,0,0,0,0);
  a=$fscanf(fd,"%d",nframes);if(a!=1 || nframes!=6)$fatal(1,"frame count");
  for(f=0;f<nframes;f=f+1)begin
   a=$fscanf(fd,"%d %d %d %d %d %d %d %d",w,h,cc,xz,tg,bad,ni,no);if(a!=8)$fatal(1,"header");
   for(k=0;k<cc;k=k+1)begin
    a=$fscanf(fd,"%h %h %h %d %d %h",w0,w1,bias,sc,sh,zz);if(a!=6)$fatal(1,"kernel vector");
    send_config(0,k,0,w0,0,0,0,0,0);send_config(0,k,1,w1,0,0,0,0,0);send_config(1,k,0,0,bias,sc,sh,zz,0);
   end
   for(k=0;k<ni;k=k+1)begin a=$fscanf(fd,"%h",image[k]);if(a!=1)$fatal(1,"input vector");end
   for(k=0;k<no;k=k+1)begin
    a=$fscanf(fd,"%h %d %d %d %d %d %d %d %d",d,cl,ix,xx,yy,ch,so,eo,la);if(a!=9)$fatal(1,"expected vector");
    unit_no=RGB?k/3:k;
    if(RGB)begin
     if(k%3==0)begin grouped=0;grouped_cl=0;grouped_ix=0;eso[unit_no]=so;end
     grouped={grouped[15:0],d[7:0]^8'h80};grouped_cl={grouped_cl[1:0],cl[0]};grouped_ix={grouped_ix[1:0],ix[0]};
     expected_data[unit_no]=grouped;expected_clip[unit_no]=grouped_cl;expected_inexact[unit_no]=grouped_ix;
    end else begin expected_data[unit_no]={16'b0,d[7:0]};expected_clip[unit_no]=cl;expected_inexact[unit_no]=ix;eso[unit_no]=so;end
    ex[unit_no]=xx;ey[unit_no]=yy;ec[unit_no]=ch;eeol[unit_no]=eo;elast[unit_no]=la;
   end
   expected_count=RGB?no/3:no;output_index=0;expected_tag=tg;checking=1;ready_mode=1;
   command(w,h,cc,xz,tg);
   for(k=0;k<ni;k=k+(RGB?3:1))begin
    grouped=RGB?{image[k],image[k+1],image[k+2]}:{16'b0,image[k]};
    send_scalar(grouped,(k==0)^((bad!=0)&&(k==0)),k%(w*cc)==w*cc-(RGB?3:1),k==ni-(RGB?3:1));
   end
   completion(bad?3:0,expected_count,tg,1);
   if(output_index!=expected_count)$fatal(1,"missing outputs");checking=0;frames=frames+1;
  end
  a=$fscanf(fd,"%s",filename);if(a==1)$fatal(1,"trailing vector records");$fclose(fd);
  // Four live cancellation phases, each followed by missing-send_config completion.
  for(phase=0;phase<4;phase=phase+1)begin
   identity_config(RGB?3:1);ready_mode=0;
   command(3,3,RGB?3:1,0,phase);
   if(phase==1)send_scalar(24'h010203,1,0,0);
   if(phase>=2)begin
    fork
     begin for(k=0;k<(RGB?9:9);k=k+1)send_scalar(24'h010203,k==0,k%3==2,k==8);end
     begin
      if(phase==2)begin wait(debug_state==12);end
      else begin wait(m_valid);end
     end
    join
   end
   reset_now;reset_phases=reset_phases+1;
   command(3,3,RGB?3:1,0,17+phase);completion(2,0,17+phase,0);
  end
  // Recover after reset with a real all-zero 3x3 frame and verify output directly.
  identity_config(RGB?3:1);ready_mode=0;command(3,3,RGB?3:1,0,29);
  for(k=0;k<9;k=k+1)send_scalar(0,k==0,k%3==2,k==8);
  wait(m_valid);if(m_data!==(RGB?24'h808080:24'h000000) || !m_sof || !m_eol || !m_last)$fatal(1,"recovery data");
  ready_mode=2;completion(0,1,29,0);
  if(holds<10 || cfg_holds<10 || done_holds<10 || preoffers!=24 || reset_phases!=4)$fatal(1,"coverage");
  $display("PASS depthwise C=%0d W=%0d H=%0d T=%0d RGB=%0d frames=%0d inputs=%0d outputs=%0d holds=%0d cfg_holds=%0d done_holds=%0d preoffers=%0d resets=%0d",C,W,H,T,RGB,frames,inputs,outputs,holds,cfg_holds,done_holds,preoffers,reset_phases);
  $finish;
 end
endmodule
