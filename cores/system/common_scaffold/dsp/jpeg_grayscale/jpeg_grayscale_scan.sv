// Grayscale 8-bit block pixels -> baseline JPEG entropy scan bytes.
// File headers and raster/block reordering are separate modules.
module jpeg_grayscale_scan(
 input wire clk,rst_n,ce,
 input wire table_valid,output wire table_ready,input wire [5:0] table_index,
 input wire [7:0] table_value,
 input wire cfg_valid,output wire cfg_ready,output wire cfg_done,cfg_error,
 input wire start_valid,output wire start_ready,
 input wire [31:0] cfg_total_blocks,cfg_restart_interval,input wire abort,
 input wire [7:0] s_data,input wire s_valid,output wire s_ready,
 input wire s_block_first,s_block_last,s_frame_last,
 output wire [7:0] m_data,output wire m_valid,input wire m_ready,
 output wire m_marker,m_scan_last,
 output wire done_valid,input wire done_ready,output wire [7:0] error_code,
 output reg busy
);
 reg configured,failed,block_enabled,next_restart;
 reg [7:0] local_error;
 reg [5:0] pixel_index,coefficient_index;
 reg [31:0] total_blocks,restart_interval,input_blocks,entropy_blocks,since_restart;
 wire dready,dvalid,dsat,qready,qvalid,qsat,coeff_ready;
 wire signed [15:0] ddata,qdata;
 wire quant_cfg_ready,quant_table_ready;
 wire signed [15:0] shifted=$signed({1'b0,s_data})-16'sd128;
 wire pixel_enable=busy&&block_enabled&&!failed&&!abort;
 assign s_ready=pixel_enable&&dready;
 dct8x8_serial dct(.clk(clk),.rst_n(rst_n),.ce(ce),.cfg_valid(1'b0),.cfg_inverse(1'b0),
 .cfg_ready(),.cfg_done(),.s_data(shifted),.s_valid(s_valid&&pixel_enable),.s_ready(dready),
 .m_data(ddata),.m_valid(dvalid),.m_ready(qready),.busy(),.saturated(dsat));
 assign table_ready=quant_table_ready&&!busy&&!failed;
 assign cfg_ready=quant_cfg_ready&&!busy&&!failed;
 jpeg_quant_zigzag quant(.clk(clk),.rst_n(rst_n),.ce(ce),
 .table_valid(table_valid&&!busy&&!failed),.table_ready(quant_table_ready),
 .table_index(table_index),.table_value(table_value),
 .cfg_valid(cfg_valid&&!busy&&!failed),.cfg_inverse(1'b0),.cfg_ready(quant_cfg_ready),
 .cfg_done(cfg_done),.cfg_error(cfg_error),.s_data(ddata),.s_valid(dvalid&&!failed),.s_ready(qready),
 .m_data(qdata),.m_valid(qvalid),.m_ready(coeff_ready),.busy(),.saturated(qsat));
 wire token_valid,token_ready,token_dc,token_end,token_restart;
 wire [3:0] token_run,token_size,symbol_error,huffman_error;
 wire [15:0] token_amplitude;
 wire [1:0] token_component;
 jpeg_baseline_symbols symbols(.clk(clk),.rst(!rst_n),.ce(ce),.s_coefficient(qdata),
 .s_valid(qvalid&&!failed),.s_ready(coeff_ready),.s_first(coefficient_index==0),
 .s_last(coefficient_index==63),.s_component(2'd0),
 .s_restart(next_restart&&coefficient_index==0),
 .token_valid(token_valid),.token_ready(token_ready),.token_dc(token_dc),
 .token_run(token_run),.token_size(token_size),.token_amplitude(token_amplitude),
 .token_block_end(token_end),.token_restart(token_restart),.token_component(token_component),
 .error_code(symbol_error));
 wire hv,hr,hend;wire [15:0] hc,ha;wire [4:0] hcb,hab;
 jpeg_default_huffman huffman(.clk(clk),.rst_n(rst_n),.ce(ce),
 .s_valid(token_valid&&!failed),.s_ready(token_ready),.s_dc(token_dc),.s_run(token_run),
 .s_size(token_size),.s_amplitude(token_amplitude),.s_block_end(token_end),
 .s_restart(token_restart),.s_component(token_component),.m_valid(hv),.m_ready(hr),
 .m_code(hc),.m_code_bits(hcb),.m_amplitude(ha),.m_amplitude_bits(hab),
 .m_block_end(hend),.m_restart(),.m_component(),.error_code(huffman_error));
 wire scan_start_ready,predictor_reset_valid;
 wire [3:0] scan_error;
 wire pipeline_error=dsat||qsat||symbol_error!=0||huffman_error!=0;
 assign start_ready=rst_n&&ce&&configured&&!busy&&!failed&&quant_cfg_ready&&scan_start_ready&&
                    !cfg_valid&&!table_valid;
 assign error_code=local_error!=0?local_error:{4'b0,scan_error};
 jpeg_entropy_scan_controller scan(.clk(clk),.rst(!rst_n),.ce(ce),
 .start_valid(start_valid&&configured&&!busy&&!failed&&quant_cfg_ready&&!cfg_valid&&!table_valid),
 .start_ready(scan_start_ready),.cfg_total_blocks(cfg_total_blocks),
 .cfg_restart_interval(cfg_restart_interval),.abort(abort||failed||pipeline_error),
 .s_code(hc),.s_amplitude(ha),.s_code_bits(hcb),.s_amplitude_bits(hab),
 .s_block_end(hend),.s_scan_last(hend&&entropy_blocks==total_blocks-1),
 .s_valid(hv&&!failed),.s_ready(hr),.m_data(m_data),.m_valid(m_valid),.m_ready(m_ready),
 .m_marker(m_marker),.m_scan_last(m_scan_last),
 .predictor_reset_valid(predictor_reset_valid),.predictor_reset_ready(busy&&!failed),
 .scan_done(done_valid),.scan_done_ready(done_ready),.error_code(scan_error),.busy());
 always @(posedge clk) begin
  if(!rst_n) begin
   configured<=0;failed<=0;block_enabled<=0;next_restart<=0;local_error<=0;busy<=0;
   pixel_index<=0;coefficient_index<=0;total_blocks<=0;restart_interval<=0;
   input_blocks<=0;entropy_blocks<=0;since_restart<=0;
  end else if(ce) begin
   if(cfg_done) configured<=1;
   if(start_valid&&start_ready) begin
    busy<=1;block_enabled<=0;next_restart<=0;pixel_index<=0;coefficient_index<=0;
    total_blocks<=cfg_total_blocks;restart_interval<=cfg_restart_interval;
    input_blocks<=0;entropy_blocks<=0;since_restart<=0;local_error<=0;
   end
   if(busy&&predictor_reset_valid&&!failed) begin
    next_restart<=1;block_enabled<=1;since_restart<=0;
   end
   if(ce&&s_valid&&s_ready) begin
    if(s_block_first!=(pixel_index==0)||s_block_last!=(pixel_index==63)||
       s_frame_last!=(input_blocks==total_blocks-1&&pixel_index==63)) begin
     failed<=1;local_error<=8'h81;block_enabled<=0;
    end
    if(pixel_index==63) begin pixel_index<=0;input_blocks<=input_blocks+1'b1;block_enabled<=0;end
    else pixel_index<=pixel_index+1'b1;
   end
   if(qvalid&&coeff_ready&&!failed) begin
    coefficient_index<=coefficient_index+1'b1;
    if(coefficient_index==0) next_restart<=0;
   end
   if(hv&&hr&&!failed&&hend) begin
    entropy_blocks<=entropy_blocks+1'b1;since_restart<=since_restart+1'b1;
    if(entropy_blocks+1<total_blocks &&
       (restart_interval==0||since_restart+1<restart_interval)) block_enabled<=1;
   end
   if(busy&&!failed&&(abort||pipeline_error)) begin
    failed<=1;block_enabled<=0;
    if(abort) local_error<=8'h86;
    else if(dsat) local_error<=8'h82;
    else if(qsat) local_error<=8'h83;
    else if(symbol_error!=0) local_error<=8'h84;
    else local_error<=8'h85;
   end
   if(done_valid&&done_ready) begin busy<=0;block_enabled<=0;end
  end
 end
endmodule
