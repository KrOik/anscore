module mldsa44_flow_scheduler (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [1:0]  flow_op,
    output wire        ready,
    output reg         busy,
    output reg         done,
    output reg         error,
    output reg  [1:0]  active_flow,
    output reg  [7:0]  phase,
    output reg  [3:0]  k_index,
    output reg  [3:0]  l_index,
    output reg         engine_start,
    output reg  [2:0]  engine_op,
    output wire        engine_mode_dsa,
    output wire        engine_inverse,
    output wire [22:0] engine_q,
    input  wire        engine_ready,
    input  wire        engine_done,
    output wire        shake_request,
    input  wire        shake_done,
    output wire        expand_request,
    input  wire        expand_done,
    output wire        sample_request,
    input  wire        sample_done,
    output wire        mac_request,
    input  wire        mac_done,
    output wire        decompose_request,
    input  wire        decompose_done,
    output wire        hint_request,
    input  wire        hint_done,
    output wire        pack_request,
    input  wire        pack_done,
    output reg  [15:0] ntt_issue_count,
    output reg  [15:0] intt_issue_count,
    output reg  [15:0] mac_issue_count,
    output reg  [15:0] stub_request_count,
    output reg  [31:0] schedule_digest,
    output reg  [15:0] terminal_error_cause
);

localparam [1:0] FLOW_KEYGEN = 2'd0;
localparam [1:0] FLOW_SIGN   = 2'd1;
localparam [1:0] FLOW_VERIFY = 2'd2;

localparam [2:0] OP_DSA_NTT    = 3'd1;
localparam [2:0] OP_DSA_INTT   = 3'd3;
localparam [2:0] OP_DSA_FLOW   = 3'd5;

localparam [7:0] P_IDLE          = 8'd0;
localparam [7:0] P_KEY_SHAKE     = 8'd1;
localparam [7:0] P_KEY_EXPAND    = 8'd2;
localparam [7:0] P_KEY_SAMPLE    = 8'd3;
localparam [7:0] P_KEY_NTT_L     = 8'd4;
localparam [7:0] P_KEY_NTT_K     = 8'd5;
localparam [7:0] P_KEY_PACK      = 8'd6;
localparam [7:0] P_SIGN_SHAKE    = 8'd16;
localparam [7:0] P_SIGN_SAMPLE   = 8'd17;
localparam [7:0] P_SIGN_NTT_L    = 8'd18;
localparam [7:0] P_SIGN_MAC_K    = 8'd19;
localparam [7:0] P_SIGN_INTT_K   = 8'd20;
localparam [7:0] P_SIGN_DECOMP_K = 8'd21;
localparam [7:0] P_SIGN_HINT_K   = 8'd22;
localparam [7:0] P_SIGN_PACK     = 8'd23;
localparam [7:0] P_VER_SHAKE     = 8'd32;
localparam [7:0] P_VER_EXPAND    = 8'd33;
localparam [7:0] P_VER_NTT_L     = 8'd34;
localparam [7:0] P_VER_MAC_K     = 8'd35;
localparam [7:0] P_VER_INTT_K    = 8'd36;
localparam [7:0] P_VER_DECOMP_K  = 8'd37;
localparam [7:0] P_VER_HINT_K    = 8'd38;

localparam [15:0] ERR_BAD_FLOW        = 16'h0001;
localparam [15:0] ERR_LEGACY_ALIAS    = 16'h0002;
localparam [15:0] ERR_ENGINE_BAD_OP   = 16'h0004;
localparam [15:0] ERR_KEM_PATH        = 16'h0008;

reg engine_waiting;
reg [3:0] loop_index;
reg [15:0] sample_total_count;

assign ready = !busy && !done;
assign engine_mode_dsa = 1'b1;
assign engine_inverse = (engine_op == OP_DSA_INTT);
assign engine_q = 23'd8380417;
assign shake_request = busy &&
    ((phase == P_KEY_SHAKE) || (phase == P_SIGN_SHAKE) ||
     (phase == P_VER_SHAKE));
assign expand_request = busy &&
    ((phase == P_KEY_EXPAND) || (phase == P_VER_EXPAND));
