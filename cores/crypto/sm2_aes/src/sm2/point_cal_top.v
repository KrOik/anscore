`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:         SHU
// Engineer:        lf
//
// Create Date:    23:16:54 04/13/2020
// Design Name:
// Module Name:    point_cal_top
// Project Name:
// Target Devices:
// Tool versions:
// Description:
//
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//  点运算顶层
//      由运算单元，存储单元以及控制单元组成
//      顶层包括一个指令输入FIFO接口,以及一个结果FIFO读取接口
//
//  二改 (GW2A-18C fit): the 12x256b operand register file and its 256b
//  operand-select muxes were the dominant LUT4 cost.  Storage moved to two
//  identical 96x32 synchronous RAM banks (BSRAM); operands are fetched
//  word-serially into op_a_reg/op_b_reg before each op, and results are
//  written back word-serially.  var_x2/y2/z2 keep DFF mirrors for the
//  combinational output ports.  cfg_prim_num is constant P256 (the ECC
//  datapath never runs mod-n).  intr_cal_done_o now pulses when an
//  instruction fully completes (including write-back), not when the ALU
//  finishes.
//////////////////////////////////////////////////////////////////////////////////
module point_cal_top(
    input           clk,
    input           rst_n,

    input  [15:0]   ins_0_i,
    input  [15:0]   ins_1_i,
    input  [15:0]   ins_2_i,
    input           ins_vld_i,

    //数据接口
    input  [255:0]  data_path_i,

    output [255:0]  var_x2_o,
    output [255:0]  var_y2_o,
    output [255:0]  var_z2_o,

    output          intr_cal_done_o
);
localparam          OP_NUM_SEL_X2 = 4'b0,OP_NUM_SEL_Y2 = 4'd1,OP_NUM_SEL_Z2 = 4'd2;
localparam          OP_NUM_SEL_T0 = 4'd3,OP_NUM_SEL_T1 = 4'd4,OP_NUM_SEL_T2 = 4'd5;
localparam          OP_NUM_CNST_X0 = 4'd6,OP_NUM_CNST_Y0 = 4'd7,OP_NUM_CNST_Z0 = 4'd8,OP_NUM_CNST_X1 = 4'd9,OP_NUM_CNST_Y1 = 4'd10,OP_NUM_CNST_Z1 = 4'd11;
localparam          OP_NUM_CNST_P256 = 4'd12;

localparam          OP_MUL = 2'b00;
localparam          OP_ADD = 2'b01;
localparam          OP_SUB = 2'b10;

localparam          INS_CAL         = 2'b00;
localparam          INS_UPDT_REG    = 2'b01;
localparam          INS_FIN         = 2'b10;

//存储单元: 2 identical 96x32 RAM banks (BSRAM).  Word address =
// {reg_sel[3:0], widx[2:0]}; reg_sel 0..5 = var, 6..11 = cnst.
// 36-bit words match the Gowin SDP width list ({1,2,4,9,18,36}); 32 would
// force the whole regfile into DFFs. Upper nibble stays zero.
reg  [35:0]         rf_a [0:95];
reg  [35:0]         rf_b [0:95];
reg                 rf_we;
reg  [6:0]          rf_waddr;
reg  [35:0]         rf_wdata;
wire [6:0]          rf_raddr_a, rf_raddr_b;
reg  [35:0]         rf_q_a, rf_q_b;

// variable register mirrors for the combinational output ports
reg  [255:0]        var_x2,var_y2,var_z2;

// operand holding registers fed to the ALU
reg  [255:0]        op_a_reg, op_b_reg;

wire [255:0]    P256 = {
    8'hFF, 8'hFF, 8'hFF, 8'hFE, 8'hFF, 8'hFF, 8'hFF, 8'hFF, /* p */
    8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF,
    8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'h00, 8'h00, 8'h00, 8'h00,
    8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF
    } ;

//控制单元
wire [3:0]          op_mod_0_a_sel,op_mod_0_b_sel;

//指令控制状态机
reg  [3:0]          state;
reg  [4:0]          wcnt;         // word counter inside multi-cycle states

localparam IDLE                     = 4'd0;
localparam FETCH                    = 4'd1;   // serial operand fetch (9 cyc)
localparam CAL                      = 4'd2;   // ALU runs
localparam WB                       = 4'd3;   // serial result write-back (8 cyc)
localparam UWR                      = 4'd4;   // UPDT_REG serial write (8 cyc)
localparam FCPY                     = 4'd5;   // FIN: var->cnst copy (25 cyc)

//运算数与结果
wire [255:0]        op_mod_0_r;

//运算单元
wire                mod_0_done;
wire                mod_0_start;
wire[1:0]           op_sel_0;
wire                op_done;//运算完成信号

//取指令中的信息
wire [1:0]          ins_type_0;
wire [1:0]          ins_op_mod_0;
wire [7:0]          ins_op_num_ab_0;
wire [3:0]          ins_op_r_0;
wire [3:0]          ins_updt_reg_id;

assign              {ins_op_mod_0,ins_type_0,ins_op_num_ab_0,ins_op_r_0}   =   ins_0_i;

// RAM ports: 1 write + 1 read per bank -> simple dual port.
always @(posedge clk) begin
    if (rf_we) begin
        rf_a[rf_waddr] <= rf_wdata;
        rf_b[rf_waddr] <= rf_wdata;
    end
end
always @(posedge clk) begin
    rf_q_a <= rf_a[rf_raddr_a];
    rf_q_b <= rf_b[rf_raddr_b];
end

// read address mux: FETCH streams operand words, FCPY streams the var copy
assign              rf_raddr_a  =   (state == FCPY) ? {2'b00, wcnt[4:3], wcnt[2:0]}
                                                    : {op_mod_0_a_sel, wcnt[2:0]};
assign              rf_raddr_b  =   {op_mod_0_b_sel, wcnt[2:0]};

//实现状态机
always @(posedge clk or negedge rst_n) begin
    if(~rst_n) begin
        state       <=  IDLE;
        wcnt        <= 5'd0;
        rf_we       <= 1'b0;
        rf_waddr    <= 7'd0;
        rf_wdata    <= 32'd0;
        op_a_reg    <= 256'd0;
        op_b_reg    <= 256'd0;
        var_x2      <= 256'd0;
        var_y2      <= 256'd0;
        var_z2      <= 256'd0;
    end else begin
        rf_we   <=  1'b0;
        case (state)
        IDLE: begin
            wcnt    <= 5'd0;
            if(ins_vld_i) begin
                if(ins_type_0 == INS_FIN)
                    state   <=  FCPY;
                else if(ins_type_0 == INS_UPDT_REG)
                    state   <=  UWR;
                else if(ins_type_0 == INS_CAL)
                    state   <=  FETCH;
            end
        end
        // serial operand fetch: issue read word wcnt (cycles 0..7),
        // capture word wcnt-1 (cycles 1..8), then run the ALU.
        FETCH: begin
            if (wcnt > 5'd0) begin
                op_a_reg[32*(wcnt-1) +: 32] <= rf_q_a[31:0];
                op_b_reg[32*(wcnt-1) +: 32] <= rf_q_b[31:0];
            end
            if (wcnt == 5'd8) begin
                wcnt    <= 5'd0;
                state   <= CAL;
            end else
                wcnt    <= wcnt + 5'd1;
        end
        CAL: begin
            if(op_done) begin
                if(ins_op_r_0 < 4'd12) begin
                    wcnt    <= 5'd0;
                    state   <=  WB;
                end else begin
                    state   <=  IDLE;   // discarded result: done
                end
            end
        end
        // serial result write-back to {ins_op_r_0, widx}
        WB: begin
            rf_we       <= 1'b1;
            rf_waddr    <= {ins_op_r_0, wcnt[2:0]};
            rf_wdata    <= op_mod_0_r[32*wcnt +: 32];
            if (ins_op_r_0 == OP_NUM_SEL_X2) var_x2[32*wcnt +: 32] <= op_mod_0_r[32*wcnt +: 32];
            if (ins_op_r_0 == OP_NUM_SEL_Y2) var_y2[32*wcnt +: 32] <= op_mod_0_r[32*wcnt +: 32];
            if (ins_op_r_0 == OP_NUM_SEL_Z2) var_z2[32*wcnt +: 32] <= op_mod_0_r[32*wcnt +: 32];
            if (wcnt == 5'd7) begin
                wcnt    <= 5'd0;
                state   <=  IDLE;
            end else
                wcnt    <= wcnt + 5'd1;
        end
        // UPDT_REG: serial write of data_path_i to {ins_updt_reg_id, widx}
        UWR: begin
            if (ins_updt_reg_id < 4'd12) begin
                rf_we       <= 1'b1;
                rf_waddr    <= {ins_updt_reg_id, wcnt[2:0]};
                rf_wdata    <= data_path_i[32*wcnt +: 32];
            end
            if (wcnt == 5'd7) begin
                wcnt    <= 5'd0;
                state   <=  IDLE;
            end else
                wcnt    <= wcnt + 5'd1;
        end
        // FIN: copy var x2,y2,z2 -> cnst x0,y0,z0 (24 words).
        // reads issue on wcnt 0..23 (src reg = wcnt[4:3], word = wcnt[2:0]),
        // writes lag one cycle (dst reg = 6 + (wcnt-1)[4:3]).
        FCPY: begin
            if (wcnt > 5'd0) begin
                rf_we       <= 1'b1;
                // dst = cnst_x0 base (word 48) + flat index (wcnt-1); a plain
                // sum avoids concat self-determined-width pitfalls.
                rf_waddr    <= 7'd47 + wcnt;
                rf_wdata    <= rf_q_a;
            end
            if (wcnt == 5'd24) begin
                wcnt    <= 5'd0;
                state   <=  IDLE;
            end else
                wcnt    <= wcnt + 5'd1;
        end
        default: state <= IDLE;
        endcase
    end
end

//读取寄存器更新指令中的寄存器id
assign              ins_updt_reg_id    =   ins_op_r_0;

//将运算类型传递给计算单元
// 二改: single-ALU configuration for GW2A-18C resource budget.
assign              mod_0_start =       state == CAL && ins_type_0 == INS_CAL;//在指令有效的情况下启动运算符
assign              op_sel_0    =       ins_op_mod_0;
assign              op_done     =       mod_0_done;

//将指令数据通路信息传递给
assign              {op_mod_0_a_sel,op_mod_0_b_sel} =   ins_op_num_ab_0;

mul_add_sub_mod_module U_cal_0 (
    .clk(clk),
    .rst_n(rst_n),

    .op_vld_i(mod_0_start),
    .op_sel_i(op_sel_0),
    .op_mod_num_i(P256),

    .op_a_i     (op_a_reg),
    .op_b_i     (op_b_reg),
    .op_done_o  (mod_0_done),
    .op_rslt_o  (op_mod_0_r)
);


//输出逻辑
assign  var_x2_o            =   var_x2;
assign  var_y2_o            =   var_y2;
assign  var_z2_o            =   var_z2;
// instruction-complete handshake: pulses when the FSM returns to IDLE
// after a CAL write-back, UPDT_REG write or FIN copy.
assign  intr_cal_done_o     =   (state == WB   && wcnt == 5'd7) ||
                                (state == UWR  && wcnt == 5'd7) ||
                                (state == FCPY && wcnt == 5'd24) ||
                                (state == CAL  && op_done && ins_op_r_0 >= 4'd12);

endmodule
