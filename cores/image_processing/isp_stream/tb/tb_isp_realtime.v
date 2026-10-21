`timescale 1ns/1ps
module tb_isp_realtime;
 reg clk=0,rst=0,start=0;always #10 clk=~clk; // 50 MHz target clock
 reg [15:0] width=320,height=240;reg [31:0] frames=3;
 wire start_ready,cv,cr,sv,sr,sof,eol,eof,rv,rr,done,source_error;
 wire [15:0] cw,ch,id;wire [9:0] raw;wire [3:0] error;
 wire [31:0] completed,misses,cs,ps,cycles;
 virtual_raw_source source(clk,rst,start,start_ready,width,height,frames,32'd1666667,10'd71,
 cv,cr,cw,ch,id,sv,sr,raw,sof,eol,eof,rv,rr,error,done,source_error,completed,misses,cs,ps,cycles);
 wire mv,ms,me,mf;wire [7:0] md;wire [15:0] mid,ow,oh;
 wire stats_valid,stats_overflow,stats_error;wire [47:0] red,green,blue;
 wire [31:0] pixels,lines;wire [15:0] stats_id;
 wire [191:0] identity={48'd0,16'd1024,16'd0,16'd0,16'd0,16'd1024,16'd0,16'd0,16'd0,16'd1024};
 isp_sobel_pipeline pipeline(.clk(clk),.rst_n(rst),.cmd_valid(cv),.cmd_ready(cr),
 .cmd_width(cw),.cmd_height(ch),.cmd_frame_id(id),.cmd_pattern(2'd0),.cmd_levels(40'd0),.cmd_target(10'd0),.cmd_blc_bypass(1'b0),.cmd_bayer_bypass(1'b0),
 .cmd_gains({16'd256,16'd256,16'd256}),.cmd_matrix(identity),.cmd_gamma_enable(1'b0),.cmd_sobel_bypass(id[0]),
 .lut_valid(1'b0),.lut_ready(),.lut_channel(2'd0),.lut_address(8'd0),.lut_value(8'd0),
 .s_valid(sv),.s_ready(sr),.s_data(raw),.s_sof(sof),.s_eol(eol),
 .m_valid(mv),.m_ready(1'b1),.m_data(md),.m_sof(ms),.m_eol(me),.m_eof(mf),.m_frame_id(mid),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_error(error),.out_width(ow),.out_height(oh),
 .stats_valid(stats_valid),.stats_ready(1'b1),.sum_r(red),.sum_g(green),.sum_b(blue),.pixel_count(pixels),.line_count(lines),
 .stats_frame_id(stats_id),.stats_overflow(stats_overflow),.stats_protocol_error(stats_error));
 integer fd,received=0,snapshots=0,tick=0,last_cmd=0,commands=0;
 reg [1023:0] path;
 always @(posedge clk)if(rst)begin
  tick=tick+1;
  if(cv&&cr)begin
   if(commands!=0&&tick-last_cmd!=1666667)$fatal(1,"ISP missed real-time command cadence %0d",tick-last_cmd);
   commands=commands+1;last_cmd=tick;
  end
  if(mv)begin received=received+1;$fwrite(fd,"%c%c%c%c",md,mid[7:0],mid[15:8],{5'd0,mf,me,ms});end
  if(stats_valid)begin
   if(stats_error||stats_overflow)$fatal(1,"real-time stats error");
   snapshots=snapshots+1;
   $display("REALTIME_STATS size=%0dx%0d id=%0d pixels=%0d lines=%0d r=%0d g=%0d b=%0d",width,height,stats_id,pixels,lines,red,green,blue);
  end
  if(rv&&rr&&(error!=0||ow!=width-4||oh!=height-4))$fatal(1,"real-time response");
 end
 task run_size(input integer w,input integer h,input integer n);
 begin
  @(negedge clk);width=w;height=h;frames=n;commands=0;received=0;snapshots=0;start=1;
  @(negedge clk);start=0;wait(done);@(negedge clk);
  if(source_error||misses||cs||completed!=n||received!=(w-4)*(h-4)*n||snapshots!=n)$fatal(1,"real-time totals or deadline failure");
  $display("REALTIME_PASS size=%0dx%0d frames=%0d output_pixels=%0d cycles=%0d pixel_stalls=%0d",w,h,n,received,cycles,ps);
 end endtask
 initial begin
  if(!$value$plusargs("output=%s",path))$fatal(1,"output missing");fd=$fopen(path,"wb");
  repeat(4)@(negedge clk);rst=1;
  run_size(320,240,3);run_size(640,480,2);
  $fclose(fd);$display("PASS real-time RAW-to-Sobel 50MHz/30fps simulation");$finish;
 end
 initial begin #400000000;$fatal(1,"timeout");end
endmodule
