`timescale 1ns/1ps
module tb_cip_image_gamma;
parameter DW=24;
reg clk=0;always #5 clk=~clk;
reg rst_n=1,ce=1,cv=0,rr=0,sv=0,mr=0,sof=0,eol=0;
reg [7:0] tag=0;
reg [15:0] w=0,h=0,dw=0,dh=0;
reg [3:0] mode=0;
reg [31:0] p0=0,p1=0;
reg [DW-1:0] sd=0;
reg coeff_valid=0;reg [15:0] coeff_addr=0;reg [31:0] coeff_data=0;wire coeff_ready;
wire cr,rv,sr,mv,ms,me;wire [DW-1:0] md;wire [7:0] rt;wire [1:0] err;
cip_image_gamma #(.DATA_W(DW)) dut(
 .clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(err),
 .cfg_src_width(w),.cfg_src_height(h),.cfg_dst_width(dw),.cfg_dst_height(dh),
 .cfg_mode(mode),.cfg_param0(p0),.cfg_param1(p1),.cfg_frame_base(32'd0),
 .cfg_frame_stride(32'd0),.cfg_aux_base(32'd0),.coeff_valid(coeff_valid),.coeff_ready(coeff_ready),
 .coeff_addr(coeff_addr),.coeff_data(coeff_data),.aux_data({DW{1'b0}}),.aux_valid(1'b0),
 .aux_sof(1'b0),.aux_eol(1'b0),.aux_ready(),.mem_req_valid(),.mem_req_write(),
 .mem_req_addr(),.mem_req_wdata(),.mem_req_wstrb(),.mem_req_ready(1'b0),
 .mem_rsp_valid(1'b0),.mem_rsp_rdata(32'd0),.mem_rsp_error(1'b0),.mem_rsp_ready(),
 .s_sof(sof),.s_eol(eol),.m_sof(ms),.m_eol(me),.s_data(sd),.s_valid(sv),.s_ready(sr),
 .m_data(md),.m_valid(mv),.m_ready(mr));
reg [31:0] commands[0:2047];
reg [33:0] inputs[0:8191],outputs[0:8191];
reg [47:0] coefficients[0:16383];
reg [4095:0] folder,path;
integer count,ninputs,noutputs,ncoeffs,packet,base,ni,no,nc,expected_error;
integer sent,received,cycle,input_index=0,output_index=0,coeff_index=0,coeff_sent;
integer reset_cases=0,reset_mode,reset_phase;
reg fi,fo,fc;
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task reset_and_identity;
integer limit;
begin
 sv=0;coeff_valid=0;cv=0;mr=0;rr=0;ce=0;rst_n=0;#1;
 if(rv || mv || sr || cr || coeff_ready)$fatal(1,"reset gating");
 tick;rst_n=1;ce=1;
 mode=0;w=1;h=1;dw=1;dh=1;p0=0;p1=0;tag=201;cv=1;tick;cv=0;
 sv=1;sd=24'h123456;sof=1;eol=1;limit=0;
 #1;while(!sr)begin tick;limit=limit+1;if(limit>20)$fatal(1,"reset input timeout");end
 tick;sv=0;limit=0;
 while(!mv)begin tick;limit=limit+1;if(limit>20)$fatal(1,"reset output timeout");end
 if(md!==24'h123456 || !ms || !me)$fatal(1,"reset identity");mr=1;tick;mr=0;
 limit=0;while(!rv)begin tick;limit=limit+1;if(limit>20)$fatal(1,"reset response timeout");end
 if(err || rt!=201)$fatal(1,"reset response");rr=1;tick;rr=0;
 // Reset must invalidate all stale RAM contents, so enabled use is rejected.
 p0=1;tag=203;cv=1;tick;cv=0;
 if(!rv || err!=2 || sr || mv)$fatal(1,"reset table validity");rr=1;tick;rr=0;
 reset_cases=reset_cases+1;
end endtask
// phase0: partial coefficient bank; phase1: bank apply; phase2: captured pixel;
// phase3: stalled output. Reset must restore identity for every phase.
task abort_phase(input integer phase);
integer index,total,limit;
begin
 mode=phase<2?1:0;w=phase<2?0:5;h=phase<2?0:4;dw=w;dh=h;p0=0;p1=0;tag=200;
 cv=1;ce=1;tick;cv=0;mr=0;
 if(phase<2)begin
   total=phase==0?5:768;
   for(index=0;index<total;index=index+1)begin
     coeff_valid=1;coeff_addr=index;coeff_data=0;#1;
     if(!coeff_ready)$fatal(1,"coefficient reset setup");tick;
   end
   coeff_valid=0;
   if(phase==1)begin
      if(!rv || err)$fatal(1,"complete LUT setup");rr=1;tick;rr=0;
      mode=0;w=1;h=1;dw=1;dh=1;p0=1;tag=202;cv=1;tick;cv=0;
      repeat(10)tick;if(sr || rv || mv)$fatal(1,"table-copy reset setup");
   end
 end else begin
   sv=1;sd=24'h123456;sof=1;eol=0;limit=0;
   #1;while(!sr)begin tick;limit=limit+1;if(limit>20)$fatal(1,"abort input timeout");end
   tick;sv=0;
   if(phase==3)begin
      limit=0;while(!mv)begin tick;limit=limit+1;if(limit>20)$fatal(1,"abort output timeout");end
      repeat(3)tick;
   end
 end
 reset_and_identity;
end endtask
initial begin
 if(!$value$plusargs("folder=%s",folder) || !$value$plusargs("commands=%d",count) ||
    !$value$plusargs("inputs=%d",ninputs) || !$value$plusargs("outputs=%d",noutputs) || !$value$plusargs("coeffs=%d",ncoeffs))$fatal(1,"fixtures missing");
 path={folder,"/commands.hex"};$readmemh(path,commands,0,count*11-1);
 path={folder,"/inputs.hex"};if(ninputs>0)$readmemh(path,inputs,0,ninputs-1);
 path={folder,"/outputs.hex"};if(noutputs>0)$readmemh(path,outputs,0,noutputs-1);
 path={folder,"/coeffs.hex"};if(ncoeffs>0)$readmemh(path,coefficients,0,ncoeffs-1);
 #1;rst_n=0;#1;rst_n=1;@(negedge clk);
 for(packet=0;packet<count;packet=packet+1)begin
   base=packet*11;mode=commands[base];w=commands[base+1];h=commands[base+2];
   dw=commands[base+3];dh=commands[base+4];p0=commands[base+5];p1=commands[base+6];
   expected_error=commands[base+7];ni=commands[base+8];no=commands[base+9];nc=commands[base+10];tag=packet+1;
   cv=1;ce=1;#1;if(!cr)$fatal(1,"command blocked packet=%0d",packet);tick;cv=0;
   // Live configuration must no longer affect the operation.
   w=0;h=0;dw=0;dh=0;p0=32'hdeadbeef;p1=7;mode=15;
   sent=0;received=0;coeff_sent=0;cycle=0;
   while(!rv)begin
     ce=cycle%7!=2;mr=cycle%11!=3 && cycle%11!=4;
     sv=sent<ni;
     coeff_valid=coeff_sent<nc;
     if(coeff_valid)begin coeff_addr=coefficients[coeff_index+coeff_sent][47:32];coeff_data=coefficients[coeff_index+coeff_sent][31:0];end
     if(sv)begin sd=inputs[input_index+sent];sof=inputs[input_index+sent][33];eol=inputs[input_index+sent][32];end
     #1;fi=ce && sv && sr;fo=ce && mv && mr;fc=ce && coeff_valid && coeff_ready;
     if(nc==0 && coeff_ready)$fatal(1,"unexpected coefficient acceptance");
     if(cr)$fatal(1,"accepted command while active");
     if(mv)begin
       if(received>=no || md!==outputs[output_index+received][DW-1:0] ||
          ms!==outputs[output_index+received][33] || me!==outputs[output_index+received][32])
          $fatal(1,"numeric/marker mismatch width=%0d packet=%0d output=%0d",DW,packet,received);
     end
     tick;if(fi)sent=sent+1;if(fo)received=received+1;if(fc)coeff_sent=coeff_sent+1;
     cycle=cycle+1;if(cycle>1000000)$fatal(1,"timeout packet=%0d",packet);
   end
   sv=0;coeff_valid=0;mr=0;ce=1;
   if(sent!=ni || received!=no || coeff_sent!=nc || rt!==tag || err!==expected_error[1:0])
     $fatal(1,"completion mismatch packet=%0d got=%0d/%0d err=%0d expected=%0d/%0d err=%0d",packet,sent,received,err,ni,no,expected_error);
   repeat(3)begin tick;if(!rv || rt!==tag || err!==expected_error[1:0] || mv || sr || cr)$fatal(1,"response hold");end
   ce=0;rr=1;repeat(3)tick;if(!rv)$fatal(1,"response CE hold");ce=1;tick;rr=0;
   input_index=input_index+ni;output_index=output_index+no;coeff_index=coeff_index+nc;
 end
 if(DW==24)for(reset_phase=0;reset_phase<4;reset_phase=reset_phase+1)abort_phase(reset_phase);
 $display("GAMMA_ADAPTER PASS width=%0d commands=%0d inputs=%0d outputs=%0d reset_cases=%0d",DW,count,input_index,output_index,reset_cases);$finish;
end
initial begin #1000000000;$fatal(1,"global timeout");end
endmodule
