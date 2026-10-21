// Authored kernel. See ip/quadrature_jitter/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_quadrature_jitter (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire in_valid, output wire in_ready,
    input wire [31:0] a, b, c,
    output reg out_valid, input wire out_ready,
    output reg [31:0] result, aux, output reg fault
);
reg [255:0] state_r, state_n;
reg [31:0] r, x, temp, mask, pa, pb, pc, ph, pl;
reg [32:0] ext;
reg [63:0] wide, wide2;
reg signed [63:0] swide, swide2;
reg signed [31:0] sa, sb, sc;
reg [95:0] data;
reg f;
integer i, j, idx, lane, sh;
function [5:0] pc32;                        // popcount, pairwise half adds
    input [31:0] v;
    reg [31:0] t;
    begin
        t = (v & 32'h55555555) + ((v >> 1) & 32'h55555555);
        t = (t & 32'h33333333) + ((t >> 2) & 32'h33333333);
        t = (t & 32'h0F0F0F0F) + ((t >> 4) & 32'h0F0F0F0F);
        // The byte fold has to be two sequential half-adds.  Written as one
        // parallel sum t + (t>>8) + (t>>16) the bit 31:24 group lands in byte 1
        // instead of byte 0, so every popcount silently lost its top byte.
        t = t + (t >> 8);
        t = t + (t >> 16);
        pc32 = t[5:0];
    end
endfunction

