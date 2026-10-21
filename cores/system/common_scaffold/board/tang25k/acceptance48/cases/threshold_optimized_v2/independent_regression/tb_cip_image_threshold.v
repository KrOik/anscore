`timescale 1ns/1ps
module tb_cip_image_threshold;
parameter DW=8;
reg clk=0;always #5 clk=~clk;
reg rst_n=1,ce=1,cv=0,rr=0,sv=0,mr=0,sof=0,eol=0;
reg [7:0] tag=0;
reg [15:0] w=5,h=3,dw=5,dh=3;
reg [3:0] mode=0;
reg [31:0] p0=0,p1=0,base=0;
reg [DW-1:0] sd=0;
wire cr,rv,sr,mv,ms,me;
wire [7:0] rt;wire [1:0] err;wire [DW-1:0] md;
wire memv,memw,memr,coeffr,auxr;wire [31:0] ma,mwd;wire [3:0] st;
cip_image_threshold #(.DATA_W(DW)) dut(
 .clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr),.cmd_tag(tag),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_tag(rt),.rsp_error(err),
 .cfg_src_width(w),.cfg_src_height(h),.cfg_dst_width(dw),.cfg_dst_height(dh),
 .cfg_mode(mode),.cfg_param0(p0),.cfg_param1(p1),.cfg_frame_base(base),
 .cfg_frame_stride(32'd0),.cfg_aux_base(32'd0),.coeff_valid(1'b1),.coeff_ready(coeffr),
 .coeff_addr(16'd0),.coeff_data(32'hffffffff),.aux_data({DW{1'b1}}),.aux_valid(1'b1),
 .aux_sof(1'b1),.aux_eol(1'b1),.aux_ready(auxr),.mem_req_valid(memv),.mem_req_write(memw),
 .mem_req_addr(ma),.mem_req_wdata(mwd),.mem_req_wstrb(st),.mem_req_ready(1'b1),
 .mem_rsp_valid(1'b1),.mem_rsp_rdata(32'hffffffff),.mem_rsp_error(1'b1),.mem_rsp_ready(memr),
 .s_sof(sof),.s_eol(eol),.m_sof(ms),.m_eol(me),.s_data(sd),.s_valid(sv),.s_ready(sr),
 .m_data(md),.m_valid(mv),.m_ready(mr));
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
integer packet,i,j,n,outputs=0,responses=0;
integer sent,received,cycle;
reg take_in,take_out;
reg [DW-1:0] threshold,want;
reg inverted;
task command;
begin cv=1;#1;if(!cr)$fatal(1,"command blocked");tick;cv=0;end
endtask
task response(input [1:0] expected);
begin
 j=0;while(!rv && j<20)begin tick;j=j+1;end
 if(!rv || rt!==tag || err!==expected || sr || mv || cr)$fatal(1,"response contract");
 repeat(3)begin tick;if(!rv || rt!==tag || err!==expected)$fatal(1,"response stall");end
 ce=0;rr=1;repeat(2)tick;if(!rv)$fatal(1,"response CE");
 ce=1;tick;rr=0;if(rv)$fatal(1,"duplicate response");responses=responses+1;
end endtask
always @(negedge clk) if(rst_n) begin
 if(memv || memw || memr || coeffr || auxr || ma || mwd || st)$fatal(1,"unused ports active");
end
initial begin
 #1;rst_n=0;#1;rst_n=1;@(negedge clk);
 mode=15;tag=1;command;response(1);mode=0;
 w=0;tag=2;command;response(2);w=5;
 dw=4;tag=3;command;response(2);dw=5;
 p1=2;tag=4;command;response(2);p1=0;
 base=1;tag=5;command;response(2);base=0;
 if(DW<32)begin p0=32'hffffffff;tag=6;command;response(2);end
 for(packet=0;packet<20;packet=packet+1)begin
   w=1+packet%7;h=1+packet%4;dw=w;dh=h;n=w*h;
   threshold=packet*31;p0=threshold;p1=packet%2;inverted=p1[0];tag=32+packet;
   ce=0;cv=1;repeat(2)tick;if(rv || sr)$fatal(1,"disabled command accepted");
   ce=1;command;
   // Configuration changes after command must have no effect.
   p0=~p0;p1=~p1;mode=14;
   j=0;while(!sr && j<20)begin tick;j=j+1;end
   for(i=0;i<n;i=i+1)begin
     sd=i*73+packet*19;sof=i==0;eol=(i%w)==w-1;
     if(packet==19 && i==n-1)eol=~eol;
     sv=1;mr=0;#1;if(!sr)$fatal(1,"input readiness");
     want={(DW){(sd>=threshold)^inverted}};
     tick;sv=0;
     repeat(2)begin
       if(!mv || md!==want || ms!==(i==0) || me!==((i%w)==w-1) || rv)$fatal(1,"output mismatch");
       tick;
     end
     ce=0;mr=1;repeat(2)tick;if(!mv || md!==want)$fatal(1,"data CE");
     ce=1;tick;mr=0;outputs=outputs+1;
   end
   response(packet==19?2:0);mode=0;
 end
 // Continuous producer with overlapping input/output and deterministic stalls.
 w=7;h=5;dw=w;dh=h;p0=1;p1=1;tag=90;command;
 sent=0;received=0;cycle=0;
 while(received<35)begin
   ce=cycle%5!=2;mr=cycle%7!=3 && cycle%7!=4;
   sv=sent<35;sd=sent*97;sof=sent==0;eol=sent%7==6;
   #1;take_in=ce && sv && sr;take_out=ce && mv && mr;
   if(take_out)begin
     threshold=received*97;want={DW{!(threshold>=1)}};
     if(md!==want || ms!==(received==0) || me!==(received%7==6))$fatal(1,"overlap ordering");
   end
   tick;
   if(take_in)sent=sent+1;
   if(take_out)received=received+1;
   cycle=cycle+1;if(cycle>500)$fatal(1,"overlap timeout");
 end
 sv=0;mr=0;ce=1;outputs=outputs+35;response(0);
 // Reset cancels a stalled final output; next command starts cleanly.
 w=1;h=1;dw=1;dh=1;p0=0;p1=0;tag=100;command;
 while(!sr)tick;
 sd=0;sv=1;sof=1;eol=1;tick;sv=0;
 rst_n=0;#1;if(mv || rv || sr || cr)$fatal(1,"reset gating");tick;rst_n=1;
 tag=101;command;while(!sr)tick;sv=1;tick;sv=0;
 if(!mv || md!=={DW{1'b1}})$fatal(1,"reset recovery");mr=1;tick;mr=0;response(0);
 $display("THRESHOLD_ADAPTER PASS width=%0d outputs=%0d responses=%0d",DW,outputs,responses);$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule

