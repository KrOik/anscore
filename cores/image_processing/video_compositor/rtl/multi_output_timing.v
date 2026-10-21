// Independent logical display timing; one clock domain, per-output pixel ticks.
module multi_output_timing #(parameter OUTPUTS=3)(
 input wire clk,rst_n,
 input wire [OUTPUTS-1:0] pixel_tick,start_valid,stop,abort,done_ready,
 output wire [OUTPUTS-1:0] start_ready,running,done_valid,frame_error,
 input wire [OUTPUTS*16-1:0] h_active,h_front,h_sync,h_back,
 input wire [OUTPUTS*16-1:0] v_active,v_front,v_sync,v_back,
 input wire [OUTPUTS-1:0] h_positive,v_positive,
 output wire [OUTPUTS*8-1:0] error_code,
 output wire [OUTPUTS*16-1:0] x,y,
 output wire [OUTPUTS-1:0] hsync,vsync,de,sof,eol,eof,frame_end,
 output wire [OUTPUTS*32-1:0] frame_count,
 output wire [OUTPUTS*64-1:0] active_pixel_count,total_tick_count
);
genvar g;
generate for(g=0;g<OUTPUTS;g=g+1)begin: outputs_timing
 reg [31:0] frames;
 reg [63:0] pixels,ticks;
 assign frame_count[g*32+:32]=frames;
 assign active_pixel_count[g*64+:64]=pixels;
 assign total_tick_count[g*64+:64]=ticks;
 video_timing_generator timer(
  .clk(clk),.rst_n(rst_n),.ce(1'b1),.pixel_tick(pixel_tick[g]),
  .start_valid(start_valid[g]),.start_ready(start_ready[g]),
  .stop(stop[g]),.abort(abort[g]),.done_ready(done_ready[g]),
  .cfg_h_active(h_active[g*16+:16]),.cfg_h_front(h_front[g*16+:16]),
  .cfg_h_sync(h_sync[g*16+:16]),.cfg_h_back(h_back[g*16+:16]),
  .cfg_v_active(v_active[g*16+:16]),.cfg_v_front(v_front[g*16+:16]),
  .cfg_v_sync(v_sync[g*16+:16]),.cfg_v_back(v_back[g*16+:16]),
  .cfg_hsync_positive(h_positive[g]),.cfg_vsync_positive(v_positive[g]),
  .running(running[g]),.done_valid(done_valid[g]),.frame_error(frame_error[g]),
  .error_code(error_code[g*8+:8]),.h_count(x[g*16+:16]),.v_count(y[g*16+:16]),
  .hsync(hsync[g]),.vsync(vsync[g]),.de(de[g]),.sof(sof[g]),
  .eol(eol[g]),.eof(eof[g]),.frame_end(frame_end[g]));
 always @(posedge clk)begin
  if(!rst_n)begin frames<=0;pixels<=0;ticks<=0;end
  else if(start_valid[g]&&start_ready[g])begin frames<=0;pixels<=0;ticks<=0;end
  else if(running[g]&&pixel_tick[g])begin
   ticks<=ticks+1;
   if(de[g])pixels<=pixels+1;
   if(frame_end[g])frames<=frames+1;
  end
 end
end endgenerate
endmodule
