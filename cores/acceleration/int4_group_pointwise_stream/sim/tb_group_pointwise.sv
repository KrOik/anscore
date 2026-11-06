`timescale 1ns/1ps
module tb_group_pointwise;
 parameter G=3,MI=9,MO=3,MP=7,TW=8;
 localparam LIMIT=65536,PAYLOAD=TW+75;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,c_rsp_ready=0,cmd_valid=0,s_valid=0,s_last=0;
 reg [1:0] c_op=0;
 reg [15:0] c_group=0,c_row=0,c_word=0;
 reg [31:0] c_weights=0;
 reg signed [31:0] c_bias=0;
 reg [15:0] c_scale=0;
 reg [4:0] c_shift=0;
 reg signed [7:0] c_zero=0;
 reg [15:0] cmd_pixels=0,cmd_in_per_group=0,cmd_out_per_group=0;
 reg [7:0] cmd_x_zero=0,s_data=0;
 reg cmd_shuffle=0;
 reg [TW-1:0] cmd_tag=0;
 reg m_ready=0,rsp_ready=0,stall_output=0;
 wire c_ready,c_rsp_valid,cmd_ready,s_ready,m_valid,m_last,m_clip,m_inexact,rsp_valid,busy;
 wire [1:0] c_error,rsp_error;
 wire signed [7:0] m_data;
 wire [15:0] m_pixel,m_channel,m_group,m_row;
 wire [31:0] rsp_outputs;
 wire [TW-1:0] m_tag,rsp_tag;
 int4_group_pointwise_stream #(.GROUPS(G),.MAX_IN_PER_GROUP(MI),.MAX_OUT_PER_GROUP(MO),
  .MAX_PIXELS(MP),.TAG_W(TW)) dut(.*);
 integer cycles=0,held_checks=0,resets=0,error_results=0,good_results=0;
 integer vector_frames=0,vector_scored=0,recovery_scored=0,clips=0,inexact=0;
 integer seen=0,expected_count=0,current_no=1;
 reg scoring=0,is_vector=0,held=0;
 reg [TW-1:0] expected_tag;
 reg [PAYLOAD-1:0] held_payload;
 wire [PAYLOAD-1:0] payload={m_data,m_pixel,m_channel,m_group,m_row,m_last,m_tag,m_clip,m_inexact};
 integer samples[0:LIMIT-1],ys[0:LIMIT-1],cs[0:LIMIT-1],xs[0:LIMIT-1],gs[0:LIMIT-1],rs[0:LIMIT-1];
 always @(negedge clk)m_ready=!stall_output && cycles%7!=0 && cycles%7!=1;
 always @(posedge clk)begin
  cycles=cycles+1;
  if(cycles>2500000)$fatal(1,"watchdog");
  if(rst)held=0;
  else begin
   if(held)begin
    if(!m_valid || payload!==held_payload)$fatal(1,"held output changed");
    held_checks=held_checks+1;
   end
   held=m_valid && !m_ready;held_payload=payload;
   if(c_ready && busy)$fatal(1,"configuration admitted during ownership");
   if(cmd_ready && (busy || c_valid))$fatal(1,"command admitted during ownership/config priority");
   if(m_valid && m_ready)begin
    if(!scoring || seen>=expected_count)$fatal(1,"unexpected output");
    if($signed(m_data)!==ys[seen] || m_clip!==cs[seen][0] || m_inexact!==xs[seen][0] ||
     m_group!==gs[seen] || m_row!==rs[seen] || m_pixel!==seen/(G*current_no) ||
     m_channel!==seen%(G*current_no) || m_last!==(seen==expected_count-1) || m_tag!==expected_tag)
     $fatal(1,"mismatch index=%0d y=%0d expected=%0d g=%0d r=%0d",seen,$signed(m_data),ys[seen],m_group,m_row);
    seen=seen+1;clips=clips+m_clip;inexact=inexact+m_inexact;
    if(is_vector)vector_scored=vector_scored+1;else recovery_scored=recovery_scored+1;
   end
  end
 end
 task reset_core;
 begin
  @(negedge clk);rst=1;s_valid=0;cmd_valid=0;c_valid=0;c_rsp_ready=0;rsp_ready=0;scoring=0;
  repeat(3)@(negedge clk);
  if(m_valid || rsp_valid || c_ready || cmd_ready || s_ready)$fatal(1,"reset gate");
  rst=0;resets=resets+1;@(negedge clk);
 end endtask
 task configure(input integer op,g,r,w,input [31:0] weight_word,input integer bias,scale,shift,zero,err);
 begin
  @(negedge clk);c_valid=1;c_op=op;c_group=g;c_row=r;c_word=w;c_weights=weight_word;
  c_bias=bias;c_scale=scale;c_shift=shift;c_zero=zero;c_rsp_ready=0;
  do @(posedge clk);while(!c_ready);
  @(negedge clk);c_valid=0;
  while(!c_rsp_valid)@(negedge clk);
  repeat(3)begin
   @(negedge clk);
   if(!c_rsp_valid || c_error!==err || c_ready || cmd_ready)$fatal(1,"configuration reply hold");
  end
  c_rsp_ready=1;@(posedge clk);@(negedge clk);c_rsp_ready=0;
 end endtask
 task command(input integer p,ni,no,xzero,shuffle,tag_value);
 begin
  @(negedge clk);cmd_valid=1;cmd_pixels=p;cmd_in_per_group=ni;cmd_out_per_group=no;
  cmd_x_zero=xzero;cmd_shuffle=shuffle;cmd_tag=tag_value;expected_tag=tag_value;rsp_ready=0;
  do @(posedge clk);while(!cmd_ready);
  @(negedge clk);cmd_valid=0;
 end endtask
 task sample(input integer value,last_value);
 begin
  s_valid=1;s_data=value;s_last=last_value;
  do @(posedge clk);while(!s_ready);
  @(negedge clk);s_valid=0;
 end endtask
 task completion(input integer err,outputs);
 reg [31:0] held_outputs;
 reg [TW-1:0] held_tag;
 begin
  while(!rsp_valid)@(negedge clk);
  held_outputs=rsp_outputs;held_tag=rsp_tag;
  if(rsp_error!==err || rsp_outputs!==outputs || seen!=outputs || rsp_tag!==expected_tag)
   $fatal(1,"completion err=%0d want=%0d outputs=%0d seen=%0d",rsp_error,err,rsp_outputs,seen);
  repeat(4)begin
   @(negedge clk);
   if(!rsp_valid || rsp_error!==err || rsp_outputs!==held_outputs || rsp_tag!==held_tag || c_ready || cmd_ready || s_ready)
    $fatal(1,"completion ownership");
  end
  rsp_ready=1;@(posedge clk);@(negedge clk);rsp_ready=0;scoring=0;
  if(err==0)good_results=good_results+1;else error_results=error_results+1;
 end endtask
 task simple_config;
 integer g;
 begin
  for(g=0;g<G;g=g+1)begin
   configure(0,g,0,0,32'd1,0,0,0,0,0);
   configure(1,g,0,65535,0,0,1,0,0,0);
  end
 end endtask
 task recover;
 integer g;
 begin
  stall_output=0;simple_config();seen=0;expected_count=G;current_no=1;scoring=1;is_vector=0;
  for(g=0;g<G;g=g+1)begin ys[g]=5;cs[g]=0;xs[g]=0;gs[g]=g;rs[g]=0;end
  command(1,1,1,0,1,27);
  for(g=0;g<G;g=g+1)sample(5,g==G-1);
  completion(0,G);
 end endtask
 integer fd,rc,frames,f,p,ni,no,xzero,shuffle,t,g,r,w,i,j,nin,nout;
 integer bias,scale,shift,zero,extra;
 reg [31:0] packed_weights;
 reg [2047:0] vector_path;
 initial begin
  if(!$value$plusargs("VECTORS=%s",vector_path))$fatal(1,"missing vectors");
  fd=$fopen(vector_path,"r");if(!fd)$fatal(1,"open vectors");
  reset_core();seen=0;
  command(1,1,1,0,0,1);completion(2,0);
  command(65535,65535,65535,0,0,2);completion(1,0);
  configure(3,0,0,0,0,0,0,0,0,2);
  configure(0,65535,0,0,0,0,0,0,0,1);
  configure(1,0,65535,0,0,0,0,0,0,1);
  configure(0,0,0,65535,0,0,0,0,0,1);
  configure(2,65535,65535,65535,0,0,0,0,0,0);
  rc=$fscanf(fd,"%d",frames);if(rc!=1 || frames!=5)$fatal(1,"frame header");
  for(f=0;f<frames;f=f+1)begin
   rc=$fscanf(fd,"%d %d %d %d %d %d",p,ni,no,xzero,shuffle,t);if(rc!=6)$fatal(1,"frame geometry");
   nin=p*G*ni;nout=p*G*no;if(nin>LIMIT || nout>LIMIT)$fatal(1,"fixture capacity");
   for(g=0;g<G;g=g+1)for(r=0;r<no;r=r+1)begin
    rc=$fscanf(fd,"%d %d %d %d",bias,scale,shift,zero);if(rc!=4)$fatal(1,"metadata");
    configure(1,g,r,65535,0,bias,scale,shift,zero,0);
    for(w=0;w<(ni+7)/8;w=w+1)begin
     rc=$fscanf(fd,"%h",packed_weights);if(rc!=1)$fatal(1,"weights");
     configure(0,g,r,w,packed_weights,0,0,0,0,0);
    end
   end
   for(i=0;i<nin;i=i+1)begin rc=$fscanf(fd,"%d",samples[i]);if(rc!=1)$fatal(1,"sample vector");end
   for(i=0;i<nout;i=i+1)begin
    rc=$fscanf(fd,"%d %d %d %d %d",ys[i],cs[i],xs[i],gs[i],rs[i]);if(rc!=5)$fatal(1,"expected vector");
   end
   seen=0;expected_count=nout;current_no=no;scoring=1;is_vector=1;
   command(p,ni,no,xzero,shuffle,t);
   for(i=0;i<nin;i=i+1)sample(samples[i],i==nin-1);
   completion(0,nout);vector_frames=vector_frames+1;
  end
  rc=$fscanf(fd,"%d",extra);if(!((rc==0 || rc==-1) && $feof(fd)))$fatal(1,"unexpected vector suffix");$fclose(fd);
  seen=0;command(1,1,1,0,0,3);sample(0,G!=1);completion(3,0);
  seen=0;command(1,1,1,0,0,4);for(g=0;g<G;g=g+1)sample(0,0);completion(3,0);
  simple_config();seen=0;command(1,1,1,0,0,5);
  for(g=0;g<G;g=g+1)sample(1,g==G-1);
  repeat(2)@(negedge clk);reset_core();
  seen=0;command(1,1,1,0,0,6);completion(2,0);recover();
  stall_output=1;seen=0;scoring=0;command(1,1,1,0,0,7);
  for(g=0;g<G;g=g+1)sample(1,g==G-1);
  while(!m_valid)@(negedge clk);
  repeat(4)@(negedge clk);
  // Both future offers must remain unaccepted until reset cancels this owner.
  c_valid=1;c_op=2;cmd_valid=1;
  repeat(3)begin @(negedge clk);if(c_ready || cmd_ready)$fatal(1,"future offer accepted");end
  reset_core();stall_output=0;
  seen=0;command(1,1,1,0,0,8);completion(2,0);recover();
  seen=0;scoring=0;command(0,1,1,0,0,9);
  while(!rsp_valid)@(negedge clk);repeat(4)@(negedge clk);reset_core();
  repeat(8)@(negedge clk);
  if(vector_frames!=5 || recovery_scored!=2*G || error_results!=6 || held_checks==0 || resets!=4)
   $fatal(1,"finite coverage counters");
  $display("PASS GROUP_POINTWISE vector_frames=%0d vector_scored=%0d recovery_scored=%0d error_results=%0d resets=%0d held=%0d clips=%0d inexact=%0d",vector_frames,vector_scored,recovery_scored,error_results,resets,held_checks,clips,inexact);
  $finish;
 end
endmodule
