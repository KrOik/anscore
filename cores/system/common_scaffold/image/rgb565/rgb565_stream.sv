// Pixel-format conversion only; color transfer function is unchanged.
module rgb565_stream #(
 parameter PACK=1, SWAP_BYTES=0, ROUND_NEAREST=0
)(
 input wire clk,rst_n,ce,
 input wire [(PACK ? 24 : 16)-1:0] s_data,
 input wire s_valid,s_sof,s_eol,output wire s_ready,
 output reg [(PACK ? 16 : 24)-1:0] m_data,
 output reg m_valid,m_sof,m_eol,input wire m_ready
);
 wire slot=!m_valid||m_ready;
 assign s_ready=rst_n&&ce&&slot;
 wire [(PACK ? 16 : 24)-1:0] converted;
 generate if(PACK) begin: pack
  wire [8:0] r={1'b0,s_data[23:16]}+(ROUND_NEAREST ? 9'd4 : 9'd0);
  wire [8:0] g={1'b0,s_data[15:8]}+(ROUND_NEAREST ? 9'd2 : 9'd0);
  wire [8:0] b={1'b0,s_data[7:0]}+(ROUND_NEAREST ? 9'd4 : 9'd0);
  wire [4:0] r5=r>255 ? 5'd31:r[7:3];
  wire [5:0] g6=g>255 ? 6'd63:g[7:2];
  wire [4:0] b5=b>255 ? 5'd31:b[7:3];
  wire [15:0] pixel={r5,g6,b5};
  assign converted=SWAP_BYTES ? {pixel[7:0],pixel[15:8]}:pixel;
 end else begin: unpack
  wire [15:0] pixel=SWAP_BYTES ? {s_data[7:0],s_data[15:8]}:s_data;
  assign converted={pixel[15:11],pixel[15:13],pixel[10:5],pixel[10:9],pixel[4:0],pixel[4:2]};
 end endgenerate
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin m_valid<=0;m_data<=0;m_sof<=0;m_eol<=0;end
  else if(ce&&slot) begin
   m_valid<=s_valid;
   if(s_valid) begin m_data<=converted;m_sof<=s_sof;m_eol<=s_eol;end
  end
 end
 initial if((PACK!=0&&PACK!=1)||(SWAP_BYTES!=0&&SWAP_BYTES!=1)||
            (ROUND_NEAREST!=0&&ROUND_NEAREST!=1)) $fatal(1,"invalid RGB565 parameters");
endmodule
