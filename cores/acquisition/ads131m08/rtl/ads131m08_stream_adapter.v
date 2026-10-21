// ADS131M08 sample FIFO and AXI4-Stream adapter.
//
// A scheduler sample event is converted into one FIFO beat and held in a
// registered output slot until the AXI sink accepts it. FIFO memory is
// synchronous and validity is defined by the read/write pointers.
`timescale 1ns/1ps

module ads131m08_stream_adapter #(
    parameter integer ADC_COUNT = 1,
    parameter integer FIFO_DEPTH = 512
) (
    input wire clk,
    input wire rst_n,
    input wire [ADC_COUNT-1:0] sample_valid,
    input wire [3:0] sample_dev,
    input wire [15:0] status_word,
    input wire [191:0] ch_data,
    input wire [ADC_COUNT-1:0] dev_timeout,
    input wire [ADC_COUNT-1:0] cfg_ok,
    input wire [ADC_COUNT-1:0] id_ok,
    input wire clear_fifo,

    output wire [255:0] m_axis_tdata,
    output wire [15:0] m_axis_tuser,
    output wire m_axis_tvalid,
    output wire m_axis_tlast,
    input wire m_axis_tready,

    output wire fifo_ovf,
    output wire fifo_full,
    output wire fifo_empty,
    output wire [15:0] fifo_level,
    output wire [31:0] fifo_drops,
    output wire [31:0] fifo_data_low
);
    localparam integer FIFO_W = 272;

    reg [7:0] frame_seq;
    wire [255:0] beat_tdata = {44'b0, sample_dev, status_word, ch_data};
    wire [15:0] beat_tuser = {dev_timeout[sample_dev], cfg_ok[sample_dev],
                               id_ok[sample_dev], 1'b0, sample_dev, frame_seq};
    wire [FIFO_W-1:0] fifo_wdata = {beat_tuser, beat_tdata};
    wire [FIFO_W-1:0] fifo_rdata;
    reg fifo_rd;
    reg out_valid;
    reg [FIFO_W-1:0] out_data;
    wire fifo_wr = (sample_valid != {ADC_COUNT{1'b0}});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_seq <= 8'd0;
        end else if (sample_valid != {ADC_COUNT{1'b0}}) begin
            frame_seq <= frame_seq + 8'd1;
        end
    end

    ads131m08_sample_fifo #(
        .WIDTH(FIFO_W),
        .DEPTH(FIFO_DEPTH)
    ) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_en(fifo_wr), .wr_data(fifo_wdata),
        .rd_en(fifo_rd), .rd_data(fifo_rdata),
        .full(fifo_full), .empty(fifo_empty), .level(fifo_level),
        .drop_count(fifo_drops), .overflow(fifo_ovf), .clear(clear_fifo)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_rd <= 1'b0;
            out_valid <= 1'b0;
            out_data <= {FIFO_W{1'b0}};
        end else begin
            fifo_rd <= 1'b0;
            if (fifo_rd) begin
                out_data <= fifo_rdata;
                out_valid <= 1'b1;
            end else if (out_valid && m_axis_tready) begin
                out_valid <= 1'b0;
            end
            if (!fifo_empty && !fifo_rd && (!out_valid || m_axis_tready))
                fifo_rd <= 1'b1;
        end
    end

    assign m_axis_tdata = out_data[255:0];
    assign m_axis_tuser = out_data[271:256];
    assign m_axis_tvalid = out_valid;
    assign m_axis_tlast = out_valid;
    assign fifo_data_low = out_data[31:0];
endmodule
