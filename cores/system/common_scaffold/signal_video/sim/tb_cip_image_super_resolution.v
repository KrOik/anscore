`timescale 1ns/1ps
module tb_cip_image_super_resolution;
parameter DW=24,F=4;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,clk_en=1,cv=0,sv=0,sof=0,eol=0,mr=0,rr=0;
reg [11:0] tag=0;
reg [3:0] op=0;
reg [15:0] w=0,h=0;
reg [8:0] mask=0;
reg [DW-1:0] sd=0;
wire cr,sr,mv,ms,me,ml,rv,ar;
reg av=0,asof=0,aeol=0;
reg [DW-1:0] ad=0;
reg kv=0;wire kr;reg [15:0] ka=0;reg [31:0] kd=0;
integer accepted_aux=0;
reg take_s=0,take_a=0;
reg [31:0] extra=0;
wire [DW-1:0] md;
reg [15:0] cw=0,ch=0,dw=0,dh=0;
reg [3:0] cm=0;
reg [31:0] param0=0,param1=0;
wire [11:0] rt;
wire [1:0] re;
integer count,pixel_count,c,i,n,ip=0,ep=0,sent,received,cycles,tick=0,err,bad;
cip_image_super_resolution #(.DATA_W(DW),.TAG_W(12),.MAX_WIDTH(8),.MAX_HEIGHT(6),.FEATURES(F)) dut(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .cfg_mode(cm),.cfg_src_width(cw),.cfg_src_height(ch),.cfg_dst_width(dw),.cfg_dst_height(dh),
 .cfg_param0(param0),.cfg_param1(param1),.cfg_frame_base(32'd0),.cfg_frame_stride(32'd0),.cfg_aux_base(32'd0),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .coeff_valid(kv),.coeff_ready(kr),.coeff_addr(ka),.coeff_data(kd),
 .aux_data(ad),.aux_valid(av),.aux_sof(asof),.aux_eol(aeol),.aux_ready(ar),
 .mem_req_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_rdata(32'd0),.mem_rsp_error(1'b0),
 .s_data(sd),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
 .m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_ready(mr));



localparam N=18*F*F+64*F+4;
localparam B1=25*F,W2=B1+F,B2=W2+9*F*F,W3=B2+F,B3=W3+9*F*F,W4=B3+F;
reg [31:0] commands[0:2047],inputs[0:8191],weights[0:131071];
reg [15:0] addresses[0:131071];reg [33:0] expected[0:32767];
reg [4095:0] folder;
integer nc,ni,no,nk,kp=0,sentk,sentout,ct,kk,phase;
reg take_k=0,parked=0;reg [DW+1:0] parked_payload;
always @(posedge clk)begin
 if(!rst_n)parked<=0;
 else begin
  if(parked && (!mv || {ms,me,md}!==parked_payload))$fatal(1,"output changed under stall/CE");
  parked<=mv && (!clk_en || !mr);parked_payload<={ms,me,md};
  if(ar || dut.mem_req_valid || dut.mem_rsp_ready || dut.mem_req_write)$fatal(1,"inactive ports");
 end
end
task issue;
input integer mode,ww,hh;
begin
 @(negedge clk);clk_en=1;cv=1;cm=mode;cw=ww;ch=hh;dw=2*ww;dh=2*hh;param0=0;param1=0;
 @(posedge clk);if(!cr)$fatal(1,"issue readiness");@(negedge clk);cv=0;
end
endtask
task clear_reset;
begin
 rst_n=0;sv=0;kv=0;av=0;cv=0;mr=0;rr=0;clk_en=1;
 repeat(2)@(negedge clk);rst_n=1;
 if(rv || mv || kr || sr)$fatal(1,"reset state");
end
endtask
task small_model;
begin
 issue(0,0,0);
 for(kk=0;kk<N;kk=kk+1)begin
  kv=1;ka=kk;kd=0;
  if(kk==12 || kk==W2+4 || kk==W3+4 || kk==W4+4 || kk==W4+9*F+4 || kk==W4+18*F+4 || kk==W4+27*F+4)kd=256;
  @(posedge clk);if(!kr)$fatal(1,"load readiness");@(negedge clk);
 end
 kv=0;if(!rv || re!=0)$fatal(1,"reset model setup");rr=1;@(posedge clk);@(negedge clk);rr=0;
end
endtask
task reset_checks;
begin
 issue(0,0,0);kv=1;ka=0;kd=0;@(posedge clk);@(negedge clk);clear_reset;
 for(phase=1;phase<=3;phase=phase+1)begin
  small_model;issue(1,2,2);
  for(kk=0;kk<(phase==1?1:4);kk=kk+1)begin
   sv=1;sd=kk+31;sof=kk==0;eol=kk%2==1;
   @(posedge clk);if(!sr)$fatal(1,"capture readiness");@(negedge clk);
  end
  sv=0;
  if(phase==2)repeat(15)@(negedge clk);
  if(phase==3)begin ct=0;while(!mv)begin @(negedge clk);ct=ct+1;if(ct>170000)$fatal(1,"reset output timeout");end repeat(3)@(negedge clk);end
  clear_reset;
 end
end
endtask
initial begin
 if(!$value$plusargs("folder=%s",folder) || !$value$plusargs("commands=%d",count))$fatal(1,"arguments");
 if(!$value$plusargs("inputs=%d",ni) || !$value$plusargs("outputs=%d",no) || !$value$plusargs("weights=%d",nk))$fatal(1,"counts");
 $readmemh({folder,"/commands.hex"},commands,0,count*10-1);
 if(ni>0)$readmemh({folder,"/inputs.hex"},inputs,0,ni-1);
 if(no>0)$readmemh({folder,"/expected.hex"},expected,0,no-1);
 if(nk>0)begin $readmemh({folder,"/weights.hex"},weights,0,nk-1);$readmemh({folder,"/addresses.hex"},addresses,0,nk-1);end
 repeat(3)@(negedge clk);rst_n=1;
 if(DW>=8 && DW<=32 && F>=1 && F<=16)reset_checks;
 for(c=0;c<count;c=c+1)begin
  @(negedge clk);clk_en=1;op=commands[c*10];cm=op;w=commands[c*10+1];h=commands[c*10+2];cw=w;ch=h;
  dw=commands[c*10+3];dh=commands[c*10+4];err=commands[c*10+5];bad=commands[c*10+6];
  n=commands[c*10+7];sentout=commands[c*10+8];nc=commands[c*10+9];tag=c | 12'ha00;param0=bad==7?1:0;param1=0;
  cv=1;@(posedge clk);if(!cr)$fatal(1,"command unavailable");
  @(negedge clk);cv=0;cw=0;ch=0;cm=15;param0=32'hffffffff;param1=32'hffffffff;tag=~tag;
  sent=0;received=0;sentk=0;cycles=0;take_s=0;take_k=0;sv=0;kv=0;av=1;ad='1;
  while(!rv)begin
   clk_en=(tick%7!=2);mr=(tick%5!=1);
   if(!sv || take_s)sv=sent<n && tick%4!=0;
   if(!kv || take_k)kv=op==1 || (sentk<nc && tick%3!=1);
   sd=inputs[ip+sent];sof=(sent==0) ^ (bad==1 && sent==0);eol=(sent%w==w-1) ^ (bad==2 && sent==n-1);
   ka=sentk<nc?addresses[kp+sentk]:16'hffff;kd=sentk<nc?weights[kp+sentk]:32'hdeadbeef;
   @(posedge clk);take_s=clk_en && sv && sr;take_k=clk_en && kv && kr;
   if(op==1 && kr)$fatal(1,"inference coefficient poison accepted");
   if(clk_en)begin
    if(take_s)sent=sent+1;if(take_k)sentk=sentk+1;
    if(mv && mr)begin
     if(received>=sentout || md!==expected[ep+received][DW-1:0])$fatal(1,"data case=%0d pixel=%0d got=%h expected=%h",c,received,md,expected[ep+received]);
     if(ms!==expected[ep+received][33] || me!==expected[ep+received][32])$fatal(1,"markers");received=received+1;
    end
   end
   @(negedge clk);tick=tick+1;cycles=cycles+1;if(cycles>3000000)$fatal(1,"timeout case %0d",c);
  end
  if(sent!=n || sentk!=nc || received!=sentout || rt!==((c%256)|12'ha00) || re!==err)$fatal(1,"response case=%0d sent=%0d received=%0d coeff=%0d error=%0d expected=%0d",c,sent,received,sentk,re,err);
  sv=0;kv=1;ka=0;kd=32'hffffffff;av=0;clk_en=1;rr=0;
  repeat(3)begin @(posedge clk);if(!rv || rt!==((c%256)|12'ha00) || re!==err || kr || sr)$fatal(1,"response hold");@(negedge clk);end
  kv=0;rr=1;@(posedge clk);@(negedge clk);rr=0;ip=ip+n;ep=ep+sentout;kp=kp+nc;
 end
 $display("SUPER_RESOLUTION PASS width=%0d features=%0d commands=%0d outputs=%0d",DW,F,count,ep);$finish;
end
initial begin #4000000000;$fatal(1,"global timeout");end
endmodule
