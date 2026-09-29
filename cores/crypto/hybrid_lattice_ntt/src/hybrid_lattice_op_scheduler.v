module hybrid_lattice_op_scheduler (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [2:0]  op_code,
    output wire        ready,
    output wire        busy,
    output wire        done,
    output reg         error,
    output reg  [2:0]  active_op,
    output wire [31:0] digest,
    output wire [31:0] cycle_count
);

localparam [2:0] OP_KEM_NTT    = 3'd0;
localparam [2:0] OP_DSA_NTT    = 3'd1;
localparam [2:0] OP_KEM_INTT   = 3'd2;
localparam [2:0] OP_DSA_INTT   = 3'd3;
localparam [2:0] OP_KEM_FLOW   = 3'd4;
localparam [2:0] OP_DSA_FLOW   = 3'd5;
localparam [2:0] OP_HYBRID_RUN = 3'd6;
localparam [2:0] S_IDLE            = 3'd0;
localparam [2:0] S_FLOW_WAIT_FIRST = 3'd2;
localparam [2:0] S_FLOW_START_INTT = 3'd3;
localparam [2:0] S_FLOW_WAIT_INTT  = 3'd4;

localparam [31:0] KEM_FLOW_TAG = 32'h4b464c57;
localparam [31:0] DSA_FLOW_TAG = 32'h44464c57;

wire op_is_supported_ntt = (op_code == OP_KEM_NTT) || (op_code == OP_DSA_NTT) ||
                            (op_code == OP_KEM_INTT) || (op_code == OP_DSA_INTT);
wire op_is_supported_flow = (op_code == OP_KEM_FLOW) || (op_code == OP_DSA_FLOW);
reg [2:0] state;
reg flow_core_start;
reg flow_mode_dsa;
reg flow_inverse;
wire core_busy;
wire core_done;
wire [31:0] core_digest;
wire [31:0] core_cycle_count;
reg done_reg;
reg [31:0] result_digest;
reg [31:0] result_cycle_count;
reg [31:0] flow_digest;
reg [31:0] flow_cycle_count;
wire direct_core_start = start && ready && op_is_supported_ntt;
wire core_start = direct_core_start || flow_core_start;
wire core_mode_dsa = direct_core_start
    ? ((op_code == OP_DSA_NTT) || (op_code == OP_DSA_INTT))
    : flow_mode_dsa;
wire core_inverse = direct_core_start
    ? ((op_code == OP_KEM_INTT) || (op_code == OP_DSA_INTT))
    : flow_inverse;

assign ready = (state == S_IDLE) && !core_busy && !done_reg;
assign busy = core_busy || ((state != S_IDLE) && !done_reg);
assign done = ((state == S_IDLE) && core_done) || done_reg;
assign digest = ((state == S_IDLE) && (core_busy || core_done)) ? core_digest : result_digest;
assign cycle_count = ((state == S_IDLE) && (core_busy || core_done)) ? core_cycle_count : result_cycle_count;

ntt256_serial_core core (
    .clk(clk),
    .rst_n(rst_n),
    .start(core_start),
    .mode_dsa(core_mode_dsa),
    .inverse(core_inverse),
    .busy(core_busy),
    .done(core_done),
    .digest(core_digest),
    .cycle_count(core_cycle_count)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
        active_op <= OP_KEM_NTT;
        error <= 1'b0;
        flow_core_start <= 1'b0;
        flow_mode_dsa <= 1'b0;
        flow_inverse <= 1'b0;
        done_reg <= 1'b0;
        result_digest <= 32'd0;
        result_cycle_count <= 32'd0;
        flow_digest <= 32'd0;
        flow_cycle_count <= 32'd0;
    end else begin
        flow_core_start <= 1'b0;
        done_reg <= 1'b0;

        case (state)
            S_IDLE: begin
                if (start) begin
                    active_op <= op_code;
                    error <= !(op_is_supported_ntt || op_is_supported_flow);

                    if (op_is_supported_ntt) begin
                        state <= S_IDLE;
                    end else if (op_is_supported_flow) begin
                        flow_mode_dsa <= (op_code == OP_DSA_FLOW);
                        flow_inverse <= 1'b0;
                        flow_core_start <= 1'b1;
                        state <= S_FLOW_WAIT_FIRST;
                    end else begin
                        result_digest <= 32'd0;
                        result_cycle_count <= 32'd0;
                        done_reg <= 1'b1;
                    end
                end
            end

            S_FLOW_WAIT_FIRST: begin
                if (core_done) begin
                    flow_digest <= core_digest ^ ((active_op == OP_KEM_FLOW) ? KEM_FLOW_TAG : DSA_FLOW_TAG);
                    flow_cycle_count <= core_cycle_count;
                    state <= S_FLOW_START_INTT;
                end
            end

            S_FLOW_START_INTT: begin
                flow_mode_dsa <= (active_op == OP_DSA_FLOW);
                flow_inverse <= 1'b1;
                flow_core_start <= 1'b1;
                state <= S_FLOW_WAIT_INTT;
            end

            S_FLOW_WAIT_INTT: begin
                if (core_done) begin
                    result_digest <= flow_digest ^ core_digest;
                    result_cycle_count <= flow_cycle_count + core_cycle_count;
                    error <= 1'b0;
                    done_reg <= 1'b1;
                    state <= S_IDLE;
                end
            end

            default: begin
                error <= 1'b1;
                result_digest <= 32'd0;
                result_cycle_count <= 32'd0;
                done_reg <= 1'b1;
                state <= S_IDLE;
            end
        endcase
    end
end

endmodule
