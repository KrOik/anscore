`timescale 1ns / 1ps
// Board report: turns core digests/counters into the ASCII acceptance lines and
// streams them out over the dock UART. Message templates are strings where '%'
// marks the next field slot, so the exact on-wire format stays readable and is
// mirrored by model/golden_all.py expectations.
module board_report #(
    parameter FIELDS   = 16,
    parameter CLK_HZ   = 50000000,
    parameter BAUD     = 115200,
    parameter DIAG     = 0       // 1 appends the same-round double-run line
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    start,      // level while reporting
    input  wire [FIELDS*32-1:0]    fields,
    output reg                     done,
    output wire                    tx
);
    // '%' == 8'h25 marks a field slot. Verilog right-justifies a string literal
    // inside the packed parameter, so character idx counts down from TL*n-1.
    localparam TL0 = 31, TL1 = 29, TL2 = 22, TL3 = 15, TL4 = 14;
    localparam [247:0] MSG0 = {"SNN PASS D=% E=% T=% SK=% S=%", 8'h0D, 8'h0A};
    localparam [231:0] MSG1 = {"LSTM PASS D=% M=% A=% SAT=%", 8'h0D, 8'h0A};
    localparam [175:0] MSG2 = {"25K SNNLSTM PASS D=%", 8'h0D, 8'h0A};
    localparam [119:0] MSG3 = {"SNNLSTM ALIVE", 8'h0D, 8'h0A};
    localparam [111:0] MSG4 = {"DIAG A=% B=%", 8'h0D, 8'h0A};

    localparam MSGS = (DIAG != 0) ? 5 : 4;

    localparam R_IDLE = 3'd0, R_CHAR = 3'd1, R_SEND = 3'd2,
             R_FIELD  = 3'd3, R_FSEND = 3'd4, R_NEXT = 3'd5, R_FIN = 3'd6;

    reg [2:0] st;
    reg [2:0] m;
    reg [6:0] i;
    reg [3:0] k;          // field slots consumed in this message
    reg [6:0] jj;         // nibble index inside a field
    reg       tx_start;
    reg [7:0] tx_data;
    wire      tx_busy;

    uart_tx #(.CLKS_PER_BIT(CLK_HZ / BAUD), .CB_W(10)) u_tx (
        .clk(clk), .rst_n(rst_n), .start(tx_start), .data(tx_data),
        .busy(tx_busy), .tx(tx)
    );

    function [7:0] msg_char;
        input [2:0] msel;
        input [6:0] idx;
        begin
            case (msel)
                3'd0:    msg_char = MSG0[(TL0-1)*8 - idx*8 +: 8];
                3'd1:    msg_char = MSG1[(TL1-1)*8 - idx*8 +: 8];
                3'd2:    msg_char = MSG2[(TL2-1)*8 - idx*8 +: 8];
                3'd4:    msg_char = MSG4[(TL4-1)*8 - idx*8 +: 8];
                default: msg_char = MSG3[(TL3-1)*8 - idx*8 +: 8];
            endcase
        end
    endfunction

    function [6:0] msg_len;
        input [2:0] msel;
        begin
            case (msel)
                3'd0:    msg_len = TL0;
                3'd1:    msg_len = TL1;
                3'd2:    msg_len = TL2;
                3'd4:    msg_len = TL4;
                default: msg_len = TL3;
            endcase
        end
    endfunction

    // field slot -> global field id
    function [3:0] field_id;
        input [2:0] msel;
        input [3:0] slot;
        begin
            case (msel)
                3'd0:    field_id = slot;                    // 0..4
                3'd1:    field_id = 4'd7 + slot;             // 7..10
                3'd2:    field_id = 4'd12;                   // combined
                3'd4:    field_id = (slot == 4'd0) ? 4'd13 : 4'd14;
                default: field_id = 4'd0;                    // MSG3 has no field
            endcase
        end
    endfunction

    function [3:0] field_nib;
        input [3:0] fid;
        begin
            case (fid)
                4'd0,  4'd7, 4'd12,
                4'd13, 4'd14:         field_nib = 4'd8;
                4'd1,  4'd2, 4'd3,
                4'd4,  4'd8, 4'd9,
                4'd15:               field_nib = 4'd4;
                4'd10:               field_nib = 4'd2;
                default:             field_nib = 4'd1;
            endcase
        end
    endfunction

    function [7:0] hex_char;
        input [3:0] n;
        begin
            hex_char = (n < 4'hA) ? {4'h3, n} : (8'h37 + {4'h0, n});
        end
    endfunction

    wire [3:0] fid = field_id(m, k);
    wire [31:0] fval = fields[fid*32 +: 32];
    wire        use_field = (msg_char(m, i) == 8'h25);
    wire [3:0]  fnib = field_nib(fid);
    wire [6:0]  sh   = (fnib - 1'b1 - jj[3:0]) * 4;
    wire [3:0]  nib  = fval[sh +: 4];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= R_IDLE; m <= 3'd0; i <= 7'd0; k <= 4'd0; jj <= 7'd0;
            done <= 1'b0; tx_start <= 1'b0; tx_data <= 8'd0;
        end else begin
            tx_start <= 1'b0;
            case (st)
                R_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        m  <= 3'd0;
                        i  <= 7'd0;
                        k  <= 4'd0;
                        st <= R_CHAR;
                    end
                end
                R_CHAR: begin
                    if (msg_char(m, i) == 8'h25) begin
                        jj <= 7'd0;
                        st <= R_FIELD;
                    end else begin
                        tx_data <= msg_char(m, i);
                        tx_start<= 1'b1;
                        st      <= R_SEND;
                    end
                end
                R_SEND: if (!tx_busy && !tx_start) begin
                    st <= R_NEXT;
                end
                R_FIELD: begin
                    tx_data <= hex_char(nib);
                    tx_start<= 1'b1;
                    st      <= R_FSEND;
                end
                R_FSEND: if (!tx_busy && !tx_start) begin
                    if (jj + 1'b1 >= fnib) begin
                        k  <= k + 1'b1;
                        st <= R_NEXT;
                    end else begin
                        jj <= jj + 1'b1;
                        st <= R_FIELD;
                    end
                end
                R_NEXT: begin
                    if (i + 1'b1 >= msg_len(m)) begin
                        i <= 7'd0;
                        k <= 4'd0;
                        if (m == MSGS - 1) begin
                            st <= R_FIN;
                        end else begin
                            m  <= m + 1'b1;
                            st <= R_CHAR;
                        end
                    end else begin
                        i  <= i + 1'b1;
                        st <= R_CHAR;
                    end
                end
                R_FIN: begin
                    done <= 1'b1;
                    if (!start) st <= R_IDLE;
                end
                default: st <= R_IDLE;
            endcase
        end
    end
endmodule
