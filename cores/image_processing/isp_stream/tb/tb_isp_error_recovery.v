`timescale 1ns/1ps
module tb_isp_error_recovery;
 reg clk=0,rst=0,cmd=0,sv=0,sof=0,eol=0,mr=0,rr=0;
 reg [15:0] id=1;always #5 clk=~clk;
 wire ready,sr,mv,ms,me,mf,rv;wire [23:0] md;wire [15:0] mid;wire [3:0] error;
 wire [191:0] identity={48'd0,16'd1024,16'd0,16'd0,16'd0,16'd1024,16'd0,16'd0,16'd0,16'd1024};
 isp_stream_core dut(.clk(clk),.rst_n(rst),.cmd_valid(cmd),.cmd_ready(ready),
 .cmd_width(16'd5),.cmd_height(16'd5),.cmd_frame_id(id),.cmd_pattern(2'd0),
 .cmd_levels(40'd0),.cmd_target(10'd0),.cmd_blc_bypass(1'b0),.cmd_bayer_bypass(1'b0),
 .cmd_gains({16'd256,16'd256,16'd256}),.cmd_matrix(identity),.cmd_gamma_enable(1'b0),
 .lut_valid(1'b0),.lut_channel(2'd0),.lut_address(8'd0),.lut_value(8'd0),
 .s_valid(sv),.s_ready(sr),.s_data(10'd100),.s_sof(sof),.s_eol(eol),
 .m_valid(mv),.m_ready(mr),.m_data(md),.m_sof(ms),.m_eol(me),.m_eof(mf),.m_frame_id(mid),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_error(error));
 integer outputs=0,index=0;reg held=0;reg [42:0] held_word;
 always @(posedge clk)if(rst)begin
  if(held&&(!mv||{mid,ms,me,mf,md}!==held_word))$fatal(1,"fatal drain revoked output");
  held<=mv&&!mr;held_word<={mid,ms,me,mf,md};
  if(mv&&mr)begin
   index=outputs%9;
   if(md!==24'h191919||mid!=outputs/9+1||ms!=(index==0)||me!=(index%3==2)||mf!=(index==8))$fatal(1,"recovery pixel/metadata");
   outputs=outputs+1;
  end
 end
 task launch;
 begin @(negedge clk);cmd=1;do @(posedge clk);while(!ready);@(negedge clk);cmd=0;end
 endtask
 task send(input bit malformed);
 begin for(integer y=0;y<5;y=y+1)for(integer x=0;x<5;x=x+1)begin
  sv=1;sof=x==0&&y==0;eol=x==4||(malformed&&x==0&&y==0);
  do @(posedge clk);while(!sr);@(negedge clk);sv=0;
 end end endtask
 task response(input integer code);
 begin wait(rv);@(negedge clk);if(error!=code)$fatal(1,"error status %d",error);
  rr=1;@(negedge clk);rr=0;end endtask
 initial begin
  repeat(4)@(negedge clk);rst=1;launch();
  fork
   send(1);
   begin
    wait(mv);@(negedge clk);mr=1;@(posedge clk);@(negedge clk);mr=0;
    wait(dut.raw_rsp);
    repeat(20)begin @(negedge clk);if(rv)$fatal(1,"response before pending color drain");end
    mr=1;
   end
  join
  response(2);id=2;launch();send(0);response(0);
  if(outputs!=18)$fatal(1,"recovery output count");
  $display("PASS ISP malformed EOL, backpressured fatal drain, reset and clean frame recovery");$finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
