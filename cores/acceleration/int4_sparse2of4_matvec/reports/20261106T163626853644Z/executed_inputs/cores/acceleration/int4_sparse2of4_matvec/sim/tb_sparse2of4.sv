`timescale 1ns/1ps
module tb_sparse2of4;
 parameter MR=3,MC=7,TW=8;
 localparam GROUPS=(MC+3)/4,PAYLOAD=TW+29;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,c_rsp_ready=0,cmd_valid=0,s_valid=0,s_last=0,m_ready=0;
 reg [1:0] c_op=0;
 reg [15:0] c_row=0,c_group=0,cmd_rows=0,cmd_cols=0;
 reg [2:0] c_pattern=0;
 reg [7:0] c_weights=0,cmd_x_zero=0,s_data=0;
 reg signed [31:0] c_bias=0;
 reg [15:0] c_scale=0;
 reg [4:0] c_shift=0;
 reg signed [7:0] c_zero=0;
 reg [TW-1:0] cmd_tag=0;
 wire c_ready,c_rsp_valid,cmd_ready,s_ready,m_valid,m_last,m_clip,m_inexact,busy;
 wire [1:0] c_error,m_error;
 wire signed [7:0] m_data;
 wire [15:0] m_row;
 wire [TW-1:0] m_tag;
 int4_sparse2of4_matvec #(.MAX_ROWS(MR),.MAX_COLS(MC),.TAG_W(TW)) dut(.*);
 integer cycles=0,held=0,vector_scored=0,recovery_scored=0,error_results=0,resets=0;
 integer frames=0,seen=0,want=0,mode=0,expected_error=0,config_errors=0;
 integer samples[0:1023],ys[0:63],clips[0:63],inexacts[0:63];
 reg [TW-1:0] expected_tag;
 reg force_stall=0,was_held=0,queued_probe=0;
 reg [PAYLOAD-1:0] held_payload;
 wire [PAYLOAD-1:0] payload={m_data,m_row,m_tag,m_last,m_clip,m_inexact,m_error};
 always @(negedge clk)m_ready=!force_stall && cycles%9!=0 && cycles%9!=1 && cycles%9!=2;
 always @(posedge clk)begin
  cycles=cycles+1;
  if(cycles>2000000)$fatal(1,"watchdog mode=%0d state=%0d seen=%0d",mode,dut.state,seen);
  if(rst)was_held=0;
  else begin
   if(was_held)begin
    if(!m_valid || payload!==held_payload)$fatal(1,"held payload changed");
    held=held+1;
   end
   was_held=m_valid && !m_ready;held_payload=payload;
   if(c_ready && busy)$fatal(1,"config ownership");
   if(cmd_ready && (busy || c_valid))$fatal(1,"command arbitration");
   if(m_valid && m_ready)begin
    if(mode==0 || seen>=want)$fatal(1,"unexpected result mode=%0d",mode);
    if(m_tag!==expected_tag || m_last!==(seen==want-1))$fatal(1,"tag/last");
    if(mode==3)begin
     if(m_error!==expected_error || m_row!==0 || m_data!==0 || m_clip || m_inexact)$fatal(1,"error response");
     error_results=error_results+1;
    end else begin
     if(m_error!==0 || m_row!==seen || $signed(m_data)!==ys[seen] ||
        m_clip!==clips[seen][0] || m_inexact!==inexacts[seen][0])
      $fatal(1,"numeric row=%0d got=%0d/%0d/%0d expected=%0d/%0d/%0d",seen,$signed(m_data),m_clip,m_inexact,ys[seen],clips[seen],inexacts[seen]);
     if(mode==1)vector_scored=vector_scored+1;else recovery_scored=recovery_scored+1;
    end
    seen=seen+1;
   end
  end
 end
 task reset_core;
 begin
  @(negedge clk);rst=1;c_valid=0;cmd_valid=0;s_valid=0;c_rsp_ready=0;mode=0;
  repeat(3)@(negedge clk);
  if(c_ready || cmd_ready || s_ready || m_valid || c_rsp_valid)$fatal(1,"reset gating");
  rst=0;resets=resets+1;@(negedge clk);
 end endtask
 task cfg(input integer op,row,group,pattern,weights,bias,scale,shift,zero,err);
 integer bound;
 begin
  @(negedge clk);c_valid=1;c_op=op;c_row=row;c_group=group;c_pattern=pattern;
  if(queued_probe)cmd_valid=1;
  c_weights=weights;c_bias=bias;c_scale=scale;c_shift=shift;c_zero=zero;c_rsp_ready=0;
  bound=0;
  do begin @(posedge clk);bound=bound+1;if(bound>100)$fatal(1,"cfg accept wait");end while(!c_ready);
  @(negedge clk);c_valid=0;bound=0;
  while(!c_rsp_valid)begin @(negedge clk);bound=bound+1;if(bound>100)$fatal(1,"cfg reply wait");end
  repeat(2)begin
   @(negedge clk);
   if(!c_rsp_valid || c_error!==err || cmd_ready || c_ready)$fatal(1,"cfg response stability err=%0d want=%0d",c_error,err);
  end
  c_rsp_ready=1;@(posedge clk);@(negedge clk);c_rsp_ready=0;
  if(queued_probe)cmd_valid=0;
  if(err!=0)config_errors=config_errors+1;
 end endtask
 task command(input integer nr,nc,xzero,tag_value);
 integer bound;
 begin
  @(negedge clk);cmd_valid=1;cmd_rows=nr;cmd_cols=nc;cmd_x_zero=xzero;cmd_tag=tag_value;
  expected_tag=tag_value;seen=0;bound=0;
  do begin @(posedge clk);bound=bound+1;if(bound>100)$fatal(1,"command wait");end while(!cmd_ready);
  @(negedge clk);cmd_valid=0;
 end endtask
 task sample(input integer value,last_value);
 integer bound;
 begin
  @(negedge clk);s_valid=1;s_data=value;s_last=last_value;bound=0;
  do begin @(posedge clk);bound=bound+1;if(bound>200)$fatal(1,"sample wait state=%0d",dut.state);end while(!s_ready);
  @(negedge clk);s_valid=0;
 end endtask
 task retire;
 integer bound;
 begin
  bound=0;
  while(!cmd_ready)begin
   @(negedge clk);bound=bound+1;
   if(bound>100000)$fatal(1,"retire wait mode=%0d state=%0d seen=%0d want=%0d",mode,dut.state,seen,want);
  end
  if(seen!=want)$fatal(1,"lost rows %0d/%0d",seen,want);
  mode=0;repeat(3)@(negedge clk);
 end endtask
 task config_one;
 begin
  cfg(0,0,0,0,0,0,0,0,0,0);
  cfg(1,0,0,0,0,3,1,1,1,0);
 end endtask
 task recovery;
 begin
  force_stall=0;config_one;mode=2;want=1;ys[0]=3;clips[0]=0;inexacts[0]=1;
  command(1,1,128,1);sample(77,1);retire;
 end endtask
 integer fd,rc,total,f,nr,nc,xzero,tag_value,reconfigure,row,g,pattern,word,bias,scale,shift,zero,i;
 reg [2047:0] vector_path;
 initial begin
  reset_core;
  if(!$value$plusargs("VECTORS=%s",vector_path))$fatal(1,"missing vectors");
  fd=$fopen(vector_path,"r");if(!fd)$fatal(1,"open vectors");
  rc=$fscanf(fd,"%d",total);if(rc!=1 || total!=10)$fatal(1,"frame count");
  for(f=0;f<total;f=f+1)begin
   rc=$fscanf(fd,"%d %d %d %d %d",nr,nc,xzero,tag_value,reconfigure);if(rc!=5)$fatal(1,"header");
   if(reconfigure)for(row=0;row<nr;row=row+1)begin
    rc=$fscanf(fd,"%d %d %d %d",bias,scale,shift,zero);if(rc!=4)$fatal(1,"metadata");
    cfg(1,row,0,0,0,bias,scale,shift,zero,0);
    for(g=0;g<(nc+3)/4;g=g+1)begin
     rc=$fscanf(fd,"%d %h",pattern,word);if(rc!=2)$fatal(1,"weights");
     cfg(0,row,g,pattern,word,0,0,0,0,0);
    end
   end
   for(i=0;i<nc;i=i+1)begin rc=$fscanf(fd,"%d",samples[i]);if(rc!=1)$fatal(1,"input");end
   for(i=0;i<nr;i=i+1)begin rc=$fscanf(fd,"%d %d %d",ys[i],clips[i],inexacts[i]);if(rc!=3)$fatal(1,"golden");end
   mode=1;want=nr;command(nr,nc,xzero,tag_value);
   for(i=0;i<nc;i=i+1)begin
    if(i%11==0)repeat(2)@(negedge clk);
    sample(samples[i],i==nc-1);
   end
   retire;frames=frames+1;
  end
  rc=$fscanf(fd,"%d",i);if(rc!=-1)$fatal(1,"trailing vectors");$fclose(fd);
  cfg(2,0,0,0,0,0,0,0,0,0);
  // A queued command cannot overtake offered configuration or its held reply.
  queued_probe=1;cmd_rows=0;cmd_cols=0;
  cfg(3,0,0,0,0,0,0,0,0,2);
  queued_probe=0;repeat(2)@(negedge clk);
  cfg(0,MR,0,0,0,0,0,0,0,1);
  cfg(0,0,GROUPS,0,0,0,0,0,0,1);
  cfg(0,0,0,6,0,0,0,0,0,2);
  if(GROUPS>1)cfg(0,0,1,0,0,0,0,0,0,3);
  mode=3;want=1;expected_error=2;command(1,1,0,1);retire;
  config_one;
  mode=3;want=1;expected_error=1;command(0,1,0,1);retire;
  mode=3;want=1;expected_error=1;command(MR+1,1,0,1);retire;
  mode=3;want=1;expected_error=3;command(1,1,0,1);sample(0,0);retire;
  if(MC>1)begin
   mode=3;want=1;expected_error=3;command(1,2,0,1);sample(0,1);retire;
  end
  if(GROUPS>1)begin
   cfg(0,0,1,0,0,0,0,0,0,0);
   cfg(0,0,0,0,0,0,0,0,0,0);
   mode=3;want=1;expected_error=2;command(1,5,0,1);retire;
  end
  // Reset an outstanding configuration reply, load, arithmetic, and held output.
  @(negedge clk);c_valid=1;c_op=1;c_row=0;
  do @(posedge clk);while(!c_ready);
  @(negedge clk);c_valid=0;
  if(!c_rsp_valid)$fatal(1,"reset cfg probe");reset_core;recovery;
  mode=2;want=1;command(1,1,0,1);
  repeat(4)@(negedge clk);if(!s_ready)$fatal(1,"reset load probe");reset_core;recovery;
  mode=2;want=1;command(1,1,0,1);sample(1,1);
  repeat(3)@(negedge clk);if(!busy || m_valid)$fatal(1,"reset arithmetic probe");reset_core;recovery;
  force_stall=1;mode=2;want=1;command(1,1,0,1);sample(1,1);
  i=0;while(!m_valid)begin @(negedge clk);i=i+1;if(i>100)$fatal(1,"held probe wait");end
  repeat(6)@(negedge clk);reset_core;recovery;
  $display("PASS SPARSE2OF4 frames=%0d vector_scored=%0d recovery_scored=%0d error_results=%0d config_errors=%0d resets=%0d held=%0d cycles=%0d",frames,vector_scored,recovery_scored,error_results,config_errors,resets,held,cycles);
  $finish;
 end
endmodule
