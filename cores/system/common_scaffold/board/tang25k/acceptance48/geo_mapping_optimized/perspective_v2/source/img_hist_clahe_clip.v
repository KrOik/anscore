// One externally accumulated tile histogram, strict clip-limit variant.
// After clipping, redistribute one count to each non-full bin in ascending bin
// order; repeat sweeps until all excess is placed. If sum > 256*clip_limit,
// a strict, count-preserving distribution is impossible: report an error and
// emit no histogram. All histogram reads/writes use registered RAM ports.
module img_hist_clahe_clip #(
    parameter integer COUNT_WIDTH = 24,
    parameter integer TAG_WIDTH = 16
) (
    input wire clk,
    input wire rst_n,
    input wire clk_en,
    input wire start_valid,
    output wire start_ready,
    input wire [COUNT_WIDTH-1:0] start_clip_limit,
    input wire [TAG_WIDTH-1:0] start_tag,
    input wire s_valid,
    output wire s_ready,
    input wire [7:0] s_bin,
    input wire [COUNT_WIDTH-1:0] s_count,
    input wire s_last,
    output wire m_valid,
    input wire m_ready,
    output wire [7:0] m_bin,
    output wire [COUNT_WIDTH-1:0] m_count,
    output wire m_last,
    output wire [TAG_WIDTH-1:0] m_tag,
    output wire m_error,
    output reg done_valid,
    input wire done_ready,
    output reg done_error,
    output reg [7:0] done_error_code,
    output reg [COUNT_WIDTH+7:0] done_total_count,
    output reg [TAG_WIDTH-1:0] done_tag
);
    localparam [2:0] IDLE = 0, LOAD = 1, REDIST_READ = 2,
        REDIST_WRITE = 3, READ_BIN = 4, OFFER = 5;
    localparam integer TOTAL_WIDTH = COUNT_WIDTH + 8;
    reg [2:0] state;
    (* ram_style = "block" *) reg [COUNT_WIDTH-1:0] clipped [0:255];
    reg [COUNT_WIDTH-1:0] ram_q;
    reg [COUNT_WIDTH-1:0] clip_limit;
    reg [TOTAL_WIDTH-1:0] excess, total;
    reg [TAG_WIDTH-1:0] tile_tag;
    reg [7:0] load_index, emit_index;
    reg redistribution_progress;
    wire load_fire = s_valid && s_ready;
    wire input_order_ok = s_bin == load_index &&
                         s_last == (load_index == 255);
    wire [COUNT_WIDTH-1:0] bounded = s_count > clip_limit ? clip_limit : s_count;
    wire [COUNT_WIDTH-1:0] removed = s_count - bounded;
    wire [TOTAL_WIDTH-1:0] next_total = total + {{8{1'b0}}, s_count};
    wire [TOTAL_WIDTH-1:0] next_excess = excess + {{8{1'b0}}, removed};
    wire [TOTAL_WIDTH-1:0] capacity = {clip_limit, 8'd0};
    wire can_redistribute = ram_q < clip_limit;

    assign start_ready = rst_n && clk_en && state == IDLE && !done_valid;
    assign s_ready = rst_n && clk_en && state == LOAD;
    assign m_valid = state == OFFER;
    assign m_bin = emit_index;
    assign m_count = ram_q;
    assign m_last = emit_index == 255;
    assign m_tag = tile_tag;
    assign m_error = 1'b0;

    always @(posedge clk) begin
        if (clk_en) begin
            if (load_fire && input_order_ok)
                clipped[load_index] <= bounded;
            if (state == READ_BIN || state == REDIST_READ)
                ram_q <= clipped[emit_index];
            if (state == REDIST_WRITE && excess != 0 && can_redistribute)
                clipped[emit_index] <= ram_q + 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            clip_limit <= 0;
            excess <= 0;
            total <= 0;
            tile_tag <= 0;
            load_index <= 0;
            emit_index <= 0;
            redistribution_progress <= 0;
            done_valid <= 0;
            done_error <= 0;
            done_error_code <= 0;
            done_total_count <= 0;
            done_tag <= 0;
        end else if (clk_en) begin
            if (done_valid && done_ready)
                done_valid <= 0;
            case (state)
                IDLE: begin
                    if (start_valid && start_ready) begin
                        clip_limit <= start_clip_limit;
                        tile_tag <= start_tag;
                        excess <= 0;
                        total <= 0;
                        load_index <= 0;
                        emit_index <= 0;
                        redistribution_progress <= 0;
                        if (start_clip_limit == 0 || COUNT_WIDTH < 1 ||
                            COUNT_WIDTH > 32) begin
                            done_valid <= 1;
                            done_error <= 1;
                            done_error_code <= 8'h01;
                            done_total_count <= 0;
                            done_tag <= start_tag;
                        end else begin
                            state <= LOAD;
                        end
                    end
                end
                LOAD: begin
                    if (load_fire) begin
                        if (!input_order_ok) begin
                            done_valid <= 1;
                            done_error <= 1;
                            done_error_code <= 8'h02;
                            done_total_count <= total;
                            done_tag <= tile_tag;
                            state <= IDLE;
                        end else begin
                            excess <= next_excess;
                            total <= next_total;
                            if (load_index == 255) begin
                                if (next_total > capacity) begin
                                    done_valid <= 1;
                                    done_error <= 1;
                                    done_error_code <= 8'h04; // CAPACITY
                                    done_total_count <= next_total;
                                    done_tag <= tile_tag;
                                    state <= IDLE;
                                end else begin
                                    state <= next_excess == 0 ? READ_BIN : REDIST_READ;
                                end
                            end else
                                load_index <= load_index + 1'b1;
                        end
                    end
                end
                REDIST_READ: state <= REDIST_WRITE;
                REDIST_WRITE: begin
                    if (excess != 0 && can_redistribute) begin
                        excess <= excess - 1'b1;
                        redistribution_progress <= 1;
                    end
                    if (excess == 1 && can_redistribute) begin
                        emit_index <= 0;
                        state <= READ_BIN;
                    end else if (emit_index == 255 &&
                        !redistribution_progress && !can_redistribute) begin
                        // Defensive guard: a full sweep with no capacity must
                        // not deadlock, even if internal state is corrupted.
                        done_valid <= 1;
                        done_error <= 1;
                        done_error_code <= 8'h08;
                        done_total_count <= total;
                        done_tag <= tile_tag;
                        state <= IDLE;
                    end else begin
                        emit_index <= emit_index + 1'b1;
                        if (emit_index == 255)
                            redistribution_progress <= 0;
                        state <= REDIST_READ;
                    end
                end
                READ_BIN: state <= OFFER;
                OFFER: begin
                    if (m_valid && m_ready) begin
                        if (emit_index == 255) begin
                            done_valid <= 1;
                            done_error <= 0;
                            done_error_code <= 0;
                            done_total_count <= total;
                            done_tag <= tile_tag;
                            state <= IDLE;
                        end else begin
                            emit_index <= emit_index + 1'b1;
                            state <= READ_BIN;
                        end
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
