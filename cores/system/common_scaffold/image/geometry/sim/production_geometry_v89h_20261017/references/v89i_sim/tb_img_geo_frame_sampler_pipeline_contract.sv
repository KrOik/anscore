`timescale 1ns/1ps
// Direct unchanged-old-sampler equivalence and enabled-edge latency contract.
// The shared registered memory returns the same four accepted taps to both.
module tb_img_geo_frame_sampler_pipeline_contract;
parameter PW=8,LANES=3,AW=32;
localparam DW=PW*LANES;
reg clk=0;always #10 clk=~clk;
reg rst_n=0;integer cycle=0;
always @(negedge clk)cycle=cycle+1;
wire ce=cycle%11!=1&&cycle%11!=5&&cycle%11!=6;
reg sv=0,mr=0;reg [2:0] markers=0;
wire osr,nsr,oqv,nqv,orr,nrr,omv,nmv,oqread,nqread;
wire [AW-1:0] oa,na;
wire [DW-1:0] od,nd;
wire [3:0] oe,ne;
wire os,ol,of,ns,nl,nf;
reg rsp=0;reg [DW-1:0] memory_data=0,pending_data=0;
integer pending=0,delay_count=0,requests=0;
wire memory_ready=cycle%5!=2;
img_geo_frame_sampler_baseline #(.PIXEL_W(PW),.LANES(LANES),.ADDR_W(AW)) old_dut(
 .clk(clk),.rst_n(rst_n),.clk_en(ce),.s_valid(sv),.s_ready(osr),
 .s_x_q8(24'd105),.s_y_q8(24'd39),.s_border(1'b0),.s_error(4'd0),
 .s_sof(markers[2]),.s_eol(markers[1]),.s_eof(markers[0]),.s_filter(2'd1),
 .s_src_width(16'd2),.s_src_height(16'd2),.s_stride(32'd2),.s_base_addr({AW{1'b0}}),
 .mem_req_valid(oqv),.mem_req_ready(memory_ready),.mem_req_read(oqread),.mem_req_addr(oa),
 .mem_rsp_valid(rsp),.mem_rsp_ready(orr),.mem_rsp_data(memory_data),.mem_rsp_error(1'b0),
 .m_valid(omv),.m_ready(mr),.m_data(od),.m_error(oe),.m_sof(os),.m_eol(ol),.m_eof(of));
img_geo_frame_sampler #(.PIXEL_W(PW),.LANES(LANES),.ADDR_W(AW)) new_dut(
 .clk(clk),.rst_n(rst_n),.clk_en(ce),.s_valid(sv),.s_ready(nsr),
 .s_x_q8(24'd105),.s_y_q8(24'd39),.s_border(1'b0),.s_error(4'd0),
 .s_sof(markers[2]),.s_eol(markers[1]),.s_eof(markers[0]),.s_filter(2'd1),
 .s_src_width(16'd2),.s_src_height(16'd2),.s_stride(32'd2),.s_base_addr({AW{1'b0}}),
 .mem_req_valid(nqv),.mem_req_ready(memory_ready),.mem_req_read(nqread),.mem_req_addr(na),
 .mem_rsp_valid(rsp),.mem_rsp_ready(nrr),.mem_rsp_data(memory_data),.mem_rsp_error(1'b0),
 .m_valid(nmv),.m_ready(mr),.m_data(nd),.m_error(ne),.m_sof(ns),.m_eol(nl),.m_eof(nf));
function [DW-1:0] memory_word;
 input [AW-1:0] address;integer lane;reg [63:0] value;
 begin
  memory_word=0;
  for(lane=0;lane<LANES;lane=lane+1)begin
   value=(address+1)*12345+lane*37+13;
   memory_word[lane*PW+:PW]=value[PW-1:0];
  end
 end
endfunction
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin rsp<=0;pending<=0;delay_count<=0;memory_data<=0;pending_data<=0;requests<=0;end
 else if(ce)begin
  if(oqv!==nqv||orr!==nrr)$fatal(1,"old/new memory cadence changed");
  if(rsp&&nrr)rsp<=0;
  if(pending)begin
   if(delay_count==0)begin rsp<=1;memory_data<=pending_data;pending<=0;end
   else delay_count<=delay_count-1;
  end
  if(nqv&&memory_ready)begin
   if(pending||rsp||oa!==na||na!==requests||!oqread||!nqread)$fatal(1,"shared memory request mismatch");
   requests<=requests+1;pending<=1;delay_count<=3;pending_data<=memory_word(na);
  end
 end
end
integer enabled_ticks=0,last_response_tick=-1,old_valid_tick=-1,new_valid_tick=-1;
always @(posedge clk)begin
 if(!rst_n)begin enabled_ticks=0;last_response_tick=-1;old_valid_tick=-1;new_valid_tick=-1;end
 else begin
  if(ce)enabled_ticks=enabled_ticks+1;
  if(ce&&rsp&&nrr)last_response_tick=enabled_ticks;
  #1;
  if(rst_n&&omv&&old_valid_tick<0)old_valid_tick=enabled_ticks;
  if(rst_n&&nmv&&new_valid_tick<0)new_valid_tick=enabled_ticks;
 end
end
localparam LW=6*(PW+9)+2*(PW+18)+(PW+19);
wire [LANES*LW-1:0] arithmetic_snapshot;
genvar lane;
generate for(lane=0;lane<LANES;lane=lane+1)begin:lanes_snapshot
 assign arithmetic_snapshot[lane*LW+:LW]={new_dut.h00[lane],new_dut.h10[lane],new_dut.h01[lane],new_dut.h11[lane],new_dut.row0[lane],new_dut.row1[lane],new_dut.vertical0[lane],new_dut.vertical1[lane],new_dut.rounded[lane]};
end endgenerate
wire [511+DW*5+LANES*LW:0] snapshot={new_dut.state,new_dut.sample_index,new_dut.bilinear,
 new_dut.x0,new_dut.x1,new_dut.y0,new_dut.y1,new_dut.frac_x,new_dut.frac_y,
 new_dut.stride,new_dut.base_addr,new_dut.p00,new_dut.p10,new_dut.p01,new_dut.p11,
 new_dut.m_data,new_dut.m_error,new_dut.m_sof,new_dut.m_eol,new_dut.m_eof,arithmetic_snapshot};
reg [511+DW*5+LANES*LW:0] saved;
integer ce_holds=0,completed=0,cancelled=0,target;
always @(posedge clk)if(rst_n&&!ce)begin
 saved=snapshot;#2;if(snapshot!==saved)$fatal(1,"new internal stage changed with CE=0");ce_holds=ce_holds+1;
end
task launch;
begin
 @(negedge clk);while(!(osr&&nsr))@(negedge clk);
 requests=0;old_valid_tick=-1;new_valid_tick=-1;last_response_tick=-1;sv=1;mr=0;
 do @(posedge clk);while(!(ce&&osr&&nsr));
 @(negedge clk);sv=0;
end
endtask
task complete_case;
begin
 launch;
 wait(omv&&nmv);@(negedge clk);
 if({od,oe,os,ol,of}!=={nd,ne,ns,nl,nf}||{ns,nl,nf}!==markers||ne!=0||requests!=4)$fatal(1,"old/new public transaction mismatch");
 if(old_valid_tick-last_response_tick!=1||new_valid_tick-last_response_tick!=5||new_valid_tick-old_valid_tick!=4)$fatal(1,"enabled interpolation latency old%0d new%0d last%0d",old_valid_tick,new_valid_tick,last_response_tick);
 repeat(13)begin @(negedge clk);if(!omv||!nmv||od!==nd)$fatal(1,"long output hold");end
 mr=1;do @(posedge clk);while(!ce);
 @(negedge clk);mr=0;completed=completed+1;
end
endtask
initial begin
 repeat(3)@(negedge clk);rst_n=1;
 for(target=0;target<8;target=target+1)begin markers=target;complete_case;end
 // Target RESPONSE with a genuinely pending registered memory return, each
 // of the five new arithmetic stages, and held OUTPUT_PIXEL.
 for(target=2;target<=8;target=target+1)begin
  launch;
  if(target==2)wait(new_dut.state==2&&pending);
  else wait(new_dut.state==target);
  #3;rst_n=0;sv=0;mr=0;#2;
  if(omv||nmv||oqv||nqv||orr||nrr||new_dut.state!=0)$fatal(1,"async stage reset cancellation");
  cancelled=cancelled+1;
  repeat(3)@(negedge clk);rst_n=1;
  complete_case;
 end
 if(cancelled!=7||completed!=15||ce_holds==0)$fatal(1,"contract coverage count");
 $display("SAMPLER CONTRACT PASS PW=%0d LANES=%0d AW=%0d old_latency=1 new_latency=5 extra_CE=4 marker_patterns=8 async_reset_points=7 replay=7 completed=15 internal_ce_holds=%0d",PW,LANES,AW,ce_holds);
 $finish;
end
initial begin #10000000;$fatal(1,"contract watchdog");end
endmodule
