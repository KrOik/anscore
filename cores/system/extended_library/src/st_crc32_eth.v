// ============================================================================
// st_crc32_eth -- selftest cell for crc32_eth (wave2 idx32, TAG "CRC").
//
// Streams (golden model: tools/golden_sys.py):
//   s1: mode0 "123456789"            -> r1, internal check === 0xCBF43926
//   s2: mode0 b(i)=(i*7+1)&FF x20    -> r2
//   s3: mode1 "123456789"            -> r3, internal check === 0x29B1
//   s4: mode1 b(i)=(i*5+3)&FF x16    -> r4
// Folded bytes: r1[7:0..31:24], r2[..], r3[7:0],[15:8], r4[..],
// then check byte {6'b0,chk16,chk32}.  13 bytes total.
// ============================================================================
`timescale 1ns/1ps
module st_crc32_eth (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,
    output reg         pass,
    output reg  [31:0] digest,
    output reg  [15:0] cycles
);
`include "w2_fnv.vh"

localparam [31:0] EXP = 32'hCE9832E0;   // tools/golden_sys.py: CRC DIGEST

localparam S_IDLE = 5'd0;
localparam S_I1   = 5'd1;
localparam S_F1   = 5'd2;
localparam S_Z1   = 5'd3;
localparam S_C1   = 5'd4;
localparam S_I2   = 5'd5;
localparam S_F2   = 5'd6;
localparam S_Z2   = 5'd7;
localparam S_C2   = 5'd8;
localparam S_I3   = 5'd9;
localparam S_F3   = 5'd10;
localparam S_Z3   = 5'd11;
localparam S_C3   = 5'd12;
localparam S_I4   = 5'd13;
localparam S_F4   = 5'd14;
localparam S_Z4   = 5'd15;
localparam S_C4   = 5'd16;
localparam S_CK   = 5'd17;
localparam S_FIN  = 5'd18;

reg [4:0]  st;
reg [7:0]  i;
reg [1:0]  j;
reg        mode_r, init_r, dv_r;
reg [7:0]  din_r;
reg        chk32, chk16;
reg        run_flag;

wire [31:0] crc_out;
wire [31:0] cstate;

crc32_eth dut (
    .clk(clk), .clk_en(clk_en || !rst_n), .rst_n(rst_n),
    .mode(mode_r), .init(init_r), .dv(dv_r), .din(din_r),
    .state(cstate), .crc_out(crc_out)
);

// byte feeders: "123456789" -> 8'h31+i ;  b7(i)=i*7+1 ;  b5(i)=i*5+3
wire [7:0] asc9  = 8'h31 + i;
wire [7:0] b7    = i + (i << 2) + (i << 1) + 8'd1;   // i*7+1
wire [7:0] b5    = i + (i << 2) + 8'd3;              // i*5+3

`ifndef SYNTHESIS
integer fd;
initial fd = $fopen("sim/dump_crc32_eth.txt", "w");
task emit;
    input [7:0] b;
    begin
        digest <= fnv(digest, b);
        $fwrite(fd, "%02x\n", b);
    end
endtask
`else
task emit;
    input [7:0] b;
    begin digest <= fnv(digest, b); end
endtask
`endif

wire ce = clk_en || !rst_n;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        st <= S_IDLE; i <= 0; j <= 0;
        mode_r <= 0; init_r <= 0; dv_r <= 0; din_r <= 0;
        chk32 <= 0; chk16 <= 0;
        done <= 0; pass <= 0; digest <= 32'h811C9DC5; cycles <= 0;
        run_flag <= 0;
    end else if (ce) begin
        init_r <= 0; dv_r <= 0;
        if (run_flag && !done) cycles <= cycles + 16'd1;

        case (st)
            S_IDLE: if (start) begin
                st <= S_I1; i <= 0;
                digest <= 32'h811C9DC5; done <= 0; pass <= 0;
                chk32 <= 0; chk16 <= 0; cycles <= 0; run_flag <= 1;
            end

            S_I1: begin mode_r <= 0; init_r <= 1; i <= 0; st <= S_F1; end
            S_F1: begin
                dv_r <= 1; din_r <= asc9;
                if (i == 8'd8) begin i <= 0; st <= S_Z1; end
                else i <= i + 8'd1;
            end
            S_Z1: st <= S_C1;
            S_C1: begin
                if (j == 0) chk32 <= (crc_out === 32'hCBF43926);
                emit(crc_out[j*8 +: 8]);
                if (j == 2'd3) begin j <= 0; i <= 0; st <= S_I2; end
                else j <= j + 2'd1;
            end

            S_I2: begin mode_r <= 0; init_r <= 1; i <= 0; st <= S_F2; end
            S_F2: begin
                dv_r <= 1; din_r <= b7;
                if (i == 8'd19) begin i <= 0; st <= S_Z2; end
                else i <= i + 8'd1;
            end
            S_Z2: st <= S_C2;
            S_C2: begin
                emit(crc_out[j*8 +: 8]);
                if (j == 2'd3) begin j <= 0; i <= 0; st <= S_I3; end
                else j <= j + 2'd1;
            end

            S_I3: begin mode_r <= 1; init_r <= 1; i <= 0; st <= S_F3; end
            S_F3: begin
                dv_r <= 1; din_r <= asc9;
                if (i == 8'd8) begin i <= 0; st <= S_Z3; end
                else i <= i + 8'd1;
            end
            S_Z3: st <= S_C3;
            S_C3: begin
                if (j == 0) chk16 <= (crc_out[15:0] === 16'h29B1);
                emit(crc_out[j*8 +: 8]);
                if (j == 2'd1) begin j <= 0; i <= 0; st <= S_I4; end
                else j <= j + 2'd1;
            end

            S_I4: begin mode_r <= 1; init_r <= 1; i <= 0; st <= S_F4; end
            S_F4: begin
                dv_r <= 1; din_r <= b5;
                if (i == 8'd15) begin i <= 0; st <= S_Z4; end
                else i <= i + 8'd1;
            end
            S_Z4: st <= S_C4;
            S_C4: begin
                emit(crc_out[j*8 +: 8]);
                if (j == 2'd1) begin j <= 0; st <= S_CK; end
                else j <= j + 2'd1;
            end

            S_CK: begin
                emit({6'b0, chk16, chk32});
                st <= S_FIN;
            end
            S_FIN: begin
                pass <= (digest === EXP) && chk32 && chk16;
                done <= 1;
                run_flag <= 0;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
    end
end

endmodule
