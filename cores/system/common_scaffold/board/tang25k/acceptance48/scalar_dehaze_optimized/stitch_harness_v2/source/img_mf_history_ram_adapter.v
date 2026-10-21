// Fixed-geometry implementation replacing the former unsupported placeholder.
module img_mf_history_ram_adapter #(
    parameter DATA_WIDTH=24, TAG_WIDTH=16, FRAME_WIDTH=16,
    parameter WIDTH=32, HEIGHT=24, CAPTURE_TIMEOUT=65536
) (
    input wire clk, rst_n, clk_en,
    input wire cmd_valid, output wire cmd_ready, input wire [3:0] cmd_opcode,
    input wire [FRAME_WIDTH-1:0] cmd_frameid,
    output wire rsp_valid, input wire rsp_ready, output wire rsp_done,
    output wire [3:0] rsp_opcode, output wire [FRAME_WIDTH-1:0] rsp_frameid,
    output wire [7:0] rsp_error, error_code,
    input wire s_valid, output wire s_ready, input wire [DATA_WIDTH-1:0] s_data,
    input wire s_sof, s_eol, input wire [TAG_WIDTH-1:0] s_tag, input wire [FRAME_WIDTH-1:0] s_frameid,
    input wire aux_valid, output wire aux_ready, input wire [DATA_WIDTH-1:0] aux_data,
    input wire aux_sof, aux_eol, input wire [TAG_WIDTH-1:0] aux_tag, input wire [FRAME_WIDTH-1:0] aux_frameid,
    output wire m_valid, input wire m_ready, output wire [DATA_WIDTH-1:0] m_data,
    output wire m_sof, m_eol, output wire [TAG_WIDTH-1:0] m_tag,
    output wire [FRAME_WIDTH-1:0] m_frameid, output wire [7:0] m_error,
    output wire [DATA_WIDTH-1:0] m_aux_data, output wire m_pair, output wire [1:0] frames_valid,
    input wire rd_valid, output wire rd_ready, input wire [31:0] rd_addr0, rd_addr1,
    output wire rd_rsp_valid, input wire rd_rsp_ready,
    output wire [DATA_WIDTH-1:0] rd_data0, rd_data1, output wire [7:0] rd_error,
    input wire wr_valid, output wire wr_ready, input wire wr_bank,
    input wire [31:0] wr_addr, input wire [DATA_WIDTH-1:0] wr_data
);
    // Optional unconnected request ports are inactive in four-state simulation.
    wire rd_request = rd_valid === 1'b1;
    wire wr_request = wr_valid === 1'b1;
    img_mf_dual_frame_store #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.DATA_WIDTH(DATA_WIDTH),.TAG_WIDTH(TAG_WIDTH),
        .FRAME_WIDTH(FRAME_WIDTH),.CAPTURE_TIMEOUT(CAPTURE_TIMEOUT)) store_i (
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),
        .cmd_opcode(cmd_opcode),.cmd_frameid(cmd_frameid),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_done(rsp_done),
        .rsp_opcode(rsp_opcode),.rsp_frameid(rsp_frameid),.rsp_error(rsp_error),.error_code(error_code),
        .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),.s_tag(s_tag),.s_frameid(s_frameid),
        .aux_valid(aux_valid),.aux_ready(aux_ready),.aux_data(aux_data),.aux_sof(aux_sof),.aux_eol(aux_eol),.aux_tag(aux_tag),.aux_frameid(aux_frameid),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_aux_data(m_aux_data),.m_pair(m_pair),.m_sof(m_sof),.m_eol(m_eol),.m_tag(m_tag),.m_frameid(m_frameid),.m_error(m_error),
        .frames_valid(frames_valid),.rd_valid(rd_request),.rd_ready(rd_ready),.rd_addr0(rd_addr0),.rd_addr1(rd_addr1),
        .rd_rsp_valid(rd_rsp_valid),.rd_rsp_ready(rd_rsp_ready),.rd_data0(rd_data0),.rd_data1(rd_data1),.rd_error(rd_error),
        .wr_valid(wr_request),.wr_ready(wr_ready),.wr_bank(wr_bank),.wr_addr(wr_addr),.wr_data(wr_data));
endmodule