function [5:0] lo32;                        // index of the lowest set bit, 32 if 0
    input [31:0] v;
    reg [31:0] t;
    reg [5:0] n;
    begin
        n = 6'd32;
        if (v != 32'd0) begin
            t = v; n = 6'd0;
            if ((t & 32'h0000FFFF) == 32'd0) begin n = n + 6'd16; t = t >> 16; end
            if ((t & 32'h000000FF) == 32'd0) begin n = n + 6'd8;  t = t >> 8;  end
            if ((t & 32'h0000000F) == 32'd0) begin n = n + 6'd4;  t = t >> 4;  end
            if ((t & 32'h00000003) == 32'd0) begin n = n + 6'd2;  t = t >> 2;  end
            if ((t & 32'h00000001) == 32'd0) begin n = n + 6'd1; end
        end
        lo32 = n;
    end
endfunction

function [15:0] sat16;                      // saturating 16-bit unsigned add
    input [15:0] p, q;
    reg [16:0] t;
    begin
        t = {1'b0, p} + {1'b0, q};
        sat16 = (t > 17'hFFFF) ? 16'hFFFF : t[15:0];
    end
endfunction

function [7:0] sat8;                        // saturating 8-bit unsigned add
    input [7:0] p, q;
    reg [8:0] t;
    begin
        t = {1'b0, p} + {1'b0, q};
        sat8 = (t > 9'hFF) ? 8'hFF : t[7:0];
    end
endfunction

function [7:0] nsym;                        // ticks to symbols, saturated at 255
    input [15:0] ticks;
    input [5:0] sh;
    reg [15:0] t;
    begin
        t = ticks >> sh;
        nsym = (t > 16'd255) ? 8'hFF : t[7:0];
    end
endfunction

function [3:0] nlog2;                       // log2 of 2,4,8,16; 0 for anything else
    input [5:0] n;
    begin
        case (n)
            6'd2:  nlog2 = 4'd1;
            6'd4:  nlog2 = 4'd2;
            6'd8:  nlog2 = 4'd3;
            6'd16: nlog2 = 4'd4;
            default: nlog2 = 4'd0;
        endcase
    end
endfunction

function [1:0] qwalk;          // 0=forward, 1=backward, 2=held, 3=diagonal
    input [3:0] pn;
    begin
        case (pn)
            4'd2, 4'd11, 4'd13, 4'd4: qwalk = 2'd0;
            4'd8, 4'd14, 4'd7, 4'd1:  qwalk = 2'd1;
            4'd3, 4'd12, 4'd9, 4'd6:  qwalk = 2'd3;
            default:                  qwalk = 2'd2;
        endcase
    end
endfunction

reg [15:0] qil, ivel, ivel_n;
reg [7:0] qbnc, qilt, qjlt, qedgc, qzlcc, qbt, qbstreak, qbstreak_n;
reg signed [31:0] qpos, qpos_n, qdevs, qvn, qdeva;
reg [1:0] qps, qns, qdir, qmode;
reg qedg, qzlc;
reg qillegal, qbounce, qjitter, qzr, qcount, qgate, qachange, qrising;
reg qprevz, qzl, qarm, qchatter;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    qil=16'd0; ivel=16'd0; ivel_n=16'd0;
qbnc=8'd0; qilt=8'd0; qjlt=8'd0; qedgc=8'd0; qzlcc=8'd0; qbt=8'd0;
qedg=1'b0; qzlc=1'b0;
qbstreak=8'd0; qbstreak_n=8'd0;
qpos=32'sd0; qpos_n=32'sd0; qdevs=32'sd0; qvn=32'sd0; qdeva=32'sd0;
qps=2'd0; qns=2'd0; qdir=2'd2; qmode=2'd0;
qillegal=1'b0; qbounce=1'b0; qjitter=1'b0; qzr=1'b0; qcount=1'b0;
qgate=1'b0; qachange=1'b0; qrising=1'b0;
qprevz=1'b0; qzl=1'b0; qarm=1'b0; qchatter=1'b0;
if (a[31:3] != 0 || b[31:16] != 0 || c[29:27] != 0 || c[1:0] == 2'd3) begin
    f = 1'b1;
end else begin
    qns = a[1:0];
    qzl = a[2];
    qil = b[15:0];
    qmode = c[1:0];
    qarm = c[31] ? c[30] : state_r[107];
    if (c[31]) begin
        qps = qns;
        qpos_n = 32'sd0;
        ivel_n = 16'd0;
        qbstreak_n = 8'd0;
    end else begin
        qps = state_r[33:32];
        qprevz = state_r[34];
        qpos = $signed(state_r[31:0]);
        ivel = state_r[50:35];
        qbstreak = state_r[74:67];
        qpos_n = qpos;
        ivel_n = ivel;
        qbstreak_n = qbstreak;
        qdir = qwalk({qps, qns});
        qillegal = (qdir == 2'd3);
        qachange = (qps[1] != qns[1]);
        qrising = (!qps[1]) && qns[1];
        qzr = (!qprevz) && qzl;
        if (qillegal) begin
            qpos_n = qpos;
            qbstreak_n = 8'd0;
        end else if (qil < {8'd0, c[15:8]}) begin
            qbounce = 1'b1;
            if (qbstreak != 8'hFF) qbstreak_n = qbstreak + 8'd1;
            if (c[23:16] != 8'd0 && qbstreak_n >= c[23:16]) qchatter = 1'b1;
        end else begin
            qbstreak_n = 8'd0;
            qedg = 1'b1;
            qgate = (qmode == 2'd0) ? qrising
                  : ((qmode == 2'd1) ? qachange : 1'b1);
            qcount = qgate && (qdir != 2'd2);
            if (qcount) qpos_n = (qdir == 2'd1) ? (qpos - 32'sd1)
                                                : (qpos + 32'sd1);
            qdevs = $signed({16'd0, qil}) - $signed({16'd0, ivel});
            if (ivel != 16'd0) begin
                qdeva = (qdevs < 32'sd0) ? -qdevs : qdevs;
                if (qdeva > ($signed({16'd0, (ivel >> c[26:24])}) + 32'sd1))
                    qjitter = 1'b1;
                qvn = $signed({16'd0, ivel}) + (qdevs >>> 4);
                if (qvn < 32'sd0) qvn = 32'sd0;
                else if (qvn > 32'sd65535) qvn = 32'sd65535;
                ivel_n = qvn[15:0];
            end else begin
                ivel_n = qil;
            end
        end
        if (qzr) begin
            qzlc = 1'b1;
            if (qarm) qpos_n = 32'sd0;
        end
    end
    if (qillegal || qjitter || qchatter) f = 1'b1;
    qilt = sat8(c[31] ? 8'd0 : state_r[82:75], qillegal ? 8'd1 : 8'd0);
    qjlt = sat8(c[31] ? 8'd0 : state_r[90:83], qjitter ? 8'd1 : 8'd0);
    qedgc = sat8(c[31] ? 8'd0 : state_r[98:91], qedg ? 8'd1 : 8'd0);
    qbnc = sat8(c[31] ? 8'd0 : state_r[106:99], qbounce ? 8'd1 : 8'd0);
    qzlcc = sat8(c[31] ? 8'd0 : state_r[115:108], qzlc ? 8'd1 : 8'd0);
    qbt = sat8(c[31] ? 8'd0 : state_r[123:116], 8'd1);
    r = qpos_n;
    x[15:0] = ivel_n;
    x[17:16] = (c[31] || qillegal) ? qns : (qbounce ? qps : qns);
    x[19:18] = qns;
    x[20] = qcount;
    x[21] = qcount && (qdir == 2'd1);
    x[22] = qillegal;
    x[23] = qbounce;
    x[24] = qjitter;
    x[25] = qzr;
    x[26] = c[31];
    x[27] = qarm;
    x[31:28] = qilt[3:0];
    state_n[31:0] = qpos_n;
    state_n[33:32] = (c[31] || qillegal) ? qns : (qbounce ? qps : qns);
    state_n[34] = qzl;
    state_n[50:35] = ivel_n;
    state_n[66:51] = qil;
    state_n[74:67] = qbstreak_n;
    state_n[82:75] = qilt;
    state_n[90:83] = qjlt;
    state_n[98:91] = qedgc;
    state_n[106:99] = qbnc;
    state_n[107] = qarm;
    state_n[115:108] = qzlcc;
    state_n[123:116] = qbt;
end
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        out_valid<=0; result<=0; aux<=0; fault<=0; state_r<=0;
    end else if(clk_en) begin
        if(in_ready) begin
            out_valid<=in_valid;
            if(in_valid) begin
                result<=r; aux<=x; fault<=f; state_r<=state_n;
            end
        end
    end
end
endmodule
