// ADS131M08 multi-device protocol scheduler.
//
// One SPI engine and one protocol state machine serve every attached device;
// only small per-device status registers are replicated.  That is the whole
// point of the IP: 16 ADS131M08 parts must not cost 16 copies of the control
// logic.
//
// ADS131M08 has no daisy-chain pin (TI SBAS950B lists 32 pins and none of them
// is a DAISY_IN/DAISY_OUT), so several parts share SCLK/DIN/DOUT and are
// selected by an individual CS.  Only the addressed part drives DOUT; the rest
// tri-state it while CS is high.
//
// FRAME-SELECT CONTRACT (learned the hard way on the single-device driver):
// ads131m08_spi_engine samples tx_data on the clock where it sees ``start``,
// and ``start`` is a registered output of this module.  Any signal that selects
// the frame payload -- the state, cfg_i, cur_dev -- must therefore not change in
// the cycle that asserts it.  Every state below asserts ``start`` while staying
// put and only advances on ``eng_done``.
`timescale 1ns/1ps

module ads131m08_scheduler #(
    parameter integer ADC_COUNT   = 1,           // 1..16
    parameter integer CLK_HZ      = 50_000_000,
    parameter integer SCK_DIV     = 1,
    parameter integer SYNC_LOW_US = 10_000,
    parameter integer SETTLE_US   = 50_000,
    parameter integer DRDY_TO_US  = 100_000,
    // Post-command settling delays from the reference driver.  Parameterised so
    // simulation can shrink them without changing the hardware values.
    parameter integer UNLOCK_DLY_US = 5_000,
    parameter integer WAKEUP_DLY_US = 10_000,
    parameter integer OSR_SEL     = 2,           // 000=128 ... 010=512 ... 111=16256
    parameter integer PWR_SEL     = 2,           // 10b = high resolution
    parameter integer SCHED_DEFAULT = 0          // 0 = round robin, 1 = DRDY priority
) (
    input  wire         clk,
    input  wire         rst_n,

    // ------------------------------------------------------------ register side
    input  wire         start_init,   // pulse: restart the whole sync + config sweep
    input  wire         enable,       // level: keep sampling once configured
    input  wire         sched_mode,   // 0 = round robin, 1 = DRDY priority
    input  wire [15:0]  gain1,
    input  wire [15:0]  gain2,
    input  wire [15:0]  mode_val,
    input  wire [15:0]  expect_id,    // whole ID register expected back
    input  wire [2:0]   osr_sel,
    input  wire [1:0]   pwr_sel,
    input  wire [ADC_COUNT-1:0] dev_enable,
    input  wire [ADC_COUNT-1:0] dev_resync, // pulse: pull one SYNC low on its own

    // ---------------------------------------------------------------- ADC pads
    output wire         adc_sclk,
    output wire         adc_din,
    input  wire         adc_dout,
    output wire [ADC_COUNT-1:0] adc_cs_n,
    output wire [ADC_COUNT-1:0] adc_sync_n,
    input  wire [ADC_COUNT-1:0] adc_drdy_n,

    // ------------------------------------------------------------------ status
    output reg  [ADC_COUNT-1:0] init_done,
    output reg  [ADC_COUNT-1:0] id_ok,
    output reg  [ADC_COUNT-1:0] cfg_ok,
    output reg  [ADC_COUNT-1:0] drdy_seen,
    output reg  [ADC_COUNT-1:0] dev_timeout,
    output reg  [ADC_COUNT-1:0] sample_valid,
    output reg  [16*ADC_COUNT-1:0] dev_id,
    output reg  [3:0]  sample_dev,    // device that produced the current sample
    output reg  [15:0] status_word,
    output reg  [191:0] ch_data,      // 8 x 24-bit of sample_dev
    output reg  [31:0] frame_count,
    output wire         spi_busy,
    output reg          all_init_done
);

    localparam [31:0] CNT_SYNC_LOW = (CLK_HZ / 1_000_000) * SYNC_LOW_US;
    localparam [31:0] CNT_SETTLE   = (CLK_HZ / 1_000_000) * SETTLE_US;
    localparam [31:0] CNT_DRDY_TO  = (CLK_HZ / 1_000_000) * DRDY_TO_US;
    localparam [31:0] CNT_5MS      = (CLK_HZ / 1_000_000) * UNLOCK_DLY_US;
    localparam [31:0] CNT_10MS     = (CLK_HZ / 1_000_000) * WAKEUP_DLY_US;

    integer k;
    integer si;
    genvar  gv;

    // ---------------------------------------------------------------- SPI PHY
    reg          eng_start;
    wire         eng_done;
    wire         eng_cs_n;
    wire [215:0] rx_data;
    wire [215:0] tx_frame;

    ads131m08_spi_engine #(
        .SCK_DIV (SCK_DIV)
    ) u_eng (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (eng_start),
        .n_bytes (5'd27),
        .tx_data (tx_frame),
        .rx_data (rx_data),
        .busy    (spi_busy),
        .done    (eng_done),
        .cs_n    (eng_cs_n),
        .sclk    (adc_sclk),
        .din     (adc_din),
        .dout    (adc_dout)
    );

    // ------------------------------------------------------------------- states
    localparam [3:0] T_POR         = 4'd0,
                     T_SYNC_HI     = 4'd1,
                     T_INIT_UNLOCK = 4'd2,
                     T_INIT_ULK_D  = 4'd3,
                     T_INIT_WAKE   = 4'd4,
                     T_INIT_WAK_D  = 4'd5,
                     T_RREG_ID     = 4'd6,
                     T_CFG         = 4'd7,
                     T_RREG_CFG    = 4'd8,
                     T_SWEEP_DONE  = 4'd9,
                     T_NEXT_DEV    = 4'd10,
                     T_WAIT_DRDY   = 4'd11,
                     T_READ        = 4'd12,
                     T_IDLE        = 4'd13;

    reg [3:0]  st;
    reg [31:0] wait_cnt;
    reg [31:0] drdy_to;
    reg [2:0]  cfg_i;
    reg [3:0]  cur_dev;      // device currently addressed
    reg        phase_init;   // 1 = configuration sweep in progress
    reg [4:0]  init_cnt;     // devices configured in this sweep

    // --------------------------------------------------------------------- CS
    // Exactly one device is selected at a time.  cur_dev only ever changes while
    // the engine has CS high, so two CS pulses can never overlap.
    generate
        for (gv = 0; gv < ADC_COUNT; gv = gv + 1) begin : g_cs
            assign adc_cs_n[gv] = (cur_dev == gv[3:0]) ? eng_cs_n : 1'b1;
        end
    endgenerate

    // ------------------------------------------------------------------- SYNC
    // The global reset sequence drives every part together.  A per-device
    // resync (recovering one part without disturbing the rest) pulls a single
    // line low for the same SYNC_LOW window.
    reg        global_sync_lo;
    reg [15:0] rs_act;
    reg [31:0] rs_cnt [0:15];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rs_act <= 16'd0;
            for (k = 0; k < 16; k = k + 1) rs_cnt[k] <= 32'd0;
        end else begin
            for (k = 0; k < 16; k = k + 1) begin
                if (k < ADC_COUNT) begin
                    if (dev_resync[k]) begin
                        rs_act[k] <= 1'b1;
                        rs_cnt[k] <= CNT_SYNC_LOW;
                    end else if (rs_act[k]) begin
                        if (rs_cnt[k] == 32'd0) rs_act[k] <= 1'b0;
                        else                    rs_cnt[k] <= rs_cnt[k] - 32'd1;
                    end
                end else begin
                    rs_act[k] <= 1'b0;
                end
            end
        end
    end

    generate
        for (gv = 0; gv < ADC_COUNT; gv = gv + 1) begin : g_sync
            assign adc_sync_n[gv] = !(global_sync_lo | rs_act[gv]);
        end
    endgenerate

    // ------------------------------------------------- how many devices to sweep
    reg [4:0] en_cnt;
    always @(*) begin
        en_cnt = 5'd0;
        for (si = 0; si < ADC_COUNT; si = si + 1)
            if (dev_enable[si]) en_cnt = en_cnt + 5'd1;
    end

    // ------------------------------------------------- per-device control words
    reg [5:0]  cfg_addr;
    reg [15:0] cfg_val;

    wire [15:0] clock_val = {8'hFF, 3'b000, osr_sel, pwr_sel};

    always @(*) begin
        case (cfg_i)
            3'd0: begin cfg_addr = 6'h03; cfg_val = clock_val; end  // CLOCK
            3'd1: begin cfg_addr = 6'h04; cfg_val = gain1;     end  // GAIN1
            3'd2: begin cfg_addr = 6'h05; cfg_val = gain2;     end  // GAIN2
            default: begin cfg_addr = 6'h02; cfg_val = mode_val; end // MODE
        endcase
    end

    wire [15:0] wreg_op = 16'h6000 | ({10'b0, cfg_addr} << 7);

    reg [215:0] tx_frame_d;
    always @(*) begin
        tx_frame_d = 216'd0;
        case (st)
            T_INIT_UNLOCK: begin
                tx_frame_d[7:0]  = 8'h06;   // UNLOCK 0x0655
                tx_frame_d[15:8] = 8'h55;
            end
            T_INIT_WAKE: begin
                tx_frame_d[7:0]  = 8'h00;   // WAKEUP 0x0033
                tx_frame_d[15:8] = 8'h33;
            end
            T_RREG_ID: begin
                tx_frame_d[7:0]  = 8'hA0;   // RREG addr 0, 1 word
                tx_frame_d[15:8] = 8'h00;
            end
            T_RREG_CFG: begin
                tx_frame_d[7:0]  = 8'hA1;   // RREG addr 3 (CLOCK), 1 word
                tx_frame_d[15:8] = 8'h80;
            end
            T_CFG: begin
                tx_frame_d[7:0]   = wreg_op[15:8];
                tx_frame_d[15:8]  = wreg_op[7:0];
                tx_frame_d[31:24] = cfg_val[15:8];
                tx_frame_d[39:32] = cfg_val[7:0];
            end
            default: ; // T_READ and every non-frame state send NULL
        endcase
    end
    assign tx_frame = tx_frame_d;

    // ------------------------------------------------------- next device search
    // Pass 1 picks the lowest enabled index above cur_dev so the sweep is a
    // clean round robin; pass 2 wraps to the lowest enabled index.  The loop
    // runs downwards, so the last assignment wins and yields the lowest match.
    reg [3:0] nxt_dev;
    reg       nxt_found;

    always @(*) begin
        nxt_dev   = 4'd0;
        nxt_found = 1'b0;
        for (si = ADC_COUNT - 1; si >= 0; si = si - 1)
            if (dev_enable[si] && (si > cur_dev))
                begin nxt_dev = si[3:0]; nxt_found = 1'b1; end
        if (!nxt_found)
            for (si = ADC_COUNT - 1; si >= 0; si = si - 1)
                if (dev_enable[si])
                    begin nxt_dev = si[3:0]; nxt_found = 1'b1; end
    end

    // ------------------------------------------------------------- DRDY picker
    // DRDY stays low until the conversion data are shifted out, so on a bus too
    // slow to serve everyone within one conversion period every part is ready
    // almost all of the time.  Picking a bare "lowest ready index" would then
    // starve devices 1..N-1 forever, so the search resumes *after* the device we
    // last served and only wraps when nothing above it is ready.
    reg [3:0] rdy_dev;
    reg       rdy_found;
    always @(*) begin
        rdy_dev   = 4'd0;
        rdy_found = 1'b0;
        for (si = ADC_COUNT - 1; si >= 0; si = si - 1)
            if (dev_enable[si] && !adc_drdy_n[si] && (si > cur_dev))
                begin rdy_dev = si[3:0]; rdy_found = 1'b1; end
        if (!rdy_found)
            for (si = ADC_COUNT - 1; si >= 0; si = si - 1)
                if (dev_enable[si] && !adc_drdy_n[si])
                    begin rdy_dev = si[3:0]; rdy_found = 1'b1; end
    end

    // ------------------------------------------------------------------ the FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st             <= T_POR;
            wait_cnt       <= 32'd0;
            drdy_to        <= 32'd0;
            cfg_i          <= 3'd0;
            cur_dev        <= 4'd0;
            phase_init     <= 1'b1;
            init_cnt       <= 4'd0;
            eng_start      <= 1'b0;
            global_sync_lo <= 1'b1;
            init_done      <= {ADC_COUNT{1'b0}};
            id_ok          <= {ADC_COUNT{1'b0}};
            cfg_ok         <= {ADC_COUNT{1'b0}};
            drdy_seen      <= {ADC_COUNT{1'b0}};
            dev_timeout    <= {ADC_COUNT{1'b0}};
            sample_valid   <= {ADC_COUNT{1'b0}};
            dev_id         <= {(16*ADC_COUNT){1'b0}};
            sample_dev     <= 4'd0;
            status_word    <= 16'd0;
            ch_data        <= 192'd0;
            frame_count    <= 32'd0;
            all_init_done  <= 1'b0;
        end else begin
            sample_valid <= {ADC_COUNT{1'b0}};
            eng_start    <= 1'b0;

            if (start_init && !spi_busy) begin
                // A restart is only accepted between frames, never mid-frame,
                // so CS can never be stranded low.
                wait_cnt       <= 32'd0;
                drdy_to        <= 32'd0;
                cfg_i          <= 3'd0;
                phase_init     <= 1'b1;
                init_cnt       <= 4'd0;
                global_sync_lo <= 1'b1;
                init_done      <= {ADC_COUNT{1'b0}};
                id_ok          <= {ADC_COUNT{1'b0}};
                cfg_ok         <= {ADC_COUNT{1'b0}};
                drdy_seen      <= {ADC_COUNT{1'b0}};
                dev_timeout    <= {ADC_COUNT{1'b0}};
                all_init_done  <= 1'b0;
                st             <= T_POR;
            end else begin
                case (st)
                    // --------------------------------------------- hardware reset
                    T_POR: begin
                        global_sync_lo <= 1'b1;
                        if (wait_cnt == CNT_SYNC_LOW) begin
                            wait_cnt <= 32'd0;
                            st       <= T_SYNC_HI;
                        end else begin
                            wait_cnt <= wait_cnt + 32'd1;
                        end
                    end

                    T_SYNC_HI: begin
                        global_sync_lo <= 1'b0;
                        if (wait_cnt == CNT_SETTLE) begin
                            wait_cnt   <= 32'd0;
                            cfg_i      <= 3'd0;
                            init_cnt   <= 4'd0;
                            phase_init <= 1'b1;
                            // Start the sweep so that the wrapping pass picks
                            // the lowest enabled device first.
                            cur_dev    <= ADC_COUNT[3:0] - 4'd1;
                            st         <= T_NEXT_DEV;
                        end else begin
                            wait_cnt <= wait_cnt + 32'd1;
                        end
                    end

                    // ----------------------------------------- pick the next device
                    T_NEXT_DEV: begin
                        if (!nxt_found) begin
                            st <= T_IDLE;   // nothing enabled at all
                        end else if (phase_init) begin
                            cur_dev <= nxt_dev;
                            cfg_i   <= 3'd0;
                            st      <= T_INIT_UNLOCK;
                        end else if (!enable) begin
                            st <= T_IDLE;
                        end else if (sched_mode) begin
                            // DRDY priority leaves cur_dev pointing at the device
                            // just served, which is what makes the ready-device
                            // search resume after it instead of restarting at 0.
                            st <= T_WAIT_DRDY;
                        end else begin
                            cur_dev <= nxt_dev;
                            drdy_to <= 32'd0;
                            st      <= T_WAIT_DRDY;
                        end
                    end

                    // ------------------------------------- per-device configuration
                    T_INIT_UNLOCK: begin
                        if (!spi_busy && !eng_done) begin
                            eng_start <= 1'b1;
                        end else if (eng_done) begin
                            wait_cnt <= 32'd0;
                            st       <= T_INIT_ULK_D;
                        end
                    end

                    T_INIT_ULK_D: begin
                        if (wait_cnt == CNT_5MS) begin
                            wait_cnt <= 32'd0;
                            st       <= T_INIT_WAKE;
                        end else begin
                            wait_cnt <= wait_cnt + 32'd1;
                        end
                    end

                    T_INIT_WAKE: begin
                        if (!spi_busy && !eng_done) begin
                            eng_start <= 1'b1;
                        end else if (eng_done) begin
                            wait_cnt <= 32'd0;
                            st       <= T_INIT_WAK_D;
                        end
                    end

                    T_INIT_WAK_D: begin
                        if (wait_cnt == CNT_10MS) begin
                            wait_cnt <= 32'd0;
                            st       <= T_RREG_ID;
                        end else begin
                            wait_cnt <= wait_cnt + 32'd1;
                        end
                    end

                    T_RREG_ID: begin
                        if (!spi_busy && !eng_done) begin
                            eng_start <= 1'b1;
                        end else if (eng_done) begin
                            dev_id[16*cur_dev +: 16] <= {rx_data[31:24], rx_data[39:32]};
                            id_ok[cur_dev] <=
                                ({rx_data[31:24], rx_data[39:32]} == expect_id);
                            cfg_i <= 3'd0;
                            st    <= T_CFG;
                        end
                    end

                    // cfg_i selects the payload, so it advances only after the
                    // engine has captured the frame.
                    T_CFG: begin
                        if (!spi_busy && !eng_done) begin
                            eng_start <= 1'b1;
                        end else if (eng_done) begin
                            if (cfg_i == 3'd3) begin
                                cfg_i <= 3'd0;
                                st    <= T_RREG_CFG;
                            end else begin
                                cfg_i <= cfg_i + 3'd1;
                            end
                        end
                    end

                    // CLOCK read-back: the register map is locked until UNLOCK,
                    // so this is the only way to tell a rejected configuration
                    // from a silent part.
                    T_RREG_CFG: begin
                        if (!spi_busy && !eng_done) begin
                            eng_start <= 1'b1;
                        end else if (eng_done) begin
                            cfg_ok[cur_dev]    <=
                                ({rx_data[31:24], rx_data[39:32]} == clock_val);
                            init_done[cur_dev] <= 1'b1;
                            if ((init_cnt + 5'd1) >= en_cnt) begin
                                st <= T_SWEEP_DONE;
                            end else begin
                                init_cnt <= init_cnt + 5'd1;
                                st       <= T_NEXT_DEV;
                            end
                        end
                    end

                    T_SWEEP_DONE: begin
                        all_init_done <= 1'b1;
                        init_cnt      <= 4'd0;
                        phase_init    <= 1'b0;
                        st            <= T_NEXT_DEV;
                    end

                    // ------------------------------------- wait for a ready device
                    T_WAIT_DRDY: begin
                        if (sched_mode) begin
                            // DRDY priority: serve whichever enabled part is ready.
                            if (rdy_found) begin
                                cur_dev <= rdy_dev;
                                st      <= T_READ;
                            end
                        end else if (!adc_drdy_n[cur_dev]) begin
                            // Round robin: still pace on each part's own DRDY so
                            // the same conversion is never read twice.
                            drdy_seen[cur_dev] <= 1'b1;
                            drdy_to            <= 32'd0;
                            st                 <= T_READ;
                        end else if (drdy_to == CNT_DRDY_TO) begin
                            drdy_to              <= 32'd0;
                            dev_timeout[cur_dev] <= 1'b1;
                            st                   <= T_READ;
                        end else begin
                            drdy_to <= drdy_to + 32'd1;
                        end
                    end

                    // ----------------------------------------- conversion frame
                    T_READ: begin
                        if (!spi_busy && !eng_done) begin
                            eng_start <= 1'b1;
                        end else if (eng_done) begin
                            status_word <= {rx_data[7:0], rx_data[15:8]};
                            for (k = 0; k < 8; k = k + 1) begin
                                ch_data[24*k +: 24] <= {
                                    rx_data[8*(3+3*k) +: 8],
                                    rx_data[8*(4+3*k) +: 8],
                                    rx_data[8*(5+3*k) +: 8] };
                            end
                            sample_dev   <= cur_dev;
                            sample_valid[cur_dev] <= 1'b1;
                            frame_count  <= frame_count + 32'd1;
                            drdy_seen[cur_dev] <= 1'b1;
                            st           <= T_NEXT_DEV;
                        end
                    end

                    // ------------------------------------------------------- idle
                    default: begin // T_IDLE
                        if (enable && nxt_found) begin
                            phase_init <= 1'b0;
                            st         <= T_NEXT_DEV;
                        end
                    end
                endcase
            end
        end
    end

endmodule
