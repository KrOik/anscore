// ============================================================================
// isp_demosaic -- Bayer RGGB -> RGB888 bilinear interpolation on a streaming
// 3x3 window (win3x3_gen / w2_win_rd layout, edge-replicated taps).
//
// Phase of output pixel (x,y) is tracked internally: new_line_out must pulse
// on the first window of each output row (x==0), exactly as win3x3_gen emits.
//   (yp,xp) = 00 R site : R=c,        G=avg4(cross),  B=avg4(diag)
//             01 G on R row: R=avg2(lf,rt), G=c,      B=avg2(up,dn)
//             10 G on B row: R=avg2(up,dn), G=c,      B=avg2(lf,rt)
//             11 B site : R=avg4(diag),     G=avg4(cross), B=c
// Averages truncate (>>1 / >>2); identical rule in tools/golden_isp.py.
// Registered output, one clk_en beat latency.  All registers clk_en gated.
// ============================================================================
module isp_demosaic #(
    parameter IMG_W = 32,
    parameter LW    = (IMG_W > 1) ? $clog2(IMG_W) : 1
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [71:0] win,
    input  wire        win_valid,
    input  wire        new_line_out,
    output reg  [23:0] rgb_out,      // {R,G,B}
    output reg         out_valid,
    output reg         nl_out
);
    // taps: 0=tl 1=up 2=tr / 3=lf 4=c 5=rt / 6=bl 7=dn 8=br
    wire [7:0] tl = win[7:0];
    wire [7:0] up = win[15:8];
    wire [7:0] tr = win[23:16];
    wire [7:0] lf = win[31:24];
    wire [7:0] c  = win[39:32];
    wire [7:0] rt = win[47:40];
    wire [7:0] bl = win[55:48];
    wire [7:0] dn = win[63:56];
    wire [7:0] br = win[71:64];

    wire [9:0] csum  = {2'b00, up} + {2'b00, dn} + {2'b00, lf} + {2'b00, rt};
    wire [9:0] dsum  = {2'b00, tl} + {2'b00, tr} + {2'b00, bl} + {2'b00, br};
    wire [7:0] g4 = csum[9:2];
    wire [7:0] d4 = dsum[9:2];
    wire [8:0] hs = {1'b0, lf} + {1'b0, rt};
    wire [8:0] vs = {1'b0, up} + {1'b0, dn};
    wire [7:0] h2 = hs[8:1];
    wire [7:0] v2 = vs[8:1];

    // Bayer phase tracking: xc = column index in row, yc = row parity counter.
    // new_line_out marks x==0 (this pixel IS column 0); yc increments on the
    // LAST pixel of each row so all pixels of row r see yc == r.
    reg  [LW-1:0] xc;
    reg           yc;
    wire          xp = new_line_out ? 1'b0 : xc[0];
    wire          yp = yc;

    reg [23:0] pix_c;
    always @(*) begin
        case ({yp, xp})
            2'b00:   pix_c = {c,  g4, d4};   // R site
            2'b01:   pix_c = {h2, c,  v2};   // G on R row
            2'b10:   pix_c = {v2, c,  h2};   // G on B row
            default: pix_c = {d4, g4, c};    // B site
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xc        <= {LW{1'b0}};
            yc        <= 1'b0;
            rgb_out   <= 24'd0;
            out_valid <= 1'b0;
            nl_out    <= 1'b0;
        end else if (clk_en) begin
            rgb_out   <= pix_c;
            out_valid <= win_valid;
            nl_out    <= new_line_out;
            if (win_valid) begin
                if (new_line_out) xc <= {{(LW-1){1'b0}}, 1'b1};
                else              xc <= xc + 1'b1;
                if (xc == IMG_W - 1) yc <= yc + 1'b1;
            end
        end
    end
endmodule
