`timescale 1ns/1ps
module tb_isp_sobel_recovery;
 reg clk=0,rst=0,cmd=0,sv=0,sof=0,eol=0,mr=0,rr=0;
 reg [15:0] id=1,command_width=7;reg lut_offer=0;wire lut_ready;always #5 clk=~clk;
 wire ready,sr,mv,ms,me,mf,rv;wire [7:0] md;wire [15:0] mid;wire [3:0] error;
 wire [191:0] identity={48'd0,16'd1024,16'd0,16'd0,16'd0,16'd1024,16'd0,16'd0,16'd0,16'd1024};
 wire stats_valid,stats_overflow,stats_error;wire [47:0] sum_r,sum_g,sum_b;
 wire [31:0] stats_pixels,stats_lines;wire [15:0] stats_id;integer snapshots=0;reg stats_ready=0;reg gamma_enable=0;
 always @(posedge clk)if(stats_valid)begin
  if(stats_id!=2||stats_pixels!=25||stats_lines!=5||sum_r!=625||sum_g!=625||sum_b!=625||stats_overflow||stats_error)$fatal(1,"bad frame statistics leaked");
  if(stats_ready)snapshots=snapshots+1;
 end
 isp_sobel_pipeline dut(.clk(clk),.rst_n(rst),.cmd_valid(cmd),.cmd_ready(ready),
 .cmd_width(command_width),.cmd_height(16'd7),.cmd_frame_id(id),.cmd_pattern(2'd0),
 .cmd_levels(40'd0),.cmd_target(10'd0),.cmd_blc_bypass(1'b0),.cmd_bayer_bypass(1'b0),
 .cmd_gains({16'd256,16'd256,16'd256}),.cmd_matrix(identity),.cmd_gamma_enable(gamma_enable),.cmd_sobel_bypass(1'b1),
 .lut_valid(lut_offer),.lut_ready(lut_ready),.lut_channel(2'd0),.lut_address(8'd0),.lut_value(8'd0),
 .s_valid(sv),.s_ready(sr),.s_data(10'd100),.s_sof(sof),.s_eol(eol),
 .m_valid(mv),.m_ready(mr),.m_data(md),.m_sof(ms),.m_eol(me),.m_eof(mf),.m_frame_id(mid),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_error(error),.stats_valid(stats_valid),.stats_ready(stats_ready),
 .sum_r(sum_r),.sum_g(sum_g),.sum_b(sum_b),.pixel_count(stats_pixels),.line_count(stats_lines),
 .stats_frame_id(stats_id),.stats_overflow(stats_overflow),.stats_protocol_error(stats_error));
 integer outputs=0,index=0,bad_outputs=0,clean_outputs=0;reg held=0;reg [42:0] held_word;
 always @(posedge clk)if(rst)begin
  if(held&&(!mv||{mid,ms,me,mf,md}!==held_word))$fatal(1,"fatal drain revoked output");
  held<=mv&&!mr;held_word<={mid,ms,me,mf,md};
  if(mv&&mr)begin
   index=mid==1?bad_outputs:clean_outputs;
   if(md!==8'd25||(mid!=1&&mid!=2)||ms!=(index==0)||me!=(index%3==2)||mf!=(index==8))$fatal(1,"recovery pixel/metadata");
   outputs=outputs+1;if(mid==1)bad_outputs=bad_outputs+1;else clean_outputs=clean_outputs+1;
  end
 end
 task launch;
 begin @(negedge clk);cmd=1;do @(posedge clk);while(!ready);@(negedge clk);cmd=0;end
 endtask
 task send(input bit malformed);
 begin for(integer y=0;y<7;y=y+1)for(integer x=0;x<7;x=x+1)begin
  sv=1;sof=x==0&&y==0;eol=x==6||(malformed&&x==0&&y==0);
  do @(posedge clk);while(!sr);@(negedge clk);sv=0;
 end end endtask
 task response(input integer code);
 begin wait(rv);@(negedge clk);if(error!=code)$fatal(1,"error status %d",error);
  rr=1;@(negedge clk);rr=0;end endtask
 initial begin
  repeat(4)@(negedge clk);rst=1;
  command_width=4;launch();lut_offer=1;
  repeat(5)begin @(negedge clk);if(lut_ready)$fatal(1,"LUT handshake offered during rejected command");end
  response(1);lut_offer=0;command_width=7;
  id=0;gamma_enable=1;launch();response(8);
  if(outputs||stats_valid)$fatal(1,"rejected configuration emitted data");
  id=1;gamma_enable=0;launch();
  fork
   send(1);
   begin
    wait(mv);@(negedge clk);mr=1;@(posedge clk);@(negedge clk);mr=0;
    wait(dut.color.core.raw_rsp);
    repeat(20)begin @(negedge clk);if(rv)$fatal(1,"response before pending color drain");end
    mr=1;
   end
  join
  response(2);id=2;launch();mr=0;
  fork
   send(0);
   begin
    wait(mv);
    repeat(20)begin @(negedge clk);if(rv)$fatal(1,"successful response before Sobel output drain");end
    mr=1;
   end
  join
  response(0);
  // A successful snapshot remains valid after response consumption and blocks
  // admission of the next frame until the independent statistics handshake.
  repeat(30)begin @(negedge clk);if(!stats_valid||ready)$fatal(1,"pending snapshot revoked or new frame admitted");end
  stats_ready=1;@(posedge clk);@(negedge clk);stats_ready=0;
  if(stats_valid||!ready)$fatal(1,"snapshot did not release command admission");
  if(clean_outputs!=9||snapshots!=1)$fatal(1,"recovery output/statistics count");
  $display("PASS ISP Sobel configuration reject, fatal drain and recovery bad_pixels=%0d clean_pixels=%0d",bad_outputs,clean_outputs);$finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