assign sample_request = busy &&
    ((phase == P_KEY_SAMPLE) || (phase == P_SIGN_SAMPLE));
assign mac_request = busy &&
    ((phase == P_SIGN_MAC_K) || (phase == P_VER_MAC_K));
assign decompose_request = busy &&
    ((phase == P_SIGN_DECOMP_K) || (phase == P_VER_DECOMP_K));
assign hint_request = busy &&
    ((phase == P_SIGN_HINT_K) || (phase == P_VER_HINT_K));
assign pack_request = busy &&
    ((phase == P_KEY_PACK) || (phase == P_SIGN_PACK));

function [31:0] rotl5;
    input [31:0] value;
    begin
        rotl5 = {value[26:0], value[31:27]};
    end
endfunction

function valid_flow;
    input [1:0] op;
    begin
        valid_flow = (op == FLOW_KEYGEN) || (op == FLOW_SIGN) ||
            (op == FLOW_VERIFY);
    end
endfunction

function [7:0] first_phase_for;
    input [1:0] op;
    begin
        case (op)
            FLOW_KEYGEN: first_phase_for = P_KEY_SHAKE;
            FLOW_SIGN:   first_phase_for = P_SIGN_SHAKE;
            default:     first_phase_for = P_VER_SHAKE;
        endcase
    end
endfunction

