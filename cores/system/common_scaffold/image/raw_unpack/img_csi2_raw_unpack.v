// CSI-2 payload byte unpacker only: no D-PHY, packet parsing or ECC/CRC.
`timescale 1ns/1ps
module img_csi2_raw_unpack #(
 parameter integer RAW_BITS = 10
)(
 input wire clk, rst_n, clk_en,
 input wire [7:0] s_data,
 input wire s_valid, output wire s_ready,
 input wire s_sof, s_eol,
 output wire [RAW_BITS-1:0] m_data,
 output wire m_valid, input wire m_ready,
 output wire m_sof, m_eol,
 output reg protocol_error, error_pulse,
 output reg [1:0] error_code
);
 localparam integer PIXELS = RAW_BITS == 10 ? 4 : 2;
 localparam integer LAST_BYTE = RAW_BITS == 10 ? 4 : 2;
 reg [2:0] byte_index;
 reg [1:0] pixel_index;
 reg [7:0] high0, high1, high2, high3, lowbits;
 reg emitting, group_sof, group_eol;
 wire parameter_ok = RAW_BITS == 10 || RAW_BITS == 12;
 assign s_ready = rst_n && clk_en && parameter_ok && !emitting;
 assign m_valid = emitting;
 assign m_sof = emitting && group_sof && pixel_index==0;
 assign m_eol = emitting && group_eol && pixel_index==PIXELS-1;
 generate if(RAW_BITS==10) begin: raw10
  assign m_data = pixel_index==0 ? {high0,lowbits[1:0]} :
                  pixel_index==1 ? {high1,lowbits[3:2]} :
                  pixel_index==2 ? {high2,lowbits[5:4]} : {high3,lowbits[7:6]};
 end else if(RAW_BITS==12) begin: raw12
  assign m_data = pixel_index==0 ? {high0,lowbits[3:0]} : {high1,lowbits[7:4]};
 end else begin: unsupported
  assign m_data = {RAW_BITS{1'b0}};
 end endgenerate
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   byte_index<=0;pixel_index<=0;emitting<=0;group_sof<=0;group_eol<=0;
   high0<=0;high1<=0;high2<=0;high3<=0;lowbits<=0;
   protocol_error<=0;error_pulse<=0;error_code<=0;
  end else if(clk_en) begin
   error_pulse<=0;
   if(!parameter_ok) begin
    protocol_error<=1;error_pulse<=!protocol_error;error_code<=3;
   end
   if(emitting && m_ready) begin
    if(pixel_index==PIXELS-1) begin emitting<=0;pixel_index<=0; end
    else pixel_index<=pixel_index+1'b1;
   end
   if(s_valid && s_ready) begin
    // EOL is legal only on the packed group's final LSB byte.
    // An unexpected SOF starts a fresh group with this same accepted byte.
    if(s_eol && (byte_index!=LAST_BYTE || s_sof)) begin
     byte_index<=0;group_sof<=0;protocol_error<=1;error_pulse<=1;error_code<=1;
    end else if(s_sof && byte_index!=0) begin
     byte_index<=1;high0<=s_data;group_sof<=1;
     protocol_error<=1;error_pulse<=1;error_code<=2;
    end else if(byte_index==LAST_BYTE) begin
     lowbits<=s_data;group_eol<=s_eol;emitting<=1;pixel_index<=0;byte_index<=0;
    end else begin
     case(byte_index)
      0:begin high0<=s_data;group_sof<=s_sof; end
      1:high1<=s_data;
      2:high2<=s_data;
      3:high3<=s_data;
     endcase
     byte_index<=byte_index+1'b1;
    end
   end
  end
 end
endmodule
