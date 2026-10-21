`timescale 1ns / 1ps
// ips_micro_sequencer16 : 16-entry program-memory sequencer for the ip_series_20k
// production line.  A loaded program is stepped one instruction per enabled rising
// edge, with a masked set/clear output word, zero-tested and unconditional branches,
// a per-step WAIT stall on an input condition with a deterministic timeout resume, a
// clean HALT and explicit terminal error states.
//
// INSTRUCTION SET (12-bit program word, the table sim/tb_ips_micro_sequencer16.v and
// models/ips_micro_sequencer16.py are both written from):
//
//    word = { op[11:8], tgt[7:4], aux[3:0] }
//    4'h0  OP_NOP    nothing, fall through
//    4'h1  OP_SET    out_word <= out_word |  aux          (masked set)
//    4'h2  OP_CLR    out_word <= out_word & ~aux          (masked clear)
//    4'h3  OP_INC    out_word <= out_word + 4'h1          (4-bit wrap)
//    4'h4  OP_JZ     if ((out_word & aux) == 0) pc <= tgt else pc <= pc + 1
//    4'h5  OP_JNZ    if ((out_word & aux) != 0) pc <= tgt else pc <= pc + 1
//    4'h6  OP_BRA    pc <= tgt
//    4'h7  OP_WAIT   stall while in_word[aux[1:0]] != aux[2]; advance when it matches
//    4'h8  OP_HALT   stop cleanly (halted high, run low)
//    other           undefined opcode -> ERR_OPC
//   aux[3] and the unused half of a field are reserved and ignored.
//
// Written contract, replayed cycle-exactly by models/ips_micro_sequencer16.py.  One
// step is one enabled rising edge (clk_en high and rst_n high); every register is
// clk_en-gated and rst_n is the active-low asynchronous reset (trap T2).  Inputs
// (ld_en/ld_idx/ld_data, arm, in_word) are sampled in the window before that edge;
// pc, cur_op, out_word, step_count, wait_cnt, tmo_total, tmo_flag, state, err_cause
// and err_seen are the registered state that edge produced, so every reported value
// is settled for the whole beat.
//
//   Program store: prog is a flat 16 x 12 register array written only through the
//   ld_en/ld_idx/ld_data update port while clk_en is high.  It is not cleared by
//   reset (a loaded program survives a re-arm), which is why the testbench loads all
//   sixteen entries before the first run: no entry is ever read unwritten.
//   Fetch/execute: prog[pc] is executed on each enabled step of S_RUN.  pc is the
//   address presented for execution (so it shows the NEXT instruction after a step
//   that advanced), cur_op is the registered opcode field of the instruction that the
//   most recent enabled step acted on, including on the step that raises an error.
//   Run control: an arm pulse while the sequencer is not running loads pc with
//   START_PC, clears out_word, wait_cnt, tmo_flag and cur_op, and enters S_RUN; the
//   instruction at START_PC is executed by the FOLLOWING enabled step.  arm is
//   ignored while S_RUN, so a pulse can never restart a run in progress.  A step on
//   which arm is high executes no instruction.  The update port owns its beat: on a
//   step where ld_en is high only prog[ld_idx] is written, no instruction retires and
//   arm is not sampled, so a program can be re-written while the sequencer is running
//   and the next enabled step fetches the new word.
//   Terminal states: S_HALT is entered by OP_HALT with pc left pointing at the HALT
//   itself; S_ERR is entered by an error with pc left pointing at the offending
//   instruction.  Neither state executes anything and neither is left except by an
//   explicit arm pulse, so a failed run can never silently continue.  step_count
//   counts retired instructions (an OP_WAIT stall beat retires nothing) and saturates
//   at STEP_SAT; it does not advance on an error step.
//   WAIT: while the condition is unmatched wait_cnt <= wait_cnt + 1 (holding at
//   WAIT_LIMIT), pc holds and nothing retires.  The step on which wait_cnt reaches
//   WAIT_LIMIT is the timeout: tmo_flag is raised, tmo_total (saturating at STEP_SAT)
//   steps once, wait_cnt clears and pc advances to the next instruction, so a stuck
//   condition always resumes deterministically one instruction later.  A WAIT whose
//   condition matches with wait_cnt below WAIT_LIMIT retires with wait_cnt cleared
//   and no timeout.
//   Error causes, checked in this order, are always explicit and terminal:
//     ERR_NONE 3'd0  no error latched
//     ERR_RUN  3'd3  pc >= PGM_LEN: the program ran off its end without a HALT
//     ERR_OPC  3'd2  prog[pc] holds an opcode outside the table above
//     ERR_TGT  3'd1  a branch that this step TAKES has tgt >= PGM_LEN (out of range)
//   A not-taken branch whose field points out of range is not an error: the jump is
//   never made, so the illegal value is simply unused.
//   The first captured cause holds in err_cause; err_seen[j] stays set once cause j
//   has ever occurred, so a run that errors, is re-armed and errors again records both.
//   PGM_LEN is the number of valid program entries: entries PGM_LEN..15 exist in the
//   store but are outside the running program, so reaching one by fall-through raises
//   ERR_RUN and branching to one raises ERR_TGT.
module ips_micro_sequencer16 #(
    parameter [3:0] PGM_LEN    = 4'd12,
    parameter [5:0] WAIT_LIMIT = 6'd13,
    parameter [3:0] START_PC   = 4'd0
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,

    input  wire        ld_en,
    input  wire [3:0]  ld_idx,
    input  wire [11:0] ld_data,

    input  wire        arm,
    input  wire [3:0]  in_word,

    output wire [3:0]  pc,
    output wire [3:0]  cur_op,
    output wire        run,
    output wire        halted,
    output reg  [1:0]  state,
    output reg  [3:0]  out_word,
    output reg  [7:0]  step_count,
    output reg  [5:0]  wait_cnt,
    output reg  [7:0]  tmo_total,
    output reg         tmo_flag,
    output reg  [2:0]  err_cause,
    output reg  [4:0]  err_seen
);

localparam [2:0] ERR_NONE = 3'd0;
localparam [2:0] ERR_TGT  = 3'd1;
localparam [2:0] ERR_OPC  = 3'd2;
localparam [2:0] ERR_RUN  = 3'd3;

localparam [1:0] S_IDLE   = 2'd0;
localparam [1:0] S_RUN    = 2'd1;
localparam [1:0] S_HALT   = 2'd2;
localparam [1:0] S_ERR    = 2'd3;

localparam [7:0] STEP_SAT = 8'hFF;

localparam [3:0] OP_NOP   = 4'h0;
localparam [3:0] OP_SET   = 4'h1;
localparam [3:0] OP_CLR   = 4'h2;
localparam [3:0] OP_INC   = 4'h3;
localparam [3:0] OP_JZ    = 4'h4;
localparam [3:0] OP_JNZ   = 4'h5;
localparam [3:0] OP_BRA   = 4'h6;
localparam [3:0] OP_WAIT  = 4'h7;
localparam [3:0] OP_HALT  = 4'h8;

reg [11:0] prog [0:15];
reg [3:0]  rpc;
reg [3:0]  ir_op;

wire [11:0] irw  = prog[rpc];
wire [3:0]  op   = irw[11:8];
wire [3:0]  tgt  = irw[7:4];
wire [3:0]  aux  = irw[3:0];

wire       z_match = ((out_word & aux) == 4'h0);
wire       j_taken = ((op == OP_JZ)  &&  z_match) ||
                     ((op == OP_JNZ) && !z_match) ||
                     (op == OP_BRA);

wire       op_known = (op == OP_NOP)  || (op == OP_SET)  || (op == OP_CLR) ||
                      (op == OP_INC)  || (op == OP_JZ)   || (op == OP_JNZ) ||
                      (op == OP_BRA)  || (op == OP_WAIT) || (op == OP_HALT);

wire [1:0] w_idx   = aux[1:0];
wire       w_level = aux[2];
wire       w_met   = (in_word[w_idx] == w_level);
wire       w_stall = (op == OP_WAIT) && !w_met;

wire [5:0] wait_nx = (wait_cnt >= WAIT_LIMIT) ? wait_cnt : (wait_cnt + 6'h1);
wire       to_now  = w_stall && (wait_nx == WAIT_LIMIT);

wire       run_off = (rpc >= PGM_LEN);
wire       tgt_off = j_taken && (tgt >= PGM_LEN);
wire [2:0] err_new = run_off ? ERR_RUN :
                     (!op_known) ? ERR_OPC :
                     (tgt_off ? ERR_TGT : ERR_NONE);

wire [7:0] step_nx = (step_count == STEP_SAT) ? step_count : (step_count + 8'h01);
wire [7:0] tmo_nx  = (tmo_total  == STEP_SAT) ? tmo_total  : (tmo_total  + 8'h01);

assign pc     = rpc;
assign cur_op = ir_op;
assign run    = (state == S_RUN);
assign halted = (state == S_HALT);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rpc        <= START_PC;
        ir_op      <= 4'h0;
        state      <= S_IDLE;
        out_word   <= 4'h0;
        step_count <= 8'h00;
        wait_cnt   <= 6'h0;
        tmo_total  <= 8'h00;
        tmo_flag   <= 1'b0;
        err_cause  <= ERR_NONE;
        err_seen   <= 5'b00000;
    end else if (clk_en) begin
        if (ld_en) begin
            prog[ld_idx] <= ld_data;
        end else if (arm && (state != S_RUN)) begin
            state      <= S_RUN;
            rpc        <= START_PC;
            ir_op      <= 4'h0;
            out_word   <= 4'h0;
            wait_cnt   <= 6'h0;
            tmo_flag   <= 1'b0;
        end else if (state == S_RUN) begin
            ir_op <= op;
            if (err_new != ERR_NONE) begin
                state <= S_ERR;
                if (err_cause == ERR_NONE) begin
                    err_cause <= err_new;
                end
                err_seen[err_new] <= 1'b1;
            end else begin
                case (op)
                    OP_NOP: begin
                        rpc        <= rpc + 4'h1;
                        step_count <= step_nx;
                    end
                    OP_SET: begin
                        out_word   <= out_word | aux;
                        rpc        <= rpc + 4'h1;
                        step_count <= step_nx;
                    end
                    OP_CLR: begin
                        out_word   <= out_word & ~aux;
                        rpc        <= rpc + 4'h1;
                        step_count <= step_nx;
                    end
                    OP_INC: begin
                        out_word   <= out_word + 4'h1;
                        rpc        <= rpc + 4'h1;
                        step_count <= step_nx;
                    end
                    OP_JZ, OP_JNZ: begin
                        rpc        <= j_taken ? tgt : (rpc + 4'h1);
                        step_count <= step_nx;
                    end
                    OP_BRA: begin
                        rpc        <= tgt;
                        step_count <= step_nx;
                    end
                    OP_WAIT: begin
                        if (w_met) begin
                            rpc        <= rpc + 4'h1;
                            step_count <= step_nx;
                            wait_cnt   <= 6'h0;
                        end else if (to_now) begin
                            rpc        <= rpc + 4'h1;
                            step_count <= step_nx;
                            wait_cnt   <= 6'h0;
                            tmo_flag   <= 1'b1;
                            tmo_total  <= tmo_nx;
                        end else begin
                            wait_cnt   <= wait_nx;
                        end
                    end
                    OP_HALT: begin
                        state      <= S_HALT;
                        step_count <= step_nx;
                    end
                    default: begin
                        // Not reachable: err_new above already turns any opcode
                        // outside the instruction table into a terminal ERR_OPC.
                    end
                endcase
            end
        end
    end
end

endmodule
