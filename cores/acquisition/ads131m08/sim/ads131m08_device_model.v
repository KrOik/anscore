// Behavioural ADS131M08 model, one instance per device.
//
// Instantiate N of these on a shared SCLK/DIN bus with individual CS lines and
// combine their DOUT with a wired-or of ``dout`` gated by ``dout_oe``.  Because
// ``dout_oe`` is exposed, a testbench can assert the tri-state discipline the
// real parts rely on: only the part with CS low may drive the shared MISO.
//
// Register semantics follow TI SBAS950B: 24-bit words, commands and register
// values 16-bit MSB aligned in a word, WREG/RREG opcodes, and a 9-word
// conversion frame (STATUS + CH0..CH7).
`timescale 1ns/1ps

module ads131m08_device_model #(
    parameter integer DEV_INDEX   = 0,
    parameter integer ID_VALUE    = 16'h0801,
    // Clocks between conversions.  DRDY goes low when a conversion lands and
    // returns high once the conversion data have been shifted out.
    parameter integer DRDY_PERIOD = 800,
    // 1: every channel always returns the same code, so two drivers fed by two
    //    identical models can be compared bit for bit regardless of timing.
    parameter integer STATIC_DATA = 0
) (
    input  wire clk,
    input  wire rst_n,

    input  wire sclk,
    input  wire din,
    input  wire cs_n,
    input  wire sync_n,

    output reg  dout,
    output reg  dout_oe,     // 1 while this part owns the shared MISO
    output reg  drdy_n,

    // ------------------------------------------------------------ observability
    output reg [15:0] reg_clock,
    output reg [15:0] reg_gain1,
    output reg [15:0] reg_gain2,
    output reg [15:0] reg_mode,
    output reg [15:0] reg_id,
    output reg [31:0] n_data_frames,
    output reg [31:0] n_wreg_frames,
    output reg [31:0] n_rreg_frames,
    output reg [15:0] last_wreg_addr,
    output reg [15:0] last_wreg_val,
    output reg        reset_seen
);
    reg [15:0] regs [0:63];

    reg [23:0] rx_word;
    reg [4:0]  bitn;
    reg [4:0]  wordn;
    reg        rreg_on;
    reg        wreg_on;
    reg [15:0] rreg_val;
    reg [5:0]  wreg_addr;
    reg [4:0]  dout_bit;

    reg [16:0] conv_cnt;
    reg [31:0] drdy_cnt;
    reg        data_pending;
    reg        read_evt;

    integer i;

    wire [23:0] full_word = {rx_word[23:1], din};

    // Channel k of a conversion frame.  Bits [23:20] carry the device index and
    // [19:17] the channel index, so a testbench can prove that a sample was
    // routed to the right device without trusting timing.
    function [23:0] ch_code;
        input integer ch;
        input [16:0] stamp;
        begin
            if (STATIC_DATA)
                ch_code = {DEV_INDEX[3:0], ch[2:0], 17'h01234};
            else
                ch_code = {DEV_INDEX[3:0], ch[2:0], stamp};
        end
    endfunction

    wire [23:0] word_sel =
        (rreg_on && wordn == 5'd1) ? {rreg_val, 8'h00} :
        (wordn >= 5'd1 && wordn <= 5'd8) ? ch_code(wordn - 5'd1, conv_cnt) :
        24'h000000;

    // ------------------------------------------------------------------ resets
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 64; i = i + 1) regs[i] <= 16'h0000;
            regs[6'h00] <= ID_VALUE;
            regs[6'h02] <= 16'h0510;
            regs[6'h03] <= 16'hFF0E;
            regs[6'h04] <= 16'h0000;
            regs[6'h05] <= 16'h0000;
        end else if (!sync_n) begin
            // /SYNC held low for >= 2048 CLKIN is a full device reset.
            for (i = 0; i < 64; i = i + 1) regs[i] <= 16'h0000;
            regs[6'h00] <= ID_VALUE;
            regs[6'h02] <= 16'h0510;
            regs[6'h03] <= 16'hFF0E;
            regs[6'h04] <= 16'h0000;
            regs[6'h05] <= 16'h0000;
        end
    end

    // ------------------------------------------------------------- DRDY timing
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            conv_cnt     <= 17'd0;
            drdy_cnt     <= 32'd0;
            data_pending <= 1'b0;
            read_evt     <= 1'b0;
            drdy_n       <= 1'b1;
        end else if (!sync_n) begin
            conv_cnt     <= 17'd0;
            drdy_cnt     <= 32'd0;
            data_pending <= 1'b0;
            read_evt     <= 1'b0;
            drdy_n       <= 1'b1;
        end else begin
            if (drdy_cnt == DRDY_PERIOD[31:0]) begin
                drdy_cnt     <= 32'd0;
                conv_cnt     <= conv_cnt + 17'd1;
                data_pending <= 1'b1;
            end else begin
                drdy_cnt <= drdy_cnt + 32'd1;
            end
            // A completed conversion read wins over an expiry in the same
            // cycle, and the whole flag lives in the clk domain so there is no
            // race with the SCLK-edge decode logic.
            if (read_evt) data_pending <= 1'b0;
            read_evt <= 1'b0;
            drdy_n   <= ~data_pending;
        end
    end

    // ------------------------------------------------------------------- shift
    // Slave launches data on the rising edge; the host samples on the falling.
    always @(posedge sclk) begin
        if (!cs_n) begin
            dout    <= word_sel[23 - dout_bit];
            dout_oe <= 1'b1;
            if (dout_bit == 5'd23) dout_bit <= 5'd0;
            else                   dout_bit <= dout_bit + 5'd1;
        end
    end

    always @(negedge sclk) begin
        if (!cs_n) begin
            rx_word[23 - bitn] <= din;
            if (bitn == 5'd23) begin
                bitn <= 5'd0;
                if (wordn == 5'd0) begin
                    case (full_word[23:21])
                        3'b101: begin // RREG
                            rreg_on  <= 1'b1;
                            wreg_on  <= 1'b0;
                            rreg_val <= regs[full_word[20:15]];
                            n_rreg_frames <= n_rreg_frames + 32'd1;
                        end
                        3'b011: begin // WREG
                            rreg_on       <= 1'b0;
                            wreg_on       <= 1'b1;
                            wreg_addr     <= full_word[20:15];
                            last_wreg_addr <= {10'b0, full_word[20:15]};
                            n_wreg_frames <= n_wreg_frames + 32'd1;
                        end
                        default: begin // NULL -> conversion data frame
                            rreg_on       <= 1'b0;
                            wreg_on       <= 1'b0;
                            n_data_frames <= n_data_frames + 32'd1;
                            read_evt      <= 1'b1; // DRDY returns high, applied on clk
                        end
                    endcase
                end else if (wordn == 5'd1 && wreg_on) begin
                    regs[wreg_addr] <= full_word[23:8];
                    last_wreg_val  <= full_word[23:8];
                end
                wordn <= wordn + 5'd1;
            end else begin
                bitn <= bitn + 5'd1;
            end
        end
    end

    always @(negedge cs_n) begin
        wordn    <= 5'd0;
        bitn     <= 5'd0;
        dout_bit <= 5'd0;
        rreg_on  <= 1'b0;
        wreg_on  <= 1'b0;
        dout_oe  <= 1'b0;
    end

    always @(posedge cs_n) dout_oe <= 1'b0;

    // ------------------------------------------------------------- reg mirrors
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_clock <= 16'hFF0E;
            reg_gain1 <= 16'h0000;
            reg_gain2 <= 16'h0000;
            reg_mode  <= 16'h0510;
            reg_id    <= ID_VALUE;
        end else begin
            reg_clock <= regs[6'h03];
            reg_gain1 <= regs[6'h04];
            reg_gain2 <= regs[6'h05];
            reg_mode  <= regs[6'h02];
            reg_id    <= regs[6'h00];
        end
    end

    always @(posedge clk or negedge rst_n)
        if (!rst_n)                   reset_seen <= 1'b0;
        else if (!sync_n)             reset_seen <= 1'b1;

    integer j;
    initial begin
        dout      = 1'b0;
        dout_oe   = 1'b0;
        drdy_n    = 1'b1;
        rx_word   = 24'd0;
        bitn      = 5'd0;
        wordn     = 5'd0;
        rreg_on   = 1'b0;
        wreg_on   = 1'b0;
        rreg_val  = 16'd0;
        wreg_addr = 6'd0;
        dout_bit  = 5'd0;
        conv_cnt  = 17'd0;
        drdy_cnt  = 32'd0;
        data_pending = 1'b0;
        read_evt     = 1'b0;
        n_data_frames = 32'd0;
        n_wreg_frames = 32'd0;
        n_rreg_frames = 32'd0;
        last_wreg_addr = 16'd0;
        last_wreg_val  = 16'd0;
        reset_seen = 1'b0;
        for (j = 0; j < 64; j = j + 1) regs[j] = 16'h0000;
        regs[6'h00] = ID_VALUE;
        regs[6'h02] = 16'h0510;
        regs[6'h03] = 16'hFF0E;
    end

endmodule
