// SD card SPI-mode reader IP for Tang Primer 20K.
// Implements card init (CMD0/CMD8/ACMD41/CMD58/CMD16) and single-block
// reads (CMD17), streaming each 512-byte sector out byte-by-byte.
// Reports card version (v1/v2) and capacity type (HC => block addressing).
//
// Transaction timing: every command is preceded by CS-low + one 0xFF byte,
// and followed by CS-high + one 0xFF byte, so the card always sees a clean
// chip-select gap between commands.
module sdcard_ip (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        init_start,
    output reg         init_busy,
    output reg         init_done,
    output reg  [3:0]  init_err,
    output reg  [7:0]  dbg_r1,
    output reg  [63:0] dbg_hist,   // last eight received bytes (raw stream)
    output reg  [39:0] dbg_r1s,    // per-stage R1: {cmd0,cmd8,cmd55,cmd41,cmd58}
    output reg  [63:0] dbg_h8,     // dbg_hist snapshot taken after CMD8
    output reg         card_v2,
    output reg         card_hc,

    input  wire        rd_start,
    input  wire [31:0] rd_lba,
    output reg         rd_busy,
    output reg         rd_done,
    output reg  [3:0]  rd_err,
    output reg  [7:0]  rd_data,
    output reg         rd_dv,

    output reg         sd_cs_n,
    input  wire        sd_miso,
    output wire        sd_sck,
    output wire        sd_mosi
);

    // ------------------------------------------------------------------
    // spi byte engine
    // ------------------------------------------------------------------
    reg        spi_start;
    reg  [7:0] spi_tx;
    wire [7:0] spi_rx;
    wire       spi_busy;
    reg        spi_fast;

    sd_spi_master spi (
        .clk(clk),
        .rst_n(rst_n),
        .fast(spi_fast),
        .start(spi_start),
        .tx_byte(spi_tx),
        .miso(sd_miso),
        .rx_byte(spi_rx),
        .busy(spi_busy),
        .sck(sd_sck),
        .mosi(sd_mosi)
    );

    // ------------------------------------------------------------------
    // states
    // ------------------------------------------------------------------
    // micro-op machine (byte sequencing within one command transaction)
    localparam [3:0]
        U_IDLE      = 4'd0,
        U_PRE_FF    = 4'd1,   // CS low, one 0xFF byte
        U_CMD       = 4'd2,   // six command bytes
        U_RESP_WAIT = 4'd3,   // poll until bit7==0 (R1)
        U_RESP_EXT  = 4'd4,   // four extra response bytes (R3/R7)
        U_GAP_FF    = 4'd5,   // CS high, one 0xFF byte, then dispatch
        U_GAP_FF_K  = 4'd6;   // keep-CS variant (block read): CS stays low

    // top-level flow states
    localparam [5:0]
        S_IDLE        = 6'd0,
        S_INIT_CLKS   = 6'd1,
        S_CMD0        = 6'd2,
        S_CMD8        = 6'd3,
        S_ACMD55      = 6'd4,
        S_ACMD41      = 6'd5,
        S_CMD58       = 6'd6,
        S_CMD16       = 6'd7,
        S_INIT_DONE   = 6'd8,
        S_RD_CMD      = 6'd9,
        S_RD_WAIT     = 6'd10,
        S_RD_DATA     = 6'd11,
        S_RD_CRC      = 6'd12,
        S_RD_END      = 6'd13,
        S_FAIL        = 6'd14,
        S_ISSUE       = 6'd15,
        S_WAIT_CMD    = 6'd16,
        S_CMD1        = 6'd17;

    reg [5:0]  state;
    reg [3:0]  ustate;
    reg [5:0]  ret_state;      // flow state that a finished command feeds
    reg [7:0]  r1;
    reg [31:0] r34;
    reg        want_ext;

    // pending-command registers: dispatch sets these, S_ISSUE launches them
    reg        cmd_pend;
    reg        cmd_keep_cs;
    reg [5:0]  pend_code;
    reg [31:0] pend_arg;
    reg [7:0]  pend_crc;
    reg        pend_ext;
    reg [5:0]  pend_ret;

    reg [5:0]  cmd_code;
    reg [31:0] cmd_arg;
    reg [7:0]  cmd_crc;
    reg [2:0]  cmd_byte_idx;
    reg [7:0]  resp_wait_cnt;
    reg [1:0]  ext_cnt;
    reg [11:0] ac41_retries;
    reg [3:0]  init_clk_cnt;
    reg [9:0]  rd_byte_cnt;
    reg [7:0]  rd_wait_cnt;
    reg [1:0]  crc_cnt;
    reg [3:0]  err_code;
    reg        spi_wait;
    reg        spi_seen_busy;
    wire       spi_done = spi_wait && spi_seen_busy && !spi_busy;

    task automatic spi_xfer(input [7:0] b);
        begin
            spi_tx        <= b;
            spi_start     <= 1'b1;
            spi_seen_busy <= 1'b0;
        end
    endtask

    // queue a command transaction (issued by S_ISSUE next cycle)
    task automatic queue_cmd(input [5:0]  code,
                             input [31:0] arg,
                             input [7:0]  crc,
                             input        ext,
                             input        keep_cs,
                             input [5:0]  ret);
        begin
            cmd_pend    <= 1'b1;
            pend_code   <= code;
            pend_arg    <= arg;
            pend_crc    <= crc;
            pend_ext    <= ext;
            cmd_keep_cs <= keep_cs;
            pend_ret    <= ret;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            ustate       <= U_IDLE;
            init_busy    <= 1'b0;
            init_done    <= 1'b0;
            init_err     <= 4'd0;
            dbg_r1       <= 8'd0;
            card_v2      <= 1'b0;
            card_hc      <= 1'b0;
            rd_busy      <= 1'b0;
            rd_done      <= 1'b0;
            rd_err       <= 4'd0;
            rd_data      <= 8'd0;
            rd_dv        <= 1'b0;
            sd_cs_n      <= 1'b1;
            spi_start    <= 1'b0;
            spi_tx       <= 8'hFF;
            spi_fast     <= 1'b0;
            spi_wait     <= 1'b0;
            spi_seen_busy<= 1'b0;
            r1           <= 8'd0;
            r34          <= 32'd0;
            want_ext     <= 1'b0;
            cmd_pend     <= 1'b0;
            cmd_keep_cs  <= 1'b0;
            pend_code    <= 6'd0;
            pend_arg     <= 32'd0;
            pend_crc     <= 8'd0;
            pend_ext     <= 1'b0;
            pend_ret     <= S_IDLE;
            cmd_code     <= 6'd0;
            cmd_arg      <= 32'd0;
            cmd_crc      <= 8'd0;
            cmd_byte_idx <= 3'd0;
            resp_wait_cnt<= 8'd0;
            ext_cnt      <= 2'd0;
            ac41_retries <= 12'd0;
            init_clk_cnt <= 4'd0;
            rd_byte_cnt  <= 10'd0;
            rd_wait_cnt  <= 8'd0;
            crc_cnt      <= 2'd0;
            err_code     <= 4'd0;
            ret_state    <= S_IDLE;
        end else begin
            spi_start <= 1'b0;
            rd_dv     <= 1'b0;
            rd_done   <= 1'b0;
            cmd_pend  <= 1'b0;
            if (spi_busy) spi_seen_busy <= 1'b1;

            // ----------------------------------------------------------
            // micro-op machine
            // ----------------------------------------------------------
            case (ustate)
                U_IDLE: ;

                U_PRE_FF: begin
                    if (!spi_wait) begin
                        spi_xfer(8'hFF);
                        spi_wait <= 1'b1;
                    end else if (spi_done) begin
                        spi_wait     <= 1'b0;
                        dbg_hist     <= {dbg_hist[55:0], spi_rx};
                        cmd_byte_idx <= 3'd0;
                        ustate       <= U_CMD;
                    end
                end

                // send 0x40|cmd, arg[31:0] msb-first, crc|01
                U_CMD: begin
                    if (!spi_wait) begin
                        case (cmd_byte_idx)
                            3'd0: spi_xfer(8'h40 | {2'b00, cmd_code});
                            3'd1: spi_xfer(cmd_arg[31:24]);
                            3'd2: spi_xfer(cmd_arg[23:16]);
                            3'd3: spi_xfer(cmd_arg[15:8]);
                            3'd4: spi_xfer(cmd_arg[7:0]);
                            default: spi_xfer(cmd_crc | 8'h01);
                        endcase
                        spi_wait <= 1'b1;
                    end else if (spi_done) begin
                        spi_wait <= 1'b0;
                        dbg_hist <= {dbg_hist[55:0], spi_rx};
                        if (cmd_byte_idx == 3'd5) begin
                            resp_wait_cnt <= 8'd0;
                            ustate        <= U_RESP_WAIT;
                        end else begin
                            cmd_byte_idx <= cmd_byte_idx + 3'd1;
                        end
                    end
                end

                U_RESP_WAIT: begin
                    if (!spi_wait) begin
                        spi_xfer(8'hFF);
                        spi_wait <= 1'b1;
                    end else if (spi_done) begin
                        spi_wait <= 1'b0;
                        r1       <= spi_rx;
                        dbg_r1   <= spi_rx;
                        dbg_hist <= {dbg_hist[55:0], spi_rx};
                        if (!spi_rx[7]) begin
                            if (want_ext) begin
                                ext_cnt <= 2'd0;
                                ustate  <= U_RESP_EXT;
                            end else begin
                                ustate <= cmd_keep_cs ? U_GAP_FF_K : U_GAP_FF;
                            end
                        end else if (resp_wait_cnt == 8'd32) begin
                            r1     <= 8'hFF;
                            ustate <= cmd_keep_cs ? U_GAP_FF_K : U_GAP_FF;
                        end else begin
                            resp_wait_cnt <= resp_wait_cnt + 8'd1;
                        end
                    end
                end

                U_RESP_EXT: begin
                    if (!spi_wait) begin
                        spi_xfer(8'hFF);
                        spi_wait <= 1'b1;
                    end else if (spi_done) begin
                        spi_wait <= 1'b0;
                        r34      <= {r34[23:0], spi_rx};
                        dbg_hist <= {dbg_hist[55:0], spi_rx};
                        if (ext_cnt == 2'd3) ustate <= U_GAP_FF;
                        else ext_cnt <= ext_cnt + 2'd1;
                    end
                end

                // end of transaction: raise CS, clock one 0xFF, dispatch
                U_GAP_FF: begin
                    if (!spi_wait) begin
                        sd_cs_n  <= 1'b1;
                        spi_xfer(8'hFF);
                        spi_wait <= 1'b1;
                    end else if (spi_done) begin
                        spi_wait <= 1'b0;
                        dbg_hist <= {dbg_hist[55:0], spi_rx};
                        ustate   <= U_IDLE;
                        state    <= ret_state;   // dispatch to flow state
                    end
                end

                // keep-CS variant used by CMD17: just one more 0xFF byte
                U_GAP_FF_K: begin
                    if (!spi_wait) begin
                        spi_xfer(8'hFF);
                        spi_wait <= 1'b1;
                    end else if (spi_done) begin
                        spi_wait <= 1'b0;
                        dbg_hist <= {dbg_hist[55:0], spi_rx};
                        ustate   <= U_IDLE;
                        state    <= ret_state;
                    end
                end

                default: ustate <= U_IDLE;
            endcase

            // ----------------------------------------------------------
            // flow machine
            // ----------------------------------------------------------
            case (state)
                S_IDLE: begin
                    init_busy <= 1'b0;
                    rd_busy   <= 1'b0;
                    err_code  <= 4'd0;
                    if (init_start) begin
                        init_busy    <= 1'b1;
                        init_done    <= 1'b0;
                        init_err     <= 4'd0;
                        card_v2      <= 1'b0;
                        card_hc      <= 1'b0;
                        spi_fast     <= 1'b0;
                        sd_cs_n      <= 1'b1;
                        init_clk_cnt <= 4'd0;
                        spi_wait     <= 1'b0;
                        state        <= S_INIT_CLKS;
                    end else if (rd_start) begin
                        rd_busy  <= 1'b1;
                        rd_done  <= 1'b0;
                        rd_err   <= 4'd0;
                        rd_wait_cnt <= 8'd0;
                        queue_cmd(6'd17,
                                  card_hc ? rd_lba : {rd_lba[22:0], 9'd0},
                                  8'h01, 1'b0, 1'b1, S_RD_WAIT);
                        state    <= S_ISSUE;
                    end
                end

                // >=74 clocks with CS high
                S_INIT_CLKS: begin
                    if (!spi_wait) begin
                        spi_xfer(8'hFF);
                        spi_wait <= 1'b1;
                    end else if (spi_done) begin
                        spi_wait <= 1'b0;
                        if (init_clk_cnt == 4'd15) begin
                            queue_cmd(6'd0, 32'd0, 8'h95, 1'b0, 1'b0,
                                      S_CMD0);
                            state <= S_ISSUE;
                        end else begin
                            init_clk_cnt <= init_clk_cnt + 4'd1;
                        end
                    end
                end

                // drop CS and launch the queued command
                S_ISSUE: begin
                    if (cmd_pend) begin
                        cmd_pend     <= 1'b0;
                        sd_cs_n      <= 1'b0;
                        cmd_code     <= pend_code;
                        cmd_arg      <= pend_arg;
                        cmd_crc      <= pend_crc;
                        want_ext     <= pend_ext;
                        ret_state    <= pend_ret;
                        cmd_byte_idx <= 3'd0;
                        ustate       <= U_PRE_FF;
                        state        <= S_WAIT_CMD;
                    end
                end

                // ustate machine owns the bus until ret_state dispatch
                S_WAIT_CMD: ;

                // ---- command completion handlers ---------------------
                S_CMD0: begin
                    dbg_r1s[39:32] <= r1;
                    if (r1 != 8'h01) begin
                        err_code <= 4'd1;
                        state    <= S_FAIL;
                    end else begin
                        queue_cmd(6'd8, 32'h000001AA, 8'h87, 1'b1, 1'b0,
                                  S_CMD8);
                        state <= S_ISSUE;
                    end
                end

                S_CMD8: begin
                    dbg_r1s[31:24] <= r1;
                    dbg_h8         <= dbg_hist;
                    // v2 card iff R1 idle + echo 0x01AA back in R7
                    card_v2 <= (r1 == 8'h01) && (r34[15:0] == 16'h01AA);
                    ac41_retries <= 12'd0;
                    queue_cmd(6'd55, 32'd0, 8'h01, 1'b0, 1'b0, S_ACMD55);
                    state <= S_ISSUE;
                end

                S_ACMD55: begin
                    dbg_r1s[23:16] <= r1;
                    queue_cmd(6'd41,
                              card_v2 ? 32'h40000000 : 32'd0,
                              8'h01, 1'b0, 1'b0, S_ACMD41);
                    state <= S_ISSUE;
                end

                S_ACMD41: begin
                    dbg_r1s[15:8] <= r1;
                    if (r1 == 8'h00) begin
                        if (card_v2) begin
                            queue_cmd(6'd58, 32'd0, 8'h01, 1'b1, 1'b0,
                                      S_CMD58);
                        end else begin
                            queue_cmd(6'd16, 32'd512, 8'h01, 1'b0, 1'b0,
                                      S_CMD16);
                        end
                        state <= S_ISSUE;
                    end else if (r1 == 8'h01) begin
                        if (ac41_retries == 12'd2000) begin
                            err_code <= 4'd2;
                            state    <= S_FAIL;
                        end else begin
                            ac41_retries <= ac41_retries + 12'd1;
                            queue_cmd(6'd55, 32'd0, 8'h01, 1'b0, 1'b0,
                                      S_ACMD55);
                            state <= S_ISSUE;
                        end
                    end else begin
                        // unexpected R1: try the MMC path (CMD1) before
                        // giving up
                        queue_cmd(6'd1, 32'd0, 8'h01, 1'b0, 1'b0,
                                  S_CMD1);
                        state <= S_ISSUE;
                    end
                end

                S_CMD1: begin
                    dbg_r1s[7:0] <= r1;
                    if (r1 == 8'h00) begin
                        // MMC is ready: force 512-byte blocks
                        queue_cmd(6'd16, 32'd512, 8'h01, 1'b0, 1'b0,
                                  S_CMD16);
                        state <= S_ISSUE;
                    end else if (r1 == 8'h01) begin
                        if (ac41_retries == 12'd2000) begin
                            err_code <= 4'd8;
                            state    <= S_FAIL;
                        end else begin
                            ac41_retries <= ac41_retries + 12'd1;
                            queue_cmd(6'd1, 32'd0, 8'h01, 1'b0, 1'b0,
                                      S_CMD1);
                            state <= S_ISSUE;
                        end
                    end else begin
                        err_code <= 4'd3;
                        state    <= S_FAIL;
                    end
                end

                S_CMD58: begin
                    dbg_r1s[7:0] <= r1;
                    card_hc <= r34[30];
                    state   <= S_INIT_DONE;
                end

                S_CMD16: begin
                    if (r1 == 8'h00 || r1 == 8'h01) state <= S_INIT_DONE;
                    else begin
                        err_code <= 4'd4;
                        state    <= S_FAIL;
                    end
                end

                S_INIT_DONE: begin
                    init_busy <= 1'b0;
                    init_done <= 1'b1;
                    spi_fast  <= 1'b1;
                    state     <= S_IDLE;
                end

                // ---- CMD17 read pipeline ------------------------------
                S_RD_WAIT: begin
                    // entered when CMD17 R1 is in (CS still low)
                    if (r1 != 8'h00) begin
                        err_code <= 4'd5;
                        state    <= S_FAIL;
                    end else if (!spi_wait) begin
                        spi_xfer(8'hFF);
                        spi_wait <= 1'b1;
                    end else if (spi_done) begin
                        spi_wait <= 1'b0;
                        if (spi_rx == 8'hFE) begin
                            rd_byte_cnt <= 10'd0;
                            state       <= S_RD_DATA;
                        end else if (spi_rx != 8'hFF) begin
                            err_code <= 4'd6;
                            state    <= S_FAIL;
                        end else if (rd_wait_cnt == 8'd200) begin
                            err_code <= 4'd7;
                            state    <= S_FAIL;
                        end else begin
                            rd_wait_cnt <= rd_wait_cnt + 8'd1;
                        end
                    end
                end

                S_RD_DATA: begin
                    if (!spi_wait) begin
                        spi_xfer(8'hFF);
                        spi_wait <= 1'b1;
                    end else if (spi_done) begin
                        spi_wait <= 1'b0;
                        rd_data  <= spi_rx;
                        rd_dv    <= 1'b1;
                        if (rd_byte_cnt == 10'd511) begin
                            crc_cnt <= 2'd0;
                            state   <= S_RD_CRC;
                        end else begin
                            rd_byte_cnt <= rd_byte_cnt + 10'd1;
                        end
                    end
                end

                S_RD_CRC: begin
                    if (!spi_wait) begin
                        spi_xfer(8'hFF);
                        spi_wait <= 1'b1;
                    end else if (spi_done) begin
                        spi_wait <= 1'b0;
                        if (crc_cnt == 2'd1) state <= S_RD_END;
                        else crc_cnt <= crc_cnt + 2'd1;
                    end
                end

                S_RD_END: begin
                    if (!spi_wait) begin
                        sd_cs_n  <= 1'b1;
                        spi_xfer(8'hFF);
                        spi_wait <= 1'b1;
                    end else if (spi_done) begin
                        spi_wait <= 1'b0;
                        rd_busy  <= 1'b0;
                        rd_done  <= 1'b1;
                        rd_err   <= 4'd0;
                        state    <= S_IDLE;
                    end
                end

                S_FAIL: begin
                    init_busy <= 1'b0;
                    rd_busy   <= 1'b0;
                    init_err  <= err_code;
                    rd_err    <= err_code;
                    sd_cs_n   <= 1'b1;
                    spi_wait  <= 1'b0;
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
