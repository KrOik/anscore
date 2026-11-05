`timescale 1ns/1ps
module tb_int4_conv3x3_frame;
 parameter MC=8,MW=16,MH=12,T=16;
 localparam MAX_OUT=(MW-2)*(MH-2)*MC;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,c_rsp_ready=0,cmd_valid=0,s_valid=0,m_ready=0,rsp_ready=0;
 reg [1:0] c_op=0;reg [15:0] c_row=0,c_word=0,c_scale=0;
 reg [31:0] c_weights=0;reg signed [31:0] c_bias=0;
 reg [4:0] c_shift=0;reg signed [7:0] c_zero=0;
 wire c_ready,c_rsp_valid;wire [1:0] c_error;
 reg [15:0] cmd_width=0,cmd_height=0,cmd_channels=0;
 reg [7:0] cmd_x_zero=0,s_data=0;reg [T-1:0] cmd_tag=0;
 reg s_sof=0,s_eol=0,s_last=0;
 wire cmd_ready,s_ready,m_valid,m_sof,m_eol,m_last,m_clip,m_inexact,busy,rsp_valid;
 wire signed [7:0] m_data;wire [15:0] m_x,m_y,m_channel;wire [T-1:0] m_tag,rsp_tag;
 wire [3:0] rsp_error;wire [31:0] rsp_outputs;
 int4_conv3x3_frame #(.MAX_CHANNELS(MC),.MAX_WIDTH(MW),.MAX_HEIGHT(MH),.TAG_W(T)) dut(.*);
 integer fd,rv,op,a,b,c,d,e,f,g,h,j,k,ns,ne,expected_error;
 integer samples[0:MW*MH-1],sofs[0:MW*MH-1],eols[0:MW*MH-1],lasts[0:MW*MH-1];
 integer ed[0:MAX_OUT],ex[0:MAX_OUT],ey[0:MAX_OUT],ech[0:MAX_OUT];
 integer es[0:MAX_OUT],ee[0:MAX_OUT],el[0:MAX_OUT],ec[0:MAX_OUT],ei[0:MAX_OUT],et[0:MAX_OUT];
 integer cycles=0,received=0,expected=0,frames=0,outputs=0,stalls=0,configs=0,resets=0,done_holds=0;
 reg collecting=0,force_stall=0,holding=0;
 reg [T+60:0] held;
 wire [T+60:0] payload={m_data,m_x,m_y,m_channel,m_tag,m_sof,m_eol,m_last,m_clip,m_inexact};
 string vectors;
 always @(negedge clk)begin
  cycles=cycles+1;if(cycles>500000)$fatal(1,"bounded watchdog");
  m_ready=collecting&&!force_stall&&(cycles%13>=5);
 end
 always @(posedge clk)if(!rst)begin
  if(holding && (!m_valid||payload!==held))$fatal(1,"held fragment changed");
  holding=m_valid&&!m_ready;held=payload;
  if(holding)stalls=stalls+1;
  if(m_valid&&m_ready)begin
   if(!collecting||received>=expected)$fatal(1,"unexpected output");
   if($signed(m_data)!==ed[received]||m_x!==ex[received][15:0]||m_y!==ey[received][15:0]||
      m_channel!==ech[received][15:0]||m_sof!==es[received][0]||m_eol!==ee[received][0]||
      m_last!==el[received][0]||m_clip!==ec[received][0]||m_inexact!==ei[received][0]||m_tag!==et[received][T-1:0])
    $fatal(1,"pixel %0d got d%0d x%0d y%0d ch%0d s%0d e%0d l%0d c%0d i%0d expected d%0d x%0d y%0d ch%0d s%0d e%0d l%0d c%0d i%0d",
     received,$signed(m_data),m_x,m_y,m_channel,m_sof,m_eol,m_last,m_clip,m_inexact,
     ed[received],ex[received],ey[received],ech[received],es[received],ee[received],el[received],ec[received],ei[received]);
   received=received+1;outputs=outputs+1;
  end
  if(rsp_valid&&collecting&&received!=expected)$fatal(1,"completion before all outputs");
  if(busy&&c_ready)$fatal(1,"busy configuration accepted");
 end
 task reset_core;
  begin
   @(negedge clk);rst=1;c_valid=0;cmd_valid=0;s_valid=0;rsp_ready=0;c_rsp_ready=0;
   collecting=0;force_stall=0;holding=0;
   repeat(2)@(posedge clk);
   @(negedge clk);rst=0;resets=resets+1;
   @(posedge clk);if(busy||m_valid||rsp_valid||s_ready)$fatal(1,"reset cancellation");
  end
 endtask
 task command(input integer w,ht,ch,z,tg);
  begin
   @(negedge clk);cmd_width=w;cmd_height=ht;cmd_channels=ch;cmd_x_zero=z;cmd_tag=tg;cmd_valid=1;
   do @(posedge clk);while(!cmd_ready);
   @(negedge clk);cmd_valid=0;
  end
 endtask
 task sample(input integer data,sf,ep,lp);
  begin
   @(negedge clk);s_data=data;s_sof=sf;s_eol=ep;s_last=lp;s_valid=1;
   do @(posedge clk);while(!s_ready);
   @(negedge clk);s_valid=0;
  end
 endtask
 initial begin
  if(!$value$plusargs("vectors=%s",vectors))$fatal(1,"vectors required");
  fd=$fopen(vectors,"r");if(!fd)$fatal(1,"file missing");
  reset_core();
  while(!$feof(fd))begin
   rv=$fscanf(fd,"%d",op);
   if(rv==1)case(op)
    0:begin
     rv=$fscanf(fd,"%d %d %d %d %d %d %d %d %d",a,b,c,d,e,f,g,h,j);if(rv!=9)$fatal(1,"config record");
     @(negedge clk);c_op=a;c_row=b;c_word=c;c_weights=d;c_bias=e;c_scale=f;c_shift=g;c_zero=h;c_valid=1;
     do @(posedge clk);while(!c_ready);
     @(negedge clk);c_valid=0;
     do @(posedge clk);while(!c_rsp_valid);
     repeat(3)begin if(!c_rsp_valid||c_error!==j[1:0])$fatal(1,"config result");@(posedge clk);end
     @(negedge clk);c_rsp_ready=1;@(posedge clk);@(negedge clk);c_rsp_ready=0;configs=configs+1;
    end
    1:begin
     rv=$fscanf(fd,"%d %d %d %d %d %d %d %d",a,b,c,d,e,ns,ne,expected_error);if(rv!=8)$fatal(1,"frame record");
     for(k=0;k<ns;k=k+1)begin rv=$fscanf(fd,"%d %d %d %d",samples[k],sofs[k],eols[k],lasts[k]);if(rv!=4)$fatal(1,"sample record");end
     for(k=0;k<ne;k=k+1)begin
      rv=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d",ed[k],ex[k],ey[k],ech[k],es[k],ee[k],el[k],ec[k],ei[k],et[k]);
      if(rv!=10)$fatal(1,"oracle record");
     end
     received=0;expected=ne;collecting=1;command(a,b,c,d,e);
     for(k=0;k<ns;k=k+1)begin repeat(k%4)@(negedge clk);sample(samples[k],sofs[k],eols[k],lasts[k]);end
     do @(posedge clk);while(!rsp_valid);
     repeat(5)begin
      if(!rsp_valid||rsp_error!==expected_error[3:0]||rsp_outputs!==ne[31:0]||rsp_tag!==e[T-1:0])$fatal(1,"frame completion");
      done_holds=done_holds+1;@(posedge clk);
     end
     @(negedge clk);rsp_ready=1;@(posedge clk);@(negedge clk);rsp_ready=0;collecting=0;frames=frames+1;
     if(busy)$fatal(1,"completion failed to release");
    end
    2:reset_core();
    3:begin
     rv=$fscanf(fd,"%d",a);if(rv!=1)$fatal(1,"reset phase record");
     force_stall=1;command(3,3,MC,128,0);
     if(a==0)repeat(1)@(negedge clk);
     else if(a==1)begin
      sample(11,1,0,0);sample(22,0,0,0);
     end else begin
      for(k=0;k<9;k=k+1)sample(k,k==0,k%3==2,k==8);
      if(a==2)repeat(22)@(negedge clk);
      else begin do @(posedge clk);while(!m_valid);repeat(4)@(negedge clk);end
     end
     reset_core();
    end
    default:$fatal(1,"bad operation");
   endcase
  end
  repeat(8)@(posedge clk);
  if(m_valid||rsp_valid||busy)$fatal(1,"trailing output");
  $display("PASS int4_conv3x3_frame C=%0d W=%0d H=%0d T=%0d frames=%0d outputs=%0d configs=%0d stalls=%0d done_holds=%0d resets=%0d",MC,MW,MH,T,frames,outputs,configs,stalls,done_holds,resets);
  $finish;
 end
endmodule
