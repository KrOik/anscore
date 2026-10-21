// Frame-buffered independent red/blue radial inverse maps; green is unchanged.
module chromatic_aberration_frame #(
 parameter WIDTH=7,HEIGHT=5,BITS=8
)(
 input wire clk,rst_n,ce,
 input wire cfg_valid,output wire cfg_ready,
 // Low to high signed32 fields: fx,fy,cx,cy,invfx,invfy,k1,k2,k3.
 input wire [287:0] cfg_red,cfg_blue,
 input wire [3*BITS-1:0] cfg_border,
 output reg cfg_done,cfg_error,output reg [3:0] error_code,
 input wire start_valid,output wire start_ready,
 input wire [3*BITS-1:0] s_rgb,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output reg [3*BITS-1:0] m_rgb,output wire m_valid,input wire m_ready,
 output reg [1:0] m_oob,m_overflow,
 output reg m_sof,m_eol,m_last,
 output wire done_valid,input wire done_ready,output wire done_error,output wire busy
);
 localparam N=WIDTH*HEIGHT,AW=(N<2?1:$clog2(N));
 localparam IDLE=0,CAPTURE=1,CFG_R=2,START_R=3,RUN_R=4,CFG_B=5,START_B=6,RUN_B=7,READ_B=8,OUT_B=9,DONE=10,PUBLISH=11;
 reg [3:0] state;
 reg configured,frame_error;
 reg [287:0] red,blue;
 reg [3*BITS-1:0] border_rgb;
 reg [AW-1:0] input_index,output_index;
 reg [15:0] input_x,input_y,output_x,output_y;
 reg [3*BITS-1:0] frame_mem[0:N-1];
 reg [BITS+1:0] red_mem[0:N-1];
 reg [BITS+1:0] red_read;
 reg [3*BITS-1:0] frame_read;
 reg [BITS-1:0] blue_pixel;
 reg blue_oob,blue_overflow;
 wire blue_phase=state>=CFG_B;
 wire [287:0] calibration=blue_phase?blue:red;
 wire map_cfg_ready,map_cfg_done,map_cfg_error,map_start_ready,map_valid,map_ready;
 wire signed [31:0] src_x,src_y;
 wire map_oob,map_overflow,map_sof,map_eol,map_last,map_done;
 wire [15:0] map_x,map_y;
 wire [3:0] map_error;
 function valid_calibration;
 input [287:0] c;
 reg signed [31:0] fx,fy,cx,cy,ix,iy;
 begin
  fx=c[0+:32];fy=c[32+:32];cx=c[64+:32];cy=c[96+:32];ix=c[128+:32];iy=c[160+:32];
  valid_calibration=fx>=65536&&fy>=65536&&fx<=536870912&&fy<=536870912&&cx>=-536870912&&cx<=536870912&&cy>=-536870912&&cy<=536870912&&ix>0&&iy>0&&ix<=1073741824&&iy<=1073741824;
 end endfunction
 assign cfg_ready=rst_n&&ce&&state==IDLE;
 assign start_ready=cfg_ready&&!cfg_valid;
 assign s_ready=rst_n&&ce&&state==CAPTURE;
 assign m_valid=rst_n&&state==OUT_B;
 assign done_valid=rst_n&&state==DONE;
 assign done_error=frame_error;
 assign busy=state!=IDLE;
 lens_distortion_map #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) mapper(
 .clk(clk),.rst_n(rst_n),.ce(ce),.cfg_valid(state==CFG_R||state==CFG_B),.cfg_ready(map_cfg_ready),
 .cfg_fx(calibration[0+:32]),.cfg_fy(calibration[32+:32]),.cfg_cx(calibration[64+:32]),.cfg_cy(calibration[96+:32]),
 .cfg_invfx(calibration[128+:32]),.cfg_invfy(calibration[160+:32]),.cfg_k1(calibration[192+:32]),.cfg_k2(calibration[224+:32]),.cfg_k3(calibration[256+:32]),.cfg_p1(32'sd0),.cfg_p2(32'sd0),
 .cfg_done(map_cfg_done),.cfg_error(map_cfg_error),.error_code(map_error),
 .start_valid(state==START_R||state==START_B),.start_ready(map_start_ready),
 .m_src_x(src_x),.m_src_y(src_y),.m_x(map_x),.m_y(map_y),.m_oob(map_oob),.m_overflow(map_overflow),
 .m_valid(map_valid),.m_ready(map_ready),.m_sof(map_sof),.m_eol(map_eol),.m_last(map_last),
 .done_valid(map_done),.done_ready(1'b1),.busy());
 wire sample_valid,sample_ready;
 wire [BITS-1:0] sample_pixel;
 wire [3:0] sample_error;
 wire sample_sof,sample_eol,sample_last;
 wire mem_req,mem_ready,mem_rsp_ready;
 wire [31:0] mem_addr;
 reg mem_rsp_valid;
 reg [BITS-1:0] mem_data;
 reg coord_oob,coord_overflow;
 assign mem_ready=!mem_rsp_valid;
 assign sample_ready=state==RUN_R||state==RUN_B;
 img_geo_frame_sampler #(.PIXEL_W(BITS),.LANES(1),.BORDER_DATA(0)) sampler(
 .clk(clk),.rst_n(rst_n),.clk_en(ce),.s_valid(map_valid),.s_ready(map_ready),
 .s_x_q8(src_x[31:8]),.s_y_q8(src_y[31:8]),.s_border(map_oob||map_overflow),.s_error(4'd0),
 .s_sof(map_sof),.s_eol(map_eol),.s_eof(map_last),.s_filter(2'd1),
 .s_src_width(16'(WIDTH)),.s_src_height(16'(HEIGHT)),.s_stride(32'(WIDTH)),.s_base_addr(32'd0),
 .mem_req_valid(mem_req),.mem_req_ready(mem_ready),.mem_req_read(),.mem_req_addr(mem_addr),
 .mem_rsp_valid(mem_rsp_valid),.mem_rsp_ready(mem_rsp_ready),.mem_rsp_data(mem_data),.mem_rsp_error(1'b0),
 .m_valid(sample_valid),.m_ready(sample_ready),.m_data(sample_pixel),.m_error(sample_error),.m_sof(sample_sof),.m_eol(sample_eol),.m_eof(sample_last));
 initial if(WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||N>65536||BITS<8||BITS>12)$fatal(1,"invalid chromatic aberration parameters");
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;configured<=0;frame_error<=0;red<=0;blue<=0;border_rgb<=0;
   input_index<=0;output_index<=0;input_x<=0;input_y<=0;output_x<=0;output_y<=0;
   cfg_done<=0;cfg_error<=0;error_code<=0;mem_rsp_valid<=0;mem_data<=0;
   coord_oob<=0;coord_overflow<=0;red_read<=0;frame_read<=0;blue_pixel<=0;blue_oob<=0;blue_overflow<=0;
   m_rgb<=0;m_oob<=0;m_overflow<=0;m_sof<=0;m_eol<=0;m_last<=0;
  end else if(ce)begin
   cfg_done<=0;cfg_error<=0;
   if(mem_rsp_valid&&mem_rsp_ready)mem_rsp_valid<=0;
   if(mem_req&&mem_ready)begin
    if(blue_phase)mem_data<=frame_mem[mem_addr][0+:BITS];else mem_data<=frame_mem[mem_addr][2*BITS+:BITS];
    mem_rsp_valid<=1;
   end
   if(map_valid&&map_ready)begin coord_oob<=map_oob;coord_overflow<=map_overflow;end
   case(state)
    IDLE:begin
     if(cfg_valid)begin
      cfg_done<=1;
      if(valid_calibration(cfg_red)&&valid_calibration(cfg_blue))begin red<=cfg_red;blue<=cfg_blue;border_rgb<=cfg_border;configured<=1;error_code<=0;end
      else begin cfg_error<=1;error_code<=2;end
     end else if(start_valid)begin
      if(!configured)error_code<=1;
      else begin state<=CAPTURE;input_index<=0;input_x<=0;input_y<=0;output_index<=0;output_x<=0;output_y<=0;frame_error<=0;end
     end
    end
    CAPTURE:if(s_valid)begin
     frame_mem[input_index]<=s_rgb;
     if(s_sof!=(input_index==0)||s_eol!=(input_x==WIDTH-1))frame_error<=1;
     if(input_index==N-1)state<=CFG_R;
     else begin input_index<=input_index+1'b1;if(input_x==WIDTH-1)begin input_x<=0;input_y<=input_y+1'b1;end else input_x<=input_x+1'b1;end
    end
    CFG_R:if(map_cfg_ready)state<=START_R;
    START_R:if(map_start_ready)state<=RUN_R;
    RUN_R:if(sample_valid)begin
     red_mem[output_index]<={coord_overflow,coord_oob,(coord_oob||coord_overflow?border_rgb[2*BITS+:BITS]:sample_pixel)};
     if(sample_error!=0)frame_error<=1;
     if(sample_last)begin state<=CFG_B;output_index<=0;end else output_index<=output_index+1'b1;
    end
    CFG_B:if(map_cfg_ready)state<=START_B;
    START_B:if(map_start_ready)state<=RUN_B;
    RUN_B:if(sample_valid)begin
     blue_pixel<=coord_oob||coord_overflow?border_rgb[0+:BITS]:sample_pixel;
     blue_oob<=coord_oob;blue_overflow<=coord_overflow;
     if(sample_error!=0)frame_error<=1;
     state<=READ_B;
    end
    READ_B:begin red_read<=red_mem[output_index];frame_read<=frame_mem[output_index];state<=PUBLISH;end
    PUBLISH:begin
     m_rgb<={red_read[BITS-1:0],frame_read[BITS+:BITS],blue_pixel};
     m_oob<={blue_oob,red_read[BITS]};m_overflow<={blue_overflow,red_read[BITS+1]};
     m_sof<=output_index==0;m_eol<=output_x==WIDTH-1;m_last<=output_index==N-1;state<=OUT_B;
    end
    OUT_B:begin
     if(m_ready)begin
      if(output_index==N-1)state<=DONE;
      else begin output_index<=output_index+1'b1;if(output_x==WIDTH-1)begin output_x<=0;output_y<=output_y+1'b1;end else output_x<=output_x+1'b1;state<=RUN_B;end
     end
    end
    DONE:if(done_ready)state<=IDLE;
    default:begin state<=IDLE;configured<=0;frame_error<=1;error_code<=3;end
   endcase
  end
 end
endmodule
