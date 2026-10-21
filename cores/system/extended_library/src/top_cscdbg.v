// ============================================================================
// top_cscdbg -- debug top: stream isp_csc DUT output bytes over UART.
// Same stimulus/DUT as st_isp_csc (w2_img_stim 32x32x2 -> isp_csc), but
// instead of a digest it UARTs every o_v byte plus a "D=XXXXXXXX" trailer.
// Stimulus paced 8192 clk/beat so the 115200 UART (2340 clk/byte) keeps up.
// ============================================================================
module top_cscdbg (
    input  wire clk,
    output wire uart_tx,
    output wire status_pass,
    output wire status_fail
);
    reg [12:0] reset_count = 13'd0;
    wire rst_n = reset_count[12];
    always @(posedge clk) if (!rst_n) reset_count <= reset_count + 13'd1;

    // slow pace: one clk_en beat per 8192 clk (3 UART bytes = 7029 clk fit)
    reg [12:0] ce_div = 13'd0;
    wire ce = (ce_div == 13'd8191);
    always @(posedge clk) ce_div <= ce_div + 13'd1;

    reg run = 1'b0;
    wire cev = (ce & run) | ~rst_n;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) run <= 1'b0;
        else if (ce && !run) run <= 1'b1;

    wire [23:0] s_p24;
    wire        s_pv, s_nl, s_done;
    wire [7:0]  s_fidx;
    w2_img_stim #(.IMG_W(32), .IMG_H(32), .N_FRAMES(2)) u_stim (
        .clk(clk), .clk_en(cev), .rst_n(rst_n),
        .pix(), .pix24(s_p24), .pix_valid(s_pv), .new_line(s_nl),
        .fidx(s_fidx), .stim_done(s_done));

    wire [23:0] o_dat;
    wire        o_v, o_nl;
    isp_csc u_dut (
        .clk(clk), .clk_en(cev), .rst_n(rst_n),
        .pix24(s_p24), .pix_valid(s_pv), .new_line(s_nl),
        .mode(s_fidx[0]),
        .pix24_out(o_dat), .out_valid(o_v), .nl_out(o_nl));

    `include "w2_fnv.vh"
    reg [31:0] digest;
    reg [15:0] ocnt;
    reg done_r, tail_done;
    reg [3:0]  tail;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            digest <= 32'h811C9DC5; ocnt <= 16'd0;
            done_r <= 1'b0; tail <= 4'd0;
        end else if (ce) begin
            if (run && !done_r) begin
                if (o_v) begin
                    digest <= fnv(fnv(fnv(digest, o_dat[23:16]),
                                      o_dat[15:8]), o_dat[7:0]);
                    ocnt <= ocnt + 16'd1;
                end
                if (s_done) begin
                    if (tail == 4'd8) done_r <= 1'b1;
                    else tail <= tail + 4'd1;
                end
            end
        end
    end

    // ---------------- UART byte queue ------------------------------------
    reg [7:0] q [0:15];
    reg [3:0] q_w, q_r;
    reg [4:0] q_n;
    reg tx_valid;
    wire tx_ready, tx_busy;

    reg [23:0] enq_dat;
    reg [7:0]  tx_dat;
    reg [1:0]  enq_st;
    reg [3:0]  tr_idx;
    reg        tr_busy, tr_done;

    function [7:0] hex_nibble;
        input [3:0] v;
        hex_nibble = (v < 10) ? (8'h30 + v) : (8'h41 + v - 10);
    endfunction

    function [7:0] tr_char;
        input [3:0] i;
        case (i)
            4'd0: tr_char = "D"; 4'd1: tr_char = "=";
            4'd2: tr_char = hex_nibble(digest[31:28]);
            4'd3: tr_char = hex_nibble(digest[27:24]);
            4'd4: tr_char = hex_nibble(digest[23:20]);
            4'd5: tr_char = hex_nibble(digest[19:16]);
            4'd6: tr_char = hex_nibble(digest[15:12]);
            4'd7: tr_char = hex_nibble(digest[11:8]);
            4'd8: tr_char = hex_nibble(digest[7:4]);
            4'd9: tr_char = hex_nibble(digest[3:0]);
            4'd10: tr_char = 8'h0d; default: tr_char = 8'h0a;
        endcase
    endfunction

    // o_v is a LEVEL held between ce beats -- enqueue once per ce edge only
    wire enq_req = (ce && o_v && enq_st == 0 && !tr_busy && q_n <= 5'd13);
    wire tr_req  = (done_r && !tr_done && !tr_busy && enq_st == 0 && q_n <= 5'd4);
    wire push  = (enq_st != 0) || tr_busy;
    wire pop   = (!tx_valid && !tx_busy && q_n != 0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_w <= 0; q_r <= 0; q_n <= 0;
            enq_st <= 0; enq_dat <= 0;
            tr_idx <= 0; tr_busy <= 0; tr_done <= 0;
            tx_valid <= 0; tx_dat <= 8'd0;
        end else begin
            // enqueue side (payload burst of 3, then trailer of 12)
            if (enq_req) begin
                enq_dat <= o_dat; enq_st <= 2'd1;
            end else if (enq_st != 0) begin
                q[q_w] <= enq_dat[23:16];
                enq_dat <= {enq_dat[15:0], 8'd0};
                q_w <= q_w + 4'd1;
                enq_st <= (enq_st == 2'd3) ? 2'd0 : enq_st + 2'd1;
            end
            if (tr_req) tr_busy <= 1'b1;
            else if (tr_busy) begin
                q[q_w] <= tr_char(tr_idx);
                q_w <= q_w + 4'd1;
                tr_idx <= tr_idx + 4'd1;
                if (tr_idx == 4'd11) begin tr_busy <= 1'b0; tr_done <= 1'b1; end
            end
            // pop side -- latch the byte being sent (tx_data must stay stable
            // through the accept edge; q_r may advance immediately)
            if (tx_valid && tx_busy) begin
                tx_valid <= 1'b0;
            end else if (pop) begin
                tx_valid <= 1'b1;
                tx_dat <= q[q_r];
                q_r <= q_r + 4'd1;
            end
            // occupancy
            case ({push, pop})
                2'b10: q_n <= q_n + 5'd1;
                2'b01: q_n <= q_n - 5'd1;
                default: q_n <= q_n;
            endcase
        end
    end

    uart_tx #(.CLK_FRE(27), .BAUD_RATE(115200)) uart (
        .clk(clk), .rst_n(rst_n),
        .tx_data(tx_dat), .tx_data_valid(tx_valid),
        .tx_data_ready(tx_ready), .tx_pin(uart_tx), .tx_busy(tx_busy));

    assign status_pass = done_r && (digest === 32'hCE41D92D) && (ocnt == 16'd2048);
    assign status_fail = done_r && !status_pass;
endmodule
