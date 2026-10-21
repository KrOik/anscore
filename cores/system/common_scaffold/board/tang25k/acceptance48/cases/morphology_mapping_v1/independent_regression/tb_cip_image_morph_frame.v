`timescale 1ns/1ps
module tb_cip_image_morph_frame;
parameter DW=8, ADAPTER=0;
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
wire [7:0] rt;
wire [1:0] re;
integer count,pixel_count,c,i,n,ip=0,ep=0,sent,received,cycles,tick=0,err,bad;
generate if(!ADAPTER)begin:engine
cip_image_morph_frame #(.DATA_W(DW),.MAX_WIDTH(8),.MAX_HEIGHT(6)) dut(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .cfg_operation(op[2:0]),.cfg_width(w),.cfg_height(h),.cfg_mask(mask),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .s_data(sd),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
 .m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_last(ml),.m_ready(mr));
end else begin:adapter
cip_image_morphology #(.DATA_W(DW),.MAX_WIDTH(8),.MAX_HEIGHT(6)) dut(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .cfg_mode(op),.cfg_src_width(w),.cfg_src_height(h),.cfg_dst_width(w),.cfg_dst_height(h),
 .cfg_param0({extra[31:9],mask}),.cfg_param1(32'd0),.cfg_frame_base(32'd0),.cfg_frame_stride(32'd0),.cfg_aux_base(32'd0),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(re),
 .coeff_valid(1'b0),.coeff_addr(16'd0),.coeff_data(32'd0),
 .aux_data({DW{1'b0}}),.aux_valid(1'b0),.aux_sof(1'b0),.aux_eol(1'b0),
 .mem_req_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_rdata(32'd0),.mem_rsp_error(1'b0),
 .s_data(sd),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
 .m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_ready(mr));
assign ml=mv && me && received==n-1;
end endgenerate

reg [31:0] commands[0:2047],inputs[0:4095],expected[0:4095];
reg [4095:0] folder;
task reset_during;
input integer phase;
integer k;
begin
 @(negedge clk);clk_en=1;cv=1;op=2;w=2;h=2;mask=511;mr=0;
 @(posedge clk);@(negedge clk);cv=0;
 for(k=0;k<(phase==0?1:4);k=k+1)begin
  while(!sr)@(negedge clk);
  sv=1;sd=k;sof=k==0;eol=k%2==1;
  @(posedge clk);@(negedge clk);sv=0;
 end
 if(phase==1)repeat(10)@(negedge clk);
 if(phase==2)begin while(!mv)@(negedge clk);repeat(3)@(negedge clk);end
 rst_n=0;sv=0;cv=0;repeat(2)@(negedge clk);rst_n=1;
 if(rv || mv)$fatal(1,"reset did not cancel frame");
end
endtask
initial begin
 if(!$value$plusargs("folder=%s",folder))$fatal(1,"folder required");
 if(!$value$plusargs("commands=%d",count))$fatal(1,"count required");
 if(!$value$plusargs("pixels=%d",pixel_count))$fatal(1,"pixel count required");
 $readmemh({folder,"/commands.hex"},commands,0,count*6-1);
 $readmemh({folder,"/inputs.hex"},inputs,0,pixel_count-1);
 $readmemh({folder,"/expected.hex"},expected,0,pixel_count-1);
 repeat(3)@(negedge clk);rst_n=1;
 reset_during(0);reset_during(1);reset_during(2);
 for(c=0;c<count;c=c+1)begin
  @(negedge clk);clk_en=1;op=commands[c*6];w=commands[c*6+1];h=commands[c*6+2];
  mask=commands[c*6+3];extra=commands[c*6+3];err=commands[c*6+4];bad=commands[c*6+5];tag=c;cv=1;
  @(posedge clk);if(!cr)$fatal(1,"command unavailable");
  @(negedge clk);cv=0;n=(err!=0 && bad==0) || mask==0 || w==0 || h==0 || w>8 || h>6?0:w*h;
  sent=0;received=0;cycles=0;
  while(!rv)begin
   clk_en=(tick%7!=2);mr=(tick%5!=1);sv=sent<n && tick%4!=0;
   sd=inputs[ip+sent];sof=(sent==0) ^ (bad==1 && sent==0);eol=(sent%w==w-1);
   @(posedge clk);
   if(clk_en)begin
    if(sv && sr)sent=sent+1;
    if(mv && mr)begin
     if(received>=n || md!==expected[ep+received][DW-1:0])$fatal(1,"data case=%0d pixel=%0d got=%h expected=%h",c,received,md,expected[ep+received]);
     if(ms!==(received==0) || me!==(received%w==w-1) || ml!==(received==n-1))$fatal(1,"markers");
     received=received+1;
    end
   end
   @(negedge clk);tick=tick+1;cycles=cycles+1;
   if(cycles>10000)$fatal(1,"timeout case %0d",c);
  end
  if(sent!=n || received!=n || rt!==(c%256) || re!==err)$fatal(1,"response case=%0d sent=%0d received=%0d error=%0d expected=%0d",c,sent,received,re,err);
  sv=0;clk_en=1;rr=0;
  repeat(3)begin @(posedge clk);if(!rv || rt!==(c%256) || re!==err)$fatal(1,"response hold");@(negedge clk);end
  rr=1;@(posedge clk);@(negedge clk);rr=0;ip=ip+n;ep=ep+n;
 end
 $display("MORPH_FRAME PASS width=%0d commands=%0d pixels=%0d adapter=%0d resets=3",DW,count,ep,ADAPTER);$finish;
end
initial begin #100000000;$fatal(1,"global timeout");end
endmodule
