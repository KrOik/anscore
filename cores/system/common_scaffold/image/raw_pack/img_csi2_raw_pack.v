// Native pixel -> CSI-2 RAW payload bytes. No packet headers, ECC, CRC or PHY.
`timescale 1ns/1ps
module img_csi2_raw_pack #(
 parameter integer RAW_BITS=10
)(
 input wire clk,rst_n,clk_en,
 input wire [RAW_BITS-1:0] s_data,
 input wire s_valid,output wire s_ready,
 input wire s_sof,s_eol,
 output wire [7:0] m_data,
 output wire m_valid,input wire m_ready,
 output wire m_sof,m_eol,
 output reg protocol_error,error_pulse,
 output reg [1:0] error_code
);
 localparam integer PIXELS=RAW_BITS==10 ? 4:2;
 localparam integer LAST_BYTE=RAW_BITS==10 ? 4:2;
 reg [RAW_BITS-1:0] pixel0,pixel1,pixel2,pixel3;
 reg [1:0] pixel_index;
 reg [2:0] byte_index;
 reg emitting,group_sof,group_eol;
 wire parameter_ok=RAW_BITS==10 || RAW_BITS==12;
 assign s_ready=rst_n && clk_en && parameter_ok && !emitting;
 assign m_valid=emitting;
 assign m_sof=emitting && group_sof && byte_index==0;
 assign m_eol=emitting && group_eol && byte_index==LAST_BYTE;
 generate if(RAW_BITS==10) begin: raw10
  assign m_data=byte_index==0 ? pixel0[9:2] : byte_index==1 ? pixel1[9:2] :
                byte_index==2 ? pixel2[9:2] : byte_index==3 ? pixel3[9:2] :
                {pixel3[1:0],pixel2[1:0],pixel1[1:0],pixel0[1:0]};
 end else if(RAW_BITS==12) begin: raw12
  assign m_data=byte_index==0 ? pixel0[11:4] : byte_index==1 ? pixel1[11:4] :
                {pixel1[3:0],pixel0[3:0]};
 end else begin: unsupported
  assign m_data=8'b0;
 end endgenerate
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   pixel0<=0;pixel1<=0;pixel2<=0;pixel3<=0;pixel_index<=0;byte_index<=0;
   emitting<=0;group_sof<=0;group_eol<=0;protocol_error<=0;error_pulse<=0;error_code<=0;
  end else if(clk_en) begin
   error_pulse<=0;
   if(!parameter_ok) begin protocol_error<=1;error_pulse<=!protocol_error;error_code<=3;end
   if(emitting && m_ready) begin
    if(byte_index==LAST_BYTE) begin emitting<=0;byte_index<=0;end
    else byte_index<=byte_index+1'b1;
   end
   if(s_valid && s_ready) begin
    if(s_eol && (pixel_index!=PIXELS-1 || s_sof)) begin
     pixel_index<=0;group_sof<=0;protocol_error<=1;error_pulse<=1;error_code<=1;
    end else if(s_sof && pixel_index!=0) begin
     pixel0<=s_data;pixel_index<=1;group_sof<=1;
     protocol_error<=1;error_pulse<=1;error_code<=2;
    end else begin
     case(pixel_index)
      0:begin pixel0<=s_data;group_sof<=s_sof;end
      1:pixel1<=s_data;
      2:pixel2<=s_data;
      3:pixel3<=s_data;
     endcase
     if(pixel_index==PIXELS-1) begin
      pixel_index<=0;emitting<=1;byte_index<=0;group_eol<=s_eol;
     end else pixel_index<=pixel_index+1'b1;
    end
   end
  end
 end
endmodule
