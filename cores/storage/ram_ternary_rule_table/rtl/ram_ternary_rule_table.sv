// SPDX-License-Identifier: Apache-2.0
// Indexed arbitrary-care rules, one synchronous packed RAM port and one matcher.
module ram_ternary_rule_table #(
    parameter integer SLOTS = 16,
    parameter integer KEY_W = 32,
    parameter integer ACTION_W = 16,
    parameter integer TAG_W = 8
) (
    input wire clk, input wire rst,
    input wire c_valid, output wire c_ready,
    input wire [2:0] c_op, input wire [31:0] c_slot,
    input wire [KEY_W-1:0] c_value, input wire [KEY_W-1:0] c_care,
    input wire [ACTION_W-1:0] c_action, input wire [TAG_W-1:0] c_tag,
    output wire m_valid, input wire m_ready,
    output wire [2:0] m_op, output wire [2:0] m_status,
    output wire [TAG_W-1:0] m_tag,
    output wire [$clog2(SLOTS+1)-1:0] m_live_count,
    output wire m_found, output wire [SLOTS-1:0] m_match_mask,
    output wire [$clog2(SLOTS+1)-1:0] m_match_count,
    output wire [31:0] m_slot,
    output wire [KEY_W-1:0] m_pattern, output wire [KEY_W-1:0] m_care,
    output wire [ACTION_W-1:0] m_action
);
    localparam integer IW = SLOTS > 1 ? $clog2(SLOTS) : 1;
    localparam integer CW = SLOTS > 0 ? $clog2(SLOTS+1) : 1;
    localparam integer RW = 2*KEY_W+ACTION_W;
    localparam [3:0] IDLE=0, VALIDATE=1, WRITE=2, READ=3, MATCH=4, FINISH=5, HOLD=6;
    localparam [2:0] QUERY=0, SET=1, DELETE=2, GET=3, CLEAR=4, STATUS=5;
    localparam [2:0] OK=0, MISS=1, BAD_SLOT=2, BAD_OP=3, NOT_LIVE=4;

    generate if (SLOTS < 1 || SLOTS > 64 || KEY_W < 1 || KEY_W > 128 ||
                 ACTION_W < 1 || ACTION_W > 64 || TAG_W < 1 || TAG_W > 32) begin: invalid
        ram_ternary_rule_table_invalid_parameters__see_README invalid_parameters();
    end endgenerate

    reg [RW-1:0] payload [0:SLOTS-1];
    reg [RW-1:0] read_q;
    reg [RW-1:0] cmd_q;
    reg [SLOTS-1:0] live_q;
    reg [SLOTS-1:0] match_q;
    reg [ACTION_W-1:0] best_action_q;
    reg [IW-1:0] scan_q, winner_q;
    reg [CW-1:0] live_count_q, match_count_q;
    reg [TAG_W-1:0] tag_q;
    reg [31:0] slot_q;
    reg [2:0] op_q, status_q;
    reg [3:0] state_q;
    reg valid_q;

    wire [KEY_W-1:0] cmd_value = cmd_q[RW-1 -: KEY_W];
    wire [KEY_W-1:0] read_pattern = read_q[RW-1 -: KEY_W];
    wire [KEY_W-1:0] read_care = read_q[ACTION_W +: KEY_W];
    wire [IW-1:0] port_addr = op_q == QUERY ? scan_q : slot_q[IW-1:0];
    wire port_write = !rst && state_q == WRITE;
    wire port_read = !rst && state_q == READ && live_q[port_addr];
    wire row_hit = live_q[scan_q] && (((read_pattern ^ cmd_value) & read_care) == {KEY_W{1'b0}});

    // Payload and synchronous read register deliberately have no reset.
    // WRITE and READ are disjoint states: a single address/control port.
    always @(posedge clk) begin
        if (port_write) payload[port_addr] <= cmd_q;
        else if (port_read) read_q <= payload[port_addr];
    end

    assign c_ready = !rst && state_q == IDLE;
    assign m_valid = !rst && valid_q;
    assign m_op = op_q;
    assign m_status = status_q;
    assign m_tag = tag_q;
    assign m_live_count = live_count_q;
    assign m_found = status_q == OK &&
                     (op_q == SET || op_q == GET || (op_q == QUERY && match_count_q != 0));
    assign m_match_mask = op_q == QUERY ? match_q : {SLOTS{1'b0}};
    assign m_match_count = op_q == QUERY ? match_count_q : {CW{1'b0}};
    assign m_slot = !m_found ? 32'b0 : op_q == QUERY ? {{(32-IW){1'b0}},winner_q} : slot_q;
    assign m_pattern = !m_found ? {KEY_W{1'b0}} :
                       op_q == SET ? cmd_value : op_q == GET ? read_pattern : {KEY_W{1'b0}};
    assign m_care = !m_found ? {KEY_W{1'b0}} : op_q == SET ? cmd_q[ACTION_W +: KEY_W] :
                    op_q == GET ? read_care : {KEY_W{1'b0}};
    assign m_action = !m_found ? {ACTION_W{1'b0}} : op_q == QUERY ? best_action_q :
                      op_q == SET ? cmd_q[ACTION_W-1:0] : read_q[ACTION_W-1:0];

    always @(posedge clk) begin
        if (rst) begin
            cmd_q <= 0; live_q <= 0; match_q <= 0; best_action_q <= 0;
            scan_q <= 0; winner_q <= 0; live_count_q <= 0; match_count_q <= 0;
            tag_q <= 0; slot_q <= 0; op_q <= 0; status_q <= OK;
            state_q <= IDLE; valid_q <= 0;
        end else begin
            case (state_q)
                IDLE: if (c_valid) begin
                    op_q <= c_op; slot_q <= c_slot; tag_q <= c_tag;
                    cmd_q <= {c_op == SET ? (c_value & c_care) : c_value, c_care, c_action};
                    match_q <= 0; match_count_q <= 0; winner_q <= 0; best_action_q <= 0;
                    status_q <= OK; state_q <= VALIDATE;
                end
                VALIDATE: begin
                    if (op_q > STATUS) begin
                        status_q <= BAD_OP; valid_q <= 1; state_q <= HOLD;
                    end else if ((op_q == SET || op_q == DELETE || op_q == GET) && slot_q >= SLOTS) begin
                        status_q <= BAD_SLOT; valid_q <= 1; state_q <= HOLD;
                    end else case (op_q)
                        QUERY: begin scan_q <= 0; state_q <= READ; end
                        SET: state_q <= WRITE;
                        DELETE: begin
                            if (live_q[slot_q[IW-1:0]]) begin
                                live_q[slot_q[IW-1:0]] <= 0;
                                live_count_q <= live_count_q - 1'b1;
                            end else status_q <= NOT_LIVE;
                            valid_q <= 1; state_q <= HOLD;
                        end
                        GET: if (live_q[slot_q[IW-1:0]]) state_q <= READ;
                             else begin status_q <= NOT_LIVE; valid_q <= 1; state_q <= HOLD; end
                        CLEAR: begin live_q <= 0; live_count_q <= 0; valid_q <= 1; state_q <= HOLD; end
                        STATUS: begin valid_q <= 1; state_q <= HOLD; end
                        default: begin status_q <= BAD_OP; valid_q <= 1; state_q <= HOLD; end
                    endcase
                end
                WRITE: begin
                    if (!live_q[slot_q[IW-1:0]]) live_count_q <= live_count_q + 1'b1;
                    live_q[slot_q[IW-1:0]] <= 1; valid_q <= 1; state_q <= HOLD;
                end
                READ: state_q <= op_q == QUERY ? MATCH : FINISH;
                MATCH: begin
                    if (row_hit) begin
                        match_q[scan_q] <= 1; match_count_q <= match_count_q + 1'b1;
                        if (match_count_q == 0) begin
                            winner_q <= scan_q; best_action_q <= read_q[ACTION_W-1:0];
                        end
                    end
                    if (scan_q == SLOTS-1) begin
                        status_q <= (match_count_q != 0 || row_hit) ? OK : MISS;
                        state_q <= FINISH;
                    end else begin scan_q <= scan_q + 1'b1; state_q <= READ; end
                end
                FINISH: begin valid_q <= 1; state_q <= HOLD; end
                HOLD: if (m_ready) begin valid_q <= 0; state_q <= IDLE; end
                default: begin valid_q <= 0; state_q <= IDLE; end
            endcase
        end
    end
endmodule
