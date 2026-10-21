`timescale 1ns/1ps
module tb_cip_image_threshold_modes;
parameter DW=8;
reg clk=0;always #5 clk=~clk;
reg rst_n=1,ce=1,cv=0,rr=0,sv=0,mr=0,sof=0,eol=0;
reg [7:0] tag=0;
reg [15:0] w=0,h=0,dw=0,dh=0;
reg [3:0] mode=0;
reg [31:0] p0=0,p1=0;
reg [DW-1:0] sd=0;
wire cr,rv,sr,mv,ms,me;wire [DW-1:0] md;wire [7:0] rt;wire [1:0] err;
cip_image_threshold #(.DATA_W(DW),.OTSU_WIDTH(5),.OTSU_HEIGHT(4),.OTSU_COUNT_W(8),.ADAPTIVE_MAX_WIDTH(8)) dut(
 .clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(err),
 .cfg_src_width(w),.cfg_src_height(h),.cfg_dst_width(dw),.cfg_dst_height(dh),
 .cfg_mode(mode),.cfg_param0(p0),.cfg_param1(p1),.cfg_frame_base(32'd0),
 .cfg_frame_stride(32'd0),.cfg_aux_base(32'd0),.coeff_valid(1'b0),.coeff_ready(),
 .coeff_addr(16'd0),.coeff_data(32'd0),.aux_data({DW{1'b0}}),.aux_valid(1'b0),
 .aux_sof(1'b0),.aux_eol(1'b0),.aux_ready(),.mem_req_valid(),.mem_req_write(),
 .mem_req_addr(),.mem_req_wdata(),.mem_req_wstrb(),.mem_req_ready(1'b0),
 .mem_rsp_valid(1'b0),.mem_rsp_rdata(32'd0),.mem_rsp_error(1'b0),.mem_rsp_ready(),
 .s_sof(sof),.s_eol(eol),.m_sof(ms),.m_eol(me),.s_data(sd),.s_valid(sv),.s_ready(sr),
 .m_data(md),.m_valid(mv),.m_ready(mr));
reg [31:0] commands[0:1023];
reg [33:0] inputs[0:4095],outputs[0:4095];
reg [4095:0] folder,path;
integer count,ninputs,noutputs,packet,base,ni,no,expected_error;
integer sent,received,cycle,input_index=0,output_index=0;
integer reset_cases=0,reset_mode,reset_phase;
reg fi,fo;
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task abort_and_recover(input [3:0] operation,input wait_output);
integer index,total,limit;
begin
 mode=operation;w=operation==1?5:3;h=operation==1?4:3;
 dw=operation==1?w:w-2;dh=operation==1?h:h-2;p0=0;p1=0;tag=200;
 cv=1;ce=1;tick;cv=0;mr=0;
 total=wait_output?w*h:2;
 for(index=0;index<total;index=index+1)begin
   sv=1;sd=index*11;sof=index==0;eol=index%w==w-1;limit=0;
   #1;while(!sr)begin tick;limit=limit+1;if(limit>1000)$fatal(1,"reset input timeout");end
   tick;
 end
 sv=0;
 if(wait_output)begin
   limit=0;while(!mv)begin tick;limit=limit+1;if(limit>1000000)$fatal(1,"reset output timeout");end
   repeat(3)tick;
 end
 ce=0;rst_n=0;#1;if(rv || mv || sr || cr)$fatal(1,"abort gating");tick;rst_n=1;ce=1;
 // A fixed-mode command after abort must see no stale completion or pixel.
 mode=0;w=1;h=1;dw=1;dh=1;p0=0;p1=0;tag=201;cv=1;tick;cv=0;
 sv=1;sd=0;sof=1;eol=1;limit=0;
 #1;while(!sr)begin tick;limit=limit+1;if(limit>20)$fatal(1,"recovery input timeout");end
 tick;sv=0;
 if(!mv || md!=={DW{1'b1}} || !ms || !me)$fatal(1,"abort recovery data");
 mr=1;tick;mr=0;limit=0;
 while(!rv)begin tick;limit=limit+1;if(limit>20)$fatal(1,"recovery completion timeout");end
 if(err || rt!=201)$fatal(1,"abort recovery response");rr=1;tick;rr=0;reset_cases=reset_cases+1;
end endtask
initial begin
 if(!$value$plusargs("folder=%s",folder) || !$value$plusargs("commands=%d",count) ||
    !$value$plusargs("inputs=%d",ninputs) || !$value$plusargs("outputs=%d",noutputs))$fatal(1,"fixtures missing");
 path={folder,"/commands.hex"};$readmemh(path,commands,0,count*10-1);
 path={folder,"/inputs.hex"};$readmemh(path,inputs,0,ninputs-1);
 path={folder,"/outputs.hex"};$readmemh(path,outputs,0,noutputs-1);
 #1;rst_n=0;#1;rst_n=1;@(negedge clk);
 for(packet=0;packet<count;packet=packet+1)begin
   base=packet*10;mode=commands[base];w=commands[base+1];h=commands[base+2];
   dw=commands[base+3];dh=commands[base+4];p0=commands[base+5];p1=commands[base+6];
   expected_error=commands[base+7];ni=commands[base+8];no=commands[base+9];tag=packet+1;
   cv=1;ce=1;#1;if(!cr)$fatal(1,"command blocked packet=%0d",packet);tick;cv=0;
   // Live configuration must no longer affect the operation.
   w=0;h=0;dw=0;dh=0;p0=32'hdeadbeef;p1=7;mode=15;
   sent=0;received=0;cycle=0;
   while(!rv)begin
     ce=cycle%7!=2;mr=cycle%11!=3 && cycle%11!=4;
     sv=sent<ni;
     if(sv)begin sd=inputs[input_index+sent];sof=inputs[input_index+sent][33];eol=inputs[input_index+sent][32];end
     #1;fi=ce && sv && sr;fo=ce && mv && mr;
     if(cr)$fatal(1,"accepted command while active");
     if(mv)begin
       if(received>=no || md!==outputs[output_index+received][DW-1:0] ||
          ms!==outputs[output_index+received][33] || me!==outputs[output_index+received][32])
          $fatal(1,"numeric/marker mismatch width=%0d packet=%0d output=%0d",DW,packet,received);
     end
     tick;if(fi)sent=sent+1;if(fo)received=received+1;
     cycle=cycle+1;if(cycle>1000000)$fatal(1,"timeout packet=%0d",packet);
   end
   sv=0;mr=0;ce=1;
   if(sent!=ni || received!=no || rt!==tag || err!==expected_error[1:0])
     $fatal(1,"completion mismatch packet=%0d got=%0d/%0d err=%0d expected=%0d/%0d err=%0d",packet,sent,received,err,ni,no,expected_error);
   repeat(3)begin tick;if(!rv || rt!==tag || err!==expected_error[1:0] || mv || sr || cr)$fatal(1,"response hold");end
   ce=0;rr=1;repeat(3)tick;if(!rv)$fatal(1,"response CE hold");ce=1;tick;rr=0;
   input_index=input_index+ni;output_index=output_index+no;
 end
 if(DW<=16)for(reset_mode=2;reset_mode<=3;reset_mode=reset_mode+1)
   for(reset_phase=0;reset_phase<=1;reset_phase=reset_phase+1)abort_and_recover(reset_mode,reset_phase);
 if(DW==8)for(reset_phase=0;reset_phase<=1;reset_phase=reset_phase+1)abort_and_recover(1,reset_phase);
 $display("THRESHOLD_MODES PASS width=%0d commands=%0d inputs=%0d outputs=%0d reset_cases=%0d",DW,count,input_index,output_index,reset_cases);$finish;
end
initial begin #1000000000;$fatal(1,"global timeout");end
endmodule
