module hybrid_ntt256_selftest (
    input  wire        clk,
    input  wire        rst_n,
    output reg         test_done,
    output reg         test_pass,
    output reg         test_fail,
    output reg  [1:0]  phase,
    output reg  [31:0] cycle_count,
    output reg  [31:0] digest,
    output reg  [31:0] kem_ntt_digest,
    output reg  [31:0] dsa_ntt_digest,
    output reg  [31:0] kem_intt_digest,
    output reg  [31:0] dsa_intt_digest,
    output reg  [31:0] kem_flow_digest,
    output reg  [31:0] dsa_flow_digest
);

localparam [3:0] S_START_KEM_NTT  = 4'd0;
localparam [3:0] S_WAIT_KEM_NTT   = 4'd1;
localparam [3:0] S_START_DSA_NTT  = 4'd2;
localparam [3:0] S_WAIT_DSA_NTT   = 4'd3;
localparam [3:0] S_START_KEM_INTT = 4'd4;
localparam [3:0] S_WAIT_KEM_INTT  = 4'd5;
localparam [3:0] S_START_DSA_INTT = 4'd6;
localparam [3:0] S_WAIT_DSA_INTT  = 4'd7;
localparam [3:0] S_START_KEM_FLOW = 4'd8;
localparam [3:0] S_WAIT_KEM_FLOW  = 4'd9;
localparam [3:0] S_START_DSA_FLOW = 4'd10;
localparam [3:0] S_WAIT_DSA_FLOW  = 4'd11;
localparam [3:0] S_DONE           = 4'd12;
localparam [2:0] OP_KEM_NTT       = 3'd0;
localparam [2:0] OP_DSA_NTT       = 3'd1;
localparam [2:0] OP_KEM_INTT      = 3'd2;
localparam [2:0] OP_DSA_INTT      = 3'd3;
localparam [2:0] OP_KEM_FLOW      = 3'd4;
localparam [2:0] OP_DSA_FLOW      = 3'd5;

reg [3:0] state;
reg op_start;
reg [2:0] op_code;
wire op_ready;
wire op_busy;
wire op_done;
wire op_error;
wire [2:0] active_op;
wire [31:0] op_digest;
wire [31:0] op_cycle_count;
reg [31:0] elapsed_cycles;

hybrid_lattice_op_scheduler scheduler (
    .clk(clk),
    .rst_n(rst_n),
    .start(op_start),
    .op_code(op_code),
    .ready(op_ready),
    .busy(op_busy),
    .done(op_done),
    .error(op_error),
    .active_op(active_op),
    .digest(op_digest),
    .cycle_count(op_cycle_count)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_START_KEM_NTT;
        op_start <= 1'b0;
        op_code <= OP_KEM_NTT;
        test_done <= 1'b0;
        test_pass <= 1'b0;
        test_fail <= 1'b0;
        phase <= 2'd0;
        cycle_count <= 32'd0;
        digest <= 32'd0;
        kem_ntt_digest <= 32'd0;
        dsa_ntt_digest <= 32'd0;
        kem_intt_digest <= 32'd0;
        dsa_intt_digest <= 32'd0;
        kem_flow_digest <= 32'd0;
        dsa_flow_digest <= 32'd0;
        elapsed_cycles <= 32'd0;
    end else begin
        op_start <= 1'b0;

        if (!test_done) begin
            elapsed_cycles <= elapsed_cycles + 32'd1;
        end

        case (state)
            S_START_KEM_NTT: begin
                phase <= 2'd0;
                op_code <= OP_KEM_NTT;
                op_start <= 1'b1;
                state <= S_WAIT_KEM_NTT;
            end

            S_WAIT_KEM_NTT: begin
                if (op_done) begin
                    kem_ntt_digest <= op_digest;
                    if (op_error || (op_digest != 32'h1e664367)) begin
                        test_fail <= 1'b1;
                    end
                    state <= S_START_DSA_NTT;
                end
            end

            S_START_DSA_NTT: begin
                phase <= 2'd1;
                op_code <= OP_DSA_NTT;
                op_start <= 1'b1;
                state <= S_WAIT_DSA_NTT;
            end

            S_WAIT_DSA_NTT: begin
                if (op_done) begin
                    dsa_ntt_digest <= op_digest;
                    digest <= kem_ntt_digest ^ op_digest ^ 32'h4e323536;
                    cycle_count <= elapsed_cycles + 32'd1;
                    if (op_error || (op_digest != 32'h7fc8e2fc)) begin
                        test_fail <= 1'b1;
                    end
                    state <= S_START_KEM_INTT;
                end
            end

            S_START_KEM_INTT: begin
                phase <= 2'd2;
                op_code <= OP_KEM_INTT;
                op_start <= 1'b1;
                state <= S_WAIT_KEM_INTT;
            end

            S_WAIT_KEM_INTT: begin
                if (op_done) begin
                    kem_intt_digest <= op_digest;
                    if (op_error || (op_digest != 32'hb88a6c64)) begin
                        test_fail <= 1'b1;
                    end
                    state <= S_START_DSA_INTT;
                end
            end

            S_START_DSA_INTT: begin
                phase <= 2'd3;
                op_code <= OP_DSA_INTT;
                op_start <= 1'b1;
                state <= S_WAIT_DSA_INTT;
            end

            S_WAIT_DSA_INTT: begin
                if (op_done) begin
                    dsa_intt_digest <= op_digest;
                    if (op_error || (op_digest != 32'hd23ecef9)) begin
                        test_fail <= 1'b1;
                    end
                    state <= S_START_KEM_FLOW;
                end
            end

            S_START_KEM_FLOW: begin
                phase <= 2'd0;
                op_code <= OP_KEM_FLOW;
                op_start <= 1'b1;
                state <= S_WAIT_KEM_FLOW;
            end

            S_WAIT_KEM_FLOW: begin
                if (op_done) begin
                    kem_flow_digest <= op_digest;
                    if (op_error || (op_digest != 32'hedaa6354)) begin
                        test_fail <= 1'b1;
                    end
                    state <= S_START_DSA_FLOW;
                end
            end

            S_START_DSA_FLOW: begin
                phase <= 2'd1;
                op_code <= OP_DSA_FLOW;
                op_start <= 1'b1;
                state <= S_WAIT_DSA_FLOW;
            end

            S_WAIT_DSA_FLOW: begin
                if (op_done) begin
                    dsa_flow_digest <= op_digest;
                    if (op_error || (op_digest != 32'he9b06052)) begin
                        test_fail <= 1'b1;
                    end
                    test_done <= 1'b1;
                    test_pass <= !test_fail &&
                        (kem_ntt_digest == 32'h1e664367) &&
                        (dsa_ntt_digest == 32'h7fc8e2fc) &&
                        (kem_intt_digest == 32'hb88a6c64) &&
                        (dsa_intt_digest == 32'hd23ecef9) &&
                        (kem_flow_digest == 32'hedaa6354) &&
                        (op_digest == 32'he9b06052) &&
                        !op_error;
                    state <= S_DONE;
                end
            end

            S_DONE: begin
                test_done <= 1'b1;
                test_pass <= !test_fail &&
                    (kem_ntt_digest == 32'h1e664367) &&
                    (dsa_ntt_digest == 32'h7fc8e2fc) &&
                    (kem_intt_digest == 32'hb88a6c64) &&
                    (dsa_intt_digest == 32'hd23ecef9) &&
                    (kem_flow_digest == 32'hedaa6354) &&
                    (dsa_flow_digest == 32'he9b06052);
            end

            default: state <= S_START_KEM_NTT;
        endcase
    end
end

endmodule
