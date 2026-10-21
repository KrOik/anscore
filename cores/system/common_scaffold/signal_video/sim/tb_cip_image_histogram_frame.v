`timescale 1ns/1ps
module tb_cip_image_histogram_frame;
parameter DW=32,ADAPTER=0,HIST=1;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,clk_en=1,cv=0,sv=0,sof=0,eol=0,mr=0,rr=0;
reg [7:0] tag=0;
reg [3:0] op=0;
reg [15:0] w=0,h=0;
reg [8:0] mask=0;
reg [DW-1:0] sd=0;
wire cr,sr,mv,ms,me,ml,rv;
reg [31:0] extra=0;
wire [DW-1:0] md;
reg [15:0] cw=0,ch=0;
reg [3:0] cm=0;
wire [7:0] rt;
wire [1:0] re;
integer count,pixel_count,output_count,c,i,n,no,ip=0,ep=0,sent,received,cycles,tick=0,err,bad;
generate if(!ADAPTER)begin:engine
cip_image_histogram_frame #(.MAX_WIDTH(32),.MAX_HEIGHT(16)) dut(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .cfg_operation(cm[0]),.cfg_width(cw),.cfg_height(ch),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .s_data(sd[7:0]),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
 .m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_last(ml),.m_ready(mr));

end else begin:adapter
wire [15:0] dw=HIST?16'd256:w;
wire [15:0] dh=HIST?16'd1:h;
if(HIST)begin:histogram
cip_image_histogram #(.DATA_W(DW),.MAX_WIDTH(32),.MAX_HEIGHT(16)) dut(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .cfg_mode(cm),.cfg_src_width(cw),.cfg_src_height(ch),.cfg_dst_width(dw+(bad==4)),.cfg_dst_height(dh),
 .cfg_param0(bad==5?32'd1:32'd0),.cfg_param1(32'd0),.cfg_frame_base(32'd0),.cfg_frame_stride(bad==6?32'd1:32'd0),.cfg_aux_base(32'd0),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .coeff_valid(1'b0),.coeff_addr(16'd0),.coeff_data(32'd0),
 .aux_data({DW{1'b0}}),.aux_valid(1'b0),.aux_sof(1'b0),.aux_eol(1'b0),
 .mem_req_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_rdata(32'd0),.mem_rsp_error(1'b0),
 .s_data(sd),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
 .m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_ready(mr));
end else begin:he
cip_image_he #(.DATA_W(DW),.MAX_WIDTH(32),.MAX_HEIGHT(16)) dut(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .cfg_mode(cm),.cfg_src_width(cw),.cfg_src_height(ch),.cfg_dst_width(dw+(bad==4)),.cfg_dst_height(dh),
 .cfg_param0(bad==5?32'd1:32'd0),.cfg_param1(32'd0),.cfg_frame_base(32'd0),.cfg_frame_stride(bad==6?32'd1:32'd0),.cfg_aux_base(32'd0),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .coeff_valid(1'b0),.coeff_addr(16'd0),.coeff_data(32'd0),
 .aux_data({DW{1'b0}}),.aux_valid(1'b0),.aux_sof(1'b0),.aux_eol(1'b0),
 .mem_req_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_rdata(32'd0),.mem_rsp_error(1'b0),
 .s_data(sd),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
 .m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_ready(mr));
end

assign ml=1'b0;
end endgenerate


reg [31:0] commands[0:2047],inputs[0:4095];
reg [33:0] expected[0:65535];
reg [4095:0] folder;
reg parked=0;
reg [DW+1:0] parked_payload;
always @(posedge clk)begin
 if(!rst_n)parked<=0;
 else begin
  if(parked && (!mv || {ms,me,md}!==parked_payload))$fatal(1,"output changed under stall/CE");
  parked<=mv && (!clk_en || !mr);
  parked_payload<={ms,me,md};
 end
end
task reset_during;
input integer phase;
integer k;
begin
 @(negedge clk);clk_en=1;cv=1;op=ADAPTER?0:1;cm=op;w=2;h=2;cw=2;ch=2;bad=0;mask=511;mr=0;
 @(posedge clk);@(negedge clk);cv=0;
 for(k=0;k<(phase==0?1:4);k=k+1)begin
  while(!sr)@(negedge clk);
  sv=1;sd=k;sof=k==0;eol=k%2==1;
  @(posedge clk);@(negedge clk);sv=0;
 end
 if(phase==1)repeat(10)@(negedge clk);
 if(phase>=2)begin
  while(!mv)@(negedge clk);repeat(3)@(negedge clk);
  if(phase==3)begin mr=1;@(posedge clk);@(negedge clk);mr=0;end
 end
 rst_n=0;sv=0;cv=0;repeat(2)@(negedge clk);rst_n=1;
 if(rv || mv)$fatal(1,"reset did not cancel frame");
end
endtask
initial begin
 if(!$value$plusargs("folder=%s",folder))$fatal(1,"folder required");
 if(!$value$plusargs("commands=%d",count))$fatal(1,"count required");
 if(!$value$plusargs("pixels=%d",pixel_count))$fatal(1,"pixel count required");
 $readmemh({folder,"/commands.hex"},commands,0,count*7-1);
 $readmemh({folder,"/inputs.hex"},inputs,0,pixel_count-1);
 if(!$value$plusargs("outputs=%d",output_count))$fatal(1,"output count required");
 $readmemh({folder,"/expected.hex"},expected,0,output_count-1);
 repeat(3)@(negedge clk);rst_n=1;
 reset_during(0);reset_during(1);reset_during(2);reset_during(3);
 for(c=0;c<count;c=c+1)begin
  @(negedge clk);clk_en=1;op=commands[c*7];w=commands[c*7+1];h=commands[c*7+2];
  err=commands[c*7+3];bad=commands[c*7+4];n=commands[c*7+5];no=commands[c*7+6];tag=c;cm=op;cw=w;ch=h;cv=1;
  @(posedge clk);if(!cr)$fatal(1,"command unavailable");
  @(negedge clk);cv=0;cw=0;ch=0;cm=15;tag=~tag;
  sent=0;received=0;cycles=0;
  while(!rv)begin
   clk_en=(tick%7!=2);mr=(tick%5!=1);sv=sent<n && tick%4!=0;
   sd=inputs[ip+sent];if(bad==3 && sent==0)sd=sd | 256;sof=(sent==0) ^ (bad==1 && sent==0);eol=(sent%w==w-1) ^ (bad==7 && sent==n-1);
   @(posedge clk);
   if(clk_en)begin
    if(sv && sr)sent=sent+1;
    if(mv && mr)begin
     if(received>=no || md!==expected[ep+received][DW-1:0])$fatal(1,"data case=%0d pixel=%0d got=%h expected=%h",c,received,md,expected[ep+received]);
     if(ms!==expected[ep+received][33] || me!==expected[ep+received][32] || (!ADAPTER && ml!==(received==no-1)))$fatal(1,"markers");
     received=received+1;
    end
   end
   @(negedge clk);tick=tick+1;cycles=cycles+1;
   if(cycles>40000)$fatal(1,"timeout case %0d",c);
  end
  if(sent!=n || received!=no || rt!==(c%256) || re!==err)$fatal(1,"response case=%0d sent=%0d received=%0d error=%0d expected=%0d",c,sent,received,re,err);
  sv=0;clk_en=1;rr=0;
  repeat(3)begin @(posedge clk);if(!rv || rt!==(c%256) || re!==err)$fatal(1,"response hold");@(negedge clk);end
  rr=1;@(posedge clk);@(negedge clk);rr=0;ip=ip+n;ep=ep+no;
 end
 $display("HISTOGRAM_FRAME PASS commands=%0d outputs=%0d resets=4 adapter=%0d hist=%0d width=%0d",count,ep,ADAPTER,HIST,DW);$finish;
end
initial begin #100000000;$fatal(1,"global timeout");end
endmodule
