// Top level for cores/acceleration/cnn_inference on the Tang Mega 138K Pro SOM
// (GW5AST-LV138FPG676AES / GW5AST-138C). 50 MHz SOM clock on P16.
//
// rst is the U4 dock key. On the bare SOM it reads LOW (measured with
// gw5a138_rxprobe), so it must NOT gate the power-on reset. The POR counter
// releases rst_n ~1.3 ms after configuration unconditionally; a HIGH level
// on U4 (dock key press) re-arms the reset.
//
// UART: TX stream fanned out to P15 (primary debug JST), U16 and V22.
// RX = N16, confirmed on hardware by projects/gw5a138_rxprobe (sticky-mask
// pin scan over all 157 free IOs of FPG676: N16 follows host TX traffic).
//
// Protocol (115200 8N1, little-endian, request -> response, one boot banner):
//   01 PING     -> A5 01 '1' '3' '8' 'K'
//   02 LOAD     -> 02 ll hh <N=ll:hh bytes> -> A5 02 st   (img write; st=01 NAK
//                  if the engine is busy, bytes still consumed, not written)
//   03 RUN      -> A5 03 00                 (start pulse, only when !busy)
//   04 STAT     -> A5 04 st c0..c3          (st: b0 busy b1 done b2 err)
//   05 RESC     -> A5 05 <40B scores> <4B digest> <4B cycles>
//   06 DUMP     -> 06 ss aa_lo aa_hi nn_lo nn_hi -> A5 06 <n bytes>
//   07 SELFTEST -> like RUN                 -> A5 07 00
//   other       -> A5 FF <op>               (NAK echo)
// Boot: engine runs once on the $readmemh default image, then one
//   "CNN138K BOOT D=XXXXXXXX C=NNNNNN\r\n" line is sent, then idle.
//
// Command handling is byte-serial (no DMA). uart_rx holds rx_valid until
// rx_ack, so bytes arriving during boot compute or response streaming are
// simply consumed when the FSM is ready. Response bytes are fed to uart_tx
// one at a time through a small put/gap pump (valid held until accepted).
// Engine rd_data has 1-cycle latency after rd_sel/rd_addr.

