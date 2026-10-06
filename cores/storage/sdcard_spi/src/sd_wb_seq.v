// Wishbone-master sequencer driving ZipCPU's sdspi core for the
// Tang Primer 20K SD-card reader.  Presents the same init/read interface
// as the previous hand-rolled sdcard_ip so top.v is a drop-in swap.
//
// Init sequence mirrors sw/sdspidrv.c:
//   SETAUX(slow,512B) -> clear errors -> CMD0 -> CMD8(0x1AA) ->
//   CMD55/ACMD41(HCS) loop -> CMD58(OCR) -> SETAUX(fast)
//   MMC fallback path: CMD1 loop -> CMD16.
// Sector read: CMD17 with FIFO_OP, then 128 FIFO word reads streamed
// out byte-by-byte on rd_data/rd_dv.
module sd_wb_seq #(
    parameter [7:0]  CLKDIV_SLOW = 8'd124,   // ~108 kHz @ 27 MHz
    parameter [7:0]  CLKDIV_FAST = 8'd3,     // ~3.4 MHz @ 27 MHz
    parameter integer STARTUP_CLOCKS = 75,
    parameter integer POWERUP_IDLE   = 1000,
    parameter integer ACMD_MAX       = 1500
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        init_start,
    output reg         init_busy,
    output reg         init_done,
    output reg  [3:0]  init_err,
    output reg  [7:0]  dbg_r1,
    output reg  [63:0] dbg_hist,   // {last status, last data-reg read}
    output reg  [63:0] dbg_h8,     // {status, data} snapshot after CMD8
    output reg  [39:0] dbg_r1s,    // per-stage R1: {cmd0,cmd8,cmd55,cmd41/1,cmd58}
    output reg         card_v2,
    output reg         card_hc,

    input  wire        rd_start,
    input  wire [31:0] rd_lba,
    output reg         rd_busy,
    output reg         rd_done,
    output reg  [3:0]  rd_err,
    output reg  [7:0]  rd_data,
    output reg         rd_dv,

    output wire        sd_cs_n,
    input  wire        sd_miso,
    output wire        sd_sck,
    output wire        sd_mosi
);

    // ------------------------------------------------------------------
    // sdspi (Wishbone-attached, card detect disabled)
    // ------------------------------------------------------------------
    reg         wb_cyc, wb_stb_r, wb_we;
    reg  [1:0]  wb_adr;
    reg  [31:0] wb_dat;
    wire        wb_ack;
    wire [31:0] wb_rdat;
    wire [31:0] sd_dbg;

    sdspi #(
        .OPT_CARD_DETECT(1'b0),
        .OPT_LITTLE_ENDIAN(1'b0),
        .LGFIFOLN(7),
        .POWERUP_IDLE(POWERUP_IDLE),
        .STARTUP_CLOCKS(STARTUP_CLOCKS),
        .CKDIV_BITS(8),
        .INITIAL_CLKDIV(CLKDIV_SLOW),
        .OPT_SPI_ARBITRATION(1'b0)
    ) u_sd (
        .i_clk(clk), .i_sd_reset(!rst_n),
        .i_wb_cyc(wb_cyc), .i_wb_stb(wb_stb_r), .i_wb_we(wb_we),
        .i_wb_addr(wb_adr), .i_wb_data(wb_dat), .i_wb_sel(4'hF),
        .o_wb_stall(), .o_wb_ack(wb_ack), .o_wb_data(wb_rdat),
        .o_cs_n(sd_cs_n), .o_sck(sd_sck), .o_mosi(sd_mosi),
        .i_miso(sd_miso), .i_card_detect(1'b1),
        .o_int(), .i_bus_grant(1'b1), .o_debug(sd_dbg)
    );

    // status register bit aliases (sd_ctrl read value)
    // [14]=busy [15]=err [18]=removed [19]=!present [21]=watchdog [7:0]=last R1

    // ------------------------------------------------------------------
    // wishbone micro engine: single-transaction write/read
    // ------------------------------------------------------------------
    localparam [1:0] W_IDLE = 2'd0, W_STB = 2'd1, W_ACK = 2'd2;
    reg  [1:0]  wst;
    reg         w_req;        // request pulse from macro FSM
    reg         w_rd;         // 1 = read, 0 = write
    reg  [1:0]  w_adr;
    reg  [31:0] w_dat;
    reg         wb_done;
    reg  [31:0] wb_out;

    // ------------------------------------------------------------------
    // macro FSM
    // ------------------------------------------------------------------
    localparam [5:0]
        M_IDLE  = 6'd0,
        // generic command dispatch
        G_WD    = 6'd1,   // write data reg (arg)
        G_WC    = 6'd2,   // write ctrl reg (command)
        G_P     = 6'd3,   // read status
        G_K     = 6'd4,   // poll check -> ret
        G_RD    = 6'd5,   // read data reg
        G_RDK   = 6'd6,   // -> ret
        // init steps (each loads pend_* then jumps to G_WD)
        M_SLOW  = 6'd10,
        M_CLR   = 6'd11,
        M_C0    = 6'd12,  M_C0K  = 6'd13,
        M_C8    = 6'd14,  M_C8K  = 6'd15,
        M_55    = 6'd16,  M_55K  = 6'd17,
        M_41    = 6'd18,  M_41K  = 6'd19,
        M_1     = 6'd20,  M_1K   = 6'd21,
        M_16    = 6'd22,  M_16K  = 6'd23,
        M_58    = 6'd24,  M_58K  = 6'd25,
        M_FAST  = 6'd26,
        M_FIN   = 6'd27,
        // sector read
        M_RD    = 6'd30,  M_RDK  = 6'd31,
        M_FRD   = 6'd32,  M_FEMIT= 6'd33,
        M_FDONE = 6'd35,
        M_FAIL  = 6'd34;

    reg  [5:0]  mstate;
    reg  [5:0]  pend_ret;
    reg         pend_dread;
    reg  [31:0] pend_arg, pend_ctrl;
    reg  [31:0] last_status, last_data;
    reg  [11:0] acmd_cnt;
    reg  [7:0]  fifo_cnt;      // 0..127 words
    reg  [2:0]  emit_cnt;      // 0..3 bytes within word
    reg  [31:0] emit_word;
    reg  [3:0]  err_code;

    wire        st_busy = last_status[14];
    wire        st_err  = last_status[15] || last_status[21] ||
                          last_status[18] || last_status[19];
    wire [7:0]  st_r1   = last_status[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wst <= W_IDLE; w_req <= 1'b0; w_rd <= 1'b0;
            w_adr <= 2'd0; w_dat <= 32'd0;
            wb_cyc <= 1'b0; wb_stb_r <= 1'b0; wb_we <= 1'b0;
            wb_adr <= 2'd0; wb_dat <= 32'd0;
            wb_done <= 1'b0; wb_out <= 32'd0;
            mstate <= M_IDLE; pend_ret <= M_IDLE; pend_dread <= 1'b0;
            pend_arg <= 32'd0; pend_ctrl <= 32'd0;
            last_status <= 32'd0; last_data <= 32'd0;
            acmd_cnt <= 12'd0;
            fifo_cnt <= 8'd0; emit_cnt <= 3'd0; emit_word <= 32'd0;
            err_code <= 4'd0;
            init_busy <= 1'b0; init_done <= 1'b0; init_err <= 4'd0;
            rd_busy <= 1'b0; rd_done <= 1'b0; rd_err <= 4'd0;
            rd_data <= 8'd0; rd_dv <= 1'b0;
            dbg_r1 <= 8'd0; dbg_hist <= 64'd0; dbg_h8 <= 64'd0;
            dbg_r1s <= 40'd0; card_v2 <= 1'b0; card_hc <= 1'b0;
        end else begin
            w_req    <= 1'b0;
            wb_done  <= 1'b0;
            rd_dv    <= 1'b0;
            rd_done  <= 1'b0;

            // -------- wishbone micro engine --------
            case (wst)
                W_IDLE: begin
                    if (w_req) begin
                        wb_cyc   <= 1'b1;
                        wb_stb_r <= 1'b1;
                        wb_we    <= !w_rd;
                        wb_adr   <= w_adr;
                        wb_dat   <= w_dat;
                        wst      <= W_STB;
                    end
                end
                W_STB: begin
                    wb_stb_r <= 1'b0;      // strobe was high for 1 clk
                    wst      <= W_ACK;
                end
                W_ACK: begin
                    // sdspi registers o_wb_ack (ack lands 2 clk after stb)
                    // and o_wb_data is valid *at* the ack cycle -- one clk
                    // later the FIFO read pointer has already advanced, so
                    // wb_rdat must be captured here, not in a later state.
                    if (wb_ack) begin
                        wb_out  <= wb_rdat;
                        wb_done <= 1'b1;
                        wb_cyc  <= 1'b0;
                        wst     <= W_IDLE;
                    end
                end
            endcase

            // -------- macro sequencer --------
            case (mstate)
                M_IDLE: begin
                    init_busy <= 1'b0;
                    rd_busy   <= 1'b0;
                    if (init_start) begin
                        init_busy <= 1'b1;
                        init_done <= 1'b0;
                        init_err  <= 4'd0;
                        card_v2   <= 1'b0;
                        card_hc   <= 1'b0;
                        acmd_cnt  <= 12'd0;
                        dbg_r1s   <= 40'd0;
                        mstate    <= M_SLOW;
                    end else if (rd_start) begin
                        rd_busy <= 1'b1;
                        rd_done <= 1'b0;
                        rd_err  <= 4'd0;
                        mstate  <= M_RD;
                    end
                end

                // generic dispatch
                G_WD: begin
                    if (wb_done) mstate <= G_WC;
                    else if (wst == W_IDLE && !w_req) begin
                        w_req <= 1'b1; w_rd <= 1'b0;
                        w_adr <= 2'd1; w_dat <= pend_arg;
                    end
                end
                G_WC: begin
                    if (wb_done) mstate <= G_P;
                    else if (wst == W_IDLE && !w_req) begin
                        w_req <= 1'b1; w_rd <= 1'b0;
                        w_adr <= 2'd0; w_dat <= pend_ctrl;
                    end
                end
                G_P: begin
                    if (wb_done) begin
                        last_status <= wb_out;
                        dbg_r1      <= wb_out[7:0];
                        mstate      <= G_K;
                    end else if (wst == W_IDLE && !w_req) begin
                        w_req <= 1'b1; w_rd <= 1'b1; w_adr <= 2'd0;
                    end
                end
                G_K: begin
                    if (st_busy) mstate <= G_P;
                    else if (pend_dread) mstate <= G_RD;
                    else mstate <= pend_ret;
                end
                G_RD: begin
                    if (wb_done) begin
                        last_data <= wb_out;
                        dbg_hist  <= {last_status, wb_out};
                        mstate    <= pend_ret;
                    end else if (wst == W_IDLE && !w_req) begin
                        w_req <= 1'b1; w_rd <= 1'b1; w_adr <= 2'd1;
                    end
                end
                G_RDK: mstate <= pend_ret;

                // -------- init --------
                M_SLOW: begin
                    pend_arg   <= {12'd0, 4'd9, 4'd0, CLKDIV_SLOW};
                    pend_ctrl  <= 32'h000000FF;   // SETAUX
                    pend_dread <= 1'b0;
                    pend_ret   <= M_CLR;
                    mstate     <= G_WD;
                end
                M_CLR: begin
                    pend_arg   <= 32'd0;
                    pend_ctrl  <= 32'h000080BF;   // CLEARERR|READAUX
                    pend_dread <= 1'b0;
                    pend_ret   <= M_C0;
                    mstate     <= G_WD;
                end
                M_C0: begin
                    pend_arg   <= 32'd0;
                    pend_ctrl  <= 32'h00048040;   // REMOVED|CLEARERR|CMD0
                    pend_dread <= 1'b0;
                    pend_ret   <= M_C0K;
                    mstate     <= G_WD;
                end
                M_C0K: begin
                    dbg_r1s[39:32] <= st_r1;
                    if (st_err || st_r1 != 8'h01) begin
                        err_code <= 4'd1;
                        mstate   <= M_FAIL;
                    end else mstate <= M_C8;
                end
                M_C8: begin
                    pend_arg   <= 32'h000001AA;
                    pend_ctrl  <= 32'h00008248;   // CLEARERR|READREG|CMD8
                    pend_dread <= 1'b1;
                    pend_ret   <= M_C8K;
                    mstate     <= G_WD;
                end
                M_C8K: begin
                    dbg_r1s[31:24] <= st_r1;
                    dbg_h8         <= {last_status, last_data};
                    card_v2        <= !st_err && (last_data == 32'h000001AA);
                    mstate         <= M_55;
                end
                M_55: begin
                    pend_arg   <= 32'd0;
                    pend_ctrl  <= 32'h00008077;   // CLEARERR|CMD55
                    pend_dread <= 1'b0;
                    pend_ret   <= M_55K;
                    mstate     <= G_WD;
                end
                M_55K: begin
                    dbg_r1s[23:16] <= st_r1;
                    // CMD55 illegal (v1/MMC card) -> try CMD1 path
                    if (st_err) mstate <= M_1;
                    else        mstate <= M_41;
                end
                M_41: begin
                    pend_arg   <= card_v2 ? 32'h40000000 : 32'd0;
                    pend_ctrl  <= 32'h00008069;   // CLEARERR|CMD41
                    pend_dread <= 1'b0;
                    pend_ret   <= M_41K;
                    mstate     <= G_WD;
                end
                M_41K: begin
                    dbg_r1s[15:8] <= st_r1;
                    if (st_err) begin
                        mstate <= M_1;
                    end else if (st_r1[0]) begin   // still idle
                        if (acmd_cnt == ACMD_MAX[11:0]) begin
                            err_code <= 4'd2;
                            mstate   <= M_FAIL;
                        end else begin
                            acmd_cnt <= acmd_cnt + 12'd1;
                            mstate   <= M_55;
                        end
                    end else mstate <= M_58;
                end
                M_1: begin
                    pend_arg   <= 32'd0;
                    pend_ctrl  <= 32'h00008041;   // CLEARERR|CMD1
                    pend_dread <= 1'b0;
                    pend_ret   <= M_1K;
                    mstate     <= G_WD;
                end
                M_1K: begin
                    dbg_r1s[15:8] <= st_r1;
                    if (st_err) begin
                        err_code <= 4'd3;
                        mstate   <= M_FAIL;
                    end else if (st_r1[0]) begin
                        if (acmd_cnt == ACMD_MAX[11:0]) begin
                            err_code <= 4'd8;
                            mstate   <= M_FAIL;
                        end else begin
                            acmd_cnt <= acmd_cnt + 12'd1;
                            mstate   <= M_1;
                        end
                    end else mstate <= M_16;
                end
                M_16: begin
                    pend_arg   <= 32'd512;
                    pend_ctrl  <= 32'h00008050;   // CLEARERR|CMD16
                    pend_dread <= 1'b0;
                    pend_ret   <= M_16K;
                    mstate     <= G_WD;
                end
                M_16K: begin
                    if (st_err) begin
                        err_code <= 4'd4;
                        mstate   <= M_FAIL;
                    end else mstate <= M_FAST;
                end
                M_58: begin
                    pend_arg   <= 32'd0;
                    pend_ctrl  <= 32'h0000827A;   // CLEARERR|READREG|CMD58
                    pend_dread <= 1'b1;
                    pend_ret   <= M_58K;
                    mstate     <= G_WD;
                end
                M_58K: begin
                    dbg_r1s[7:0] <= st_r1;
                    card_hc      <= last_data[30];   // CCS
                    mstate       <= M_FAST;
                end
                M_FAST: begin
                    pend_arg   <= {12'd0, 4'd9, 4'd0, CLKDIV_FAST};
                    pend_ctrl  <= 32'h000000FF;
                    pend_dread <= 1'b0;
                    pend_ret   <= M_FIN;
                    mstate     <= G_WD;
                end
                M_FIN: begin
                    init_busy <= 1'b0;
                    init_done <= 1'b1;
                    mstate    <= M_IDLE;
                end

                // -------- sector read --------
                M_RD: begin
                    // HC cards: block addressing; else byte addressing
                    pend_arg   <= card_hc ? rd_lba : {rd_lba[22:0], 9'd0};
                    pend_ctrl  <= 32'h00008851;   // CLEARERR|FIFO_OP|CMD17
                    pend_dread <= 1'b0;
                    pend_ret   <= M_RDK;
                    mstate     <= G_WD;
                end
                M_RDK: begin
                    if (st_err) begin
                        rd_err   <= 4'd5;
                        rd_busy  <= 1'b0;
                        rd_done  <= 1'b1;
                        mstate   <= M_IDLE;
                    end else begin
                        fifo_cnt <= 8'd0;
                        mstate   <= M_FRD;
                    end
                end
                M_FRD: begin
                    if (wb_done) begin
                        emit_word <= wb_out;
                        emit_cnt  <= 3'd0;
                        mstate    <= M_FEMIT;
                    end else if (wst == W_IDLE && !w_req) begin
                        w_req <= 1'b1; w_rd <= 1'b1; w_adr <= 2'd2;
                    end
                end
                M_FEMIT: begin
                    rd_dv   <= 1'b1;
                    case (emit_cnt)
                        3'd0: rd_data <= emit_word[31:24];
                        3'd1: rd_data <= emit_word[23:16];
                        3'd2: rd_data <= emit_word[15:8];
                        default: rd_data <= emit_word[7:0];
                    endcase
                    if (emit_cnt == 3'd3) begin
                        if (fifo_cnt == 8'd127) begin
                            mstate  <= M_FDONE;
                        end else begin
                            fifo_cnt <= fifo_cnt + 8'd1;
                            mstate   <= M_FRD;
                        end
                    end else emit_cnt <= emit_cnt + 3'd1;
                end
                M_FDONE: begin
                    // rd_done one clk after the last rd_dv byte so the
                    // consumer can latch byte 511 before checking it
                    rd_busy <= 1'b0;
                    rd_done <= 1'b1;
                    mstate  <= M_IDLE;
                end

                M_FAIL: begin
                    init_err  <= err_code;
                    init_busy <= 1'b0;
                    mstate    <= M_IDLE;
                end
                default: mstate <= M_IDLE;
            endcase
        end
    end

endmodule
