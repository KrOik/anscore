module mlkem768_flow_scheduler (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [1:0]  cmd,
    output wire        ready,
    output wire        busy,
    output reg         done,
    output reg         error,
    output reg  [1:0]  active_cmd,
    output reg  [4:0]  active_phase,
    output reg  [1:0]  vector_index,
    output reg  [3:0]  terminal_cause,
    output reg  [31:0] digest,
    output reg  [31:0] cycle_count,
    output reg  [15:0] ntt_issue_count,
    output reg  [15:0] ntt_done_count,
    output reg  [15:0] subblock_issue_count,

    output reg         ntt_start,
    output reg  [2:0]  ntt_op,
    output reg         ntt_mode_dsa,
    input  wire        ntt_ready,
    input  wire        ntt_done,
    input  wire        ntt_error,
    input  wire [31:0] ntt_digest,
    input  wire [31:0] ntt_cycle_count,

    output reg         seed_start,
    input  wire        seed_ready,
    input  wire        seed_done,
    input  wire        seed_error,
    input  wire [31:0] seed_digest,

    output reg         xof_start,
    input  wire        xof_ready,
    input  wire        xof_done,
    input  wire        xof_error,
    input  wire [31:0] xof_digest,

    output reg         matrix_start,
    input  wire        matrix_ready,
    input  wire        matrix_done,
    input  wire        matrix_error,
    input  wire [31:0] matrix_digest,

    output reg         cbd_start,
    input  wire        cbd_ready,
    input  wire        cbd_done,
    input  wire        cbd_error,
    input  wire [31:0] cbd_digest,

    output reg         compress_start,
    input  wire        compress_ready,
    input  wire        compress_done,
    input  wire        compress_error,
    input  wire [31:0] compress_digest,

    output reg         verify_start,
    input  wire        verify_ready,
    input  wire        verify_done,
    input  wire        verify_error,
    input  wire [31:0] verify_digest
);

localparam [1:0] CMD_KEYGEN = 2'd0;
localparam [1:0] CMD_ENCAPS = 2'd1;
localparam [1:0] CMD_DECAPS = 2'd2;

localparam [2:0] OP_KEM_NTT    = 3'd0;
localparam [2:0] OP_DSA_NTT    = 3'd1;
localparam [2:0] OP_KEM_INTT   = 3'd2;
localparam [2:0] OP_DSA_INTT   = 3'd3;
localparam [2:0] OP_KEM_FLOW   = 3'd4;
localparam [2:0] OP_DSA_FLOW   = 3'd5;
localparam [2:0] OP_HYBRID_RUN = 3'd6;
localparam [2:0] OP_INVALID    = 3'd7;

localparam [4:0] PH_IDLE            = 5'd0;
localparam [4:0] PH_SEED            = 5'd1;
localparam [4:0] PH_XOF             = 5'd2;
localparam [4:0] PH_MATRIX          = 5'd3;
localparam [4:0] PH_CBD             = 5'd4;
localparam [4:0] PH_KEYGEN_S_NTT    = 5'd5;
localparam [4:0] PH_KEYGEN_E_NTT    = 5'd6;
localparam [4:0] PH_ENCAPS_R_NTT    = 5'd7;
localparam [4:0] PH_ENCAPS_U_INTT   = 5'd8;
localparam [4:0] PH_COMPRESS        = 5'd9;
localparam [4:0] PH_DECAPS_U_NTT    = 5'd10;
localparam [4:0] PH_DECAPS_M_INTT   = 5'd11;
localparam [4:0] PH_VERIFY          = 5'd12;
localparam [4:0] PH_DONE            = 5'd13;
localparam [4:0] PH_ERROR           = 5'd14;

localparam [2:0] SB_SEED     = 3'd0;
localparam [2:0] SB_XOF      = 3'd1;
localparam [2:0] SB_MATRIX   = 3'd2;
localparam [2:0] SB_CBD      = 3'd3;
localparam [2:0] SB_COMPRESS = 3'd4;
localparam [2:0] SB_VERIFY   = 3'd5;

localparam [3:0] CAUSE_NONE           = 4'd0;
localparam [3:0] CAUSE_INVALID_CMD    = 4'd1;
localparam [3:0] CAUSE_SUBBLOCK_ERROR = 4'd2;
localparam [3:0] CAUSE_NTT_ERROR      = 4'd3;
localparam [3:0] CAUSE_INTERNAL       = 4'd4;

localparam [3:0] S_IDLE           = 4'd0;
localparam [3:0] S_START_SUBBLOCK = 4'd1;
localparam [3:0] S_WAIT_SUBBLOCK  = 4'd2;
localparam [3:0] S_START_NTT      = 4'd3;
localparam [3:0] S_WAIT_NTT       = 4'd4;
localparam [3:0] S_DONE           = 4'd5;

