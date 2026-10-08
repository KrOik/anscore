// ============================================================================
// mem_bist -- wave2 idx34 "MBST": March-style memory BIST engine, wrapping
// one w2_dpram (W=8, DEPTH<=1024).  Doubles as a silicon RAM-integrity
// probe -- the pattern sequence is fixed and documented:
//
//   phase 0: W   cb(a)        write  (a[0] ? 8'h55 : 8'hAA)        1 beat/addr
//   phase 1: R,W cb(a),~cb(a) read exp cb(a), then write ~cb(a)    2 beats/addr
//   phase 2: R   ~cb(a)       read exp ~cb(a)                      2 beats/addr
//   phase 3: W   wk(a)        write  walking-1 8'h01<<a[2:0]       1 beat/addr
//   phase 4: R,W wk(a),~wk(a) read exp wk(a), then write ~wk(a)    2 beats/addr
//   phase 5: R   ~wk(a)       read exp ~wk(a)                      2 beats/addr
//   phase 6: done (final RAM contents = ~wk(a) at every address)
//
// Any mismatch sets `fail` and latches the FIRST failing
// address/expected/got/phase; the march continues to completion.
//
// Fault-injection test hook (test-only, keep fi_en=0 in production):
// during phase 0 the write at fi_addr is XORed with 8'hFF, so phase 1 must
// report a failure at exactly fi_addr -- proves the checker path works.
//
// Host access: while busy==0 the RAM ports are muxed to h_*/h_q, so the
// integrator can preload or inspect the array.
//
// All registers clk_en gated (T2); RAM is a direct w2_dpram instance (T9).
// ============================================================================
module mem_bist #(
    parameter DEPTH = 256,
    parameter AW    = 8
)(
    input  wire           clk,
    input  wire           clk_en,
    input  wire           rst_n,
    input  wire           start,

    output reg            busy,
    output reg            done,
    output reg            fail,
    output reg  [AW-1:0]  fail_addr,
    output reg  [7:0]     fail_exp,
    output reg  [7:0]     fail_got,
    output reg  [3:0]     fail_phase,
    output reg  [3:0]     phase,

    input  wire           fi_en,
    input  wire [AW-1:0]  fi_addr,

    input  wire           h_we,
    input  wire [AW-1:0]  h_waddr,
    input  wire [7:0]     h_wdata,
    input  wire           h_re,
    input  wire [AW-1:0]  h_raddr,
    output wire [7:0]     h_q
);

localparam S_IDLE = 3'd0;
localparam S_W    = 3'd1;   // pure-write phase (0,3)
localparam S_RI   = 3'd2;   // read issue
localparam S_RC   = 3'd3;   // read check (+ optional write)
localparam S_FIN  = 3'd4;

reg [2:0]    stt;
reg [AW-1:0] addr;

function [7:0] cb;
    input [AW-1:0] a;
    begin cb = a[0] ? 8'h55 : 8'hAA; end
endfunction

function [7:0] wk;
    input [AW-1:0] a;
    begin wk = 8'h01 << a[2:0]; end
endfunction

// expected read data for read phases
function [7:0] exp_patt;
    input [3:0]    p;
    input [AW-1:0] a;
    begin
        case (p)
            4'd1: exp_patt =  cb(a);
            4'd2: exp_patt = ~cb(a);
            4'd4: exp_patt =  wk(a);
            default: exp_patt = ~wk(a);   // phase 5
        endcase
    end
endfunction

// write data for write phases and the write-back of R,W phases
function [7:0] wr_patt;
    input [3:0]    p;
    input [AW-1:0] a;
    begin
        case (p)
            4'd0: wr_patt =  cb(a);
            4'd1: wr_patt = ~cb(a);
            4'd3: wr_patt =  wk(a);
            default: wr_patt = ~wk(a);    // phase 4
        endcase
    end
endfunction

wire is_wr_ph  = (phase == 4'd0) || (phase == 4'd3);
wire has_wrbak = (phase == 4'd1) || (phase == 4'd4);

wire [7:0] wraw = wr_patt(phase, addr);
wire [7:0] wdat = (fi_en && (phase == 4'd0) && (addr == fi_addr))
                  ? (wraw ^ 8'hFF) : wraw;

wire eng_we = busy && ((stt == S_W) || (stt == S_RC && has_wrbak));
wire eng_re = busy && (stt == S_RI);

wire        ram_we    = busy ? eng_we   : h_we;
wire [AW-1:0] ram_waddr = busy ? addr    : h_waddr;
wire [7:0]  ram_wdata = busy ? wdat     : h_wdata;
wire        ram_re    = busy ? eng_re   : h_re;
wire [AW-1:0] ram_raddr = busy ? addr    : h_raddr;

w2_dpram #(.W(8), .DEPTH(DEPTH), .AW(AW)) u_ram (
    .clk(clk), .clk_en(clk_en),
    .we(ram_we), .waddr(ram_waddr), .wdata(ram_wdata),
    .re(ram_re), .raddr(ram_raddr), .q(h_q)
);

wire last_addr = (addr == (DEPTH - 1));

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        stt <= S_IDLE; addr <= {AW{1'b0}}; phase <= 4'd0;
        busy <= 1'b0; done <= 1'b0; fail <= 1'b0;
        fail_addr <= {AW{1'b0}}; fail_exp <= 8'd0; fail_got <= 8'd0;
        fail_phase <= 4'd0;
    end else if (clk_en) begin
        case (stt)
            S_IDLE: begin
                if (start) begin
                    busy  <= 1'b1;
                    done  <= 1'b0;
                    fail  <= 1'b0;
                    addr  <= {AW{1'b0}};
                    phase <= 4'd0;
                    stt   <= S_W;
                end
            end
            S_W: begin
                if (last_addr) begin
                    addr  <= {AW{1'b0}};
                    phase <= phase + 4'd1;
                    stt   <= S_RI;   // phases 1,2,4,5 are all read phases
                end else begin
                    addr <= addr + {{(AW-1){1'b0}},1'b1};
                end
            end
            S_RI: begin
                stt <= S_RC;
            end
            S_RC: begin
                if (h_q !== exp_patt(phase, addr) && !fail) begin
                    fail       <= 1'b1;
                    fail_addr  <= addr;
                    fail_exp   <= exp_patt(phase, addr);
                    fail_got   <= h_q;
                    fail_phase <= phase;
                end
                if (last_addr) begin
                    addr  <= {AW{1'b0}};
                    phase <= phase + 4'd1;
                    if (phase == 4'd2 || phase == 4'd5)
                        stt <= (phase == 4'd2) ? S_W : S_FIN;
                    else
                        stt <= S_RI;
                end else begin
                    addr <= addr + {{(AW-1){1'b0}},1'b1};
                    stt  <= S_RI;
                end
            end
            S_FIN: begin
                done  <= 1'b1;
                busy  <= 1'b0;
                phase <= 4'd6;
                stt   <= S_IDLE;
            end
            default: stt <= S_IDLE;
        endcase
    end
end

endmodule
