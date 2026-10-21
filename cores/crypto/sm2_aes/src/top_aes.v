`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// top_aes.v — Tang Primer 20K board image A: UART command shell over
// aes_core (AES-128/256 enc/dec) + sm3_top.
//
// UART 115200 8N1.  Binary commands (host -> FPGA):
//   'H' 0x48                ping                              -> "OK"
//   'S' 0x53                status -> 1B {4'b0, aes_rvld, aes_rdy, 2'b0}
//   'A' 0x41 klen k[32]     AES key: klen 0=128b (k[0:15]), 1=256b -> 'a'
//   'E' 0x45 ed blk[16]     AES run block, ed 1=enc 0=dec          -> 16B result
//   'M' 0x4D len[2] d[len]  SM3 hash len bytes (BE length) -> 'D' + 32B digest
//////////////////////////////////////////////////////////////////////////////////
module top_aes(
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

// ---------------- SM3 engine --------------------------------------------------
wire        h_rdy;
wire [255:0] h_res;
wire        h_res_vld;

sm3_top U_SM3(
    .clk(clk), .rst_n(rst_n),
    .msg_inpt_d_i(h_d),
    .msg_inpt_vld_byte_i(h_vb),
    .msg_inpt_vld_i(h_vld),
    .msg_inpt_lst_i(h_lst),
    .msg_inpt_rdy_o(h_rdy),
    .cmprss_otpt_res_o(h_res),
    .cmprss_otpt_vld_o(h_res_vld)
);

// ---------------- SM3 feeder --------------------------------------------------
// Contract with the legacy pad core: msg_inpt_vld_i may only be asserted in
// the same cycle msg_inpt_rdy_o is high (pad ingests on vld alone); lst must
// be qualified by vld.
// Incoming UART bytes are assembled into 64-bit words in wsh; each completed
// word is moved into h_d and offered to the core via sf_pend.  UART bytes
// arrive ~2000 clocks apart, far longer than any downstream stall.
reg  [15:0] m_len;
reg  [15:0] rcvd;
reg  [63:0] wsh;
reg  [2:0]  wcnt;
reg         sf_pend;
reg         feed_done;
reg  [63:0] h_d;
reg  [7:0]  h_vb;
reg         h_lst_r;

wire h_vld = sf_pend && h_rdy;
wire h_lst = h_vld && h_lst_r;

// ---------------- command parser ----------------------------------------------
localparam P_CMD  = 4'd0;
localparam P_PAY  = 4'd1;
localparam P_AK   = 4'd2;   // 'A' key latch + ack
localparam P_EI   = 4'd3;   // 'E' aes init
localparam P_EW   = 4'd4;   // 'E' wait ready low then high
localparam P_EN   = 4'd5;   // 'E' aes next
localparam P_EV   = 4'd6;   // 'E' wait result_valid + push 16B
localparam P_MR   = 4'd7;   // 'M' receive msg bytes (streamed to SM3)
localparam P_MW   = 4'd9;   // 'M' wait digest
localparam P_MD   = 4'd10;  // 'M' push 'D' + 32B digest
localparam P_ACK  = 4'd11;

reg  [3:0]  pstate;
reg  [7:0]  cmd;
reg  [5:0]  pb_cnt;
reg  [5:0]  pb_need;
reg  [7:0]  pb [0:33];
reg  [5:0]  q_cnt;
reg  [255:0] q_word;
reg  [7:0]  ack_ch;
reg  [63:0] wrd;
reg         wd_rdy;
reg  [7:0]  wd_vb;
reg         wd_lst;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        pstate <= P_CMD; cmd <= 0; pb_cnt <= 0; pb_need <= 0;
        q_cnt <= 0; q_word <= 0; ack_ch <= 0;
        resp_we <= 0; resp_d <= 0;
        aes_init <= 0; aes_next <= 0; aes_encdec <= 0;
        aes_key <= 0; aes_keylen <= 0; aes_blk <= 0;
        m_len <= 0; rcvd <= 0; wsh <= 0; wcnt <= 0;
        sf_pend <= 0; feed_done <= 0;
        h_d <= 0; h_vb <= 0; h_lst_r <= 0;
        wrd <= 0; wd_rdy <= 0; wd_vb <= 0; wd_lst <= 0;
    end else begin
        resp_we   <= 1'b0;
        aes_init  <= 1'b0;
        aes_next  <= 1'b0;

        // SM3 feeder: move a completed word into h_d, then offer it to the
        // core while rdy is high.
        if (wd_rdy && !sf_pend) begin
            h_d <= wrd; h_vb <= wd_vb; h_lst_r <= wd_lst;
            sf_pend <= 1'b1; wd_rdy <= 1'b0;
        end
        if (h_vld) begin
            sf_pend <= 1'b0;
            if (h_lst_r) feed_done <= 1'b1;
        end

        case (pstate)
        P_CMD: begin
            if (rx_dv) begin
                cmd    <= rx_d;
                pb_cnt <= 0;
                case (rx_d)
                    8'h41: begin pb_need <= 6'd33; pstate <= P_PAY; end // 'A'
                    8'h45: begin pb_need <= 6'd17; pstate <= P_PAY; end // 'E'
                    8'h4D: begin pb_need <= 6'd2;  pstate <= P_PAY; end // 'M'
                    8'h48: begin                       // 'H' -> "OK"
                        resp_we <= 1'b1; resp_d <= 8'h4F;
                        ack_ch  <= 8'h4B; pstate <= P_ACK;
                    end
                    8'h53: begin                       // 'S' -> status byte
                        resp_we <= 1'b1;
                        resp_d  <= {4'b0, aes_rvld, aes_rdy, 2'b0};
                    end
                    default: ;
                endcase
            end
        end

        P_PAY: begin
            if (rx_dv) begin
                pb[pb_cnt] <= rx_d;
                pb_cnt     <= pb_cnt + 6'd1;
                if (pb_cnt == pb_need - 6'd1) begin
                    case (cmd)
                        8'h41: pstate <= P_AK;
                        8'h45: pstate <= P_EI;
                        8'h4D: begin
                            // 'M' len[2] BE = {pb[0], rx_d}
                            m_len     <= {pb[0], rx_d};
                            rcvd      <= 16'd0;
                            wcnt      <= 3'd0;
                            wsh       <= 64'd0;
                            feed_done <= 1'b0;
                            if ({pb[0], rx_d} == 16'd0) begin
                                h_d <= 64'd0; h_vb <= 8'h00; h_lst_r <= 1'b1;
                                sf_pend <= 1'b1;
                                pstate  <= P_MW;
                            end else begin
                                pstate <= P_MR;
                            end
                        end
                        default: pstate <= P_CMD;
                    endcase
                end
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
            if (!aes_rdy) pstate <= P_EN;
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

        // 'M': assemble UART bytes into 64-bit words and stream to SM3.
        P_MR: begin
            if (rx_dv) begin
                rcvd <= rcvd + 16'd1;
                if (wcnt == 3'd7 || rcvd == m_len - 16'd1) begin
                    // left-align the bytes of the completed word
                    wrd    <= {wsh[55:0], rx_d} << ((3'd7 - wcnt) * 8);
                    wd_vb  <= (wcnt == 3'd7) ? 8'hFF : (8'hFF << (3'd7 - wcnt));
                    wd_lst <= (rcvd == m_len - 16'd1);
                    wd_rdy <= 1'b1;
                    wsh    <= 64'd0;
                    wcnt   <= 3'd0;
                    if (rcvd == m_len - 16'd1) pstate <= P_MW;
                end else begin
                    wsh  <= {wsh[55:0], rx_d};
                    wcnt <= wcnt + 3'd1;
                end
            end
        end
        P_MW: begin
            if (feed_done && h_res_vld) begin
                resp_we <= 1'b1; resp_d <= 8'h44;      // 'D'
                q_word  <= h_res;
                q_cnt   <= 6'd1;
                pstate  <= P_MD;
            end
        end
        P_MD: begin
            resp_we <= 1'b1; resp_d <= q_word[255 -: 8];
            q_word  <= {q_word[247:0], 8'h00};
            if (q_cnt == 6'd32) begin
                q_cnt  <= 0;
                pstate <= P_CMD;
            end else
                q_cnt <= q_cnt + 6'd1;
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
assign led = {~aes_rvld, ~aes_rdy, ~h_res_vld, ~feed_done, ~rx_dv, ~rst_n};

endmodule
