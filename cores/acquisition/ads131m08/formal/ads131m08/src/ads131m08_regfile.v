// ADS131M08 register, control and sticky-status block.
//
// This module owns the AXI-to-register state that used to live in the top
// level.  Scheduler status is sampled here for the per-device snapshots;
// sample storage and AXI-Stream buffering are deliberately kept in the
// separate stream adapter.
`timescale 1ns/1ps

module ads131m08_regfile #(
    parameter integer ADC_COUNT = 1,
    parameter integer SCHED_DEFAULT = 0,
    parameter integer OSR_SEL = 2,
    parameter integer PWR_SEL = 2,
    parameter integer EXPECT_ID_DEFAULT = 16'h0801,
    parameter integer ADDR_W = 12
) (
    input wire clk,
    input wire rst_n,

    input wire [ADDR_W-1:0] wr_addr,
    input wire [31:0] wr_data,
    input wire [3:0] wr_strb,
    input wire wr_en,
    input wire [ADDR_W-1:0] rd_addr,
    input wire rd_en,
    output wire [31:0] rd_data,

    output wire cfg_enable,
    output wire cfg_sched_mode,
    output wire [15:0] cfg_dev_mask,
    output wire [31:0] cfg_irq_en,
    output wire [2:0] cfg_osr,
    output wire [1:0] cfg_pwr,
    output wire [15:0] cfg_expect_id,
    output wire [15:0] cfg_gain1,
    output wire [15:0] cfg_gain2,
    output wire [15:0] cfg_mode,
    output wire [ADC_COUNT-1:0] dev_ctrl_en,
    output wire [ADC_COUNT-1:0] dev_ctrl_rst,
    output wire c_start_init,
    output wire c_clear_fifo,
    output wire c_resync,

    input wire [ADC_COUNT-1:0] init_done,
    input wire [ADC_COUNT-1:0] id_ok,
    input wire [ADC_COUNT-1:0] cfg_ok,
    input wire [ADC_COUNT-1:0] drdy_seen,
    input wire [ADC_COUNT-1:0] dev_timeout,
    input wire [16*ADC_COUNT-1:0] dev_id_v,
    input wire [3:0] sample_dev,
    input wire [15:0] status_word,
    input wire [191:0] ch_data,
    input wire [ADC_COUNT-1:0] sample_valid,
    input wire [ADC_COUNT-1:0] adc_drdy_n,
    input wire spi_busy,
    input wire all_init_done,

    input wire fifo_ovf,
    input wire fifo_full,
    input wire fifo_empty,
    input wire [15:0] fifo_level,
    input wire [31:0] fifo_drops,
    input wire [31:0] fifo_data_low,

    output wire irq
);
    // AXI WSTRB and rd_en are part of the plain register-bus contract. WSTRB
    // remains intentionally ignored for compatibility (H-005); rd_en is a
    // timing marker and does not add read side effects.
    wire unused_wr_strb = ^wr_strb;
    wire unused_rd_en = rd_en;

    wire [9:0] widx = wr_addr[11:2];
    wire [9:0] ridx = rd_addr[11:2];
    wire is_devctrl_w = (widx >= 10'h008) && (widx <= 10'h017);
    wire is_devctrl_r = (ridx >= 10'h008) && (ridx <= 10'h017);
    wire is_status = (ridx >= 10'h018) && (ridx <= 10'h027);
    wire is_devid = (ridx >= 10'h040) && (ridx <= 10'h04F);
    wire is_devsmp = (ridx >= 10'h050) && (ridx <= 10'h05F);
    wire wr_mapped = (widx <= 10'h007) || is_devctrl_w ||
                     (widx >= 10'h060 && widx <= 10'h062);

    wire wr_ctrl = wr_en && (widx == 10'h000);
    wire wr_sched = wr_en && (widx == 10'h002);
    wire wr_irqen = wr_en && (widx == 10'h004);
    wire wr_irqcl = wr_en && (widx == 10'h005);
    wire wr_cfg0 = wr_en && (widx == 10'h006);
    wire wr_cfg1 = wr_en && (widx == 10'h007);
    wire wr_gain1 = wr_en && (widx == 10'h060);
    wire wr_gain2 = wr_en && (widx == 10'h061);
    wire wr_devmode = wr_en && (widx == 10'h062);

    wire c_soft_reset = wr_ctrl && wr_data[0];
    assign c_start_init = wr_ctrl && wr_data[1];
    wire c_clear_errors = wr_ctrl && wr_data[3];
    assign c_clear_fifo = wr_ctrl && wr_data[4];
    assign c_resync = wr_ctrl && wr_data[5];

    reg cfg_enable_r;
    reg cfg_sched_mode_r;
    reg [15:0] cfg_dev_mask_r;
    reg [31:0] cfg_irq_en_r;
    reg [31:0] irq_status;
    reg [2:0] cfg_osr_r;
    reg [1:0] cfg_pwr_r;
    reg [15:0] cfg_expect_id_r;
    reg [15:0] cfg_gain1_r, cfg_gain2_r, cfg_mode_r;
    reg [ADC_COUNT-1:0] dev_ctrl_en_r;
    reg [ADC_COUNT-1:0] dev_ctrl_rst_r;
    reg [31:0] dev_samples [0:15];
    reg [16*ADC_COUNT-1:0] dev_last_status;
    reg bad_addr_sticky;
    integer dq;
    integer mq;

    wire [15:0] dev_err = dev_timeout | ~id_ok | ~cfg_ok;
    wire [31:0] err_now = {13'b0, bad_addr_sticky, (|dev_timeout), fifo_ovf,
                           dev_err};

    assign cfg_enable = cfg_enable_r;
    assign cfg_sched_mode = cfg_sched_mode_r;
    assign cfg_dev_mask = cfg_dev_mask_r;
    assign cfg_irq_en = cfg_irq_en_r;
    assign cfg_osr = cfg_osr_r;
    assign cfg_pwr = cfg_pwr_r;
    assign cfg_expect_id = cfg_expect_id_r;
    assign cfg_gain1 = cfg_gain1_r;
    assign cfg_gain2 = cfg_gain2_r;
    assign cfg_mode = cfg_mode_r;
    assign dev_ctrl_en = dev_ctrl_en_r;
    assign dev_ctrl_rst = dev_ctrl_rst_r;
    assign irq = |(irq_status & cfg_irq_en_r);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_enable_r <= 1'b0;
            cfg_sched_mode_r <= SCHED_DEFAULT[0];
            cfg_dev_mask_r <= 16'hFFFF;
            cfg_irq_en_r <= 32'd0;
            irq_status <= 32'd0;
            cfg_osr_r <= OSR_SEL[2:0];
            cfg_pwr_r <= PWR_SEL[1:0];
            cfg_expect_id_r <= EXPECT_ID_DEFAULT[15:0];
            cfg_gain1_r <= 16'h0000;
            cfg_gain2_r <= 16'h0000;
            cfg_mode_r <= 16'h0100;
            dev_ctrl_en_r <= {ADC_COUNT{1'b1}};
            dev_ctrl_rst_r <= {ADC_COUNT{1'b0}};
            dev_last_status <= {(16*ADC_COUNT){1'b0}};
            bad_addr_sticky <= 1'b0;
            for (dq = 0; dq < 16; dq = dq + 1) dev_samples[dq] <= 32'd0;
        end else begin
            dev_ctrl_rst_r <= {ADC_COUNT{1'b0}};

            if (c_soft_reset) begin
                cfg_enable_r <= 1'b0;
                bad_addr_sticky <= 1'b0;
                irq_status <= 32'd0;
                for (dq = 0; dq < 16; dq = dq + 1) dev_samples[dq] <= 32'd0;
            end else begin
                if (wr_ctrl) cfg_enable_r <= wr_data[2];
                if (wr_sched) begin
                    cfg_sched_mode_r <= wr_data[0];
                    cfg_dev_mask_r <= wr_data[31:16];
                end
                if (wr_irqen) cfg_irq_en_r <= wr_data;
                if (wr_cfg0) begin
                    cfg_osr_r <= wr_data[2:0];
                    cfg_pwr_r <= wr_data[4:3];
                end
                if (wr_cfg1) cfg_expect_id_r <= wr_data[15:0];
                if (wr_gain1) cfg_gain1_r <= wr_data[15:0];
                if (wr_gain2) cfg_gain2_r <= wr_data[15:0];
                if (wr_devmode) cfg_mode_r <= wr_data[15:0];

                if (is_devctrl_w) begin
                    mq = widx - 10'h008;
                    if (mq < ADC_COUNT) begin
                        dev_ctrl_en_r[mq] <= wr_data[0];
                        dev_ctrl_rst_r[mq] <= wr_data[1];
                    end
                end

                // A clear command wins over a simultaneous sticky set.
                irq_status <= irq_status | (err_now & cfg_irq_en_r);
                bad_addr_sticky <= bad_addr_sticky | (wr_en & ~wr_mapped);
                if (c_clear_errors) begin
                    irq_status <= 32'd0;
                    bad_addr_sticky <= 1'b0;
                end
                if (wr_irqcl) begin
                    irq_status <= (irq_status | (err_now & cfg_irq_en_r)) & ~wr_data;
                    if (wr_data[18]) bad_addr_sticky <= 1'b0;
                end

                if (sample_valid != {ADC_COUNT{1'b0}}) begin
                    dev_samples[sample_dev] <= dev_samples[sample_dev] + 32'd1;
                    dev_last_status[16*sample_dev +: 16] <= status_word;
                end
            end
        end
    end

    reg [31:0] rd_mux;
    integer mr;
    always @(*) begin
        rd_mux = 32'hDEADBEEF;
        if (ridx == 10'h000)
            rd_mux = {29'b0, cfg_enable_r, 2'b00};
        else if (ridx == 10'h001)
            rd_mux = {20'b0, sample_dev, (cfg_ok == {ADC_COUNT{1'b1}}),
                      (id_ok == {ADC_COUNT{1'b1}}), all_init_done, spi_busy,
                      ADC_COUNT[3:0]};
        else if (ridx == 10'h002)
            rd_mux = {cfg_dev_mask_r, 15'b0, cfg_sched_mode_r};
        else if (ridx == 10'h003) rd_mux = err_now;
        else if (ridx == 10'h004) rd_mux = cfg_irq_en_r;
        else if (ridx == 10'h005) rd_mux = irq_status;
        else if (ridx == 10'h006) rd_mux = {27'b0, cfg_pwr_r, cfg_osr_r};
        else if (ridx == 10'h007) rd_mux = {16'b0, cfg_expect_id_r};
        else if (is_devctrl_r) begin
            mr = ridx - 10'h008;
            if (mr < ADC_COUNT) rd_mux = {31'b0, dev_ctrl_en_r[mr]};
        end
        else if (is_status) begin
            mr = ridx - 10'h018;
            if (mr < ADC_COUNT)
                rd_mux = {dev_last_status[16*mr +: 16], 10'b0,
                          ~adc_drdy_n[mr], dev_timeout[mr],
                          drdy_seen[mr], cfg_ok[mr], id_ok[mr], init_done[mr]};
        end
        else if (is_devid) begin
            mr = ridx - 10'h040;
            if (mr < ADC_COUNT) rd_mux = {16'b0, dev_id_v[16*mr +: 16]};
        end
        else if (is_devsmp) begin
            mr = ridx - 10'h050;
            if (mr < ADC_COUNT) rd_mux = dev_samples[mr];
        end
        else if (ridx == 10'h060) rd_mux = {16'b0, cfg_gain1_r};
        else if (ridx == 10'h061) rd_mux = {16'b0, cfg_gain2_r};
        else if (ridx == 10'h062) rd_mux = {16'b0, cfg_mode_r};
        else if (ridx == 10'h080) rd_mux = fifo_data_low;
        else if (ridx == 10'h081) rd_mux = {14'b0, fifo_empty, fifo_full, fifo_level};
        else if (ridx == 10'h082) rd_mux = fifo_drops;
    end

    assign rd_data = rd_mux;

    // Keep lint from treating these compatibility inputs as accidental state.
    wire unused_bus_activity = unused_wr_strb ^ unused_rd_en;
endmodule
