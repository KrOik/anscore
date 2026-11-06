`timescale 1ns/1ps
module tb_int4_subpixel_upsample2x;
 parameter CI=9,CO=3,W=7,H=5,T=8;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,c_rsp_ready=0,cmd_valid=0,s_valid=0,m_ready=0,rsp_ready=0;
 wire c_ready,c_rsp_valid,cmd_ready,s_ready,m_valid,rsp_valid,busy;
 reg [1:0] c_op=0;reg [15:0] c_row=0,c_word=0;
 reg [31:0] c_weights=0;reg signed [31:0] c_bias=0;
 reg [15:0] c_scale=0;reg [4:0] c_shift=0;reg signed [7:0] c_zero=0;
 wire [1:0] c_error;
 reg [15:0] cmd_width=0,cmd_height=0,cmd_in_channels=0,cmd_out_channels=0;
 reg [7:0] cmd_x_zero=0;reg [T-1:0] cmd_tag=0;
 reg [7:0] s_data=0;reg s_sof=0,s_eol=0,s_last=0;
 wire signed [7:0] m_data;wire [15:0] m_x,m_y,m_channel;
 wire [T-1:0] m_tag,rsp_tag;wire m_sof,m_eol,m_last,m_clip,m_inexact;
 wire [2:0] rsp_error;wire [31:0] rsp_inputs,rsp_outputs;
 int4_subpixel_upsample2x #(.MAX_IN_CHANNELS(CI),.MAX_OUT_CHANNELS(CO),.MAX_WIDTH(W),.MAX_HEIGHT(H),.TAG_W(T)) dut(.*);
 integer iv[0:131071],isof[0:131071],ieol[0:131071],ilast[0:131071];
 integer ov[0:131071],oclip[0:131071],oinexact[0:131071],ox[0:131071],oy[0:131071],och[0:131071],osof[0:131071],oeol[0:131071],olast[0:131071];
 integer cop[0:2047],crow[0:2047],cword[0:2047],cbias[0:2047],cscale[0:2047],cshift[0:2047],czero[0:2047],cerror[0:2047];
 reg [31:0] cpacked[0:2047];
 integer fd,nframes,f,i,j,nread,fw,fh,fci,fco,fzero,ftag,ferror,nin,nout,ncfg,doreset;
 integer sent,received,cycles,donewait,gotdone,offers,holds=0,rsp_holds=0,preoffers=0;
 integer frames=0,inputs=0,outputs=0,configs=0,clips=0,inexact=0,resets=0,futures=0,future_commands=0;
 reg [127:0] held_m,held_r;
 reg was_mheld=0,was_rheld=0,input_fire=0,was_cmdheld=0,was_cheld=0,was_sheld=0,arbitrate_once=1;
 reg [127:0] held_cmd,held_c;reg [10:0] held_s;
 reg [1023:0] vector_path;
 wire [127:0] mp={m_data,m_x,m_y,m_channel,m_tag,m_sof,m_eol,m_last,m_clip,m_inexact};
 wire [127:0] rp={rsp_error,rsp_tag,rsp_inputs,rsp_outputs};
 wire [127:0] cmdp={cmd_width,cmd_height,cmd_in_channels,cmd_out_channels,cmd_x_zero,cmd_tag};
 wire [127:0] cp={c_op,c_row,c_word,c_weights,c_bias,c_scale,c_shift,c_zero};
 wire [10:0] sp={s_data,s_sof,s_eol,s_last};
 always @(posedge clk) begin
  if(!rst) begin
   if(was_mheld && (!m_valid || mp!==held_m)) $fatal(1,"output changed while held");
   if(was_rheld && (!rsp_valid || rp!==held_r)) $fatal(1,"completion changed while held");
   if(was_cmdheld && (!cmd_valid || cmdp!==held_cmd)) $fatal(1,"command source changed a stalled offer");
   if(was_cheld && (!c_valid || cp!==held_c)) $fatal(1,"configuration source changed a stalled offer");
   if(was_sheld && (!s_valid || sp!==held_s)) $fatal(1,"input source changed a stalled offer");
   if(m_valid && !m_ready) holds=holds+1;
   if(rsp_valid && !rsp_ready) rsp_holds=rsp_holds+1;
  end
  was_mheld=!rst&&m_valid&&!m_ready;held_m=mp;
  was_rheld=!rst&&rsp_valid&&!rsp_ready;held_r=rp;
  was_cmdheld=!rst&&cmd_valid&&!cmd_ready;held_cmd=cmdp;
  was_cheld=!rst&&c_valid&&!c_ready;held_c=cp;
  was_sheld=!rst&&s_valid&&!s_ready;held_s=sp;
 end
 task reset_dut;
  begin
   @(negedge clk);rst=1;c_valid=0;c_rsp_ready=0;cmd_valid=0;s_valid=0;m_ready=0;rsp_ready=0;
   repeat(2) begin @(posedge clk);if(c_ready||c_rsp_valid||cmd_ready||s_ready||m_valid||rsp_valid)$fatal(1,"reset gating");end
   @(negedge clk);rst=0;resets=resets+1;
  end
 endtask
 task retire_invalid_future;
  input [T-1:0] expected_tag;
  integer t;
  begin
   t=0;begin:future_accept
    while(1)begin @(posedge clk);if(cmd_valid&&cmd_ready)disable future_accept;t=t+1;if(t>2000)$fatal(1,"future command timeout");end
   end
   @(negedge clk);cmd_valid=0;rsp_ready=0;t=0;
   begin:future_result
    while(1)begin @(posedge clk);if(rsp_valid)disable future_result;t=t+1;if(t>2000)$fatal(1,"future result timeout");end
   end
   if(rsp_error!==3'd1||rsp_tag!==expected_tag||rsp_inputs!=0||rsp_outputs!=0||m_valid||s_ready)$fatal(1,"future dimension-error result");
   repeat(2)@(posedge clk);
   @(negedge clk);rsp_ready=1;@(posedge clk);
   if(!rsp_valid)$fatal(1,"future completion disappeared");
   @(negedge clk);rsp_ready=0;future_commands=future_commands+1;
  end
 endtask
 task cfg;
  input integer op,row,word;input [31:0] packed_w;input integer bias,scale,shift,zero,err;
  integer t;
  begin
   @(negedge clk);c_op=op;c_row=row;c_word=word;c_weights=packed_w;c_bias=bias;c_scale=scale;c_shift=shift;c_zero=zero;c_valid=1;
   if(arbitrate_once)begin cmd_valid=1;cmd_width=0;cmd_height=1;cmd_in_channels=1;cmd_out_channels=1;cmd_x_zero=0;cmd_tag=0;end
   t=0;begin:wait_c
    while(1) begin @(posedge clk);if(cmd_ready)$fatal(1,"configuration must win command arbitration");if(c_ready)disable wait_c;t=t+1;if(t>2000)$fatal(1,"cfg ready timeout");end
   end
   @(negedge clk);c_valid=0;c_rsp_ready=0;t=0;
   begin:wait_cr
    while(1) begin @(posedge clk);if(c_rsp_valid)disable wait_cr;t=t+1;if(t>2000)$fatal(1,"cfg response timeout");end
   end
   repeat(3) begin @(posedge clk);if(!c_rsp_valid||c_error!==err[1:0]||cmd_ready)$fatal(1,"cfg held/command arbitration");end
   @(negedge clk);c_rsp_ready=1;@(posedge clk);
   if(!c_rsp_valid||c_error!==err[1:0])$fatal(1,"cfg result");
   @(negedge clk);c_rsp_ready=0;
   if(arbitrate_once)begin retire_invalid_future({T{1'b0}});arbitrate_once=0;end
  end
 endtask
 task command;
  input integer w,h,cin,cout,zero,tag;
  integer t;
  begin
   @(negedge clk);cmd_width=w;cmd_height=h;cmd_in_channels=cin;cmd_out_channels=cout;cmd_x_zero=zero;cmd_tag=tag;cmd_valid=1;
   t=0;begin:wait_cmd
    while(1)begin @(posedge clk);if(cmd_ready)disable wait_cmd;t=t+1;if(t>2000)$fatal(1,"command timeout");end
   end
   @(negedge clk);cmd_valid=0;
  end
 endtask
 task known_config;
  integer r;
  begin
   cfg(2,0,0,0,0,0,0,0,0);
   for(r=0;r<4;r=r+1)begin cfg(0,r,0,1,0,0,0,0,0);cfg(1,r,0,0,r,1,0,0,0);end
  end
 endtask
 task known_future;
  integer a,b,t,complete;
  begin
   known_config();command(1,1,1,1,0,1);a=0;b=0;t=0;complete=0;
   while(!complete)begin
    @(negedge clk);s_valid=a==0;s_data=25;s_sof=1;s_eol=1;s_last=1;m_ready=(t%5)!=1;rsp_ready=1;
    @(posedge clk);
    if(s_valid&&s_ready)a=a+1;
    if(m_valid&&m_ready)begin
     if($signed(m_data)!==25+b || m_x!==(b%2) || m_y!==(b/2) || m_channel!==0 ||
        m_tag!=={{(T-1){1'b0}},1'b1} || m_clip || m_inexact || m_sof!==(b==0) || m_eol!==(b%2==1) || m_last!==(b==3))$fatal(1,"future arithmetic/order b=%0d",b);
     b=b+1;
    end
    if(rsp_valid&&rsp_ready)begin
     if(rsp_error||rsp_inputs!=1||rsp_outputs!=4||a!=1||b!=4)$fatal(1,"future completion");complete=1;
    end
    t=t+1;if(t>3000)$fatal(1,"future timeout");
   end
   @(negedge clk);s_valid=0;m_ready=0;rsp_ready=0;futures=futures+1;
  end
 endtask
 task cancel_live;
  input integer phase;
  integer a,t,reached;
  begin
   known_config();command(1,1,1,1,0,1);a=0;t=0;reached=0;
   while(!reached)begin
    @(negedge clk);s_valid=(phase!=0&&a==0);s_data=25;s_sof=1;s_eol=1;s_last=1;
    m_ready=phase==2?0:phase==3?(m_y==0):1;rsp_ready=0;
    @(posedge clk);
    if(s_valid&&s_ready)a=a+1;
    if(phase==0&&s_ready)reached=1;
    if(phase==1&&dut.state==3&&!m_valid)reached=1;
    if(phase==2&&m_valid&&!m_ready&&m_y==0)reached=1;
    if(phase==3&&m_valid&&!m_ready&&m_y==1)reached=1;
    if(phase==4&&rsp_valid)reached=1;
    t=t+1;if(t>3000)$fatal(1,"live cancellation phase %0d",phase);
   end
   reset_dut();known_future();
  end
 endtask
 initial begin
  if(!$value$plusargs("vectors=%s",vector_path))$fatal(1,"missing vectors");
  fd=$fopen(vector_path,"r");if(!fd)$fatal(1,"vector open");
  reset_dut();nread=$fscanf(fd,"%d",nframes);if(nread!=1)$fatal(1,"frame count");
  for(f=0;f<nframes;f=f+1)begin
   nread=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d",fw,fh,fci,fco,fzero,ftag,ferror,nin,nout,ncfg,doreset);
   if(nread!=11||nin>131072||nout>131072||ncfg>2048)$fatal(1,"header f=%0d",f);
   for(i=0;i<ncfg;i=i+1)begin
    nread=$fscanf(fd,"%d %d %d %h %d %d %d %d %d",cop[i],crow[i],cword[i],cpacked[i],cbias[i],cscale[i],cshift[i],czero[i],cerror[i]);
    if(nread!=9)$fatal(1,"config vector");
   end
   for(i=0;i<nin;i=i+1)begin nread=$fscanf(fd,"%d %d %d %d",iv[i],isof[i],ieol[i],ilast[i]);if(nread!=4)$fatal(1,"input vector");end
   for(i=0;i<nout;i=i+1)begin
    nread=$fscanf(fd,"%d %d %d %d %d %d %d %d %d",ov[i],oclip[i],oinexact[i],ox[i],oy[i],och[i],osof[i],oeol[i],olast[i]);if(nread!=9)$fatal(1,"output vector");
   end
   for(i=0;i<ncfg;i=i+1)begin cfg(cop[i],crow[i],cword[i],cpacked[i],cbias[i],cscale[i],cshift[i],czero[i],cerror[i]);configs=configs+1;end
   command(fw,fh,fci,fco,fzero,ftag);sent=0;received=0;cycles=0;donewait=0;gotdone=0;input_fire=0;
   while(!gotdone)begin
    @(negedge clk);
    if(!s_valid || input_fire)begin
     s_valid=sent<nin && cycles%7!=2;
     if(sent<nin)begin s_data=iv[sent];s_sof=isof[sent];s_eol=ieol[sent];s_last=ilast[sent];end
    end
    // Deliberately long top/lower stalls plus irregular gaps.
    m_ready=cycles%13!=2 && !(cycles%131>=70&&cycles%131<83);rsp_ready=donewait>=5;
    cmd_valid=1;cmd_width=0;cmd_height=1;cmd_in_channels=1;cmd_out_channels=1;cmd_tag=~ftag;
    @(posedge clk);
    if(cmd_ready)$fatal(1,"preoffered future command accepted before completion");preoffers=preoffers+1;
    input_fire=s_valid&&s_ready;
    if(input_fire)begin sent=sent+1;inputs=inputs+1;end
    if(m_valid&&m_ready)begin
     if(received>=nout)$fatal(1,"extra output f=%0d",f);
     if($signed(m_data)!==ov[received] || m_clip!==oclip[received][0] || m_inexact!==oinexact[received][0] ||
        m_x!==ox[received][15:0] || m_y!==oy[received][15:0] || m_channel!==och[received][15:0] ||
        m_tag!==ftag[T-1:0] || m_sof!==osof[received][0] || m_eol!==oeol[received][0] || m_last!==olast[received][0])
      $fatal(1,"mismatch f=%0d n=%0d got=%0d x=%0d y=%0d c=%0d expected=%0d x=%0d y=%0d c=%0d",f,received,$signed(m_data),m_x,m_y,m_channel,ov[received],ox[received],oy[received],och[received]);
     clips=clips+m_clip;inexact=inexact+m_inexact;received=received+1;outputs=outputs+1;
    end
    if(rsp_valid)begin
     if(rsp_error!==ferror[2:0]||rsp_tag!==ftag[T-1:0]||rsp_inputs!=nin||rsp_outputs!=nout||sent!=nin||received!=nout)
      $fatal(1,"completion f=%0d err=%0d expected=%0d in=%0d/%0d out=%0d/%0d sent=%0d rec=%0d",f,rsp_error,ferror,rsp_inputs,nin,rsp_outputs,nout,sent,received);
     donewait=donewait+1;if(rsp_ready)gotdone=1;
    end
    cycles=cycles+1;if(cycles>2000000)$fatal(1,"finite frame timeout f=%0d",f);
   end
   @(negedge clk);s_valid=0;m_ready=0;rsp_ready=0;
   retire_invalid_future(~ftag[T-1:0]);frames=frames+1;
  end
  $fclose(fd);
  for(j=0;j<5;j=j+1)cancel_live(j);
  if(holds<1||rsp_holds<1||preoffers<1||futures!=5||resets!=6||future_commands!=frames+1)$fatal(1,"coverage");
  $display("PASS int4_subpixel_upsample2x CI=%0d CO=%0d W=%0d H=%0d T=%0d frames=%0d inputs=%0d outputs=%0d configs=%0d clips=%0d inexact=%0d holds=%0d rsp_holds=%0d preoffers=%0d resets=%0d futures=%0d future_commands=%0d",CI,CO,W,H,T,frames,inputs,outputs,configs,clips,inexact,holds,rsp_holds,preoffers,resets,futures,future_commands);
  $finish;
 end
 initial begin #2000000000;$fatal(1,"global finite watchdog");end
endmodule
