// Original implementation; algorithm reference and license are in SOURCES.md.
module descriptor_drr_scheduler #(
    parameter integer FLOWS = 4,
    parameter integer DEPTH = 8,
    parameter integer COST_W = 12,
    parameter integer DATA_W = 32,
    parameter integer TAG_W = 8,
    parameter integer DEFAULT_QUANTUM = 64,
    parameter integer PW = (DEPTH <= 1 ? 1 : $clog2(DEPTH)),
    parameter integer CW = (DEPTH <= 1 ? 1 : $clog2(DEPTH+1))
) (
    input wire clk, input wire rst, input wire run_enable,
    input wire cmd_valid, output wire cmd_ready,
    input wire [1:0] cmd_op, input wire [31:0] cmd_flow,
    input wire [COST_W-1:0] cmd_cost,
    input wire [DATA_W-1:0] cmd_data, input wire [TAG_W-1:0] cmd_tag,
    output reg rsp_valid, input wire rsp_ready,
    output reg [2:0] rsp_status, output reg [31:0] rsp_flow,
    output reg [TAG_W-1:0] rsp_tag, output reg [CW-1:0] rsp_count,
    output reg [COST_W-1:0] rsp_quantum,
    output reg [COST_W:0] rsp_deficit,
    output wire m_valid, input wire m_ready,
    output wire [31:0] m_flow, output wire [COST_W-1:0] m_cost,
    output wire [DATA_W-1:0] m_data, output wire [TAG_W-1:0] m_tag
);
    localparam integer FW = (FLOWS <= 1 ? 1 : $clog2(FLOWS));
    localparam integer RW = COST_W + DATA_W + TAG_W;
    localparam [2:0] OK=0, BAD_OP=1, BAD_FLOW=2, ZERO_COST=3,
                     FULL=4, BUSY=5, ZERO_QUANTUM=6;
    localparam [1:0] VISIT=0, READ_HEAD=1, CHECK_HEAD=2, HOLD=3;
    generate if (FLOWS < 1 || FLOWS > 16 || DEPTH < 1 || DEPTH > 32 ||
                 COST_W < 1 || COST_W > 16 || DATA_W < 1 || DATA_W > 64 ||
                 TAG_W < 1 || TAG_W > 32 || DEFAULT_QUANTUM < 1 ||
                 DEFAULT_QUANTUM > ((64'd1 << COST_W)-1) ||
                 PW != (DEPTH <= 1 ? 1 : $clog2(DEPTH)) ||
                 CW != (DEPTH <= 1 ? 1 : $clog2(DEPTH+1))) begin: invalid
        descriptor_drr_scheduler_invalid_parameters__see_README invalid_parameters();
    end endgenerate

    reg [RW-1:0] memory [0:FLOWS*DEPTH-1];
    reg [PW-1:0] head [0:FLOWS-1], tail [0:FLOWS-1];
    reg [CW-1:0] count [0:FLOWS-1];
    reg [COST_W-1:0] quantum [0:FLOWS-1];
    reg [COST_W:0] deficit [0:FLOWS-1];
    reg [FW-1:0] cursor;
    reg [1:0] state;
    reg [RW-1:0] head_word;
    reg [2:0] command_status;
    wire command_flow_ok = cmd_flow < FLOWS;
    wire [FW-1:0] command_index = cmd_flow[FW-1:0];
    wire command_fire = cmd_valid && cmd_ready;
    wire enqueue_fire = command_fire && command_status == OK && cmd_op == 0;
    wire configure_fire = command_fire && command_status == OK && cmd_op == 1;
    wire retire = m_valid && m_ready;
    wire same_enqueue = enqueue_fire && command_index == cursor;
    wire [COST_W-1:0] head_cost = head_word[RW-1 -: COST_W];

    function automatic [PW-1:0] next_pointer(input [PW-1:0] pointer);
        next_pointer = pointer == DEPTH-1 ? {PW{1'b0}} : pointer + 1'b1;
    endfunction
    function automatic [FW-1:0] next_flow(input [FW-1:0] flow);
        next_flow = flow == FLOWS-1 ? {FW{1'b0}} : flow + 1'b1;
    endfunction

    // The full supplied index is checked before every dynamic array access.
    always @* begin
        command_status = OK;
        if (cmd_op == 3) command_status = BAD_OP;
        else if (!command_flow_ok) command_status = BAD_FLOW;
        else begin
            case (cmd_op)
                0: if (cmd_cost == 0) command_status = ZERO_COST;
                   else if (count[command_index] == DEPTH) command_status = FULL;
                1: if (cmd_cost == 0) command_status = ZERO_QUANTUM;
                   else if (count[command_index] != 0) command_status = BUSY;
                default: command_status = OK;
            endcase
        end
    end
    assign cmd_ready = !rst && !rsp_valid;
    assign m_valid = !rst && state == HOLD;
    assign m_flow = {{(32-FW){1'b0}}, cursor};
    assign m_cost = head_cost;
    assign m_data = head_word[TAG_W +: DATA_W];
    assign m_tag = head_word[TAG_W-1:0];

    // One synchronous write port and one synchronous read port. A descriptor
    // remains in its slot through output retirement. Therefore an enqueue's
    // write slot cannot equal a simultaneous head read slot: full queues reject
    // admission, and an empty-to-nonempty edge cannot launch a head read.
    always @(posedge clk) begin
        if (!rst) begin
            if (enqueue_fire)
                memory[command_index*DEPTH + tail[command_index]] <=
                    {cmd_cost, cmd_data, cmd_tag};
            if (run_enable && state == READ_HEAD)
                head_word <= memory[cursor*DEPTH + head[cursor]];
        end
    end

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            rsp_valid <= 0; rsp_status <= 0; rsp_flow <= 0; rsp_tag <= 0;
            rsp_count <= 0; rsp_quantum <= 0; rsp_deficit <= 0;
            cursor <= 0; state <= VISIT;
            for (i=0; i<FLOWS; i=i+1) begin
                head[i] <= 0; tail[i] <= 0; count[i] <= 0;
                quantum[i] <= DEFAULT_QUANTUM; deficit[i] <= 0;
            end
        end else begin
            if (rsp_valid && rsp_ready) rsp_valid <= 0;
            if (command_fire) begin
                rsp_valid <= 1; rsp_status <= command_status;
                rsp_flow <= cmd_flow; rsp_tag <= cmd_tag;
                rsp_count <= 0; rsp_quantum <= 0; rsp_deficit <= 0;
                if (command_flow_ok) begin
                    rsp_count <= count[command_index];
                    rsp_quantum <= quantum[command_index];
                    rsp_deficit <= deficit[command_index];
                end
                if (enqueue_fire)
                    tail[command_index] <= next_pointer(tail[command_index]);
                if (configure_fire) begin
                    quantum[command_index] <= cmd_cost;
                    deficit[command_index] <= 0;
                end
            end

            for (i=0; i<FLOWS; i=i+1) begin
                case ({enqueue_fire && command_index == i, retire && cursor == i})
                    2'b10: count[i] <= count[i] + 1'b1;
                    2'b01: count[i] <= count[i] - 1'b1;
                    default: count[i] <= count[i];
                endcase
            end

            if (state == HOLD) begin
                if (retire) begin
                    head[cursor] <= next_pointer(head[cursor]);
                    if (count[cursor] == 1 && !same_enqueue) begin
                        deficit[cursor] <= 0;
                        cursor <= next_flow(cursor); state <= VISIT;
                    end else begin
                        deficit[cursor] <= deficit[cursor] - {1'b0, head_cost};
                        state <= READ_HEAD;
                    end
                end
            end else if (run_enable) begin
                case (state)
                    VISIT: begin
                        if (count[cursor] == 0) begin
                            deficit[cursor] <= 0;
                            cursor <= next_flow(cursor);
                        end else begin
                            // Initial/empty activation starts at zero. Every
                            // retained visit ended at D < its unchanged head
                            // cost, so D+Q needs exactly COST_W+1 bits.
                            deficit[cursor] <= deficit[cursor] + {1'b0, quantum[cursor]};
                            state <= READ_HEAD;
                        end
                    end
                    READ_HEAD: state <= CHECK_HEAD;
                    CHECK_HEAD: begin
                        if ({1'b0, head_cost} <= deficit[cursor]) state <= HOLD;
                        else begin cursor <= next_flow(cursor); state <= VISIT; end
                    end
                    default: state <= VISIT;
                endcase
            end
        end
    end
endmodule
