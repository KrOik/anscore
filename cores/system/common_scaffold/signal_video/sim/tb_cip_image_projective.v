`timescale 1ns/1ps
module tb_cip_image_projective;
parameter DW=24,PW=8,PERSPECTIVE=0;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,clk_en=1,cv=0,sv=0,sof=0,eol=0,mr=0,rr=0;
reg kv=0;wire kr;reg [15:0] ka=0;reg [31:0] kd=0;
reg [31:0] matrices[0:8191];
reg [7:0] tag=0;
reg [3:0] op=0;
reg [15:0] w=0,h=0;
reg [8:0] mask=0;
reg [DW-1:0] sd=0;
wire cr,sr,mv,ms,me,ml,rv,ar,memv,memw,memr;wire [31:0] mema,memd;wire [3:0] memst;
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
`ifdef PROJECTIVE_PERSPECTIVE
cip_image_perspective #(
`else
cip_image_affine #(
`endif
.DATA_W(DW),.MAX_WIDTH(8),.MAX_HEIGHT(6),.PIXEL_W(PW)) dut(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .cfg_mode(cm),.cfg_src_width(cw),.cfg_src_height(ch),.cfg_dst_width(dw),.cfg_dst_height(dh),
 .cfg_param0(param0),.cfg_param1(param1),.cfg_frame_base(32'd0),.cfg_frame_stride(32'd0),.cfg_aux_base(32'd0),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .coeff_valid(kv),.coeff_ready(kr),.coeff_addr(ka),.coeff_data(kd),
 .aux_data(ad),.aux_valid(av),.aux_sof(asof),.aux_eol(aeol),.aux_ready(ar),
 .mem_req_valid(memv),.mem_req_write(memw),.mem_req_addr(mema),.mem_req_wdata(memd),.mem_req_wstrb(memst),.mem_rsp_ready(memr),.mem_req_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_rdata(32'd0),.mem_rsp_error(1'b0),
 .s_data(sd),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
 .m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_ready(mr));



reg [31:0] commands[0:8191],inputs[0:8191],auxiliary[0:8191];
reg [33:0] expected[0:8191];
reg [4095:0] folder;
reg parked=0;
reg [DW+1:0] parked_payload;
always @(posedge clk)begin
 if(!rst_n)parked<=0;
 else begin
  if(memv || memw || memr || mema!=0 || memd!=0 || memst!=0 || ar)$fatal(1,"inactive external interfaces");
  if(kr && (sr || mv))$fatal(1,"coefficient loading overlapped a frame");
  if(parked && (!mv || {ms,me,md}!==parked_payload))$fatal(1,"output changed under stall/CE");
  parked<=mv && (!clk_en || !mr);parked_payload<={ms,me,md};
 end
end
task reset_during;
input integer phase;
integer k;
begin
 @(negedge clk);clk_en=1;cv=1;op=0;cm=0;w=2;h=2;cw=2;ch=2;dw=2;dh=2;param0=0;param1=0;mr=0;
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
task reset_load;
integer j;
begin
 @(negedge clk);clk_en=1;cm=2;cw=0;ch=0;dw=0;dh=0;param0=0;param1=0;cv=1;
 @(posedge clk);@(negedge clk);cv=0;
 for(j=0;j<4;j=j+1)begin
  kv=1;ka=j;kd=32'hbad00000+j;@(posedge clk);@(negedge clk);
 end
 kv=0;rst_n=0;repeat(2)@(negedge clk);rst_n=1;
 if(rv || mv || kr)$fatal(1,"partial-load reset did not cancel");
end
endtask
task load_matrix;
input integer index,broken;
integer j;
begin
 @(negedge clk);clk_en=1;cm=2;cw=0;ch=0;dw=0;dh=0;param0=0;param1=0;tag=8'ha7;cv=1;
 @(posedge clk);if(!cr)$fatal(1,"load unavailable");@(negedge clk);cv=0;cm=15;tag=0;
 for(j=0;j<9;j=j+1)begin
  kv=1;ka=(broken==1 && j==8)?0:j;kd=matrices[index*9+j];
  if(broken==2 && j==8)kd=0;
  clk_en=0;@(posedge clk);@(negedge clk);clk_en=1;
  @(posedge clk);if(!kr)$fatal(1,"coeff not ready");@(negedge clk);
 end
 kv=0;ka=16'hffff;kd=32'hdeadbeef;
 while(!rv)@(negedge clk);
 if(rt!=8'ha7 || re!==((broken!=0)?2'd2:2'd0))$fatal(1,"load response %d expected broken %d",re,broken);
 repeat(2)@(negedge clk);
 rr=1;@(posedge clk);@(negedge clk);rr=0;
end
endtask
initial begin
 if(!$value$plusargs("folder=%s",folder))$fatal(1,"folder required");
 if(!$value$plusargs("commands=%d",count))$fatal(1,"count required");
 if(!$value$plusargs("pixels=%d",pixel_count))$fatal(1,"pixel count required");
 $readmemh({folder,"/matrices.hex"},matrices,0,count*9-1);
 $readmemh({folder,"/commands.hex"},commands,0,count*11-1);
 if(!$value$plusargs("outputs=%d",output_count))$fatal(1,"outputs required");
 if(pixel_count>0)begin
 $readmemh({folder,"/inputs.hex"},inputs,0,pixel_count-1);
 $readmemh({folder,"/auxiliary.hex"},auxiliary,0,pixel_count-1);
 end
 if(output_count>0)begin $readmemh({folder,"/expected.hex"},expected,0,output_count-1);
 end
 repeat(3)@(negedge clk);rst_n=1;
 if(DW>=PW && DW<=32 && PW>=1 && PW<=16 && DW%PW==0)begin reset_load;reset_during(0);reset_during(1);reset_during(2);end
 for(c=0;c<count;c=c+1)begin
  if(DW>=PW && DW<=32 && PW>=1 && PW<=16 && DW%PW==0 && commands[c*11+9]>0)begin
   load_matrix(c,0);
   load_matrix(c,1); // failed duplicate bank must preserve the active transform
   if(!PERSPECTIVE)load_matrix(c,2); // non-affine bottom row must preserve active bank
  end
  @(negedge clk);clk_en=1;op=commands[c*11];cm=op;w=commands[c*11+1];h=commands[c*11+2];cw=w;ch=h;
  dw=commands[c*11+3];dh=commands[c*11+4];param0=commands[c*11+5];param1=commands[c*11+6];
  err=commands[c*11+7];bad=commands[c*11+8];n=commands[c*11+9];nout=commands[c*11+10];tag=c;
  if(bad==8)begin rst_n=0;sv=0;av=0;repeat(2)@(negedge clk);rst_n=1;end
  cv=1;
  @(posedge clk);if(!cr)$fatal(1,"command unavailable");
  @(negedge clk);cv=0;cw=0;ch=0;dw=0;dh=0;cm=15;param0=32'hffffffff;param1=32'hffffffff;tag=~tag;
  kv=1;ka=16'hffff;kd=32'hdeadbeef;
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
   if(kr)$fatal(1,"busy frame accepted coefficient poison");
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
 $display("PROJECTIVE PASS width=%0d pixel=%0d commands=%0d pixels=%0d",DW,PW,count,ep);$finish;
end
initial begin #500000000;$fatal(1,"global timeout");end
endmodule
