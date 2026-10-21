`timescale 1ns / 1ps
// Deterministic quantized input-sequence generator for lstm_temporal_core.
// Same 16-bit Galois LFSR as snn_event_loader, mirrored by model/golden_all.py.
module lstm_input_loader #(
    parameter N_IN   = 4,
    parameter N_T    = 8,
    parameter T_BITS = 4,
    parameter SEED   = 16'h5A5A
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              start,

    output reg               ld_en,
    output reg  [7:0]        ld_addr,
    output reg  signed [7:0] ld_data,
    output reg  [8:0]        ld_count,
    output reg               load_done,
    output reg               busy
);
    localparam LLEN = N_T * N_IN;

    reg [15:0] lfsr;
    reg [1:0]  ph;
    reg [7:0]  cnt;

    wire [15:0] nxt = (lfsr >> 1) ^ (lfsr[0] ? 16'hB400 : 16'h0000);

    localparam G_IDLE = 2'd0, G_RUN = 2'd1, G_FIN = 2'd2, G_WAIT = 2'd3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr <= SEED; ph <= G_IDLE; cnt <= 8'd0; ld_addr <= 8'd0;
            ld_en <= 1'b0; ld_data <= 8'sd0; ld_count <= 9'd0;
            load_done <= 1'b0; busy <= 1'b0;
        end else begin
            ld_en <= 1'b0;
            case (ph)
                G_IDLE: if (start) begin
                    busy      <= 1'b1;
                    load_done <= 1'b0;
                    lfsr      <= SEED;
                    cnt       <= 8'd0;
                    ld_addr   <= 8'd0;
                    ph        <= G_RUN;
                end
                G_RUN: begin
                    lfsr    <= nxt;
                    ld_en   <= 1'b1;
                    ld_addr <= cnt;
                    // keep the stimulus inside the linear region of the network
                    ld_data <= $signed({1'b0, nxt[6:0]}) - 8'sd64;
                    if (cnt == LLEN - 1) begin
                        ph       <= G_FIN;
                        ld_count <= LLEN;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
                G_FIN: begin
                    load_done <= 1'b1;
                    busy      <= 1'b0;
                    ph        <= G_WAIT;
                end
                G_WAIT: if (!start) ph <= G_IDLE;
            endcase
        end
    end
endmodule
