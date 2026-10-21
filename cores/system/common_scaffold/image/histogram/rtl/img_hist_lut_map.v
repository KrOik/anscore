// Local functional simulation and GW5A memory mapping validated; timing and
// board behavior have not been validated. Two synchronous 256x8 LUT banks.
// A successfully committed build activates on the NEXT accepted SOF.
// All stream participants must share clk_en. Valid/payload hold while paused.
module img_hist_lut_map #(
    parameter integer TAG_WIDTH = 16
) (
    input wire clk,
    input wire rst_n,
    input wire clk_en,
    input wire cfg_begin_valid,
    output wire cfg_begin_ready,
    input wire [TAG_WIDTH-1:0] cfg_begin_tag,
    input wire cfg_wr_valid,
    output wire cfg_wr_ready,
    input wire [7:0] cfg_wr_addr,
    input wire [7:0] cfg_wr_data,
    input wire cfg_wr_last,
    input wire [TAG_WIDTH-1:0] cfg_wr_tag,
    input wire cfg_commit_valid,
    output wire cfg_commit_ready,
    input wire cfg_commit_error,
    output reg cfg_done_valid,
    input wire cfg_done_ready,
    output reg cfg_done_error,
    output reg [7:0] cfg_done_error_code,
    output reg [8:0] cfg_done_count,
    output reg [TAG_WIDTH-1:0] cfg_done_tag,
    input wire s_valid,
    output wire s_ready,
    input wire [7:0] s_gray,
    input wire s_sof,
    input wire s_eol,
    input wire [TAG_WIDTH-1:0] s_tag,
    output reg m_valid,
    input wire m_ready,
    output reg [7:0] m_gray,
    output reg m_sof,
    output reg m_eol,
    output reg [TAG_WIDTH-1:0] m_tag,
    output reg [TAG_WIDTH-1:0] m_lut_tag,
    output reg m_error,
    output wire active_lut_valid
);
    (* ram_style = "block" *) reg [7:0] lut0 [0:255];
    (* ram_style = "block" *) reg [7:0] lut1 [0:255];
    // Each physical LUT bank has one synchronous read register. Keep the
    // selected-bank bit in the same pipeline stage as these read results so
    // bank switching at an accepted SOF does not add a bubble or misalign the
    // output value.
    reg [7:0] lut0_q, lut1_q;
    reg read_bank_q;
    reg active_bank, active_valid;
    reg [TAG_WIDTH-1:0] active_tag;
    reg building, build_bank, build_bad, pending;
    reg [8:0] write_count;
    reg [TAG_WIDTH-1:0] build_tag;
    reg read_valid, read_sof, read_eol, read_error;
    reg [7:0] read_source;
    reg [TAG_WIDTH-1:0] read_tag, read_lut_tag;
    wire output_can_load = !m_valid || m_ready;
    wire input_fire = s_valid && s_ready;
    wire activate = input_fire && s_sof && pending;
    wire selected_bank = activate ? build_bank : active_bank;
    wire write_fire = cfg_wr_valid && cfg_wr_ready;
    wire write_ok = write_fire && cfg_wr_addr == write_count[7:0] &&
        cfg_wr_last == (write_count == 255) && cfg_wr_tag == build_tag;

    assign active_lut_valid = active_valid;
    assign cfg_begin_ready = rst_n && clk_en && !building && !pending &&
        !cfg_done_valid;
    assign cfg_wr_ready = rst_n && clk_en && building && !build_bad &&
        write_count < 256;
    assign cfg_commit_ready = rst_n && clk_en && building && !cfg_done_valid &&
        !cfg_wr_valid;
    assign s_ready = rst_n && clk_en && (!read_valid || output_can_load);

    always @(posedge clk) begin
        if (clk_en) begin
            if (write_ok) begin
                if (build_bank)
                    lut1[cfg_wr_addr] <= cfg_wr_data;
                else
                    lut0[cfg_wr_addr] <= cfg_wr_data;
            end
            if (input_fire) begin
                lut0_q <= lut0[s_gray];
                lut1_q <= lut1[s_gray];
                read_bank_q <= selected_bank;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_bank <= 0;
            active_valid <= 0;
            active_tag <= 0;
            building <= 0;
            build_bank <= 1;
            build_bad <= 0;
            pending <= 0;
            write_count <= 0;
            build_tag <= 0;
            cfg_done_valid <= 0;
            cfg_done_error <= 0;
            cfg_done_error_code <= 0;
            cfg_done_count <= 0;
            cfg_done_tag <= 0;
            read_valid <= 0;
            read_sof <= 0;
            read_eol <= 0;
            read_error <= 0;
            read_source <= 0;
            read_tag <= 0;
            read_lut_tag <= 0;
            m_valid <= 0;
            m_gray <= 0;
            m_sof <= 0;
            m_eol <= 0;
            m_tag <= 0;
            m_lut_tag <= 0;
            m_error <= 0;
        end else if (clk_en) begin
            if (cfg_done_valid && cfg_done_ready)
                cfg_done_valid <= 0;
            if (cfg_begin_valid && cfg_begin_ready) begin
                building <= 1;
                build_bank <= !active_bank;
                build_tag <= cfg_begin_tag;
                write_count <= 0;
                build_bad <= 0;
            end
            if (write_fire) begin
                if (write_ok)
                    write_count <= write_count + 1'b1;
                else
                    build_bad <= 1;
            end
            if (cfg_commit_valid && cfg_commit_ready) begin
                building <= 0;
                if (cfg_commit_error || build_bad || write_count != 256) begin
                    cfg_done_valid <= 1;
                    cfg_done_error <= 1;
                    cfg_done_error_code <= (cfg_commit_error ? 8'h04 : 8'd0) |
                        (build_bad ? 8'h01 : 8'd0) |
                        (write_count != 256 ? 8'h02 : 8'd0);
                    cfg_done_count <= write_count;
                    cfg_done_tag <= build_tag;
                end else begin
                    pending <= 1;
                end
            end
            if (activate) begin
                active_bank <= build_bank;
                active_valid <= 1;
                active_tag <= build_tag;
                pending <= 0;
                cfg_done_valid <= 1;
                cfg_done_error <= 0;
                cfg_done_error_code <= 0;
                cfg_done_count <= 256;
                cfg_done_tag <= build_tag;
            end

            if (output_can_load) begin
                m_valid <= read_valid;
                if (read_valid) begin
                    // Without a valid LUT the identity value is accompanied
                    // by m_error=1. It is never reported as successful mapping.
                    m_gray <= read_error ? read_source :
                        (read_bank_q ? lut1_q : lut0_q);
                    m_sof <= read_sof;
                    m_eol <= read_eol;
                    m_tag <= read_tag;
                    m_lut_tag <= read_lut_tag;
                    m_error <= read_error;
                end
            end
            if (s_ready) begin
                read_valid <= s_valid;
                if (input_fire) begin
                    read_source <= s_gray;
                    read_sof <= s_sof;
                    read_eol <= s_eol;
                    read_tag <= s_tag;
                    read_lut_tag <= activate ? build_tag : active_tag;
                    read_error <= !(active_valid || activate);
                end
            end
        end
    end
endmodule
