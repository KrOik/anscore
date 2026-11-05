// SPDX-License-Identifier: Apache-2.0
// Original ANSCORE implementation. Canonical encoder codebook, two active banks.
module canonical_huffman_table #(
    parameter integer SYMBOLS = 256,
    parameter integer MAX_BITS = 16,
    parameter integer TAG_W = 8
)(
    input wire clk, rst,
    input wire c_valid, output wire c_ready,
    input wire [1:0] c_op,
    input wire [31:0] c_symbol, c_length,
    input wire [TAG_W-1:0] c_tag,
    output wire r_valid, input wire r_ready,
    output reg [1:0] r_op,
    output reg [2:0] r_status,
    output reg [MAX_BITS-1:0] r_code,
    output reg [31:0] r_length,
    output reg [TAG_W-1:0] r_tag
);
    localparam integer SW = (SYMBOLS <= 1) ? 1 : $clog2(SYMBOLS);
    localparam integer LW = $clog2(MAX_BITS+1);
    localparam [2:0] INIT=0, IDLE=1, CLEAR=2, INIT_BANK=3,
                     SCAN=4, ADVANCE=5, FINISH=6, RESPONSE=7;
    localparam [2:0] OK=0, BAD_SYMBOL=1, BAD_LENGTH=2,
                     BAD_TREE=3, NO_TABLE=4, ABSENT=5;
    reg [2:0] state;
    reg [SW-1:0] symbol_index;
    reg [LW-1:0] level;
    reg [MAX_BITS:0] next_code;
    reg any_symbol, active_valid, active_bank;
    reg [LW-1:0] staging [0:SYMBOLS-1];
    reg [LW-1:0] lengths0 [0:SYMBOLS-1];
    reg [LW-1:0] lengths1 [0:SYMBOLS-1];
    reg [MAX_BITS-1:0] codes0 [0:SYMBOLS-1];
    reg [MAX_BITS-1:0] codes1 [0:SYMBOLS-1];
    wire [MAX_BITS:0] capacity = {{MAX_BITS{1'b0}},1'b1} << level;
    assign c_ready = !rst && state == IDLE;
    assign r_valid = !rst && state == RESPONSE;

    generate if (SYMBOLS < 1 || SYMBOLS > 256 || MAX_BITS < 1 ||
                 MAX_BITS > 16 || TAG_W < 1 || TAG_W > 32) begin: bad_parameters
        canonical_huffman_table_invalid_parameters invalid_parameters();
    end endgenerate

    always @(posedge clk) begin
        if (rst) begin
            state <= INIT;
            symbol_index <= 0;
            active_valid <= 0;
            active_bank <= 0;
            r_op <= 0; r_status <= OK; r_code <= 0;
            r_length <= 0; r_tag <= 0;
            level <= 1; next_code <= 0; any_symbol <= 0;
        end else begin
            case (state)
                INIT, CLEAR: begin
                    staging[symbol_index] <= 0;
                    if (symbol_index == SYMBOLS-1) begin
                        symbol_index <= 0;
                        state <= (state == INIT) ? IDLE : RESPONSE;
                    end else symbol_index <= symbol_index + 1'b1;
                end
                IDLE: if (c_valid) begin
                    r_op <= c_op; r_tag <= c_tag;
                    r_status <= OK; r_code <= 0; r_length <= 0;
                    state <= RESPONSE;
                    case (c_op)
                        0: begin // LOAD changes only staging lengths.
                            if (c_symbol >= SYMBOLS) r_status <= BAD_SYMBOL;
                            else if (c_length > MAX_BITS) r_status <= BAD_LENGTH;
                            else staging[c_symbol[SW-1:0]] <= c_length[LW-1:0];
                        end
                        1: begin // BUILD targets the inactive bank.
                            symbol_index <= 0; level <= 1;
                            next_code <= 0; any_symbol <= 0;
                            state <= INIT_BANK;
                        end
                        2: begin // QUERY reads the committed bank only.
                            if (c_symbol >= SYMBOLS) r_status <= BAD_SYMBOL;
                            else if (!active_valid) r_status <= NO_TABLE;
                            else if (active_bank) begin
                                if (lengths1[c_symbol[SW-1:0]] == 0) r_status <= ABSENT;
                                else begin
                                    r_code <= codes1[c_symbol[SW-1:0]];
                                    r_length <= lengths1[c_symbol[SW-1:0]];
                                end
                            end else begin
                                if (lengths0[c_symbol[SW-1:0]] == 0) r_status <= ABSENT;
                                else begin
                                    r_code <= codes0[c_symbol[SW-1:0]];
                                    r_length <= lengths0[c_symbol[SW-1:0]];
                                end
                            end
                        end
                        3: begin // CLEAR invalidates active and staging.
                            active_valid <= 0; symbol_index <= 0; state <= CLEAR;
                        end
                    endcase
                end
                INIT_BANK: begin
                    // Zero length marks an absent symbol; code bits need no reset.
                    if (active_bank) lengths0[symbol_index] <= 0;
                    else lengths1[symbol_index] <= 0;
                    if (symbol_index == SYMBOLS-1) begin
                        symbol_index <= 0; state <= SCAN;
                    end else symbol_index <= symbol_index + 1'b1;
                end
                SCAN: begin
                    if (staging[symbol_index] == level) begin
                        if (next_code >= capacity) begin
                            r_status <= BAD_TREE; state <= RESPONSE;
                        end else begin
                            if (active_bank) begin
                                lengths0[symbol_index] <= level;
                                codes0[symbol_index] <= next_code[MAX_BITS-1:0];
                            end else begin
                                lengths1[symbol_index] <= level;
                                codes1[symbol_index] <= next_code[MAX_BITS-1:0];
                            end
                            any_symbol <= 1;
                            next_code <= next_code + 1'b1;
                            if (symbol_index == SYMBOLS-1) state <= ADVANCE;
                            else symbol_index <= symbol_index + 1'b1;
                        end
                    end else begin
                        if (symbol_index == SYMBOLS-1) state <= ADVANCE;
                        else symbol_index <= symbol_index + 1'b1;
                    end
                end
                ADVANCE: begin
                    if (level == MAX_BITS) state <= FINISH;
                    else begin
                        level <= level + 1'b1; symbol_index <= 0;
                        next_code <= next_code << 1; state <= SCAN;
                    end
                end
                FINISH: begin
                    if (any_symbol) begin
                        active_bank <= !active_bank; active_valid <= 1;
                    end else r_status <= BAD_TREE;
                    state <= RESPONSE;
                end
                RESPONSE: if (r_ready) state <= IDLE;
                default: state <= INIT;
            endcase
        end
    end
endmodule