reg [3:0] state;
reg [2:0] active_subblock;

// Prototype/test-gated interfaces for ML-KEM subblocks that are not implemented here.
wire subblock_ready =
    (active_subblock == SB_SEED)     ? seed_ready :
    (active_subblock == SB_XOF)      ? xof_ready :
    (active_subblock == SB_MATRIX)   ? matrix_ready :
    (active_subblock == SB_CBD)      ? cbd_ready :
    (active_subblock == SB_COMPRESS) ? compress_ready :
    (active_subblock == SB_VERIFY)   ? verify_ready : 1'b0;

wire subblock_done =
    (active_subblock == SB_SEED)     ? seed_done :
    (active_subblock == SB_XOF)      ? xof_done :
    (active_subblock == SB_MATRIX)   ? matrix_done :
    (active_subblock == SB_CBD)      ? cbd_done :
    (active_subblock == SB_COMPRESS) ? compress_done :
    (active_subblock == SB_VERIFY)   ? verify_done : 1'b0;

wire subblock_error =
    (active_subblock == SB_SEED)     ? seed_error :
    (active_subblock == SB_XOF)      ? xof_error :
    (active_subblock == SB_MATRIX)   ? matrix_error :
    (active_subblock == SB_CBD)      ? cbd_error :
    (active_subblock == SB_COMPRESS) ? compress_error :
    (active_subblock == SB_VERIFY)   ? verify_error : 1'b1;

wire [31:0] subblock_digest =
    (active_subblock == SB_SEED)     ? seed_digest :
    (active_subblock == SB_XOF)      ? xof_digest :
    (active_subblock == SB_MATRIX)   ? matrix_digest :
    (active_subblock == SB_CBD)      ? cbd_digest :
    (active_subblock == SB_COMPRESS) ? compress_digest :
    (active_subblock == SB_VERIFY)   ? verify_digest : 32'hbad0bad0;

assign ready = (state == S_IDLE);
assign busy = (state != S_IDLE) && (state != S_DONE);

function [31:0] rotl7;
    input [31:0] value;
    begin
        rotl7 = {value[24:0], value[31:25]};
    end
endfunction

function [31:0] cmd_tag;
    input [1:0] value;
    begin
        case (value)
            CMD_KEYGEN: cmd_tag = 32'h4b454d4b;
            CMD_ENCAPS: cmd_tag = 32'h4b454d45;
            CMD_DECAPS: cmd_tag = 32'h4b454d44;
            default:    cmd_tag = 32'hbad0bad0;
        endcase
    end
endfunction

function [2:0] phase_ntt_op;
    input [4:0] phase;
    begin
        case (phase)
            PH_KEYGEN_S_NTT,
            PH_KEYGEN_E_NTT,
            PH_ENCAPS_R_NTT,
            PH_DECAPS_U_NTT:  phase_ntt_op = OP_KEM_NTT;
            PH_ENCAPS_U_INTT,
            PH_DECAPS_M_INTT: phase_ntt_op = OP_KEM_INTT;
            default:          phase_ntt_op = OP_INVALID;
        endcase
    end
endfunction

function is_valid_cmd;
    input [1:0] value;
    begin
        is_valid_cmd = (value == CMD_KEYGEN) || (value == CMD_ENCAPS) || (value == CMD_DECAPS);
    end
endfunction

