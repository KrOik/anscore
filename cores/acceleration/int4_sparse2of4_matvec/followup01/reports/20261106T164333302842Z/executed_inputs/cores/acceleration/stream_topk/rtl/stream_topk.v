// Stable, descending block Top-K. Single-clock ready/valid, synchronous reset.
module stream_topk #(
    parameter SCORE_W = 16,
    parameter TAG_W = 16,
    parameter K = 8,
    parameter SIGNED_SCORE = 1
) (
    input wire clk,
    input wire rst,
    input wire s_valid,
    output wire s_ready,
    input wire [SCORE_W-1:0] s_score,
    input wire [TAG_W-1:0] s_tag,
    input wire s_last,
    output wire m_valid,
    input wire m_ready,
    output wire [SCORE_W-1:0] m_score,
    output wire [TAG_W-1:0] m_tag,
    output wire m_last
);
    localparam CW = (K < 2) ? 1 : $clog2(K+1);
    localparam ACCEPT = 2'd0, INSERT = 2'd1, EMIT = 2'd2;
    reg [1:0] state;
    reg [CW-1:0] count, pos, out_pos;
    reg [SCORE_W-1:0] scores [0:K-1];
    reg [TAG_W-1:0] tags [0:K-1];
    reg [SCORE_W-1:0] pending_score;
    reg [TAG_W-1:0] pending_tag;
    reg pending_last;
    wire better = SIGNED_SCORE ?
        ($signed(pending_score) > $signed(scores[pos])) :
        (pending_score > scores[pos]);
    assign s_ready = !rst && (state == ACCEPT);
    assign m_valid = !rst && (state == EMIT);
    assign m_score = scores[out_pos];
    assign m_tag = tags[out_pos];
    assign m_last = (out_pos == count-1'b1);
    integer j;
    always @(posedge clk) begin
        if (rst) begin
            state <= ACCEPT;
            count <= 0;
            pos <= 0;
            out_pos <= 0;
        end else begin
            case (state)
                ACCEPT: if (s_valid) begin
                    pending_score <= s_score;
                    pending_tag <= s_tag;
                    pending_last <= s_last;
                    pos <= 0;
                    state <= INSERT;
                end
                INSERT: begin
                    // pos never reaches K: a full list rejects at K-1.
                    // Strict comparison inserts ties AFTER earlier equal scores.
                    if ((pos == count) || better) begin
                        // Each slot has one static write site. A variable-index
                        // write combined with parallel shifts creates many
                        // overlapping write ports and a costly priority mux.
                        if (pos == 0) begin
                            scores[0] <= pending_score;
                            tags[0] <= pending_tag;
                        end
                        for (j = 1; j < K; j = j+1) begin
                            if (pos == j) begin
                                scores[j] <= pending_score;
                                tags[j] <= pending_tag;
                            end else if (j > pos) begin
                                scores[j] <= scores[j-1];
                                tags[j] <= tags[j-1];
                            end
                        end
                        if (count < K) count <= count+1'b1;
                        if (pending_last) begin
                            out_pos <= 0;
                            state <= EMIT;
                        end else state <= ACCEPT;
                    end else if (pos == K-1) begin
                        if (pending_last) begin
                            out_pos <= 0;
                            state <= EMIT;
                        end else state <= ACCEPT;
                    end else pos <= pos+1'b1;
                end
                EMIT: if (m_ready) begin
                    if (m_last) begin
                        count <= 0;
                        state <= ACCEPT;
                    end else out_pos <= out_pos+1'b1;
                end
                default: state <= ACCEPT;
            endcase
        end
    end
endmodule
