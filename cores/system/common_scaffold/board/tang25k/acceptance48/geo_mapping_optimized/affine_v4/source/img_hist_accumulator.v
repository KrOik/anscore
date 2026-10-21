// Local functional simulation and GW5A memory mapping validated; timing and
// board behavior have not been validated.
// Transfers happen only on rising edges with clk_en && valid && ready.
// One synchronous RAM read/modify/write at a time: input initiation interval 2.
module img_hist_accumulator #(
    parameter integer FRAME_WIDTH = 640,
    parameter integer FRAME_HEIGHT = 480,
    parameter integer COUNT_WIDTH = 24,
    parameter integer TAG_WIDTH = 16
) (
    input wire clk,
    input wire rst_n,
    input wire clk_en,
    input wire start_valid,
    output wire start_ready,
    input wire [TAG_WIDTH-1:0] start_tag,
    input wire s_valid,
    output wire s_ready,
    input wire [7:0] s_gray,
    input wire s_sof,
    input wire s_eol,
    output reg done_valid,
    input wire done_ready,
    output reg done_error,
    output reg [7:0] done_error_code,
    output reg [COUNT_WIDTH-1:0] done_count,
    output reg [TAG_WIDTH-1:0] done_tag,
    input wire rd_req_valid,
    output wire rd_req_ready,
    input wire [7:0] rd_req_bin,
    output reg rd_rsp_valid,
    input wire rd_rsp_ready,
    output reg [7:0] rd_rsp_bin,
    output reg [COUNT_WIDTH-1:0] rd_rsp_count,
    output reg [TAG_WIDTH-1:0] rd_rsp_tag,
    output reg rd_rsp_error,
    output wire busy
);
    localparam [2:0] IDLE = 0, CLEAR = 1, COLLECT = 2,
                     UPDATE = 3, HOLD = 4, READBACK = 5;
    localparam [63:0] FRAME_PIXELS = 64'd1 * FRAME_WIDTH * FRAME_HEIGHT;
    localparam integer PARAM_OK = FRAME_WIDTH > 0 && FRAME_HEIGHT > 0 &&
        COUNT_WIDTH > 0 && COUNT_WIDTH <= 32 &&
        FRAME_PIXELS <= ((64'd1 << COUNT_WIDTH) - 1);
    localparam [7:0] ERR_PARAM = 8'h01, ERR_FRAME = 8'h02,
                     ERR_OVERFLOW = 8'h04;

    reg [2:0] state;
    // No reset loop on this array. CLEAR writes one location per enabled clock.
    // "bins" is a reserved SystemVerilog coverage keyword.
    (* ram_style = "block" *) reg [COUNT_WIDTH-1:0] hist_bins [0:255];
    reg [COUNT_WIDTH-1:0] ram_q;
    reg [7:0] clear_bin, pending_bin, read_bin;
    reg [31:0] x;
    reg [COUNT_WIDTH-1:0] accepted_count;
    reg [TAG_WIDTH-1:0] frame_tag;
    reg pending_last, histogram_valid;
    reg [7:0] frame_error;

    wire input_fire = s_valid && s_ready;
    wire read_fire = rd_req_valid && rd_req_ready;
    // Keep exactly one synchronous histogram read port. The two clients are
    // mutually exclusive by construction: pixel reads happen only in
    // COLLECT, and software readback only in HOLD.
    wire hist_rd_en = input_fire || read_fire;
    wire [7:0] hist_rd_addr = input_fire ? s_gray : rd_req_bin;
    wire is_last_input = accepted_count == FRAME_PIXELS - 1;
    wire framing_bad = (s_sof != (accepted_count == 0)) ||
                       (s_eol != (x == FRAME_WIDTH - 1));
    wire bin_overflow = &ram_q;

    assign start_ready = rst_n && clk_en &&
        (state == IDLE || state == HOLD) && !done_valid && !rd_rsp_valid;
    assign s_ready = rst_n && clk_en && state == COLLECT;
    assign rd_req_ready = rst_n && clk_en && state == HOLD &&
        !start_valid && !rd_rsp_valid;
    assign busy = state != IDLE && state != HOLD;

    // RAM read and write ports are synchronous. UPDATE cannot coincide with
    // another input acceptance, so consecutive equal-valued pixels are safe.
    always @(posedge clk) begin
        if (clk_en) begin
            if (state == CLEAR)
                hist_bins[clear_bin] <= {COUNT_WIDTH{1'b0}};
            else if (state == UPDATE)
                hist_bins[pending_bin] <= bin_overflow ? ram_q : ram_q + 1'b1;
            if (hist_rd_en)
                ram_q <= hist_bins[hist_rd_addr];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            clear_bin <= 0;
            pending_bin <= 0;
            read_bin <= 0;
            x <= 0;
            accepted_count <= 0;
            frame_tag <= 0;
            pending_last <= 0;
            histogram_valid <= 0;
            frame_error <= 0;
            done_valid <= 0;
            done_error <= 0;
            done_error_code <= 0;
            done_count <= 0;
            done_tag <= 0;
            rd_rsp_valid <= 0;
            rd_rsp_bin <= 0;
            rd_rsp_count <= 0;
            rd_rsp_tag <= 0;
            rd_rsp_error <= 0;
        end else if (clk_en) begin
            if (done_valid && done_ready)
                done_valid <= 0;
            if (rd_rsp_valid && rd_rsp_ready)
                rd_rsp_valid <= 0;

            case (state)
                IDLE, HOLD: begin
                    if (start_valid && start_ready) begin
                        frame_tag <= start_tag;
                        clear_bin <= 0;
                        accepted_count <= 0;
                        x <= 0;
                        frame_error <= 0;
                        histogram_valid <= 0;
                        if (!PARAM_OK) begin
                            state <= HOLD;
                            done_valid <= 1;
                            done_error <= 1;
                            done_error_code <= ERR_PARAM;
                            done_count <= 0;
                            done_tag <= start_tag;
                        end else begin
                            state <= CLEAR;
                        end
                    end else if (read_fire) begin
                        read_bin <= rd_req_bin;
                        state <= READBACK;
                    end
                end
                CLEAR: begin
                    if (clear_bin == 255)
                        state <= COLLECT;
                    else
                        clear_bin <= clear_bin + 1'b1;
                end
                COLLECT: begin
                    if (input_fire) begin
                        pending_bin <= s_gray;
                        pending_last <= is_last_input;
                        accepted_count <= accepted_count + 1'b1;
                        x <= x == FRAME_WIDTH - 1 ? 0 : x + 1'b1;
                        if (framing_bad)
                            frame_error <= frame_error | ERR_FRAME;
                        state <= UPDATE;
                    end
                end
                UPDATE: begin
                    if (bin_overflow)
                        frame_error <= frame_error | ERR_OVERFLOW;
                    if (pending_last) begin
                        done_valid <= 1;
                        done_error <= (frame_error != 0) || bin_overflow;
                        done_error_code <= frame_error |
                            (bin_overflow ? ERR_OVERFLOW : 8'd0);
                        done_count <= accepted_count;
                        done_tag <= frame_tag;
                        histogram_valid <= (frame_error == 0) && !bin_overflow;
                        state <= HOLD;
                    end else begin
                        state <= COLLECT;
                    end
                end
                READBACK: begin
                    rd_rsp_valid <= 1;
                    rd_rsp_bin <= read_bin;
                    rd_rsp_count <= histogram_valid ? ram_q :
                        {COUNT_WIDTH{1'b0}};
                    rd_rsp_tag <= frame_tag;
                    rd_rsp_error <= !histogram_valid;
                    state <= HOLD;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
