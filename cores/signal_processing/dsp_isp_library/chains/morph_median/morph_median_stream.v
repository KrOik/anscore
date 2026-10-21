// Delivery bundle: programmable morphology feeding a 3x3 median stage.
//
// Both leaves are verified individually on the 25K dock (isp CORE=3 morphology,
// isp CORE=0 median); this module is the composed deliverable, so the frame's
// binary shapes are cleaned of speckle after the structuring element runs.  The
// median stage adds no runtime configuration, so the whole control surface stays
// morphology's: op/binary/mask, committed before SOF.
module morph_median_stream #(parameter BITS=8,WIDTH=8,HEIGHT=8,K=3,PAD_MODE=1)(
 input wire clk,rst_n,
 input wire [BITS-1:0] s_tdata,
 input wire s_tvalid,s_tuser,s_tlast,output wire s_tready,
 output wire [BITS-1:0] m_tdata,
 output wire m_tvalid,m_tuser,m_tlast,input wire m_tready,
 input wire cfg_valid,output wire cfg_ready,
 input wire [1:0] cfg_op,input wire cfg_binary,input wire [K*K-1:0] cfg_mask,
 output wire cfg_done,cfg_error,output wire marker_error,output wire busy
);
 wire [BITS-1:0] shape_data;
 wire shape_valid,shape_user,shape_last,shape_ready;
 wire shape_marker,median_marker;
 morphology_stream #(.BITS(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT),.K(K),.PAD_MODE(PAD_MODE)) shape(
   .clk(clk),.rst_n(rst_n),
   .s_tdata(s_tdata),.s_tvalid(s_tvalid),.s_tuser(s_tuser),.s_tlast(s_tlast),.s_tready(s_tready),
   .m_tdata(shape_data),.m_tvalid(shape_valid),.m_tuser(shape_user),.m_tlast(shape_last),
   .m_tready(shape_ready),
   .cfg_valid(cfg_valid),.cfg_ready(cfg_ready),
   .cfg_op(cfg_op),.cfg_binary(cfg_binary),.cfg_mask(cfg_mask),
   .cfg_done(cfg_done),.cfg_error(cfg_error),.marker_error(shape_marker),.busy(busy));
 median_stream #(.BITS(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT),.K(K),.PAD_MODE(PAD_MODE)) denoise(
   .clk(clk),.rst_n(rst_n),
   .s_tdata(shape_data),.s_tvalid(shape_valid),.s_tuser(shape_user),.s_tlast(shape_last),
   .s_tready(shape_ready),
   .m_tdata(m_tdata),.m_tvalid(m_tvalid),.m_tuser(m_tuser),.m_tlast(m_tlast),.m_tready(m_tready),
   .marker_error(median_marker));
 assign marker_error=shape_marker|median_marker;
endmodule
