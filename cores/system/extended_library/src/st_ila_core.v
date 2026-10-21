// ============================================================================
// st_ila_core -- selftest cell for ila_core (wave2 idx31, TAG "ILA").
//
// Stimulus: 16-bit sample counter cnt, probe = cnt[7:0] ^ {cnt[10:8],5'b0}.
// Run 1: trig_mask=0xE0 trig_val=0xE0 mode=0(level) pre_trig=200.
// Run 2: trig_mask=0x01 trig_val=0x01 mode=1(rising) pre_trig=50.
// Per run the whole 1024-deep buffer is read back and folded, then
// trig_ptr[7:0], {6'b0,trig_ptr[9:8]} and status {6'b0,fired,done}.
// Stream = 2 x (1024 + 3) = 2054 bytes (golden: tools/golden_sys.py).
// ============================================================================
`timescale 1ns/1ps
module st_ila_core (
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

localparam [31:0] EXP = 32'h17852826;   // tools/golden_sys.py: ILA DIGEST
localparam AW = 10;

localparam S_IDLE = 5'd0;
localparam S_CFG  = 5'd1;
localparam S_ARM  = 5'd2;
localparam S_RUN  = 5'd3;
localparam S_RDI  = 5'd4;
localparam S_RDW  = 5'd5;
localparam S_RDC  = 5'd6;
localparam S_T0   = 5'd7;
localparam S_T1   = 5'd8;
localparam S_T2   = 5'd9;
localparam S_NEXT = 5'd10;
localparam S_FIN  = 5'd11;

reg [4:0]    st;
reg [15:0]   cnt;
reg [9:0]    ri;
reg [2:0]    dw;
reg          run;        // 0 = run1, 1 = run2
reg          saw_busy;
reg          cwe;
reg [1:0]    caddr;
reg [15:0]   cdata;
reg          arm_r;
reg          rd_en_r;
reg [AW-1:0] rd_addr_r;
reg          run1_ok, run2_ok;
reg          run_flag;

wire [7:0] probe = cnt[7:0] ^ {cnt[10:8], 5'b00000};

wire        ila_busy, ila_done, ila_fired;
wire [AW-1:0] ila_tp;
wire [7:0]  rd_q;

ila_core #(.AW(AW)) dut (
    .clk(clk), .clk_en(clk_en || !rst_n), .rst_n(rst_n),
    .probe(probe),
    .cfg_we(cwe), .cfg_addr(caddr), .cfg_data(cdata),
    .arm(arm_r),
    .busy(ila_busy), .done(ila_done), .fired(ila_fired),
    .trig_ptr(ila_tp),
    .rd_en(rd_en_r), .rd_addr(rd_addr_r), .rd_q(rd_q)
);

`ifndef SYNTHESIS
integer fd;
initial fd = $fopen("sim/dump_ila_core.txt", "w");
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
        st <= S_IDLE; cnt <= 16'd0; ri <= 10'd0; dw <= 3'd0;
        run <= 0; saw_busy <= 0;
        cwe <= 0; caddr <= 0; cdata <= 0; arm_r <= 0;
        rd_en_r <= 0; rd_addr_r <= 0;
        run1_ok <= 0; run2_ok <= 0;
        done <= 0; pass <= 0; digest <= 32'h811C9DC5; cycles <= 16'd0;
        run_flag <= 0;
    end else if (ce) begin
        cwe <= 0; arm_r <= 0; rd_en_r <= 0;
        if (run_flag && !done) cycles <= cycles + 16'd1;

        case (st)
            S_IDLE: begin
                if (start) begin
                    st <= S_CFG; run <= 0; dw <= 0; cnt <= 0;
                    digest <= 32'h811C9DC5; done <= 0; pass <= 0;
                    cycles <= 0; run1_ok <= 0; run2_ok <= 0;
                    run_flag <= 1;
                end
            end
            S_CFG: begin
                cwe <= 1;
                if (!run) begin
                    case (dw)
                        3'd0: begin caddr <= 0; cdata <= 16'h00E0; end // mask
                        3'd1: begin caddr <= 1; cdata <= 16'h00E0; end // val
                        3'd2: begin caddr <= 2; cdata <= 16'd200;  end // pre_trig
                        default: begin caddr <= 3; cdata <= 16'd0; end // mode level
                    endcase
                end else begin
                    case (dw)
                        3'd0: begin caddr <= 0; cdata <= 16'h0001; end
                        3'd1: begin caddr <= 1; cdata <= 16'h0001; end
                        3'd2: begin caddr <= 2; cdata <= 16'd50;   end
                        default: begin caddr <= 3; cdata <= 16'd1; end // rising
                    endcase
                end
                if (dw == 3'd3) begin dw <= 0; st <= S_ARM; end
                else dw <= dw + 3'd1;
            end
            S_ARM: begin
                arm_r <= 1;
                cnt <= 0;
                saw_busy <= 0;
                st <= S_RUN;
            end
            S_RUN: begin
                // probe = f(cnt); advance only while the ILA is capturing so
                // the first CAP beat samples f(0) (busy asserts the same edge
                // the ILA enters CAP, one beat after arm).
                if (ila_busy) cnt <= cnt + 16'd1;
                if (ila_busy) saw_busy <= 1;
                if (saw_busy && ila_done) begin
                    ri <= 0;
                    st <= S_RDI;
                end
            end
            S_RDI: begin
                rd_en_r <= 1; rd_addr_r <= ri;
                st <= S_RDW;
            end
            S_RDW: st <= S_RDC;
            S_RDC: begin
                emit(rd_q);
                if (ri == 10'd1023) st <= S_T0;
                else begin ri <= ri + 10'd1; st <= S_RDI; end
            end
            S_T0: begin emit(ila_tp[7:0]);            st <= S_T1; end
            S_T1: begin emit({6'b0, ila_tp[9:8]});    st <= S_T2; end
            S_T2: begin
                emit({6'b0, ila_fired, ila_done});
                if (!run && ila_fired && ila_done) run1_ok <= 1;
                if ( run && ila_fired && ila_done) run2_ok <= 1;
                st <= S_NEXT;
            end
            S_NEXT: begin
                if (!run) begin
                    run <= 1; dw <= 0; st <= S_CFG;
                end else begin
                    st <= S_FIN;
                end
            end
            S_FIN: begin
                pass <= (digest === EXP) && run1_ok && run2_ok;
                done <= 1;
                run_flag <= 0;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
    end
end

endmodule
