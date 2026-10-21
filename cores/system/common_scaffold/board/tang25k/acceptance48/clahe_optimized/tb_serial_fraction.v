`timescale 1ns/1ps
module tb_serial_fraction;
reg clk=0;always #5 clk=~clk;reg rst_n=0;
cip_image_clahe_frame #(.MAX_WIDTH(34),.MAX_HEIGHT(34)) uut(.clk(clk),.rst_n(rst_n),.clk_en(1'b1),.start_valid(1'b0),.s_valid(1'b0),.m_ready(1'b0),.done_ready(1'b0));
integer n,d,i,checks=0,ex,ey;
initial begin
 repeat(2)@(negedge clk);rst_n=1;
 for(d=1;d<=68;d=d+1)for(n=0;n<=d;n=n+1)begin
  @(negedge clk);uut.state=29;uut.offset_x=n;uut.offset_y=d-n;uut.span_x=d;uut.span_y=d;
  uut.cx0_q=0;uut.cx1_q=0;uut.cy0_q=0;uut.cy1_q=0;
  // One initialization edge followed by8 enabled restoring-division edges.
  for(i=0;i<9;i=i+1)begin @(posedge clk);@(negedge clk);end
  ex=n*256/d;ey=(d-n)*256/d;
  if(uut.fraction_x!==ex || uut.fraction_y!==ey || uut.state!=17)$fatal(1,"serial fraction n=%0d d=%0d got=%0d/%0d expected=%0d/%0d state=%0d",n,d,uut.fraction_x,uut.fraction_y,ex,ey,uut.state);
  checks=checks+2;
 end
 $display("CLAHE_SERIAL_FRACTION PASS checks=%0d all nonnegative offsets<=span<=68",checks);$finish;
end
endmodule