function is_valid_kem_ntt_op;
    input [2:0] value;
    begin
        is_valid_kem_ntt_op = (value == OP_KEM_NTT) || (value == OP_KEM_INTT);
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
        done <= 1'b0;
        error <= 1'b0;
        active_cmd <= CMD_KEYGEN;
        active_phase <= PH_IDLE;
        active_subblock <= SB_SEED;
        vector_index <= 2'd0;
        terminal_cause <= CAUSE_NONE;
        digest <= 32'd0;
        cycle_count <= 32'd0;
        ntt_issue_count <= 16'd0;
        ntt_done_count <= 16'd0;
        subblock_issue_count <= 16'd0;
        ntt_start <= 1'b0;
        ntt_op <= OP_KEM_NTT;
        ntt_mode_dsa <= 1'b0;
        seed_start <= 1'b0;
        xof_start <= 1'b0;
        matrix_start <= 1'b0;
        cbd_start <= 1'b0;
        compress_start <= 1'b0;
        verify_start <= 1'b0;
    end else begin
        done <= 1'b0;
        ntt_start <= 1'b0;
        seed_start <= 1'b0;
        xof_start <= 1'b0;
        matrix_start <= 1'b0;
        cbd_start <= 1'b0;
        compress_start <= 1'b0;
        verify_start <= 1'b0;
        ntt_mode_dsa <= 1'b0;

        case (state)
            S_IDLE: begin
                active_phase <= PH_IDLE;
                if (start) begin
                    active_cmd <= cmd;
                    vector_index <= 2'd0;
                    terminal_cause <= CAUSE_NONE;
                    error <= 1'b0;
                    digest <= 32'h4d4c4b45 ^ cmd_tag(cmd);
                    cycle_count <= 32'd0;
                    ntt_issue_count <= 16'd0;
                    ntt_done_count <= 16'd0;
                    subblock_issue_count <= 16'd0;

                    if (!is_valid_cmd(cmd)) begin
                        active_phase <= PH_ERROR;
                        terminal_cause <= CAUSE_INVALID_CMD;
                        error <= 1'b1;
                        state <= S_DONE;
                    end else if (cmd == CMD_DECAPS) begin
                        active_phase <= PH_XOF;
                        active_subblock <= SB_XOF;
                        state <= S_START_SUBBLOCK;
                    end else begin
                        active_phase <= PH_SEED;
                        active_subblock <= SB_SEED;
                        state <= S_START_SUBBLOCK;
                    end
                end
            end

            S_START_SUBBLOCK: begin
                if (subblock_ready) begin
                    case (active_subblock)
                        SB_SEED:     seed_start <= 1'b1;
                        SB_XOF:      xof_start <= 1'b1;
                        SB_MATRIX:   matrix_start <= 1'b1;
                        SB_CBD:      cbd_start <= 1'b1;
                        SB_COMPRESS: compress_start <= 1'b1;
                        SB_VERIFY:   verify_start <= 1'b1;
                        default: begin end
                    endcase
                    subblock_issue_count <= subblock_issue_count + 16'd1;
                    state <= S_WAIT_SUBBLOCK;
                end
            end

            S_WAIT_SUBBLOCK: begin
                if (subblock_done) begin
                    digest <= rotl7(digest) ^ subblock_digest ^ {19'd0, active_phase, active_subblock};
                    if (subblock_error) begin
                        active_phase <= PH_ERROR;
                        terminal_cause <= CAUSE_SUBBLOCK_ERROR;
                        error <= 1'b1;
                        state <= S_DONE;
                    end else begin
                        case (active_cmd)
                            CMD_KEYGEN: begin
                                case (active_phase)
                                    PH_SEED: begin
                                        active_phase <= PH_XOF;
                                        active_subblock <= SB_XOF;
                                        state <= S_START_SUBBLOCK;
                                    end
                                    PH_XOF: begin
                                        active_phase <= PH_MATRIX;
                                        active_subblock <= SB_MATRIX;
                                        state <= S_START_SUBBLOCK;
                                    end
                                    PH_MATRIX: begin
                                        active_phase <= PH_CBD;
                                        active_subblock <= SB_CBD;
                                        state <= S_START_SUBBLOCK;
                                    end
                                    PH_CBD: begin
                                        active_phase <= PH_KEYGEN_S_NTT;
                                        vector_index <= 2'd0;
                                        state <= S_START_NTT;
                                    end
                                    default: begin
                                        active_phase <= PH_ERROR;
                                        terminal_cause <= CAUSE_INTERNAL;
                                        error <= 1'b1;
                                        state <= S_DONE;
                                    end
                                endcase
                            end

                            CMD_ENCAPS: begin
                                case (active_phase)
                                    PH_SEED: begin
                                        active_phase <= PH_XOF;
                                        active_subblock <= SB_XOF;
                                        state <= S_START_SUBBLOCK;
                                    end
                                    PH_XOF: begin
                                        active_phase <= PH_MATRIX;
                                        active_subblock <= SB_MATRIX;
                                        state <= S_START_SUBBLOCK;
                                    end
                                    PH_MATRIX: begin
                                        active_phase <= PH_CBD;
                                        active_subblock <= SB_CBD;
                                        state <= S_START_SUBBLOCK;
                                    end
                                    PH_CBD: begin
                                        active_phase <= PH_ENCAPS_R_NTT;
                                        vector_index <= 2'd0;
                                        state <= S_START_NTT;
                                    end
                                    PH_COMPRESS: begin
                                        active_phase <= PH_DONE;
                                        terminal_cause <= CAUSE_NONE;
                                        error <= 1'b0;
                                        state <= S_DONE;
                                    end
                                    default: begin
                                        active_phase <= PH_ERROR;
                                        terminal_cause <= CAUSE_INTERNAL;
                                        error <= 1'b1;
                                        state <= S_DONE;
                                    end
                                endcase
                            end

                            CMD_DECAPS: begin
                                case (active_phase)
                                    PH_XOF: begin
                                        active_phase <= PH_MATRIX;
                                        active_subblock <= SB_MATRIX;
                                        state <= S_START_SUBBLOCK;
                                    end
                                    PH_MATRIX: begin
                                        active_phase <= PH_DECAPS_U_NTT;
                                        vector_index <= 2'd0;
                                        state <= S_START_NTT;
                                    end
                                    PH_COMPRESS: begin
                                        active_phase <= PH_VERIFY;
                                        active_subblock <= SB_VERIFY;
                                        state <= S_START_SUBBLOCK;
                                    end
                                    PH_VERIFY: begin
                                        active_phase <= PH_DONE;
                                        terminal_cause <= CAUSE_NONE;
                                        error <= 1'b0;
                                        state <= S_DONE;
                                    end
                                    default: begin
                                        active_phase <= PH_ERROR;
                                        terminal_cause <= CAUSE_INTERNAL;
                                        error <= 1'b1;
                                        state <= S_DONE;
                                    end
                                endcase
                            end

                            default: begin
                                active_phase <= PH_ERROR;
                                terminal_cause <= CAUSE_INVALID_CMD;
                                error <= 1'b1;
                                state <= S_DONE;
                            end
                        endcase
                    end
                end
            end

            S_START_NTT: begin
                ntt_op <= phase_ntt_op(active_phase);
                if (!is_valid_kem_ntt_op(phase_ntt_op(active_phase))) begin
                    active_phase <= PH_ERROR;
                    terminal_cause <= CAUSE_INTERNAL;
                    error <= 1'b1;
                    state <= S_DONE;
                end else if (ntt_ready) begin
                    ntt_start <= 1'b1;
                    ntt_issue_count <= ntt_issue_count + 16'd1;
                    state <= S_WAIT_NTT;
                end
            end

            S_WAIT_NTT: begin
                if (ntt_done) begin
                    digest <= rotl7(digest) ^ ntt_digest ^ {21'd0, active_phase, vector_index};
                    cycle_count <= cycle_count + ntt_cycle_count;
                    ntt_done_count <= ntt_done_count + 16'd1;
                    if (ntt_error) begin
                        active_phase <= PH_ERROR;
                        terminal_cause <= CAUSE_NTT_ERROR;
                        error <= 1'b1;
                        state <= S_DONE;
                    end else begin
                        case (active_phase)
                            PH_KEYGEN_S_NTT: begin
                                if (vector_index < 2'd2) begin
                                    vector_index <= vector_index + 2'd1;
                                    state <= S_START_NTT;
                                end else begin
                                    active_phase <= PH_KEYGEN_E_NTT;
                                    vector_index <= 2'd0;
                                    state <= S_START_NTT;
                                end
                            end

                            PH_KEYGEN_E_NTT: begin
                                if (vector_index < 2'd2) begin
                                    vector_index <= vector_index + 2'd1;
                                    state <= S_START_NTT;
                                end else begin
                                    active_phase <= PH_DONE;
                                    terminal_cause <= CAUSE_NONE;
                                    error <= 1'b0;
                                    state <= S_DONE;
                                end
                            end

                            PH_ENCAPS_R_NTT: begin
                                if (vector_index < 2'd2) begin
                                    vector_index <= vector_index + 2'd1;
                                    state <= S_START_NTT;
                                end else begin
                                    active_phase <= PH_ENCAPS_U_INTT;
                                    vector_index <= 2'd0;
                                    state <= S_START_NTT;
                                end
                            end

                            PH_ENCAPS_U_INTT: begin
                                if (vector_index < 2'd2) begin
                                    vector_index <= vector_index + 2'd1;
                                    state <= S_START_NTT;
                                end else begin
                                    active_phase <= PH_COMPRESS;
                                    active_subblock <= SB_COMPRESS;
                                    state <= S_START_SUBBLOCK;
                                end
                            end

                            PH_DECAPS_U_NTT: begin
                                if (vector_index < 2'd2) begin
                                    vector_index <= vector_index + 2'd1;
                                    state <= S_START_NTT;
                                end else begin
                                    active_phase <= PH_DECAPS_M_INTT;
                                    vector_index <= 2'd0;
                                    state <= S_START_NTT;
                                end
                            end

                            PH_DECAPS_M_INTT: begin
                                active_phase <= PH_COMPRESS;
                                active_subblock <= SB_COMPRESS;
                                state <= S_START_SUBBLOCK;
                            end

                            default: begin
                                active_phase <= PH_ERROR;
                                terminal_cause <= CAUSE_INTERNAL;
                                error <= 1'b1;
                                state <= S_DONE;
                            end
                        endcase
                    end
                end
            end

            S_DONE: begin
                done <= 1'b1;
                state <= S_IDLE;
            end

            default: begin
                active_phase <= PH_ERROR;
                terminal_cause <= CAUSE_INTERNAL;
                error <= 1'b1;
                state <= S_DONE;
            end
        endcase
    end
end

endmodule
