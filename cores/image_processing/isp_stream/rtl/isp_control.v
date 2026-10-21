// Runtime CSR-controlled source/ISP with canonical coherent snapshot/probes.
module isp_control #(parameter RAW_BITS=10,MAX_WIDTH=640)(
 input wire clk,rst_n,req_valid,req_write,input wire [7:0] req_addr,
 input wire [31:0] req_data,input wire [3:0] req_strobe,
 output wire req_ready,resp_valid,resp_error,output wire [31:0] resp_data,input wire resp_ready,
 output wire [7:0] probe,output wire out_valid,input wire out_ready,output wire [7:0] out_data,
 output wire out_sof,out_eol,out_eof,output wire [15:0] out_frame_id
);
 reg busy,local_route,local_error,captured;reg [31:0] local_data;
 reg [1:0] probe_page;reg metric_page;
 wire local_address=req_addr>=8'hc0||(req_addr>=8'h0c&&req_addr<=8'h1c);
 wire accept=req_valid&&req_ready;
 wire cready,cvalid,cerror;wire [31:0] cdata,version;
 wire cfg_valid,cfg_ready,cfg_pending;wire [511:0] cfg;
 wire source_ready,source_done,source_error,cv,cr,sv,sr,sof,eol,eof,rv,rr;
 wire [15:0] cw,ch,frame_id;wire [RAW_BITS-1:0] raw;wire [3:0] error;
 wire [31:0] completed,misses,cmd_stalls,pixel_stalls,cycles;
 wire launch=cfg_valid&&cfg_ready;
 assign cfg_ready=source_ready&&cr;
 assign req_ready=rst_n&&!busy&&(local_address||cready);
 assign resp_valid=rst_n&&busy&&(local_route||cvalid);
 assign resp_error=local_route?local_error:cerror;
 assign resp_data=local_route?local_data:cdata;
 isp_config_registers #(.RAW_BITS(RAW_BITS),.MAX_WIDTH(MAX_WIDTH)) config_regs(
 .clk(clk),.rst_n(rst_n),.req_valid(req_valid&&!busy&&!local_address),.req_write(req_write),.req_addr(req_addr),
 .req_data(req_data),.req_strobe(req_strobe),.req_ready(cready),.resp_valid(cvalid),.resp_error(cerror),.resp_data(cdata),
 .resp_ready(busy&&!local_route&&resp_ready),.cfg_valid(cfg_valid),.cfg_ready(cfg_ready),.cfg_words(cfg),.cfg_version(version),.cfg_pending(cfg_pending));
 virtual_raw_source #(.RAW_BITS(RAW_BITS)) source(
 .clk(clk),.rst_n(rst_n),.start(launch),.start_ready(source_ready),.width(cfg[15:0]),.height(cfg[31:16]),
 .frame_count(cfg[63:32]),.period_cycles(cfg[95:64]),.seed(cfg[96+:RAW_BITS]),
 .cmd_valid(cv),.cmd_ready(cr),.cmd_width(cw),.cmd_height(ch),.cmd_frame_id(frame_id),
 .m_valid(sv),.m_ready(sr),.m_data(raw),.m_sof(sof),.m_eol(eol),.m_eof(eof),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_error(error),.done(source_done),.error(source_error),
 .completed_frames(completed),.deadline_misses(misses),.command_stalls(cmd_stalls),.pixel_stalls(pixel_stalls),.run_cycles(cycles));
 wire lut_ready;
 wire lut_fields=(req_data&32'hfc00ff00)==0&&req_data[25:24]<3;
 wire can_lut=source_ready&&!cfg_pending&&lut_ready;
 wire lut_write=accept&&req_write&&req_addr==8'h10&&req_strobe==15&&lut_fields&&can_lut;
 wire stats_valid,stats_overflow,stats_error;wire [47:0] sum_r,sum_g,sum_b;
 wire [31:0] stat_pixels,stat_lines;wire [15:0] stat_id;
 wire [4*RAW_BITS-1:0] levels;
 wire [47:0] selected_gains;wire [191:0] selected_matrix;
 wire blc_bypass,gamma_enable,sobel_bypass,bayer_bypass;wire [1:0] bayer_pattern;
 isp_mode_config modes(cfg,selected_gains,selected_matrix,blc_bypass,gamma_enable,sobel_bypass,bayer_bypass,bayer_pattern);
 genvar plane;
 generate for(plane=0;plane<4;plane=plane+1)begin:unpack_levels
  assign levels[plane*RAW_BITS+:RAW_BITS]=cfg[192+plane*16+:RAW_BITS];
 end endgenerate
 isp_sobel_pipeline #(.RAW_BITS(RAW_BITS),.MAX_WIDTH(MAX_WIDTH)) pipeline(
 .clk(clk),.rst_n(rst_n),.cmd_valid(cv),.cmd_ready(cr),.cmd_width(cw),.cmd_height(ch),.cmd_frame_id(frame_id),
 .cmd_pattern(bayer_pattern),.cmd_levels(levels),.cmd_target(cfg[160+:RAW_BITS]),.cmd_blc_bypass(blc_bypass),.cmd_bayer_bypass(bayer_bypass),
 .cmd_gains(selected_gains),.cmd_matrix(selected_matrix),.cmd_gamma_enable(gamma_enable),.cmd_sobel_bypass(sobel_bypass),
 .lut_valid(lut_write),.lut_ready(lut_ready),.lut_channel(req_data[25:24]),.lut_address(req_data[23:16]),.lut_value(req_data[7:0]),
 .s_valid(sv),.s_ready(sr),.s_data(raw),.s_sof(sof),.s_eol(eol),
 .m_valid(out_valid),.m_ready(out_ready),.m_data(out_data),.m_sof(out_sof),.m_eol(out_eol),.m_eof(out_eof),.m_frame_id(out_frame_id),
 .rsp_valid(rv),.rsp_ready(rr),.rsp_error(error),.out_width(),.out_height(),
 .stats_valid(stats_valid),.stats_ready(1'b1),.sum_r(sum_r),.sum_g(sum_g),.sum_b(sum_b),
 .pixel_count(stat_pixels),.line_count(stat_lines),.stats_frame_id(stat_id),.stats_overflow(stats_overflow),.stats_protocol_error(stats_error));
 wire [31:0] out_bytes,out_frames,out_stalls,last_cycles,crc,last_crc;
 frame_stream_monitor monitor(.clk(clk),.rst_n(rst_n&&!launch),.valid(out_valid),.ready(out_ready),
 .data({24'd0,out_data}),.keep(4'b0001),.last(out_eof),.bytes(out_bytes),.frames(out_frames),
 .stall_cycles(out_stalls),.last_frame_cycles(last_cycles),.crc32(crc),.last_frame_crc32(last_crc));
 reg [47:0] last_r,last_g,last_b;reg [31:0] last_pixels,last_lines;reg [15:0] last_id;reg last_overflow,last_error;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin last_r<=0;last_g<=0;last_b<=0;last_pixels<=0;last_lines<=0;last_id<=0;last_overflow<=0;last_error<=0;end
  else if(launch)begin last_r<=0;last_g<=0;last_b<=0;last_pixels<=0;last_lines<=0;last_id<=0;last_overflow<=0;last_error<=0;end
  else if(stats_valid)begin last_r<=sum_r;last_g<=sum_g;last_b<=sum_b;last_pixels<=stat_pixels;last_lines<=stat_lines;last_id<=stat_id;last_overflow<=stats_overflow;last_error<=stats_error;end
 end
 wire [1023:0] live,snapshot;
 assign live={288'd0,{24'd0,cfg[135:128]}, {16'd0,frame_id},version,
  {16'd0,last_b[47:32]},last_b[31:0],{16'd0,last_g[47:32]},last_g[31:0],{16'd0,last_r[47:32]},last_r[31:0],
  last_lines,last_pixels,{14'd0,last_error,last_overflow,last_id},last_cycles,last_crc,crc,out_frames,out_bytes,
  cycles,pixel_stalls,cmd_stalls,misses,completed,{28'd0,cfg_pending,source_error,source_done,source_ready}};
 wire [63:0] timestamp;wire [31:0] snapshot_id;wire snap_ready;
 wire capture=accept&&req_write&&req_addr==8'h0c&&req_strobe==15&&req_data==1;
 sys_register_snapshot #(.WORDS(32)) metrics(.clk(clk),.rst_n(rst_n),.live(live),.s_valid(capture),.s_ready(snap_ready),
 .m_ready(1'b1),.m_valid(),.snapshot(snapshot),.timestamp(timestamp),.snapshot_id(snapshot_id));
 logic_probe8 probes(.clk(clk),.rst_n(rst_n),.probe_page({1'b0,probe_page}),
 .stream_signals({rv,rr,out_eof,out_eol,out_sof,out_ready,out_valid,sv&&sr}),
 .serial_signals(raw[7:0]),.motor_signals(out_data),
 .data_signals({2'd0,cfg_pending,cfg_valid,source_error,source_done,source_ready,cv&&cr}),.probe(probe));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin busy<=0;local_route<=0;local_error<=0;local_data<=0;probe_page<=0;metric_page<=0;captured<=0;end
  else begin
   if(resp_valid&&resp_ready)busy<=0;
   if(capture)captured<=1;
   if(accept)begin
    busy<=1;local_route<=local_address;local_error<=0;local_data<=0;
    if(local_address)begin
     if(req_addr[1:0]!=0)local_error<=1;
     else if(req_write)begin
      if(req_strobe!=15)local_error<=1;
      else case(req_addr)
       8'h0c:if(req_data!=1||!snap_ready)local_error<=1;
       8'h10:if(!lut_fields||!can_lut)local_error<=1;
       8'h1c:if((req_data&32'hfffffefc)==0)begin probe_page<=req_data[1:0];metric_page<=req_data[8];end else local_error<=1;
       default:local_error<=1;
      endcase
     end else if(req_addr>=8'hc0)begin
      if(captured)local_data<=snapshot[({metric_page,req_addr[5:2]})*32+:32];else local_error<=1;
     end else case(req_addr)
      8'h0c:local_data<={31'd0,captured};
      8'h10:local_data<=timestamp[31:0];
      8'h14:local_data<=timestamp[63:32];
      8'h18:local_data<=snapshot_id;
      8'h1c:local_data<={23'd0,metric_page,6'd0,probe_page};
      default:local_error<=1;
     endcase
    end
   end
  end
 end
endmodule