module top(
    input  wire       clk,           // P16, 50 MHz SOM oscillator
    input  wire       rst,           // U4 dock key (pull-up; floats high on SOM)
    output wire [5:0] led,           // dock LEDs: N23 N21 M25 L20 R26 J14
    output wire       uart_tx_p15,
    output wire       uart_tx_u16,
    output wire       uart_tx_v22,
    input  wire       uart_rx        // N16, debug JST UART RX (probed)
);

    // ---------------------------------------------------------------
    // Power-on reset (~1.3 ms at 50 MHz). U4 reads LOW on the bare SOM,
    // so the counter runs unconditionally; a HIGH on the key re-arms it.
    // ---------------------------------------------------------------
    reg [16:0] por_cnt = 17'd0;
    wire       rst_n   = por_cnt[16];
    always @(posedge clk) begin
        if (rst)          por_cnt <= 17'd0;
        else if (!rst_n)  por_cnt <= por_cnt + 17'd1;
    end

    // ---------------------------------------------------------------
    // UART RX (N16, verified by gw5a138_rxprobe)
    // ---------------------------------------------------------------
    wire rx_pin = uart_rx;

    wire [7:0] rx_data;
    wire       rx_valid;
    reg        rx_ack = 1'b0;
    wire       rx_ferr;
    // uart_rx clears rx_valid one edge AFTER rx_ack; during that window
    // rx_ack is still high, so gating on !rx_ack consumes each byte once.
    wire       rx_ready = rx_valid && !rx_ack;

    uart_rx #(.CLK_FRE(50), .BAUD_RATE(115200)) u_rx (
        .clk(clk), .rst_n(rst_n), .clk_en(1'b1), .rx_pin(rx_pin),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_ack(rx_ack),
        .framing_err(rx_ferr)
    );

    // ---------------------------------------------------------------
    // UART TX
    // ---------------------------------------------------------------
    reg  [7:0] tx_data       = 8'd0;
    reg        tx_data_valid = 1'b0;
    wire       tx_data_ready;
    wire       tx_pin;

    uart_tx #(.CLK_FRE(50), .BAUD_RATE(115200)) u_tx (
        .clk(clk), .rst_n(rst_n), .tx_data(tx_data),
        .tx_data_valid(tx_data_valid), .tx_data_ready(tx_data_ready),
        .tx_pin(tx_pin), .tx_busy()
    );

    assign uart_tx_p15 = tx_pin;
    assign uart_tx_u16 = tx_pin;
    assign uart_tx_v22 = tx_pin;

    // ---------------------------------------------------------------
    // CNN engine
    // ---------------------------------------------------------------
    reg         eng_start    = 1'b0;
    wire        eng_busy, eng_done, eng_err;
    reg         eng_in_we    = 1'b0;
    reg  [9:0]  eng_in_waddr = 10'd0;
    reg  [7:0]  eng_in_wdata = 8'd0;
    reg  [2:0]  eng_rd_sel   = 3'd0;
    reg  [14:0] eng_rd_addr  = 15'd0;
    wire [31:0] eng_rd_data;
    wire [31:0] eng_digest, eng_cycles;

    cnn_engine u_eng (
        .clk(clk), .rst_n(rst_n), .start(eng_start),
        .busy(eng_busy), .done(eng_done), .err(eng_err),
        .in_we(eng_in_we), .in_waddr(eng_in_waddr), .in_wdata(eng_in_wdata),
        .rd_sel(eng_rd_sel), .rd_addr(eng_rd_addr), .rd_data(eng_rd_data),
        .digest(eng_digest), .cycles(eng_cycles)
    );

    // ---------------------------------------------------------------
    // LEDs: busy / done-sticky / err-sticky + free-run blink
    // ---------------------------------------------------------------
    reg        done_sticky = 1'b0;
    reg        err_sticky  = 1'b0;
    reg [26:0] hb_cnt      = 27'd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            hb_cnt      <= 27'd0;
            done_sticky <= 1'b0;
            err_sticky  <= 1'b0;
        end else begin
            hb_cnt <= hb_cnt + 27'd1;
            if (eng_start) begin
                done_sticky <= 1'b0;
                err_sticky  <= 1'b0;
            end
            if (eng_done) done_sticky <= 1'b1;
            if (eng_err)  err_sticky  <= 1'b1;
        end
    end

    assign led[0]   = eng_busy;
    assign led[1]   = done_sticky;
    assign led[2]   = err_sticky;
    assign led[5:3] = hb_cnt[25:23];

    // ---------------------------------------------------------------
    // Command opcodes / FSM encodings
    // ---------------------------------------------------------------
    localparam [7:0] OP_PING = 8'h01, OP_LOAD = 8'h02, OP_RUN  = 8'h03,
                     OP_STAT = 8'h04, OP_RESC = 8'h05, OP_DUMP = 8'h06,
                     OP_SELF = 8'h07;

    localparam [4:0] S_BOOT_START = 5'd0,
                     S_BOOT_WAIT  = 5'd1,
                     S_BDEC       = 5'd2,   // cycles -> 6 decimal digits
                     S_RESP       = 5'd3,   // response/banner serializer
                     S_IDLE       = 5'd4,
                     S_LOAD_LL    = 5'd5,
                     S_LOAD_HH    = 5'd6,
                     S_LOAD_DATA  = 5'd7,
                     S_DUMP_SEL   = 5'd8,
                     S_DUMP_A0    = 5'd9,
                     S_DUMP_A1    = 5'd10,
                     S_DUMP_N0    = 5'd11,
                     S_DUMP_N1    = 5'd12;

    // response kinds
    localparam [2:0] K_PING   = 3'd0,
                     K_STATUS = 3'd1,   // single status byte
                     K_STAT   = 3'd2,   // status + 4 cycle bytes
                     K_RESC   = 3'd3,   // 40B scores + 4B digest + 4B cycles
                     K_DUMP   = 3'd4,   // n read bytes
                     K_BANNER = 3'd5;   // boot line, no A5 header

    // response sub-states (inside S_RESP)
    localparam [3:0] R_HDR   = 4'd0,   // emit A5
                     R_OP    = 4'd1,   // emit opcode echo
                     R_ENTRY = 4'd2,   // dispatch on kind
                     R_BODY  = 4'd3,   // const/reg byte streams
                     R_RADDR = 4'd4,   // present rd_sel/rd_addr
                     R_RWAIT = 4'd5,   // rd_data latency
                     R_RUSE  = 4'd6,   // latch word / emit dump byte
                     R_WBYTE = 4'd7,   // emit latched word, LE bytes
                     R_TAIL  = 4'd8,   // digest then cycles, LE bytes
                     R_PUT   = 4'd9,   // drive tx_data_valid
                     R_GAP   = 4'd10,  // hold valid until accepted
                     R_FIN   = 4'd11;

    // ---------------------------------------------------------------
    // FSM registers
    // ---------------------------------------------------------------
    reg [4:0]  state      = S_BOOT_START;
    reg [3:0]  rstate     = R_FIN;
    reg [3:0]  rret       = R_FIN;    // where R_GAP returns after a byte
    reg [2:0]  rkind      = K_STATUS;
    reg [7:0]  rsp_op     = 8'h00;
    reg [7:0]  rsp_status = 8'h00;
    reg [7:0]  pb         = 8'h00;    // pending byte for the TX pump
    reg [7:0]  idx        = 8'd0;     // const-stream index
    reg [15:0] widx       = 16'd0;    // score word / dump byte index
    reg [3:0]  wait_cnt    = 4'd0;     // rd settle cycles for deep muxes
    reg [15:0] load_len   = 16'd0;
    reg [15:0] load_addr  = 16'd0;
    reg        load_nak   = 1'b0;
    reg [7:0]  len_lo     = 8'd0;
    reg [2:0]  dump_sel   = 3'd0;
    reg [15:0] dump_addr  = 16'd0;
    reg [15:0] dump_len   = 16'd0;
    reg [31:0] word_buf   = 32'd0;
    reg [1:0]  lane       = 2'd0;
    reg        tail_phase = 1'b0;     // 0 digest, 1 cycles
    reg [19:0] rem        = 20'd0;    // decimal conversion remainder
    reg [2:0]  didx       = 3'd0;
    reg [23:0] ddig       = 24'd0;    // 6 packed BCD digits, [23:20] first

    function [19:0] pow10;
        input [2:0] d;
        case (d)
            3'd0:    pow10 = 20'd100000;
            3'd1:    pow10 = 20'd10000;
            3'd2:    pow10 = 20'd1000;
            3'd3:    pow10 = 20'd100;
            3'd4:    pow10 = 20'd10;
            default: pow10 = 20'd1;
        endcase
    endfunction

    // "CNN138K BOOT D=XXXXXXXX C=NNNNNN\r\n" -> 34 chars, index 0..33
    function [7:0] banner_char;
        input [5:0] i;
        reg [3:0] nib;
        begin
            case (i)
                6'd0:  banner_char = "C";
                6'd1:  banner_char = "N";
                6'd2:  banner_char = "N";
                6'd3:  banner_char = "1";
                6'd4:  banner_char = "3";
                6'd5:  banner_char = "8";
                6'd6:  banner_char = "K";
                6'd7:  banner_char = " ";
                6'd8:  banner_char = "B";
                6'd9:  banner_char = "O";
                6'd10: banner_char = "O";
                6'd11: banner_char = "T";
                6'd12: banner_char = " ";
                6'd13: banner_char = "D";
                6'd14: banner_char = "=";
                6'd23: banner_char = " ";
                6'd24: banner_char = "C";
                6'd25: banner_char = "=";
                6'd32: banner_char = 8'd13;   // CR
                6'd33: banner_char = 8'd10;   // LF
                default: begin
                    if (i >= 6'd15 && i <= 6'd22) begin
                        // digest hex, MSB first (i=15 -> [31:28])
                        nib = eng_digest[4*(6'd22 - i) +: 4];
                        banner_char = (nib < 4'd10) ? (8'h30 + nib)
                                                    : (8'h41 + nib - 4'd10);
                    end else if (i >= 6'd26 && i <= 6'd31) begin
                        // decimal digits, most significant first
                        banner_char = 8'h30 + ddig[4*(i - 6'd26) +: 4];
                    end else begin
                        banner_char = " ";
                    end
                end
            endcase
        end
    endfunction

    // ---------------------------------------------------------------
    // Main FSM
    // ---------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state         <= S_BOOT_START;
            rstate        <= R_FIN;
            rret          <= R_FIN;
            rkind         <= K_STATUS;
            rsp_op        <= 8'h00;
            rsp_status    <= 8'h00;
            pb            <= 8'h00;
            idx           <= 8'd0;
            widx          <= 16'd0;
            load_len      <= 16'd0;
            load_addr     <= 16'd0;
            load_nak      <= 1'b0;
            len_lo        <= 8'd0;
            dump_sel      <= 2'd0;
            dump_addr     <= 16'd0;
            dump_len      <= 16'd0;
            word_buf      <= 32'd0;
            lane          <= 2'd0;
            tail_phase    <= 1'b0;
            rem           <= 20'd0;
            didx          <= 3'd0;
            ddig          <= 24'd0;
            rx_ack        <= 1'b0;
            tx_data_valid <= 1'b0;
            tx_data       <= 8'd0;
            eng_start     <= 1'b0;
            eng_in_we     <= 1'b0;
            eng_in_waddr  <= 10'd0;
            eng_in_wdata  <= 8'd0;
            eng_rd_sel    <= 3'd0;
            eng_rd_addr   <= 15'd0;
        end else begin
            // single-cycle strobes
            rx_ack    <= 1'b0;
            eng_start <= 1'b0;
            eng_in_we <= 1'b0;
            // tx_data_valid is NOT defaulted: the R_PUT/R_GAP pump holds it
            // high until uart_tx accepts the byte.

            case (state)

                // -------- boot: run once on the $readmemh image --------
                S_BOOT_START: begin
                    eng_start <= 1'b1;
                    state     <= S_BOOT_WAIT;
                end

                S_BOOT_WAIT: begin
                    if (eng_done || done_sticky || eng_err) begin
                        rem   <= (eng_cycles >= 32'd1000000) ? 20'd999999
                                                             : eng_cycles[19:0];
                        didx  <= 3'd0;
                        ddig  <= 24'd0;
                        state <= S_BDEC;
                    end
                end

                // binary -> 6 decimal digits by compare/subtract of powers of 10
                S_BDEC: begin
                    if (rem >= pow10(didx)) begin
                        rem                 <= rem - pow10(didx);
                        ddig[4*didx +: 4]   <= ddig[4*didx +: 4] + 4'd1;
                    end else if (didx == 3'd5) begin
                        rkind  <= K_BANNER;
                        idx    <= 8'd0;
                        rstate <= R_BODY;
                        state  <= S_RESP;
                    end else begin
                        didx <= didx + 3'd1;
                    end
                end

                // -------- command byte dispatch --------
                S_IDLE: begin
                    if (rx_ready) begin
                        rx_ack <= 1'b1;
                        case (rx_data)
                            OP_PING: begin
                                rkind  <= K_PING;
                                rsp_op <= rx_data;
                                idx    <= 8'd0;
                                rstate <= R_HDR;
                                state  <= S_RESP;
                            end
                            OP_LOAD: begin
                                state <= S_LOAD_LL;
                            end
                            OP_RUN, OP_SELF: begin
                                if (!eng_busy) eng_start <= 1'b1;
                                rkind      <= K_STATUS;
                                rsp_op     <= rx_data;
                                rsp_status <= 8'h00;
                                rstate     <= R_HDR;
                                state      <= S_RESP;
                            end
                            OP_STAT: begin
                                rkind      <= K_STAT;
                                rsp_op     <= rx_data;
                                rsp_status <= {5'b0,
                                               (err_sticky  | eng_err),
                                               (done_sticky | eng_done),
                                               eng_busy};
                                idx        <= 8'd0;
                                rstate     <= R_HDR;
                                state      <= S_RESP;
                            end
                            OP_RESC: begin
                                rkind      <= K_RESC;
                                rsp_op     <= rx_data;
                                widx       <= 16'd0;
                                lane       <= 2'd0;
                                tail_phase <= 1'b0;
                                rstate     <= R_HDR;
                                state      <= S_RESP;
                            end
                            OP_DUMP: begin
                                state <= S_DUMP_SEL;
                            end
                            default: begin  // unknown opcode -> A5 FF <op>
                                rkind      <= K_STATUS;
                                rsp_op     <= 8'hFF;
                                rsp_status <= rx_data;
                                rstate     <= R_HDR;
                                state      <= S_RESP;
                            end
                        endcase
                    end
                end

                // -------- LOAD: 02 ll hh <N bytes> --------
                S_LOAD_LL: begin
                    if (rx_ready) begin
                        rx_ack <= 1'b1;
                        len_lo <= rx_data;
                        state  <= S_LOAD_HH;
                    end
                end

                S_LOAD_HH: begin
                    if (rx_ready) begin
                        rx_ack    <= 1'b1;
                        load_len  <= {rx_data, len_lo};
                        load_addr <= 16'd0;
                        load_nak  <= eng_busy;
                        if ({rx_data, len_lo} == 16'd0) begin
                            rkind      <= K_STATUS;
                            rsp_op     <= OP_LOAD;
                            rsp_status <= eng_busy ? 8'h01 : 8'h00;
                            rstate     <= R_HDR;
                            state      <= S_RESP;
                        end else begin
                            state <= S_LOAD_DATA;
                        end
                    end
                end

                S_LOAD_DATA: begin
                    if (rx_ready) begin
                        rx_ack <= 1'b1;
                        if (!load_nak) begin
                            eng_in_we    <= 1'b1;
                            eng_in_waddr <= load_addr[9:0];
                            eng_in_wdata <= rx_data;
                        end
                        if (load_len == 16'd1) begin
                            rkind      <= K_STATUS;
                            rsp_op     <= OP_LOAD;
                            rsp_status <= load_nak ? 8'h01 : 8'h00;
                            rstate     <= R_HDR;
                            state      <= S_RESP;
                        end else begin
                            load_len  <= load_len  - 16'd1;
                            load_addr <= load_addr + 16'd1;
                        end
                    end
                end

                // -------- DUMP: 06 ss aa_lo aa_hi nn_lo nn_hi --------
                S_DUMP_SEL: begin
                    if (rx_ready) begin
                        rx_ack   <= 1'b1;
                        dump_sel <= rx_data[2:0];
                        state    <= S_DUMP_A0;
                    end
                end
                S_DUMP_A0: begin
                    if (rx_ready) begin
                        rx_ack          <= 1'b1;
                        dump_addr[7:0]  <= rx_data;
                        state           <= S_DUMP_A1;
                    end
                end
                S_DUMP_A1: begin
                    if (rx_ready) begin
                        rx_ack          <= 1'b1;
                        dump_addr[15:8] <= rx_data;
                        state           <= S_DUMP_N0;
                    end
                end
                S_DUMP_N0: begin
                    if (rx_ready) begin
                        rx_ack         <= 1'b1;
                        dump_len[7:0]  <= rx_data;
                        state          <= S_DUMP_N1;
                    end
                end
                S_DUMP_N1: begin
                    if (rx_ready) begin
                        rx_ack          <= 1'b1;
                        dump_len[15:8]  <= rx_data;
                        rkind           <= K_DUMP;
                        rsp_op          <= OP_DUMP;
                        widx            <= 16'd0;
                        rstate          <= R_HDR;
                        state           <= S_RESP;
                    end
                end

                // -------- response / banner serializer --------
                S_RESP: begin
                    case (rstate)
                        R_HDR: begin
                            pb     <= 8'hA5;
                            rret   <= R_OP;
                            rstate <= R_PUT;
                        end
                        R_OP: begin
                            pb     <= rsp_op;
                            rret   <= R_ENTRY;
                            rstate <= R_PUT;
                        end
                        R_ENTRY: begin
                            case (rkind)
                                K_RESC: begin
                                    widx   <= 16'd0;
                                    rstate <= R_RADDR;
                                end
                                K_DUMP: begin
                                    widx   <= 16'd0;
                                    rstate <= (dump_len == 16'd0) ? R_FIN
                                                                  : R_RADDR;
                                end
                                default: rstate <= R_BODY;
                            endcase
                        end
                        R_BODY: begin
                            case (rkind)
                                K_PING: begin
                                    case (idx[1:0])
                                        2'd0:    pb <= "1";
                                        2'd1:    pb <= "3";
                                        2'd2:    pb <= "8";
                                        default: pb <= "K";
                                    endcase
                                    if (idx == 8'd3) rret <= R_FIN;
                                    else begin
                                        idx  <= idx + 8'd1;
                                        rret <= R_BODY;
                                    end
                                end
                                K_STAT: begin
                                    if (idx == 8'd0) pb <= rsp_status;
                                    else             pb <= eng_cycles >> (8*(idx - 8'd1));
                                    if (idx == 8'd4) rret <= R_FIN;
                                    else begin
                                        idx  <= idx + 8'd1;
                                        rret <= R_BODY;
                                    end
                                end
                                K_BANNER: begin
                                    pb <= banner_char(idx[5:0]);
                                    if (idx == 8'd33) rret <= R_FIN;
                                    else begin
                                        idx  <= idx + 8'd1;
                                        rret <= R_BODY;
                                    end
                                end
                                default: begin  // K_STATUS
                                    pb   <= rsp_status;
                                    rret <= R_FIN;
                                end
                            endcase
                            rstate <= R_PUT;
                        end
                        R_RADDR: begin
                            // scores (sel 0) use word address widx; dump uses
                            // byte address dump_addr+widx
                            eng_rd_sel  <= (rkind == K_DUMP) ? dump_sel : 3'd0;
                            eng_rd_addr <= (rkind == K_DUMP)
                                           ? (dump_addr[14:0] + widx[14:0])
                                           : {11'd0, widx[3:0]};
                            rstate <= R_RWAIT;
                        end
                        R_RWAIT: begin
                            // engine rd_data re-latches each cycle; deep
                            // muxes (wmem ROM, fmap LUTRAM) need a few ns
                            // to settle - hold the address 16 cycles so
                            // rd_data is guaranteed clean before R_RUSE.
                            if (wait_cnt == 4'd15) begin
                                wait_cnt <= 4'd0;
                                rstate   <= R_RUSE;
                            end else begin
                                wait_cnt <= wait_cnt + 4'd1;
                            end
                        end
                        R_RUSE: begin
                            if (rkind == K_DUMP) begin
                                pb <= eng_rd_data[7:0];
                                if (widx == dump_len - 16'd1) begin
                                    rret <= R_FIN;
                                end else begin
                                    widx <= widx + 16'd1;
                                    rret <= R_RADDR;
                                end
                                rstate <= R_PUT;
                            end else begin
                                // K_RESC score word -> emit 4 LE bytes
                                word_buf <= eng_rd_data;
                                lane     <= 2'd0;
                                rstate   <= R_WBYTE;
                            end
                        end
                        R_WBYTE: begin
                            pb <= word_buf >> (8*lane);
                            if (lane == 2'd3) begin
                                if (widx == 16'd9) begin
                                    lane       <= 2'd0;
                                    tail_phase <= 1'b0;
                                    rret       <= R_TAIL;
                                end else begin
                                    widx <= widx + 16'd1;
                                    rret <= R_RADDR;
                                end
                            end else begin
                                lane <= lane + 2'd1;
                                rret <= R_WBYTE;
                            end
                            rstate <= R_PUT;
                        end
                        R_TAIL: begin
                            pb <= (tail_phase ? eng_cycles : eng_digest)
                                   >> (8*lane);
                            if (lane == 2'd3) begin
                                if (tail_phase) begin
                                    rret <= R_FIN;
                                end else begin
                                    tail_phase <= 1'b1;
                                    lane       <= 2'd0;
                                    rret       <= R_TAIL;
                                end
                            end else begin
                                lane <= lane + 2'd1;
                                rret <= R_TAIL;
                            end
                            rstate <= R_PUT;
                        end
                        R_PUT: begin
                            tx_data       <= pb;
                            tx_data_valid <= 1'b1;
                            rstate        <= R_GAP;
                        end
                        R_GAP: begin
                            // valid is held; uart_tx accepts on the next edge
                            // where it is idle (tx_data_ready high)
                            if (tx_data_ready) begin
                                tx_data_valid <= 1'b0;
                                rstate        <= rret;
                            end
                        end
                        default: begin  // R_FIN
                            rstate <= R_FIN;
                            state  <= S_IDLE;
                        end
                    endcase
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
