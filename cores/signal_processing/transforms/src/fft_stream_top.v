// ============================================================================
// fft_stream_top -- debug top: verbatim copy of sig_selftest's U0 FFT control
// FSM (ce=1/16, comb ld_re via stim_fft/costab, F_LOAD..F_RDC timing, same
// clk_en=ce||!rst_n), but each hashed read is also streamed over UART:
//   per read: [0x40|fvec][addr][reH][reL][imH][imL]   (6 bytes x 256 reads)
//   per vec end: [0x80|fvec][dg0][dg1][dg2][dg3]      (vec digest snapshot)
// uart/dbg_uart -> A11 (LA D0).
// ============================================================================
module fft_stream_top (
    input  wire clk,
    output wire uart_tx,
    output wire dbg_uart
);

// ---------------------------------------------------------------- exact copy
function [31:0] fnv;
    input [31:0] h;
    input [7:0]  b;
    reg [31:0] x;
    begin
        x = h ^ {24'd0, b};
        fnv = x + (x << 1) + (x << 4) + (x << 7) + (x << 8) + (x << 24);
    end
endfunction

function signed [31:0] mul16;
    input signed [15:0] a;
    input signed [15:0] b;
    reg signed [31:0] acc, sa;
    integer i;
    begin
        sa  = a;
        acc = 32'sd0;
        for (i = 0; i < 15; i = i + 1)
            if (b[i]) acc = acc + (sa <<< i);
        if (b[15]) acc = acc - (sa <<< 15);
        mul16 = acc;
    end
endfunction

reg [3:0] ce_div = 4'd0;
wire ce = (ce_div == 4'd15);
always @(posedge clk) ce_div <= ce_div + 4'd1;

localparam [3:0] F_LOAD  = 4'd1;
localparam [3:0] F_START = 4'd2;
localparam [3:0] F_WBUSY = 4'd7;
localparam [3:0] F_WAIT  = 4'd3;
localparam [3:0] F_RDQ   = 4'd4;
localparam [3:0] F_RDZ   = 4'd6;
localparam [3:0] F_RDC   = 4'd5;
localparam [3:0] F_SND   = 4'd8;   // extra: wait for UART send of this record
localparam [3:0] F_SNDV  = 4'd9;   // extra: vec-end digest record send
localparam [3:0] F_SNDW  = 4'd10;

reg signed [15:0] costab [0:31];
initial $readmemh("fft64_cos.mem", costab);

function signed [15:0] stim_fft;
    input [1:0] v;
    input [5:0] n;
    reg [5:0] ci;
    reg signed [15:0] c;
    begin
        case (v)
            2'd0: stim_fft = (n == 6'd0) ? 16'sd16384 : 16'sd0;
            2'd1: stim_fft = 16'sd4096;
            2'd2: begin
                ci = {n[3:0], 2'b00};
                c  = ci[5] ? -costab[ci[4:0]] : costab[ci[4:0]];
                stim_fft = c >>> 2;
            end
            default: stim_fft = n[0] ? -16'sd8192 : 16'sd8192;
        endcase
    end
endfunction

// fused magnitude-squared: re^2+im^2 in ONE shift-add network -> completely
// different mapped structure than mul16(re,re)+mul16(im,im)
function signed [31:0] mag_sq;
    input signed [15:0] a;
    input signed [15:0] b;
    reg signed [31:0] acc, sa, sb;
    integer i;
    begin
        sa  = a;
        sb  = b;
        acc = 32'sd0;
        for (i = 0; i < 15; i = i + 1) begin
            if (a[i]) acc = acc + (sa <<< i);
            if (b[i]) acc = acc + (sb <<< i);
        end
        if (a[15]) acc = acc - (sa <<< 15);
        if (b[15]) acc = acc - (sb <<< 15);
        mag_sq = acc;
    end
endfunction

reg [3:0]  fstate;
reg [1:0]  fvec;
reg [7:0]  fcnt;
reg        f_done;
reg [31:0] f_dg = 32'h811c9dc5;
reg [31:0] f_dg2 = 32'h811c9dc5;   // digest over fused mag_sq path
reg [23:0] rerun_cnt = 24'd0;          // auto-rerun every ~0.62s
always @(posedge clk) rerun_cnt <= rerun_cnt + 24'd1;
reg        fft_ld_en, fft_start, fft_rd_en;
reg [5:0]  fft_ld_addr, fft_rd_addr;
wire       fft_busy, fft_done;
wire signed [15:0] fft_rd_re, fft_rd_im;
// HW-DEBUG: mul16(re,re)+mul16(im,im) produces bit2|=bit0 on this silicon
// (deterministic; verified vs netlist sim).  Try the fused form instead.
wire [31:0] fft_mag2 = mag_sq(fft_rd_re, fft_rd_im);
wire [31:0] fft_mag2b = mul16(fft_rd_re, fft_rd_re) +
                        mul16(fft_rd_im, fft_rd_im);   // suspect path, watch-only

// power-on reset identical to top.v (4096 clk; fft clk_en=ce||!rst_n)
reg [12:0] reset_count = 13'd0;
wire rst_n = reset_count[12];
always @(posedge clk) if (!rst_n) reset_count <= reset_count + 13'd1;

fft64 u_fft (
    .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
    .ld_en(fft_ld_en), .ld_addr(fft_ld_addr),
    .ld_re(stim_fft(fvec, fft_ld_addr)), .ld_im(16'sd0),
    .start(fft_start), .busy(fft_busy), .done(fft_done),
    .rd_en(fft_rd_en), .rd_addr(fft_rd_addr),
    .rd_re(fft_rd_re), .rd_im(fft_rd_im)
);

// ---------------------------------------------------------------- sender
// full-rate UART sender; the ce-FSM parks in F_SND until send_ack.
reg        send_req;
reg        send_ack;
reg [7:0]  snap_addr;
reg [15:0] snap_re, snap_im;
reg [31:0] snap_dg;
reg [31:0] snap_mag;            // fft_mag2 snapshot -- the hashed word
reg        snap_isvec;          // 1: vec-end digest record, 0: bin record
reg [4:0]  sbyte;
reg [7:0]  tx_latched;
reg        tx_valid;
wire       tx_ready, tx_busy;

uart_tx #(.CLK_FRE(27), .BAUD_RATE(115200)) uart (
    .clk(clk), .rst_n(rst_n),
    .tx_data(tx_latched), .tx_data_valid(tx_valid),
    .tx_data_ready(tx_ready), .tx_pin(dbg_uart), .tx_busy(tx_busy)
);
assign uart_tx = dbg_uart;

// bin record (14 B): [40|a&3][addr][reH][reL][imH][imL][magA 31:24..7:0]
//                    [magB 31:24..7:0]  -- magA=mul16+mul16, magB=fused mag_sq
// vec record (9 B):  [80|v][dgA0..3][dgB0..3]
reg [31:0] snap_magb;
reg [31:0] snap_dgb;
wire [7:0] sdata =
    snap_isvec ?
      ((sbyte == 4'd0) ? (8'h80 | {6'd0, snap_addr[1:0]}) :
       (sbyte == 4'd1) ? snap_dg[7:0]   :
       (sbyte == 4'd2) ? snap_dg[15:8]  :
       (sbyte == 4'd3) ? snap_dg[23:16] :
                         snap_dg[31:24]) :
      ((sbyte == 4'd0) ? (8'h40 | {6'd0, snap_addr[1:0]}) :
       (sbyte == 4'd1) ? snap_addr :
       (sbyte == 4'd2) ? snap_re[15:8] :
       (sbyte == 4'd3) ? snap_re[7:0]  :
       (sbyte == 4'd4) ? snap_im[15:8] :
       (sbyte == 4'd5) ? snap_im[7:0]  :
       (sbyte == 4'd6) ? snap_mag[31:24] :
       (sbyte == 4'd7) ? snap_mag[23:16] :
       (sbyte == 4'd8) ? snap_mag[15:8]  :
       (sbyte == 4'd9) ? snap_mag[7:0]   :
       (sbyte == 4'd10) ? snap_magb[31:24] :
       (sbyte == 4'd11) ? snap_magb[23:16] :
       (sbyte == 4'd12) ? snap_magb[15:8]  :
                          snap_magb[7:0]);

wire [4:0] slen = snap_isvec ? 5'd4 : 5'd13;   // last byte index

// status heartbeat: if the FSM stalls, stream fstate/fvec/fcnt/f_done so we
// can see where it is.  Fires only when no record send is in flight.
reg [24:0] hb_cnt;
reg        hb_pend;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        send_ack <= 1'b0; sbyte <= 3'd0;
        tx_latched <= 8'd0; tx_valid <= 1'b0;
        hb_cnt <= 25'd0; hb_pend <= 1'b0;
    end else begin
        if (!send_req) send_ack <= 1'b0;               // level handshake
        hb_cnt <= hb_cnt + 25'd1;
        if (&hb_cnt) hb_pend <= 1'b1;                  // every ~1.24 s
        // Present/wait-busy handshake: hold tx_valid until the UART has
        // actually left S_IDLE (proof the byte was latched), then advance.
        // (The old code advanced sbyte on tx_ready alone; at the accept edge
        // tx_ready is still 1 for one extra clk, so every odd byte was
        // re-asserted into a busy UART and silently dropped.)
        if (send_req && !send_ack) begin
            if (!tx_valid) begin
                if (tx_ready) begin
                    tx_latched <= sdata;
                    tx_valid   <= 1'b1;      // present byte k
                end
            end else if (tx_busy) begin
                tx_valid <= 1'b0;            // byte k was accepted
                if (sbyte == slen) begin
                    sbyte    <= 3'd0;
                    send_ack <= 1'b1;        // record done -> release FSM
                end else sbyte <= sbyte + 3'd1;
            end
        end else begin
            tx_valid <= 1'b0;
            if (hb_pend && tx_ready && !tx_busy) begin
                // heartbeat: [0xF0 | fstate] [fvec..fcnt..busy..done flags]
                if (sbyte == 3'd0) begin
                    tx_latched <= 8'hF0 | {4'd0, fstate};
                    tx_valid   <= 1'b1;
                    sbyte      <= 3'd1;
                end else begin
                    tx_latched <= {f_done, fft_done, fft_busy, fvec, fcnt[2:0]};
                    tx_valid   <= 1'b1;
                    sbyte      <= 3'd0;
                    hb_pend    <= 1'b0;
                end
            end else if (tx_valid && tx_busy) begin
                tx_valid <= 1'b0;            // heartbeat byte accepted
            end
        end
    end
end

// ------------------------------------------------- selftest U0 FSM + streaming
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        fstate <= F_LOAD; fvec <= 2'd0; fcnt <= 8'd0;
        f_done <= 1'b0; f_dg <= 32'h811c9dc5; f_dg2 <= 32'h811c9dc5;
        fft_ld_en <= 1'b0; fft_start <= 1'b0; fft_rd_en <= 1'b0;
        fft_ld_addr <= 6'd0; fft_rd_addr <= 6'd0;
        send_req <= 1'b0;
        snap_addr <= 8'd0; snap_re <= 16'd0; snap_im <= 16'd0;
        snap_dg <= 32'd0; snap_mag <= 32'd0; snap_magb <= 32'd0;
        snap_dgb <= 32'd0; snap_isvec <= 1'b0;
    end else if (ce && !f_done) begin
        fft_ld_en <= 1'b0; fft_start <= 1'b0; fft_rd_en <= 1'b0;
        case (fstate)
            F_LOAD: begin
                fft_ld_en <= 1'b1;
                fft_ld_addr <= fcnt[5:0];
                if (fcnt == 8'd63) begin
                    fcnt <= 8'd0; fstate <= F_START;
                end else begin
                    fcnt <= fcnt + 8'd1;
                end
            end
            F_START: begin
                fft_start <= 1'b1;
                fstate <= F_WBUSY;
            end
            F_WBUSY: begin
                if (fft_busy) fstate <= F_WAIT;
            end
            F_WAIT: begin
                if (fft_done) begin
                    fcnt <= 8'd0; fstate <= F_RDQ;
                end
            end
            F_RDQ: begin
                fft_rd_en <= 1'b1;
                fft_rd_addr <= fcnt[5:0];
                fstate <= F_RDZ;
            end
            F_RDZ: begin
                fstate <= F_RDC;
            end
            F_RDC: begin
                f_dg <= fnv(fnv(fnv(fnv(f_dg, fft_mag2[7:0]),
                            fft_mag2[15:8]), fft_mag2[23:16]), fft_mag2[31:24]);

                // snapshot & queue this record for streaming
                snap_addr  <= fcnt;
                snap_re    <= fft_rd_re;
                snap_im    <= fft_rd_im;
                snap_mag   <= fft_mag2;    // the word f_dg just absorbed
                snap_magb  <= fft_mag2b;   // fused-path word
                snap_isvec <= 1'b0;
                send_req   <= 1'b1;
                fstate     <= F_SND;
            end
            F_SND: begin
                if (send_ack) begin
                    send_req <= 1'b0;
                    if (fcnt == 8'd63) begin
                        // queue vec-end digest record (re-arm request)
                        snap_isvec <= 1'b1;
                        snap_addr  <= {6'd0, fvec};
                        snap_dg    <= f_dg;      // already includes this hash
                        snap_dgb   <= f_dg2;     // fused-path digest
                        fstate     <= F_SNDV;
                    end else begin
                        fcnt <= fcnt + 8'd1;
                        fstate <= F_RDQ;
                    end
                end
            end
            F_SNDV: begin
                send_req <= 1'b1;                // re-assert for vec record
                fstate   <= F_SNDW;
            end
            F_SNDW: begin
                if (send_ack) begin
                    send_req <= 1'b0;
                    fcnt <= 8'd0;
                    if (fvec == 2'd3) begin
                        f_done <= 1'b1;
                    end else begin
                        fvec <= fvec + 2'd1;
                        fstate <= F_LOAD;
                    end
                end
            end
            default: fstate <= F_LOAD;
        endcase
    end else if (ce && f_done && (&rerun_cnt)) begin
        // periodic re-run so a late LA capture still catches a full pass
        f_done <= 1'b0; fstate <= F_LOAD; fvec <= 2'd0;
        fcnt <= 8'd0; f_dg <= 32'h811c9dc5; f_dg2 <= 32'h811c9dc5;
    end
end

endmodule
