`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// top_sm2.v — Tang Primer 20K board image B: UART command shell over
// sm2_ecc (JAC_ONLY Jacobian point engine).
//
// The GW2A-18C cannot host the monolithic sm2_top protocol layer, so this
// image exposes only the ECC primitives (PMUL_G / PMUL_P / PADD, Jacobian
// out).  SM3 hashing lives in image A (top_aes); the host performs affine
// conversion, mod-n arithmetic and protocol sequencing (see
// host/crypto_uart.py).
//
// UART 115200 8N1.  Binary commands (host -> FPGA):
//   'H' 0x48                ping                    -> "OK"
//   'S' 0x53                status -> 1B {4'b0, err, inf, done, busy}
//   'L' 0x4C sel d[32]      load 256b param 0:k 1:ax 2:ay 3:bx 4:by  -> 'l'
//   'G' 0x47 op             run ECC op (0=PMUL_G 1=PMUL_P 2=PADD)
//                                                              -> 'D' 1B {6'b0,err,inf}
//   'Q' 0x51 sel            read result (0:x 1:y 2:z)                -> 32B
//////////////////////////////////////////////////////////////////////////////////
module top_sm2(
    input  wire       clk,        // 27 MHz, H11
    input  wire       rst_n,      // T10 pushbutton (active low)
    input  wire       uart_rx,    // T13
    output wire       uart_tx,    // M11
    output wire [5:0] led
);

// ---------------- UART -------------------------------------------------------
wire       rx_dv;
wire [7:0] rx_d;

uart_rx #(.CLK_HZ(27000000), .BAUD(115200)) U_RX(
    .clk(clk), .rst(~rst_n), .rx(uart_rx),
    .data_valid(rx_dv), .data(rx_d)
);

reg        tx_dv;
reg  [7:0] tx_d;
wire       tx_rdy, tx_busy;

uart_tx #(.CLK_FRE(27), .BAUD_RATE(115200)) U_TX(
    .clk(clk), .rst_n(rst_n),
    .tx_data(tx_d), .tx_data_valid(tx_dv),
    .tx_data_ready(tx_rdy), .tx_pin(uart_tx), .tx_busy(tx_busy)
);

// ---------------- TX response FIFO (64B ring) ---------------------------------
reg  [7:0] txq [0:63];
reg  [5:0] txq_w, txq_r;

reg        resp_we;
reg  [7:0] resp_d;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        txq_w <= 0; txq_r <= 0; tx_dv <= 0; tx_d <= 0;
    end else begin
        if (resp_we) begin
            txq[txq_w] <= resp_d;
            txq_w      <= txq_w + 6'd1;
        end
        tx_dv <= 1'b0;
        if (txq_r != txq_w && tx_rdy && !tx_dv) begin
            tx_d  <= txq[txq_r];
            tx_dv <= 1'b1;
            txq_r <= txq_r + 6'd1;
        end
    end
end

// ---------------- ECC engine (Jacobian out) -----------------------------------
reg          ecc_start;
reg  [1:0]   ecc_op;
reg  [255:0] p_k, p_ax, p_ay, p_bx, p_by;
wire         ecc_busy, ecc_done, ecc_inf, ecc_err;
wire [255:0] ecc_rx, ecc_ry, ecc_rz;

sm2_ecc #(.JAC_ONLY(1)) U_ECC(
    .clk(clk), .rst_n(rst_n),
    .start(ecc_start), .op_i(ecc_op), .k_i(p_k),
    .ax_i(p_ax), .ay_i(p_ay), .bx_i(p_bx), .by_i(p_by),
    .busy_o(ecc_busy), .done_o(ecc_done), .inf_o(ecc_inf), .err_o(ecc_err),
    .rx_o(ecc_rx), .ry_o(ecc_ry), .rz_o(ecc_rz)
);

// ---------------- command parser ----------------------------------------------
// 二改: payload gather replaced by a 256-bit shift register (l_shf) — the
// 34-byte pb[] array and its wide byte-gather muxes cost too many LUT4s.
// 'L' = sel byte + 32 data bytes (BE); 'G'/'Q' take a single op/sel byte.
localparam P_CMD  = 4'd0;
localparam P_LSEL = 4'd1;   // 'L' read sel byte
localparam P_LDAT = 4'd2;   // 'L' shift in 32 data bytes
localparam P_GO   = 4'd3;   // 'G' read op byte + start pulse
localparam P_GW   = 4'd4;   // 'G' wait done
localparam P_GS   = 4'd5;   // 'G' push status
localparam P_Q    = 4'd6;   // 'Q' read sel + push 32B result
localparam P_ACK  = 4'd11;  // second byte of a 2B response

reg  [3:0]  pstate;
reg  [5:0]  pb_cnt;
reg  [2:0]  l_sel;
reg  [255:0] l_shf;           // 'L' data shift register
reg  [255:0] q_word;
reg  [5:0]  q_cnt;
reg  [7:0]  ack_ch;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        pstate <= P_CMD; pb_cnt <= 0; l_sel <= 0; l_shf <= 0;
        q_cnt <= 0; q_word <= 0; ack_ch <= 0;
        resp_we <= 0; resp_d <= 0;
        ecc_start <= 0; ecc_op <= 0;
        p_k <= 0; p_ax <= 0; p_ay <= 0; p_bx <= 0; p_by <= 0;
    end else begin
        resp_we   <= 1'b0;
        ecc_start <= 1'b0;

        case (pstate)
        P_CMD: begin
            if (rx_dv) begin
                case (rx_d)
                    8'h4C: pstate <= P_LSEL;             // 'L'
                    8'h47: pstate <= P_GO;               // 'G'
                    8'h51: pstate <= P_Q;                // 'Q'
                    8'h48: begin                       // 'H' -> "OK"
                        resp_we <= 1'b1; resp_d <= 8'h4F;
                        ack_ch  <= 8'h4B; pstate <= P_ACK;
                    end
                    8'h53: begin                       // 'S' -> status byte
                        resp_we <= 1'b1;
                        resp_d  <= {4'b0, ecc_err, ecc_inf, ecc_done, ecc_busy};
                    end
                    default: ;
                endcase
            end
        end

        P_LSEL: begin   // 'L': sel byte first
            if (rx_dv) begin
                l_sel  <= rx_d[2:0];
                l_shf  <= 256'd0;
                pb_cnt <= 6'd0;
                pstate <= P_LDAT;
            end
        end

        P_LDAT: begin   // 'L': shift in 32 data bytes, MSB first
            if (rx_dv) begin
                l_shf  <= {l_shf[247:0], rx_d};
                pb_cnt <= pb_cnt + 6'd1;
                if (pb_cnt == 6'd31) begin
                    case (l_sel)
                        3'd0: p_k  <= {l_shf[247:0], rx_d};
                        3'd1: p_ax <= {l_shf[247:0], rx_d};
                        3'd2: p_ay <= {l_shf[247:0], rx_d};
                        3'd3: p_bx <= {l_shf[247:0], rx_d};
                        3'd4: p_by <= {l_shf[247:0], rx_d};
                        default: ;
                    endcase
                    resp_we <= 1'b1; resp_d <= 8'h6C;    // 'l'
                    pstate  <= P_CMD;
                end
            end
        end

        P_GO: begin
            if (rx_dv) begin
                ecc_op    <= rx_d[1:0];
                ecc_start <= 1'b1;
                pstate    <= P_GW;
            end
        end
        P_GW: begin
            if (ecc_done) begin
                resp_we <= 1'b1; resp_d <= 8'h44;      // 'D'
                ack_ch  <= {6'b0, ecc_err, ecc_inf};
                pstate  <= P_GS;
            end
        end
        P_GS: begin
            resp_we <= 1'b1; resp_d <= ack_ch;
            pstate  <= P_CMD;
        end

        P_Q: begin
            if (q_cnt == 6'd0) begin
                if (rx_dv) begin
                    case (rx_d[1:0])
                        2'd0: q_word <= ecc_rx;
                        2'd1: q_word <= ecc_ry;
                        default: q_word <= ecc_rz;
                    endcase
                    q_cnt <= 6'd1;
                end
            end else begin
                resp_we <= 1'b1; resp_d <= q_word[255 -: 8];
                q_word  <= {q_word[247:0], 8'h00};
                if (q_cnt == 6'd32) begin
                    q_cnt  <= 0;
                    pstate <= P_CMD;
                end else
                    q_cnt <= q_cnt + 6'd1;
            end
        end

        P_ACK: begin
            resp_we <= 1'b1; resp_d <= ack_ch;
            pstate  <= P_CMD;
        end

        default: pstate <= P_CMD;
        endcase
    end
end

// ---------------- LEDs ---------------------------------------------------------
assign led = {~ecc_err, ~ecc_inf, ~ecc_done, ~ecc_busy, 2'b11};

endmodule
