`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// top.v — Tang Primer 20K board top: UART command shell over sm2_top + aes_core
//
// UART 115200 8N1.  Binary commands (host -> FPGA):
//   'H' 0x48                ping          -> "OK"
//   'S' 0x53                status        -> 1B {4'b0, valid, err, done, busy}
//   'L' 0x4C sel d[32]      load 256b param (sel 0..9, big-endian)  -> 'l'
//   'W' 0x57 addr d         write m_buf byte                       -> 'w'
//   'R' 0x52 addr           read  o_buf byte                       -> 1B data
//   'G' 0x47 op             run sm2 op (0..5), wait done
//                                                              -> 'D' 1B {6'b0,err,valid}
//   'Q' 0x51 sel            read result (0:rx 1:ry 2:sr 3:ss 4:c3) -> 32B
//   'A' 0x41 klen k[32]     AES key: klen 0=128b (k[0:15]), 1=256b -> 'a'
//   'E' 0x45 ed blk[16]     AES run block, ed 1=enc 0=dec          -> 16B result
//////////////////////////////////////////////////////////////////////////////////
module top(
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

// ---------------- SM2 engine --------------------------------------------------
reg          sm2_start;
reg  [2:0]   sm2_op;
reg          p_we;
reg  [3:0]   p_sel;
reg  [255:0] p_data;
reg          m_we;
reg  [8:0]   m_addr;
reg  [7:0]   m_data;
reg  [8:0]   o_addr;
wire [7:0]   o_data;
wire         sm2_busy, sm2_done, sm2_err, sm2_valid;
wire [255:0] sm2_rx, sm2_ry, sm2_sr, sm2_ss, sm2_c3;

sm2_top U_SM2(
    .clk(clk), .rst_n(rst_n),
    .start(sm2_start), .op_i(sm2_op),
    .p_we(p_we), .p_sel(p_sel), .p_data(p_data),
    .m_we(m_we), .m_addr(m_addr), .m_data(m_data),
    .o_addr(o_addr), .o_data(o_data),
    .busy_o(sm2_busy), .done_o(sm2_done), .err_o(sm2_err), .valid_o(sm2_valid),
    .rx_o(sm2_rx), .ry_o(sm2_ry), .sr_o(sm2_sr), .ss_o(sm2_ss), .c3_o(sm2_c3)
);

// ---------------- AES core ----------------------------------------------------
reg          aes_init, aes_next, aes_encdec;
reg  [255:0] aes_key;
reg          aes_keylen;
reg  [127:0] aes_blk;
wire         aes_rdy, aes_rvld;
wire [127:0] aes_res;

aes_core U_AES(
    .clk(clk), .reset_n(rst_n),
    .encdec(aes_encdec), .init(aes_init), .next(aes_next),
    .ready(aes_rdy), .key(aes_key), .keylen(aes_keylen),
    .block(aes_blk), .result(aes_res), .result_valid(aes_rvld)
);

// ---------------- command parser ----------------------------------------------
localparam P_CMD  = 4'd0;
localparam P_PAY  = 4'd1;
localparam P_PLD  = 4'd2;   // 'L' param write pulse
localparam P_PMW  = 4'd3;   // 'W' msg write pulse
localparam P_RD   = 4'd4;   // 'R' obuf read (wait o_addr settle)
localparam P_RD2  = 4'd5;   // 'R' push byte
localparam P_GO   = 4'd6;   // 'G' start pulse
localparam P_GW   = 4'd7;   // 'G' wait done
localparam P_GS   = 4'd8;   // 'G' push 'D' + status
localparam P_Q    = 4'd9;   // 'Q' push 32B result
localparam P_AK   = 4'd10;  // 'A' key latch + ack
localparam P_EI   = 4'd11;  // 'E' aes init
localparam P_EW   = 4'd12;  // 'E' wait ready low then high
localparam P_EN   = 4'd13;  // 'E' aes next
localparam P_EV   = 4'd14;  // 'E' wait result_valid + push 16B
localparam P_ACK  = 4'd15;  // single-byte ack

reg  [3:0]  pstate;
reg  [7:0]  cmd;
reg  [5:0]  pb_cnt;
reg  [5:0]  pb_need;
reg  [7:0]  pb [0:39];          // payload buffer (max 34B)
reg  [5:0]  q_cnt;              // byte counter for 'Q'/'E' bursts
reg  [255:0] q_word;            // shift source for 'Q'
reg  [7:0]  ack_ch;

integer bi;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        pstate <= P_CMD; cmd <= 0; pb_cnt <= 0; pb_need <= 0;
        q_cnt <= 0; q_word <= 0; ack_ch <= 0;
        resp_we <= 0; resp_d <= 0;
        sm2_start <= 0; sm2_op <= 0;
        p_we <= 0; p_sel <= 0; p_data <= 0;
        m_we <= 0; m_addr <= 0; m_data <= 0; o_addr <= 0;
        aes_init <= 0; aes_next <= 0; aes_encdec <= 0;
        aes_key <= 0; aes_keylen <= 0; aes_blk <= 0;
    end else begin
        resp_we    <= 1'b0;
        sm2_start  <= 1'b0;
        p_we       <= 1'b0;
        m_we       <= 1'b0;
        aes_init   <= 1'b0;
        aes_next   <= 1'b0;

        case (pstate)
        P_CMD: begin
            if (rx_dv) begin
                cmd    <= rx_d;
                pb_cnt <= 0;
                case (rx_d)
                    8'h4C: begin pb_need <= 6'd33; pstate <= P_PAY; end // 'L'
                    8'h57: begin pb_need <= 6'd2;  pstate <= P_PAY; end // 'W'
                    8'h52: begin pb_need <= 6'd1;  pstate <= P_PAY; end // 'R'
                    8'h47: begin pb_need <= 6'd1;  pstate <= P_PAY; end // 'G'
                    8'h51: begin pb_need <= 6'd1;  pstate <= P_PAY; end // 'Q'
                    8'h41: begin pb_need <= 6'd33; pstate <= P_PAY; end // 'A'
                    8'h45: begin pb_need <= 6'd17; pstate <= P_PAY; end // 'E'
                    8'h48: begin                       // 'H' -> "OK"
                        resp_we <= 1'b1; resp_d <= 8'h4F;             // 'O'
                        ack_ch  <= 8'h4B; pstate <= P_ACK;            // 'K'
                    end
                    8'h53: begin                       // 'S' -> status byte
                        resp_we <= 1'b1;
                        resp_d  <= {4'b0, sm2_valid, sm2_err, sm2_done, sm2_busy};
                    end
                    default: ; // unknown command: ignore
                endcase
            end
        end

        P_PAY: begin
            if (rx_dv) begin
                pb[pb_cnt] <= rx_d;
                pb_cnt     <= pb_cnt + 6'd1;
                if (pb_cnt == pb_need - 6'd1) begin
                    // full payload collected
                    case (cmd)
                        8'h4C: pstate <= P_PLD;
                        8'h57: pstate <= P_PMW;
                        8'h52: pstate <= P_RD;
                        8'h47: pstate <= P_GO;
                        8'h51: pstate <= P_Q;
                        8'h41: pstate <= P_AK;
                        8'h45: pstate <= P_EI;
                        default: pstate <= P_CMD;
                    endcase
                end
            end
        end

        P_PLD: begin   // 'L': p_sel = pb[0], p_data = pb[1..32] big-endian
            p_sel  <= pb[0][3:0];
            p_data <= {pb[1],  pb[2],  pb[3],  pb[4],  pb[5],  pb[6],  pb[7],  pb[8],
                       pb[9],  pb[10], pb[11], pb[12], pb[13], pb[14], pb[15], pb[16],
                       pb[17], pb[18], pb[19], pb[20], pb[21], pb[22], pb[23], pb[24],
                       pb[25], pb[26], pb[27], pb[28], pb[29], pb[30], pb[31], pb[32]};
            p_we   <= 1'b1;
            resp_we <= 1'b1; resp_d <= 8'h6C;          // 'l'
            pstate <= P_CMD;
        end

        P_PMW: begin   // 'W': m_buf[pb[0]] = pb[1]
            m_addr  <= {1'b0, pb[0]};
            m_data  <= pb[1];
            m_we    <= 1'b1;
            resp_we <= 1'b1; resp_d <= 8'h77;          // 'w'
            pstate  <= P_CMD;
        end

        P_RD: begin
            o_addr  <= {1'b0, pb[0]};
            pstate  <= P_RD2;
        end
        P_RD2: begin
            resp_we <= 1'b1; resp_d <= o_data;
            pstate  <= P_CMD;
        end

        P_GO: begin
            sm2_op    <= pb[0][2:0];
            sm2_start <= 1'b1;
            pstate    <= P_GW;
        end
        P_GW: begin
            if (sm2_done) begin
                resp_we <= 1'b1; resp_d <= 8'h44;      // 'D'
                ack_ch  <= {6'b0, sm2_err, sm2_valid};
                pstate  <= P_GS;
            end
        end
        P_GS: begin
            resp_we <= 1'b1; resp_d <= ack_ch;
            pstate  <= P_CMD;
        end

        P_Q: begin
            if (q_cnt == 6'd0) begin
                case (pb[0][2:0])
                    3'd0: q_word <= sm2_rx;
                    3'd1: q_word <= sm2_ry;
                    3'd2: q_word <= sm2_sr;
                    3'd3: q_word <= sm2_ss;
                    default: q_word <= sm2_c3;
                endcase
                q_cnt <= 6'd1;
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

        P_AK: begin    // 'A': klen=pb[0], key=pb[1..32]
            aes_keylen <= pb[0][0];
            aes_key    <= {pb[1],  pb[2],  pb[3],  pb[4],  pb[5],  pb[6],  pb[7],  pb[8],
                           pb[9],  pb[10], pb[11], pb[12], pb[13], pb[14], pb[15], pb[16],
                           pb[17], pb[18], pb[19], pb[20], pb[21], pb[22], pb[23], pb[24],
                           pb[25], pb[26], pb[27], pb[28], pb[29], pb[30], pb[31], pb[32]};
            resp_we <= 1'b1; resp_d <= 8'h61;          // 'a'
            pstate  <= P_CMD;
        end

        P_EI: begin    // 'E': ed=pb[0], block=pb[1..16]
            aes_encdec <= pb[0][0];
            aes_blk    <= {pb[1],  pb[2],  pb[3],  pb[4],  pb[5],  pb[6],  pb[7],  pb[8],
                           pb[9],  pb[10], pb[11], pb[12], pb[13], pb[14], pb[15], pb[16]};
            aes_init   <= 1'b1;
            pstate     <= P_EW;
        end
        P_EW: begin
            if (!aes_rdy) pstate <= P_EN;   // wait for core to start
        end
        P_EN: begin
            if (aes_rdy) begin
                aes_next <= 1'b1;
                pstate   <= P_EV;
                q_cnt    <= 6'd0;
            end
        end
        P_EV: begin
            if (aes_rvld) begin
                resp_we <= 1'b1; resp_d <= aes_res[127 - (q_cnt << 3) -: 8];
                if (q_cnt == 6'd15) begin
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
assign led = {~sm2_valid, ~sm2_err, ~sm2_done, ~sm2_busy, ~rx_dv, ~rst_n};

endmodule
