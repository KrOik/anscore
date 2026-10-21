// ads131m08_multi_ip -- parameterised multi-device ADS131M08 front end.
//
//   * 1..16 ADS131M08 parts on one shared SCLK/DIN/DOUT bus, each with its own
//     CS and DRDY (ADS131M08 has no daisy-chain pin, so this is the only way to
//     hang several of them off one controller);
//   * AXI4-Lite control/status register file;
//   * AXI4-Stream sample output, one beat per conversion frame;
//   * a sample FIFO with explicit overflow accounting.
//
// Everything runs in the single ``clk`` domain; CLK_HZ only scales the
// microsecond delays.
//
// Register map (byte offsets, 32-bit, single beat, no bursts)
//   0x000 CTRL        W[0] soft reset  W[1] start init  W[2] enable level
//                     W[3] clear errors W[4] clear FIFO W[5] resync
//   0x004 STATUS      [3:0] ADC_COUNT [4] spi_busy [5] all_init_done
//                     [6] all_id_ok [7] all_cfg_ok [11:8] current sample device
//   0x008 SCHED       [0] mode (0 round robin, 1 DRDY priority) [31:16] dev mask
//   0x00C ERR         [15:0] per-device error [16] FIFO overflow [17] DRDY
//                     timeout [18] unmapped access.  All sticky.
//   0x010 IRQ_EN, 0x014 IRQ_STATUS (W1C)
//   0x018 CFG0        [2:0] OSR select [4:3] power mode
//   0x01C CFG1        [15:0] expected ID register
//   0x020+4n DEV_CTRL[n]   [0] enable [1] resync pulse
//   0x060+4n DEV_STATUS[n] [0] init_done [1] id_ok [2] cfg_ok [3] drdy_seen
//                          [4] timeout [5] drdy_n live [31:16] last STATUS word
//   0x100+4n DEV_ID[n]     [15:0] ID register read back
//   0x140+4n DEV_SAMPLES[n] frame counter
//   0x180 CFG_GAIN1, 0x184 CFG_GAIN2, 0x188 CFG_MODE
//   0x200 FIFO_DATA   low 32 bits of the most recently popped beat
//   0x204 FIFO_STATUS [15:0] level [16] full [17] empty
//   0x208 DROP_COUNT
`timescale 1ns/1ps

module ads131m08_multi_ip #(
    parameter integer ADC_COUNT   = 1,           // 1..16
    parameter integer CLK_HZ      = 50_000_000,
    parameter integer SCK_DIV     = 1,
    parameter integer SYNC_LOW_US = 10_000,
    parameter integer SETTLE_US   = 50_000,
    parameter integer DRDY_TO_US  = 100_000,
    parameter integer UNLOCK_DLY_US = 5_000,
    parameter integer WAKEUP_DLY_US = 10_000,
    parameter integer OSR_SEL     = 2,           // 000=128 ... 010=512 ... 111=16256
    parameter integer PWR_SEL     = 2,           // 10b = high resolution
    parameter integer SCHED_DEFAULT = 0,         // 0 = round robin, 1 = DRDY priority
    parameter integer FIFO_DEPTH  = 512,
    parameter integer EXPECT_ID_DEFAULT = 16'h0801,
    parameter integer ADDR_W      = 12
) (
    input  wire         clk,
    input  wire         rst_n,

    // ---------------------------------------------------------------- ADC pads
    output wire         adc_sclk,
    output wire         adc_din,
    input  wire         adc_dout,
    output wire [ADC_COUNT-1:0] adc_cs_n,
    output wire [ADC_COUNT-1:0] adc_sync_n,
    input  wire [ADC_COUNT-1:0] adc_drdy_n,

    // ------------------------------------------------------------ AXI4-Lite
    input  wire [ADDR_W-1:0] s_axi_awaddr,
    input  wire [2:0]        s_axi_awprot,
    input  wire              s_axi_awvalid,
    output wire              s_axi_awready,
    input  wire [31:0]       s_axi_wdata,
    input  wire [3:0]        s_axi_wstrb,
    input  wire              s_axi_wvalid,
    output wire              s_axi_wready,
    output wire [1:0]        s_axi_bresp,
    output wire              s_axi_bvalid,
    input  wire              s_axi_bready,
    input  wire [ADDR_W-1:0] s_axi_araddr,
    input  wire [2:0]        s_axi_arprot,
    input  wire              s_axi_arvalid,
    output wire              s_axi_arready,
    output wire [31:0]       s_axi_rdata,
    output wire [1:0]        s_axi_rresp,
    output wire              s_axi_rvalid,
    input  wire              s_axi_rready,

    // --------------------------------------------------------- AXI4-Stream
    // tdata = {44'b0, adc_index[3:0], status[15:0], ch7..ch0}, one beat per frame
    output wire [255:0] m_axis_tdata,
    output wire [15:0]  m_axis_tuser,
    output wire         m_axis_tvalid,
    output wire         m_axis_tlast,
    input  wire         m_axis_tready,

    output wire         irq
);
    // Elaboration contract. These checks are simulation-visible and prevent
    // unsupported configurations from silently producing a misleading build.
    // The storage and scheduler implementation remains unchanged for valid
    // configurations.
    initial begin
        if (ADC_COUNT < 1 || ADC_COUNT > 16)
            $fatal(1, "ADC_COUNT must be in the range 1..16");
        if (CLK_HZ <= 0)
            $fatal(1, "CLK_HZ must be positive");
        if (SCK_DIV < 0)
            $fatal(1, "SCK_DIV must be non-negative");
        if (OSR_SEL < 0 || OSR_SEL > 7)
            $fatal(1, "OSR_SEL must be in the range 0..7");
        if (PWR_SEL < 0 || PWR_SEL > 3)
            $fatal(1, "PWR_SEL must be in the range 0..3");
        if (SCHED_DEFAULT < 0 || SCHED_DEFAULT > 1)
            $fatal(1, "SCHED_DEFAULT must be 0 or 1");
        if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0)
            $fatal(1, "FIFO_DEPTH must be a power of two >= 2");
        if (ADDR_W < 12)
            $fatal(1, "ADDR_W must be at least 12");
    end

    localparam integer FIFO_W = 272;   // 256 data + 16 user

    // ------------------------------------------------------- AXI-Lite bridge
    wire [ADDR_W-1:0] wr_addr, rd_addr;
    wire [31:0]       wr_data, rd_data;
    wire [3:0]        wr_strb;
    wire              wr_en, rd_en;

    ads131m08_axi_lite #(.ADDR_W(ADDR_W)) u_axi (
        .clk (clk), .rst_n (rst_n),
        .s_axi_awaddr (s_axi_awaddr), .s_axi_awprot (s_axi_awprot),
        .s_axi_awvalid (s_axi_awvalid), .s_axi_awready (s_axi_awready),
        .s_axi_wdata (s_axi_wdata), .s_axi_wstrb (s_axi_wstrb),
        .s_axi_wvalid (s_axi_wvalid), .s_axi_wready (s_axi_wready),
        .s_axi_bresp (s_axi_bresp), .s_axi_bvalid (s_axi_bvalid),
        .s_axi_bready (s_axi_bready),
        .s_axi_araddr (s_axi_araddr), .s_axi_arprot (s_axi_arprot),
        .s_axi_arvalid (s_axi_arvalid), .s_axi_arready (s_axi_arready),
        .s_axi_rdata (s_axi_rdata), .s_axi_rresp (s_axi_rresp),
        .s_axi_rvalid (s_axi_rvalid), .s_axi_rready (s_axi_rready),
        .wr_addr (wr_addr), .wr_data (wr_data), .wr_strb (wr_strb), .wr_en (wr_en),
        .rd_addr (rd_addr), .rd_en (rd_en), .rd_data (rd_data)
    );

    // Register and stream ownership is implemented by the narrow blocks
    // instantiated below. This top-level only connects the shared scheduler.

    // Scheduler and adapter state. Register ownership is isolated in
    // ads131m08_regfile; FIFO and stream ownership is isolated in
    // ads131m08_stream_adapter.
    wire [ADC_COUNT-1:0] init_done, id_ok, cfg_ok, drdy_seen, dev_timeout, sample_valid;
    wire [16*ADC_COUNT-1:0] dev_id_v;
    wire [3:0] sample_dev;
    wire [15:0] status_word;
    wire [191:0] ch_data;
    wire [31:0] frame_count;
    wire spi_busy, all_init_done;
    wire [ADC_COUNT-1:0] dev_ctrl_en, dev_ctrl_rst;
    wire cfg_enable, cfg_sched_mode;
    wire [15:0] cfg_dev_mask;
    wire [31:0] cfg_irq_en;
    wire [2:0] cfg_osr;
    wire [1:0] cfg_pwr;
    wire [15:0] cfg_expect_id, cfg_gain1, cfg_gain2, cfg_mode;
    wire c_start_init, c_clear_fifo, c_resync;
    wire fifo_ovf;
    wire [31:0] fifo_drops, fifo_data_low;
    wire fifo_full, fifo_empty;
    wire [15:0] fifo_level;

    ads131m08_regfile #(
        .ADC_COUNT(ADC_COUNT), .SCHED_DEFAULT(SCHED_DEFAULT),
        .OSR_SEL(OSR_SEL), .PWR_SEL(PWR_SEL),
        .EXPECT_ID_DEFAULT(EXPECT_ID_DEFAULT), .ADDR_W(ADDR_W)
    ) u_regfile (
        .clk(clk), .rst_n(rst_n),
        .wr_addr(wr_addr), .wr_data(wr_data), .wr_strb(wr_strb), .wr_en(wr_en),
        .rd_addr(rd_addr), .rd_en(rd_en), .rd_data(rd_data),
        .cfg_enable(cfg_enable), .cfg_sched_mode(cfg_sched_mode),
        .cfg_dev_mask(cfg_dev_mask), .cfg_irq_en(cfg_irq_en),
        .cfg_osr(cfg_osr), .cfg_pwr(cfg_pwr), .cfg_expect_id(cfg_expect_id),
        .cfg_gain1(cfg_gain1), .cfg_gain2(cfg_gain2), .cfg_mode(cfg_mode),
        .dev_ctrl_en(dev_ctrl_en), .dev_ctrl_rst(dev_ctrl_rst),
        .c_start_init(c_start_init), .c_clear_fifo(c_clear_fifo),
        .c_resync(c_resync),
        .init_done(init_done), .id_ok(id_ok), .cfg_ok(cfg_ok),
        .drdy_seen(drdy_seen), .dev_timeout(dev_timeout), .dev_id_v(dev_id_v),
        .sample_dev(sample_dev), .status_word(status_word), .ch_data(ch_data),
        .sample_valid(sample_valid), .adc_drdy_n(adc_drdy_n),
        .spi_busy(spi_busy), .all_init_done(all_init_done),
        .fifo_ovf(fifo_ovf), .fifo_full(fifo_full), .fifo_empty(fifo_empty),
        .fifo_level(fifo_level), .fifo_drops(fifo_drops),
        .fifo_data_low(fifo_data_low), .irq(irq)
    );

    // ------------------------------------------------------------- scheduler


    wire [ADC_COUNT-1:0] dev_enable = dev_ctrl_en & cfg_dev_mask[ADC_COUNT-1:0];

    ads131m08_scheduler #(
        .ADC_COUNT     (ADC_COUNT),
        .CLK_HZ        (CLK_HZ),
        .SCK_DIV       (SCK_DIV),
        .SYNC_LOW_US   (SYNC_LOW_US),
        .SETTLE_US     (SETTLE_US),
        .DRDY_TO_US    (DRDY_TO_US),
        .UNLOCK_DLY_US (UNLOCK_DLY_US),
        .WAKEUP_DLY_US (WAKEUP_DLY_US),
        .OSR_SEL       (OSR_SEL),
        .PWR_SEL       (PWR_SEL),
        .SCHED_DEFAULT (SCHED_DEFAULT)
    ) u_sched (
        .clk          (clk),
        .rst_n        (rst_n),
        .start_init   (c_start_init),
        .enable       (cfg_enable),
        .sched_mode   (cfg_sched_mode),
        .gain1        (cfg_gain1),
        .gain2        (cfg_gain2),
        .mode_val     (cfg_mode),
        .expect_id    (cfg_expect_id),
        .osr_sel      (cfg_osr),
        .pwr_sel      (cfg_pwr),
        .dev_enable   (dev_enable),
        .dev_resync   (dev_ctrl_rst | {ADC_COUNT{c_resync}}),
        .adc_sclk     (adc_sclk),
        .adc_din      (adc_din),
        .adc_dout     (adc_dout),
        .adc_cs_n     (adc_cs_n),
        .adc_sync_n   (adc_sync_n),
        .adc_drdy_n   (adc_drdy_n),
        .init_done    (init_done),
        .id_ok        (id_ok),
        .cfg_ok       (cfg_ok),
        .drdy_seen    (drdy_seen),
        .dev_timeout  (dev_timeout),
        .sample_valid (sample_valid),
        .dev_id       (dev_id_v),
        .sample_dev   (sample_dev),
        .status_word  (status_word),
        .ch_data      (ch_data),
        .frame_count  (frame_count),
        .spi_busy     (spi_busy),
        .all_init_done(all_init_done)
    );

    // ------------------------------------------------------- sample streaming
    ads131m08_stream_adapter #(
        .ADC_COUNT(ADC_COUNT),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_stream (
        .clk(clk), .rst_n(rst_n),
        .sample_valid(sample_valid), .sample_dev(sample_dev),
        .status_word(status_word), .ch_data(ch_data),
        .dev_timeout(dev_timeout), .cfg_ok(cfg_ok), .id_ok(id_ok),
        .clear_fifo(c_clear_fifo),
        .m_axis_tdata(m_axis_tdata), .m_axis_tuser(m_axis_tuser),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tlast(m_axis_tlast),
        .m_axis_tready(m_axis_tready),
        .fifo_ovf(fifo_ovf), .fifo_full(fifo_full), .fifo_empty(fifo_empty),
        .fifo_level(fifo_level), .fifo_drops(fifo_drops),
        .fifo_data_low(fifo_data_low)
    );

endmodule
