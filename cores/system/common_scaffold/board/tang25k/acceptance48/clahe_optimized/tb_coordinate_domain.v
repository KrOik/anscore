`timescale 1ns/1ps
module tb_coordinate_domain;
reg clk=0;always #5 clk=~clk;reg rst_n=0,cv=0;wire wide_rsp_valid;wire [1:0] wide_rsp_error;
cip_image_clahe #(.DATA_W(8),.MAX_WIDTH(34),.MAX_HEIGHT(34)) bounded(.clk(1'b0),.rst_n(1'b0),.clk_en(1'b0));
cip_image_clahe #(.DATA_W(8),.MAX_WIDTH(513),.MAX_HEIGHT(1)) wide(.clk(clk),.rst_n(rst_n),.clk_en(1'b1),.cmd_valid(cv),.cmd_tag(8'h51),.rsp_valid(wide_rsp_valid),.rsp_ready(1'b0),.rsp_error(wide_rsp_error),.cfg_src_width(16'd513),.cfg_src_height(16'd1),.cfg_dst_width(16'd513),.cfg_dst_height(16'd1),.cfg_mode(4'd0),.cfg_param0(32'd1),.cfg_param1(32'h00010001),.cfg_frame_base(32'd0),.cfg_frame_stride(32'd0),.cfg_aux_base(32'd0));
integer w,t,n,d,expected,checks=0;
initial begin
 #1;
 for(w=1;w<=34;w=w+1)for(t=1;t<=w;t=t+1)begin
  expected=(w+t-1)/t;
  if(bounded.grid_x(w,t)!==expected || bounded.grid_y(w,t)!==expected || bounded.enabled.core.grid_x(w,t)!==expected || bounded.enabled.core.grid_y(w,t)!==expected)$fatal(1,"ceil mismatch %0d %0d",w,t);
  checks=checks+4;
 end
 for(d=1;d<=68;d=d+1)for(n=0;n<=68;n=n+1)begin
  expected=n/d;
  if(bounded.enabled.core.coordinate_quotient(n,d)!==expected)$fatal(1,"quotient mismatch");
  checks=checks+1;
  if(n<=d)begin
   expected=n*256/d;
   if(bounded.enabled.core.coordinate_fraction(n,d)!==expected)$fatal(1,"fraction mismatch %0d %0d",n,d);
   checks=checks+1;
  end
 end
 if(wide.grid_x(513,1)!==16'd513 || wide.enabled.core.grid_x(513,1)!==16'd513)$fatal(1,"wide illegal count truncated");
 rst_n=1;@(negedge clk);cv=1;@(posedge clk);@(negedge clk);cv=0;#1;
 if(!wide_rsp_valid || wide_rsp_error!==2'd2)$fatal(1,"wide513 illegal tile-count command not rejected");
 $display("CLAHE_COORDINATE_DOMAIN PASS checks=%0d plus wide513 command rejection",checks);$finish;
end
endmodule
