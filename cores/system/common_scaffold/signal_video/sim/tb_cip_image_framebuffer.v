`timescale 1ns/1ps
module tb_cip_image_framebuffer;
parameter DW=24;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,clk_en=1,cv=0,sv=0,sof=0,eol=0,mr=0,rr=0;
reg [7:0] tag=0;
reg [3:0] op=0;
reg [15:0] w=0,h=0;
reg [8:0] mask=0;
reg [DW-1:0] sd=0;
wire cr,sr,mv,ms,me,ml,rv,ar;
reg av=0,asof=0,aeol=0;
reg [DW-1:0] ad=0;
integer accepted_aux=0;
reg take_s=0,take_a=0;
reg [31:0] extra=0;
wire [DW-1:0] md;
reg [15:0] cw=0,ch=0,dw=0,dh=0;
reg [3:0] cm=0;
reg [31:0] param0=0,param1=0;
wire [7:0] rt;
wire [1:0] re;
integer count,pixel_count,c,i,n,ip=0,ep=0,sent,received,cycles,tick=0,err,bad,nout,output_count;
reg [31:0] fbbase=0,fbstride=0;
wire qv,qw,pr;wire [31:0] qa,qd;wire [3:0] qb;
reg pending=0,pv=0,pe=0;reg [31:0] pd=0;
wire qr=rst_n && !pending && tick%5!=2;
integer delay_count=0,mi;
reg [31:0] memory[0:1023];
initial for(mi=0;mi<1024;mi=mi+1)memory[mi]=0;
reg req_parked=0;
reg [68:0] req_payload;
always @(posedge clk)begin
 if(!rst_n)req_parked<=0;
 else begin
  if(req_parked && (!qv || {qw,qa,qd,qb}!==req_payload))$fatal(1,"memory request changed under stall/CE");
  req_parked<=qv && (!clk_en || !qr);req_payload<={qw,qa,qd,qb};
 end
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin pending<=0;pv<=0;pd<=0;pe<=0;delay_count<=0;end
 else if(clk_en)begin
  if(qv && qr)begin
   if(qa[1:0]!=0 || qa>=4096)$fatal(1,"bad memory address %h",qa);
   if(qb!==(qw?4'hf:4'h0))$fatal(1,"memory strobes");
   pending<=1;delay_count<=2;pe<=bad==7 || bad==8;
   if(qw && bad!=7)memory[qa>>2]<=qd;
   if(!qw)pd<=memory[qa>>2];
  end
  if(pending && !pv)begin
   if(delay_count==0)pv<=1;else delay_count<=delay_count-1;
  end
  if(pv && pr)begin pv<=0;pending<=0;end
 end
end
cip_image_framebuffer #(.DATA_W(DW),.MAX_WIDTH(8),.MAX_HEIGHT(6)) dut(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .cfg_mode(cm),.cfg_src_width(cw),.cfg_src_height(ch),.cfg_dst_width(dw),.cfg_dst_height(dh),
 .cfg_param0(param0),.cfg_param1(param1),.cfg_frame_base(fbbase),.cfg_frame_stride(fbstride),.cfg_aux_base(32'd0),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .coeff_valid(1'b0),.coeff_addr(16'd0),.coeff_data(32'd0),
 .aux_data(ad),.aux_valid(av),.aux_sof(asof),.aux_eol(aeol),.aux_ready(ar),
 .mem_req_valid(qv),.mem_req_write(qw),.mem_req_addr(qa),.mem_req_wdata(qd),.mem_req_wstrb(qb),
 .mem_req_ready(qr),.mem_rsp_valid(pv),.mem_rsp_ready(pr),.mem_rsp_rdata(pd),.mem_rsp_error(pe),
 .s_data(sd),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
 .m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_ready(mr));



reg [31:0] commands[0:2047],inputs[0:8191],auxiliary[0:8191];
reg [33:0] expected[0:8191];
reg [4095:0] folder;
reg parked=0;
reg [DW+1:0] parked_payload;
always @(posedge clk)begin
 if(!rst_n)parked<=0;
 else begin
  if(parked && (!mv || {ms,me,md}!==parked_payload))$fatal(1,"output changed under stall/CE");
  parked<=mv && (!clk_en || !mr);parked_payload<={ms,me,md};
 end
end
task reset_during;
input integer phase;
integer k;
begin
 @(negedge clk);clk_en=1;cv=1;op=0;cm=0;w=2;h=2;cw=2;ch=2;dw=2;dh=2;param0=0;param1=0;fbbase=0;fbstride=8;bad=0;mr=0;
 @(posedge clk);@(negedge clk);cv=0;
 for(k=0;k<(phase==0?1:4);k=k+1)begin
  while(!sr)@(negedge clk);sv=1;sd=k;sof=k==0;eol=k%2==1;
  @(posedge clk);@(negedge clk);sv=0;
 end
 if(phase==1)begin while(!mv)@(negedge clk);repeat(3)@(negedge clk);end
 if(phase==2)repeat(10)@(negedge clk);
 rst_n=0;sv=0;av=0;cv=0;repeat(2)@(negedge clk);rst_n=1;
 if(rv || mv)$fatal(1,"reset did not cancel frame");
end
endtask
initial begin
 if(!$value$plusargs("folder=%s",folder))$fatal(1,"folder required");
 if(!$value$plusargs("commands=%d",count))$fatal(1,"count required");
 if(!$value$plusargs("pixels=%d",pixel_count))$fatal(1,"pixel count required");
 $readmemh({folder,"/commands.hex"},commands,0,count*13-1);
 if(!$value$plusargs("outputs=%d",output_count))$fatal(1,"outputs required");
 if(pixel_count>0)begin
 $readmemh({folder,"/inputs.hex"},inputs,0,pixel_count-1);
 $readmemh({folder,"/auxiliary.hex"},auxiliary,0,pixel_count-1);
 end
 if(output_count>0)begin $readmemh({folder,"/expected.hex"},expected,0,output_count-1);
 end
 repeat(3)@(negedge clk);rst_n=1;
 if(DW>=1 && DW<=32)begin reset_during(0);reset_during(1);reset_during(2);end
 for(c=0;c<count;c=c+1)begin
  @(negedge clk);clk_en=1;op=commands[c*13];cm=op;w=commands[c*13+1];h=commands[c*13+2];cw=w;ch=h;
  dw=commands[c*13+3];dh=commands[c*13+4];param0=commands[c*13+5];param1=commands[c*13+6];
  err=commands[c*13+7];bad=commands[c*13+8];n=commands[c*13+9];nout=commands[c*13+10];fbbase=commands[c*13+11];fbstride=commands[c*13+12];tag=c;
  if(bad==8)begin rst_n=0;sv=0;av=0;repeat(2)@(negedge clk);rst_n=1;end
  cv=1;
  @(posedge clk);if(!cr)$fatal(1,"command unavailable");
  @(negedge clk);cv=0;cw=0;ch=0;dw=0;dh=0;fbbase=32'hffffffff;fbstride=1;cm=15;param0=32'hffffffff;param1=32'hffffffff;tag=~tag;
  sent=0;received=0;cycles=0;accepted_aux=0;take_s=0;take_a=0;sv=0;av=0;
  while(!rv)begin
   clk_en=(tick%7!=2);mr=(tick%5!=1);
   if(!sv || take_s)sv=sent<n && tick%4!=0;
   if(!av || take_a)av=op>=2 || (accepted_aux<n && tick%6!=1 && tick%6!=2);
   ad=auxiliary[ip+accepted_aux];asof=(accepted_aux==0) ^ (bad==3 && accepted_aux==0);
   aeol=(accepted_aux%w==w-1) ^ (bad==4 && accepted_aux==n-1);
   sd=inputs[ip+sent];sof=(sent==0) ^ (bad==1 && sent==0);eol=(sent%w==w-1) ^ (bad==2 && sent==n-1);
   @(posedge clk);
   take_s=clk_en && sv && sr;take_a=clk_en && av && ar;
   if(ar)$fatal(1,"temporal filter consumed auxiliary");

   if(take_a)accepted_aux=accepted_aux+1;
   if(clk_en)begin
    if(take_s)sent=sent+1;
    if(mv && mr)begin
     if(received>=nout || md!==expected[ep+received][DW-1:0])$fatal(1,"data case=%0d pixel=%0d got=%h expected=%h",c,received,md,expected[ep+received]);
     if(ms!==expected[ep+received][33] || me!==expected[ep+received][32])$fatal(1,"markers");
     received=received+1;
    end
   end
   @(negedge clk);tick=tick+1;cycles=cycles+1;
   if(cycles>200000)$fatal(1,"timeout case %0d",c);
  end
  if(sent!=n || received!=nout || rt!==(c%256) || re!==err)$fatal(1,"response case=%0d sent=%0d received=%0d error=%0d expected=%0d",c,sent,received,re,err);
  sv=0;av=0;clk_en=1;rr=0;
  repeat(3)begin @(posedge clk);if(!rv || rt!==(c%256) || re!==err)$fatal(1,"response hold");@(negedge clk);end
  rr=1;@(posedge clk);@(negedge clk);rr=0;ip=ip+n;ep=ep+nout;
 end
 $display("FRAMEBUFFER PASS width=%0d commands=%0d pixels=%0d",DW,count,ep);$finish;
end
initial begin #100000000;$fatal(1,"global timeout");end
endmodule