task mark_stub_complete;
    input [7:0] current_phase;
    input [3:0] index_value;
    begin
        stub_request_count <= stub_request_count + 16'd1;
        schedule_digest <= rotl5(schedule_digest) ^
            {8'h44, current_phase, 4'd0, index_value, active_flow, 6'd0};
    end
endtask

task finish_flow;
    begin
        busy <= 1'b0;
        done <= 1'b1;
        phase <= P_IDLE;
        loop_index <= 4'd0;
        k_index <= 4'd0;
        l_index <= 4'd0;
    end
endtask

task advance_loop_or_phase;
    input [3:0] limit_value;
    input [7:0] next_phase;
    begin
        if (loop_index == (limit_value - 4'd1)) begin
            loop_index <= 4'd0;
            phase <= next_phase;
        end else begin
            loop_index <= loop_index + 4'd1;
        end
    end
endtask

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        engine_waiting <= 1'b0;
        loop_index <= 4'd0;
        sample_total_count <= 16'd0;
        busy <= 1'b0;
        done <= 1'b0;
        error <= 1'b0;
        active_flow <= FLOW_KEYGEN;
        phase <= P_IDLE;
        k_index <= 4'd0;
        l_index <= 4'd0;
        engine_start <= 1'b0;
        engine_op <= OP_DSA_NTT;
        ntt_issue_count <= 16'd0;
        intt_issue_count <= 16'd0;
        mac_issue_count <= 16'd0;
        stub_request_count <= 16'd0;
        schedule_digest <= 32'h4d445341;
        terminal_error_cause <= 16'd0;
    end else begin
        done <= 1'b0;
        engine_start <= 1'b0;

        if (ready && start) begin
            active_flow <= flow_op;
            error <= !valid_flow(flow_op);
            terminal_error_cause <= valid_flow(flow_op) ? 16'd0 : ERR_BAD_FLOW;
            phase <= first_phase_for(flow_op);
            loop_index <= 4'd0;
            k_index <= 4'd0;
            l_index <= 4'd0;
            engine_waiting <= 1'b0;
            ntt_issue_count <= 16'd0;
            intt_issue_count <= 16'd0;
            mac_issue_count <= 16'd0;
            stub_request_count <= 16'd0;
            sample_total_count <= 16'd0;
            schedule_digest <= 32'h4d445341 ^ {30'd0, flow_op};

            if (valid_flow(flow_op)) begin
                busy <= 1'b1;
            end else begin
                busy <= 1'b0;
                done <= 1'b1;
            end
        end else if (busy) begin
            case (phase)
                P_KEY_SHAKE: begin
                    if (shake_done) begin
                        mark_stub_complete(phase, 4'd0);
                        phase <= P_KEY_EXPAND;
                    end
                end

                P_KEY_EXPAND: begin
                    if (expand_done) begin
                        mark_stub_complete(phase, 4'd0);
                        phase <= P_KEY_SAMPLE;
                    end
                end

                P_KEY_SAMPLE: begin
                    if (sample_done) begin
                        mark_stub_complete(phase, loop_index);
                        sample_total_count <= sample_total_count + 16'd1;
                        advance_loop_or_phase(4'd8, P_KEY_NTT_L);
                    end
                end

                P_KEY_NTT_L: begin
                    l_index <= loop_index;
                    engine_op <= OP_DSA_NTT;
                    if (!engine_waiting) begin
                        if (engine_ready) begin
                            engine_start <= 1'b1;
                            engine_waiting <= 1'b1;
                            ntt_issue_count <= ntt_issue_count + 16'd1;
                        end
                    end else if (engine_done) begin
                        engine_waiting <= 1'b0;
                        schedule_digest <= rotl5(schedule_digest) ^
                            {8'h4e, phase, 4'd0, loop_index, 8'd0};
                        advance_loop_or_phase(4'd4, P_KEY_NTT_K);
                    end
                end

                P_KEY_NTT_K: begin
                    k_index <= loop_index;
                    engine_op <= OP_DSA_NTT;
                    if (!engine_waiting) begin
                        if (engine_ready) begin
                            engine_start <= 1'b1;
                            engine_waiting <= 1'b1;
                            ntt_issue_count <= ntt_issue_count + 16'd1;
                        end
                    end else if (engine_done) begin
                        engine_waiting <= 1'b0;
                        schedule_digest <= rotl5(schedule_digest) ^
                            {8'h4e, phase, 4'd0, loop_index, 8'd0};
                        advance_loop_or_phase(4'd4, P_KEY_PACK);
                    end
                end

                P_KEY_PACK: begin
                    if (pack_done) begin
                        mark_stub_complete(phase, 4'd0);
                        finish_flow();
                    end
                end

                P_SIGN_SHAKE: begin
                    if (shake_done) begin
                        mark_stub_complete(phase, 4'd0);
                        phase <= P_SIGN_SAMPLE;
                    end
                end

                P_SIGN_SAMPLE: begin
                    if (sample_done) begin
                        mark_stub_complete(phase, loop_index);
                        sample_total_count <= sample_total_count + 16'd1;
                        advance_loop_or_phase(4'd4, P_SIGN_NTT_L);
                    end
                end

                P_SIGN_NTT_L: begin
                    l_index <= loop_index;
                    engine_op <= OP_DSA_NTT;
                    if (!engine_waiting) begin
                        if (engine_ready) begin
                            engine_start <= 1'b1;
                            engine_waiting <= 1'b1;
                            ntt_issue_count <= ntt_issue_count + 16'd1;
                        end
                    end else if (engine_done) begin
                        engine_waiting <= 1'b0;
                        schedule_digest <= rotl5(schedule_digest) ^
                            {8'h4e, phase, 4'd0, loop_index, 8'd0};
                        advance_loop_or_phase(4'd4, P_SIGN_MAC_K);
                    end
                end

                P_SIGN_MAC_K: begin
                    k_index <= loop_index;
                    if (mac_done) begin
                        mac_issue_count <= mac_issue_count + 16'd1;
                        schedule_digest <= rotl5(schedule_digest) ^
                            {8'h4d, phase, 4'd0, loop_index, 8'd0};
                        advance_loop_or_phase(4'd4, P_SIGN_INTT_K);
                    end
                end

                P_SIGN_INTT_K: begin
                    k_index <= loop_index;
                    engine_op <= OP_DSA_INTT;
                    if (!engine_waiting) begin
                        if (engine_ready) begin
                            engine_start <= 1'b1;
                            engine_waiting <= 1'b1;
                            intt_issue_count <= intt_issue_count + 16'd1;
                        end
                    end else if (engine_done) begin
                        engine_waiting <= 1'b0;
                        schedule_digest <= rotl5(schedule_digest) ^
                            {8'h49, phase, 4'd0, loop_index, 8'd0};
                        advance_loop_or_phase(4'd4, P_SIGN_DECOMP_K);
                    end
                end

                P_SIGN_DECOMP_K: begin
                    k_index <= loop_index;
                    if (decompose_done) begin
                        mark_stub_complete(phase, loop_index);
                        advance_loop_or_phase(4'd4, P_SIGN_HINT_K);
                    end
                end

                P_SIGN_HINT_K: begin
                    k_index <= loop_index;
                    if (hint_done) begin
                        mark_stub_complete(phase, loop_index);
                        advance_loop_or_phase(4'd4, P_SIGN_PACK);
                    end
                end

                P_SIGN_PACK: begin
                    if (pack_done) begin
                        mark_stub_complete(phase, 4'd0);
                        finish_flow();
                    end
                end

                P_VER_SHAKE: begin
                    if (shake_done) begin
                        mark_stub_complete(phase, 4'd0);
                        phase <= P_VER_EXPAND;
                    end
                end

                P_VER_EXPAND: begin
                    if (expand_done) begin
                        mark_stub_complete(phase, 4'd0);
                        phase <= P_VER_NTT_L;
                    end
                end

                P_VER_NTT_L: begin
                    l_index <= loop_index;
                    engine_op <= OP_DSA_NTT;
                    if (!engine_waiting) begin
                        if (engine_ready) begin
                            engine_start <= 1'b1;
                            engine_waiting <= 1'b1;
                            ntt_issue_count <= ntt_issue_count + 16'd1;
                        end
                    end else if (engine_done) begin
                        engine_waiting <= 1'b0;
                        schedule_digest <= rotl5(schedule_digest) ^
                            {8'h4e, phase, 4'd0, loop_index, 8'd0};
                        advance_loop_or_phase(4'd4, P_VER_MAC_K);
                    end
                end

                P_VER_MAC_K: begin
                    k_index <= loop_index;
                    if (mac_done) begin
                        mac_issue_count <= mac_issue_count + 16'd1;
                        schedule_digest <= rotl5(schedule_digest) ^
                            {8'h4d, phase, 4'd0, loop_index, 8'd0};
                        advance_loop_or_phase(4'd4, P_VER_INTT_K);
                    end
                end

                P_VER_INTT_K: begin
                    k_index <= loop_index;
                    engine_op <= OP_DSA_INTT;
                    if (!engine_waiting) begin
                        if (engine_ready) begin
                            engine_start <= 1'b1;
                            engine_waiting <= 1'b1;
                            intt_issue_count <= intt_issue_count + 16'd1;
                        end
                    end else if (engine_done) begin
                        engine_waiting <= 1'b0;
                        schedule_digest <= rotl5(schedule_digest) ^
                            {8'h49, phase, 4'd0, loop_index, 8'd0};
                        advance_loop_or_phase(4'd4, P_VER_DECOMP_K);
                    end
                end

                P_VER_DECOMP_K: begin
                    k_index <= loop_index;
                    if (decompose_done) begin
                        mark_stub_complete(phase, loop_index);
                        advance_loop_or_phase(4'd4, P_VER_HINT_K);
                    end
                end

                P_VER_HINT_K: begin
                    k_index <= loop_index;
                    if (hint_done) begin
                        mark_stub_complete(phase, loop_index);
                        if (loop_index == 4'd3) begin
                            finish_flow();
                        end else begin
                            loop_index <= loop_index + 4'd1;
                        end
                    end
                end

                default: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    error <= 1'b1;
                    terminal_error_cause <= terminal_error_cause | ERR_BAD_FLOW;
                    phase <= P_IDLE;
                end
            endcase

            if (engine_start &&
                ((engine_op == OP_DSA_FLOW) ||
                 ((engine_op != OP_DSA_NTT) && (engine_op != OP_DSA_INTT)))) begin
                error <= 1'b1;
                terminal_error_cause <= terminal_error_cause |
                    ERR_LEGACY_ALIAS | ERR_ENGINE_BAD_OP;
            end
            if (engine_start && !engine_mode_dsa) begin
                error <= 1'b1;
                terminal_error_cause <= terminal_error_cause | ERR_KEM_PATH;
            end
        end
    end
end

endmodule
