// ============================================================================
// st_tmr_voter -- selftest cell for tmr_voter + tmr_reg (idx37, TAG TMR).
//
// Scenario: 8 writes to a tmr_reg.  Write i injects a single-bit fault
// (mask = 1<<i) on replica (i mod 3); write 7 is clean.  One clk_en beat
// after each write the voter samples the triplicated register.
//   Folded per vote: byte0 = y (corrected data), byte1 = {4'b0, err, mism_c,
//   mism_b, mism_a}.  At the end: err_cnt[7:0], err_cnt[15:8] (== 7).
// Internal checks: y === din on every write (single faults always voted
//   away), err_cnt == 7, exactly 8 votes.
// EXP comes from tools/golden_acc.py only (trap T1).
// ============================================================================
module st_tmr_voter (
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

    localparam [31:0] EXP = 32'hDCA39FBD;   // golden_acc.py TMR

    reg         running;
    reg  [1:0]  ph;        // 0=write, 1=gap(vote samples), 2=collect, 3=fin
    reg  [1:0]  fin;       // substage of ph==3
    reg  [3:0]  idx;       // write index 0..7
    reg  [3:0]  idx_r;     // collect index
    reg  [1:0]  rep;       // replica to fault: 0=a,1=b,2=c
    reg  [3:0]  nvote;
    reg  [31:0] dg;
    reg         ok;
    reg  [7:0]  dbuf [0:7];
    reg  [31:0] dbg_data;
    reg  [2:0]  dbg_cnt;

    // DUT drive
    reg         wr;
    reg  [7:0]  din, fa, fb, fc;
    wire [7:0]  y;
    wire        y_valid, m_a, m_b, m_c, derr;
    wire [15:0] err_cnt;

    wire [7:0] din_f = ({4'b0, idx} << 5) ^ ({4'b0, idx} << 3) ^
                       ({4'b0, idx} << 1) ^ 8'h11;
    wire [7:0] mask  = (idx < 4'd7) ? (8'h01 << idx[2:0]) : 8'h00;

    tmr_reg #(.W(8)) u_dut (
        .clk(clk), .clk_en((clk_en && running) || !rst_n), .rst_n(rst_n),
        .wr(wr), .din(din), .fa(fa), .fb(fb), .fc(fc), .clr_cnt(1'b0),
        .y(y), .y_valid(y_valid),
        .mism_a(m_a), .mism_b(m_b), .mism_c(m_c),
        .err(derr), .err_cnt(err_cnt));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running   <= 1'b0;
            done      <= 1'b0;
            pass      <= 1'b0;
            digest    <= 32'h811C9DC5;
            cycles    <= 16'd0;
            ph        <= 2'd0;
            fin       <= 2'd0;
            idx       <= 4'd0;
            idx_r     <= 4'd0;
            rep       <= 2'd0;
            nvote     <= 4'd0;
            dg        <= 32'h811C9DC5;
            ok        <= 1'b1;
            wr        <= 1'b0;
            din       <= 8'd0;
            fa        <= 8'd0;
            fb        <= 8'd0;
            fc        <= 8'd0;
            dbg_data  <= 32'd0;
            dbg_cnt   <= 3'd0;
        end else if (clk_en) begin
            dbg_cnt <= 3'd0;
            if (start && !running && !done) begin
                running <= 1'b1;
                cycles  <= 16'd0;
                ph      <= 2'd0;
                fin     <= 2'd0;
                idx     <= 4'd0;
                idx_r   <= 4'd0;
                rep     <= 2'd0;
                nvote   <= 4'd0;
                dg      <= 32'h811C9DC5;
                ok      <= 1'b1;
            end else if (running && !done) begin
                cycles <= cycles + 16'd1;
                case (ph)
                    // ---- issue write with fault injection --------------
                    2'd0: begin
                        wr  <= 1'b1;
                        din <= din_f;
                        fa  <= (rep == 2'd0) ? mask : 8'd0;
                        fb  <= (rep == 2'd1) ? mask : 8'd0;
                        fc  <= (rep == 2'd2) ? mask : 8'd0;
                        dbuf[idx] <= din_f;
                        rep <= (rep == 2'd2) ? 2'd0 : rep + 2'd1;
                        ph  <= 2'd1;
                    end
                    // ---- voter samples the replicas this beat ----------
                    2'd1: begin
                        wr <= 1'b0;
                        ph <= 2'd2;
                    end
                    // ---- collect voted output --------------------------
                    2'd2: begin
                        if (y_valid) begin
                            dg       <= fnv(fnv(dg, y),
                                            {4'b0, derr, m_c, m_b, m_a});
                            dbg_data <= {16'b0, 4'b0, derr, m_c, m_b, m_a, y};
                            dbg_cnt  <= 3'd2;
                            nvote    <= nvote + 4'd1;
                            if (y !== dbuf[idx_r]) ok <= 1'b0;
                            idx_r <= idx_r + 4'd1;
                            if (nvote == 4'd7) begin
                                ph  <= 2'd3;
                                fin <= 2'd0;
                            end else begin
                                ph  <= 2'd0;
                                idx <= idx + 4'd1;
                            end
                        end
                    end
                    // ---- fold sticky error counter, finish -------------
                    default: begin
                        if (fin == 2'd0) begin
                            dg       <= fnv(dg, err_cnt[7:0]);
                            dbg_data <= {24'b0, err_cnt[7:0]};
                            dbg_cnt  <= 3'd1;
                            fin      <= 2'd1;
                        end else if (fin == 2'd1) begin
                            dg       <= fnv(dg, err_cnt[15:8]);
                            dbg_data <= {24'b0, err_cnt[15:8]};
                            dbg_cnt  <= 3'd1;
                            fin      <= 2'd2;
                        end else begin
                            done   <= 1'b1;
                            digest <= dg;
                            pass   <= (dg === EXP) && ok &&
                                      (err_cnt == 16'd7) && (nvote == 4'd8);
                        end
                    end
                endcase
            end
        end
    end
endmodule
