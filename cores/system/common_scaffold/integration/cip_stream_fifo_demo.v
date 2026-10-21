// Runnable integration example: 2 elastic stages -> synchronous FIFO.
// All payload sidebands travel through FIFO together; both blocks share CE.
module cip_stream_fifo_demo #(parameter DATA_WIDTH=32, parameter DEPTH=8)(
    input wire clk,rst_n,clk_en,
    input wire [DATA_WIDTH-1:0] s_data,
    input wire [DATA_WIDTH/8-1:0] s_keep,
    input wire s_sof,s_last,s_valid,
    output wire s_ready,
    output wire [DATA_WIDTH-1:0] m_data,
    output wire [DATA_WIDTH/8-1:0] m_keep,
    output wire m_sof,m_last,m_valid,
    input wire m_ready
);
localparam PACKED_WIDTH=DATA_WIDTH+DATA_WIDTH/8+2;
wire [DATA_WIDTH-1:0] pipe_data;
wire [DATA_WIDTH/8-1:0] pipe_keep;
wire pipe_sof,pipe_last,pipe_valid,pipe_ready;
sb_stream_register_slice #(.DATA_WIDTH(DATA_WIDTH),.USER_WIDTH(1),.STAGES(2)) pipe (
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .s_data(s_data),.s_keep(s_keep),.s_user(s_sof),.s_last(s_last),.s_valid(s_valid),.s_ready(s_ready),
    .m_data(pipe_data),.m_keep(pipe_keep),.m_user(pipe_sof),.m_last(pipe_last),.m_valid(pipe_valid),.m_ready(pipe_ready)
);
cip_sync_fifo #(.DATA_WIDTH(PACKED_WIDTH),.DEPTH(DEPTH)) fifo (
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .in_valid(pipe_valid),.in_ready(pipe_ready),.in_data({pipe_sof,pipe_last,pipe_keep,pipe_data}),
    .out_valid(m_valid),.out_ready(m_ready),.out_data({m_sof,m_last,m_keep,m_data}),
    .level(),.full(),.empty()
);
endmodule
