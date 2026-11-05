// SPDX-License-Identifier: Apache-2.0
// Original ANSCORE implementation. No upstream code is included.
module grayscale_vertical_seam_carve #(
    parameter integer WIDTH = 16,
    parameter integer HEIGHT = 16,
    parameter integer TAG_W = 8
) (
    input wire clk, input wire rst,
    input wire c_valid, output wire c_ready, input wire [TAG_W-1:0] c_tag,
    input wire s_valid, output wire s_ready,
    input wire [7:0] s_pixel, input wire s_sof, s_eol, s_last,
    output wire m_valid, input wire m_ready,
    output wire [7:0] m_pixel, output wire m_sof, m_eol, m_last,
    output wire [6:0] m_removed_x,
    output wire d_valid, input wire d_ready,
    output wire d_error, output wire [15:0] d_cost,
    output wire [TAG_W-1:0] d_tag
);
    localparam integer XW = (WIDTH <= 2) ? 1 : $clog2(WIDTH);
    localparam integer YW = (HEIGHT <= 1) ? 1 : $clog2(HEIGHT);
    localparam integer AW = $clog2(WIDTH*HEIGHT);
    localparam integer CW = $clog2(510*HEIGHT+1);
    generate if (WIDTH < 2 || WIDTH > 64 || HEIGHT < 1 || HEIGHT > 64 || TAG_W < 1 || TAG_W > 32) begin : bad_parameters
        grayscale_vertical_seam_carve_invalid_parameters invalid_parameters();
    end endgenerate
    localparam [4:0] IDLE=0, CAPTURE=1, EL=2, ER=3, EU=4, ED=5,
        ENERGY=6, FIRST=7, PREV_INIT=8, PREV_READ=9, PREV_USE=10,
        WRITE_ROW=11, ADVANCE=12, TERM_READ=13, TERM_USE=14,
        BACK_START=15, BACK_WRITE=16, BACK_USE=17, OUT_READ=18,
        OUT_VALID=19, DONE=20;
    reg [4:0] state;
    reg [7:0] pixels [0:WIDTH*HEIGHT-1];
    reg [XW-1:0] parents [0:WIDTH*HEIGHT-1];
    reg [XW-1:0] seam [0:HEIGHT-1];
    reg [CW-1:0] dp [0:2*WIDTH-1];
    reg [XW-1:0] x, p, p_end, best_x, terminal_x, parent_q;
    reg [YW-1:0] y;
    reg [AW-1:0] capture_index;
    reg [7:0] sample_q, left_q, right_q, up_q;
    reg [8:0] energy_q;
    reg [CW-1:0] cost_q, best_cost, terminal_cost;
    reg [15:0] total_cost;
    reg error_q;
    reg [TAG_W-1:0] tag_q;
    wire [7:0] dx = left_q >= right_q ? left_q-right_q : right_q-left_q;
    wire [7:0] dy = up_q >= sample_q ? up_q-sample_q : sample_q-up_q;
    assign c_ready = state == IDLE && !rst;
    assign s_ready = state == CAPTURE && !rst;
    assign m_valid = state == OUT_VALID && !rst;
    assign m_pixel = sample_q;
    assign m_sof = (x == 0 && y == 0);
    assign m_eol = (x == WIDTH-2);
    assign m_last = m_eol && (y == HEIGHT-1);
    assign m_removed_x = {{(7-XW){1'b0}},seam[y]};
    assign d_valid = state == DONE && !rst;
    assign d_error = error_q;
    assign d_cost = total_cost;
    assign d_tag = tag_q;
    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            x <= 0; y <= 0; capture_index <= 0;
            total_cost <= 0; error_q <= 0; tag_q <= 0;
            sample_q <= 0;
        end else begin
            case (state)
                IDLE: if (c_valid) begin
                    tag_q <= c_tag; error_q <= 0; total_cost <= 0;
                    capture_index <= 0; x <= 0; y <= 0;
                    state <= CAPTURE;
                end
                CAPTURE: if (s_valid) begin
                    if (s_sof != (capture_index == 0) || s_eol != (x == WIDTH-1) ||
                        s_last != (capture_index == WIDTH*HEIGHT-1)) begin
                        error_q <= 1; state <= DONE;
                    end else begin
                        pixels[capture_index] <= s_pixel;
                        if (capture_index == WIDTH*HEIGHT-1) begin
                            x <= 0; y <= 0; state <= EL;
                        end else begin
                            capture_index <= capture_index + 1'b1;
                            if (x == WIDTH-1) begin x <= 0; y <= y+1'b1; end
                            else x <= x+1'b1;
                        end
                    end
                end
                EL: begin
                    sample_q <= pixels[y*WIDTH + ((x == 0) ? 0 : x-1'b1)];
                    state <= ER;
                end
                ER: begin
                    left_q <= sample_q;
                    sample_q <= pixels[y*WIDTH + ((x == WIDTH-1) ? x : x+1'b1)];
                    state <= EU;
                end
                EU: begin
                    right_q <= sample_q;
                    sample_q <= pixels[((y == 0) ? 0 : y-1'b1)*WIDTH + x];
                    state <= ED;
                end
                ED: begin
                    up_q <= sample_q;
                    sample_q <= pixels[((y == HEIGHT-1) ? y : y+1'b1)*WIDTH + x];
                    state <= ENERGY;
                end
                ENERGY: begin
                    energy_q <= {1'b0,dx}+{1'b0,dy};
                    state <= (y == 0) ? FIRST : PREV_INIT;
                end
                FIRST: begin
                    dp[x] <= energy_q;
                    state <= ADVANCE;
                end
                PREV_INIT: begin
                    p <= (x == 0) ? 0 : x-1'b1;
                    p_end <= (x == WIDTH-1) ? x : x+1'b1;
                    best_cost <= {CW{1'b1}}; best_x <= 0;
                    state <= PREV_READ;
                end
                PREV_READ: begin
                    cost_q <= dp[(y[0] ? 0 : WIDTH)+p];
                    state <= PREV_USE;
                end
                PREV_USE: begin
                    // Ascending predecessor order plus strict compare chooses
                    // the smaller predecessor coordinate on exact ties.
                    if (cost_q < best_cost) begin best_cost <= cost_q; best_x <= p; end
                    if (p == p_end) state <= WRITE_ROW;
                    else begin p <= p+1'b1; state <= PREV_READ; end
                end
                WRITE_ROW: begin
                    dp[(y[0] ? WIDTH : 0)+x] <= best_cost + energy_q;
                    parents[y*WIDTH+x] <= best_x;
                    state <= ADVANCE;
                end
                ADVANCE: begin
                    if (x == WIDTH-1) begin
                        x <= 0;
                        if (y == HEIGHT-1) begin
                            terminal_cost <= {CW{1'b1}}; terminal_x <= 0;
                            state <= TERM_READ;
                        end else begin y <= y+1'b1; state <= EL; end
                    end else begin x <= x+1'b1; state <= EL; end
                end
                TERM_READ: begin
                    cost_q <= dp[((HEIGHT-1)%2)*WIDTH+x]; state <= TERM_USE;
                end
                TERM_USE: begin
                    if (cost_q < terminal_cost) begin terminal_cost <= cost_q; terminal_x <= x; end
                    if (x == WIDTH-1) state <= BACK_START;
                    else begin x <= x+1'b1; state <= TERM_READ; end
                end
                BACK_START: begin
                    x <= terminal_x; y <= HEIGHT-1; total_cost <= terminal_cost;
                    state <= BACK_WRITE;
                end
                BACK_WRITE: begin
                    seam[y] <= x;
                    if (y == 0) begin x <= 0; y <= 0; state <= OUT_READ; end
                    else begin parent_q <= parents[y*WIDTH+x]; state <= BACK_USE; end
                end
                BACK_USE: begin x <= parent_q; y <= y-1'b1; state <= BACK_WRITE; end
                OUT_READ: begin
                    sample_q <= pixels[y*WIDTH + ((x >= seam[y]) ? x+1'b1 : x)];
                    state <= OUT_VALID;
                end
                OUT_VALID: if (m_ready) begin
                    if (x == WIDTH-2) begin
                        x <= 0;
                        if (y == HEIGHT-1) state <= DONE;
                        else begin y <= y+1'b1; state <= OUT_READ; end
                    end else begin x <= x+1'b1; state <= OUT_READ; end
                end
                DONE: if (d_ready) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
