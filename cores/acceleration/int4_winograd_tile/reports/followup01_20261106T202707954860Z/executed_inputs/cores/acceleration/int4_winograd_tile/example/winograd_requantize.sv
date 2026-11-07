// SPDX-License-Identifier: Apache-2.0
// Actual composition with the unchanged production stream_requantize core.
module winograd_requantize #(
 parameter integer MAX_ROWS=8,TAG_W=16
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire [1:0] c_op,
 input wire [15:0] c_row,input wire [3:0] c_tap,
 input wire signed [3:0] c_weight,input wire signed [31:0] c_bias,
 input wire [15:0] c_scale,input wire [5:0] c_shift,input wire signed [7:0] c_zero,
 output wire c_rsp_valid,input wire c_rsp_ready,output wire [1:0] c_error,
 input wire cmd_valid,output wire cmd_ready,input wire [15:0] cmd_rows,
 input wire [7:0] cmd_x_zero,input wire [TAG_W-1:0] cmd_tag,
 input wire s_valid,output wire s_ready,input wire [7:0] s_data,input wire s_last,
 output wire m_valid,input wire m_ready,output wire signed [7:0] m_data,
 output wire [15:0] m_row,output wire [1:0] m_pixel,
 output wire [TAG_W-1:0] m_tag,output wire m_last,m_clip,m_inexact,
 output wire rsp_valid,input wire rsp_ready,output wire [1:0] rsp_error,
 output wire [8:0] rsp_outputs,output wire [TAG_W-1:0] rsp_tag,output wire busy
);
 localparam QT=TAG_W+27;
 wire raw_valid,raw_ready,raw_last,raw_rsp_valid;
 wire signed [32:0] raw_acc;
 wire [15:0] raw_row,raw_scale;
 wire [1:0] raw_pixel;
 wire [4:0] raw_shift;
 wire signed [7:0] raw_zero;
 wire [TAG_W-1:0] raw_tag;
 reg scaled_valid;
 reg signed [49:0] scaled;
 reg [4:0] shift;
 reg [QT-1:0] scaled_tag;
 wire quant_ready,quant_valid,quant_clip,quant_inexact;
 wire [15:0] quant_data;
 wire [QT-1:0] quant_tag;
 reg [2:0] outstanding;
 wire scale_ready=!scaled_valid || quant_ready;
 wire signed [16:0] positive_scale=$signed({1'b0,raw_scale});
 wire signed [49:0] scale_product=raw_acc*positive_scale;
 wire signed [7:0] output_zero=$signed(quant_tag[7:0]);
 wire signed [16:0] shifted_zero_sum=$signed({quant_data[15],quant_data})+
                                  $signed({{9{output_zero[7]}},output_zero});
 assign raw_ready=!rst && scale_ready;
 // Keep the core response/configuration lock until all public outputs retire.
 assign rsp_valid=raw_rsp_valid && outstanding==0;
 assign m_valid=quant_valid;
 assign m_data=shifted_zero_sum>17'sd127 ? 8'sd127 :
               shifted_zero_sum< -17'sd128 ? -8'sd128 : shifted_zero_sum[7:0];
 assign m_clip=quant_clip || shifted_zero_sum>17'sd127 || shifted_zero_sum< -17'sd128;
 assign m_inexact=quant_inexact;
 assign {m_tag,m_row,m_pixel,m_last}=quant_tag[QT-1:8];
 int4_winograd_tile #(.MAX_ROWS(MAX_ROWS),.TAG_W(TAG_W)) tile(
  .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_op(c_op),
  .c_row(c_row),.c_tap(c_tap),.c_weight(c_weight),.c_bias(c_bias),
  .c_scale(c_scale),.c_shift(c_shift),.c_zero(c_zero),
  .c_rsp_valid(c_rsp_valid),.c_rsp_ready(c_rsp_ready),.c_error(c_error),
  .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_rows(cmd_rows),
  .cmd_x_zero(cmd_x_zero),.cmd_tag(cmd_tag),.s_valid(s_valid),.s_ready(s_ready),
  .s_data(s_data),.s_last(s_last),.m_valid(raw_valid),.m_ready(raw_ready),
  .m_acc(raw_acc),.m_row(raw_row),.m_pixel(raw_pixel),.m_scale(raw_scale),
  .m_shift(raw_shift),.m_zero(raw_zero),.m_tag(raw_tag),.m_last(raw_last),
  .rsp_valid(raw_rsp_valid),.rsp_ready(rsp_ready && outstanding==0),
  .rsp_error(rsp_error),.rsp_outputs(rsp_outputs),.rsp_tag(rsp_tag),.busy(busy)
 );
 // OUT_W=16 preserves all signed8 zero-offset decisions after rounding.
 // An intermediate signed16 clip implies final signed8 clip for any S8 zero.
 stream_requantize #(.IN_W(50),.OUT_W(16),.TAG_W(QT)) quantizer(
  .clk(clk),.rst(rst),.s_valid(scaled_valid),.s_ready(quant_ready),
  .s_data(scaled),.s_shift({1'b0,shift}),.s_tag(scaled_tag),
  .m_valid(quant_valid),.m_ready(m_ready),.m_data(quant_data),
  .m_clip(quant_clip),.m_inexact(quant_inexact),.m_tag(quant_tag)
 );
 always @(posedge clk) begin
  if(rst) begin scaled_valid<=0;outstanding<=0;end
  else begin
   if(scale_ready) begin
    scaled_valid<=raw_valid;
    if(raw_valid) begin
     scaled<=scale_product;shift<=raw_shift;
     scaled_tag<={raw_tag,raw_row,raw_pixel,raw_last,raw_zero};
    end
   end
   case({raw_valid && raw_ready,quant_valid && m_ready})
    2'b10:outstanding<=outstanding+3'd1;
    2'b01:outstanding<=outstanding-3'd1;
    default:outstanding<=outstanding;
   endcase
  end
 end
endmodule
