`timescale 1ns / 1ps
// Deterministic spike-event queue generator for snn_sparse_conv_core.
// 16-bit Galois LFSR (mask 0xB400) mirrored bit-for-bit by model/golden_all.py,
// so the board runs exactly the stimulus that was checked in simulation.
module snn_event_loader #(
    parameter IMG_W     = 8,
    parameter IMG_H     = 8,
    parameter CIN       = 2,
    parameter N_STEPS   = 8,
    parameter STEP_BITS = 4,
    parameter EV_MASK   = 7,        // events per step = 1 + (draw & EV_MASK)
    parameter IDX_MASK  = 127,      // input neuron index mask (NIN-1)
    parameter SEED      = 16'hACE1
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   start,

    output reg                    ld_en,
    output reg  [7:0]             ld_addr,
    output reg  [STEP_BITS+15:0]  ld_data,
    output reg  [8:0]             ld_count,
    output reg                    load_done,
    output reg                    busy
);
    localparam L_IDLE = 2'd0, L_STEP = 2'd1, L_IDX = 2'd2, L_VAL = 2'd3;

    reg [15:0]          lfsr;
    reg [2:0]           ph;
    reg [STEP_BITS-1:0] step;
    reg [3:0]           per, j;
    reg [7:0]           idx_lat;
    reg [7:0]           cnt;      // write index; ld_addr follows it by one cycle

    wire [15:0] nxt = (lfsr >> 1) ^ (lfsr[0] ? 16'hB400 : 16'h0000);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph <= L_IDLE; lfsr <= SEED; step <= {STEP_BITS{1'b0}};
            per <= 4'd0; j <= 4'd0; idx_lat <= 8'd0;
            ld_addr <= 8'd0; ld_count <= 9'd0; load_done <= 1'b0;
            busy <= 1'b0; ld_en <= 1'b0; ld_data <= {(STEP_BITS+16){1'b0}};
            cnt <= 8'd0;
        end else begin
            ld_en <= 1'b0;
            case (ph)
                L_IDLE: if (start) begin
                    busy      <= 1'b1;
                    load_done <= 1'b0;
                    lfsr      <= SEED;
                    step      <= {STEP_BITS{1'b0}};
                    ld_addr   <= 8'd0;
                    ph        <= L_STEP;
                end
                L_STEP: begin
                    lfsr <= nxt;
                    per  <= 4'd1 + (nxt[3:0] & EV_MASK[3:0]);
                    j    <= 4'd0;
                    ph   <= L_IDX;
                end
                L_IDX: begin
                    lfsr     <= nxt;
                    idx_lat  <= nxt[7:0] & IDX_MASK[7:0];
                    ph       <= L_VAL;
                end
                L_VAL: begin
                    lfsr     <= nxt;
                    // registered write strobe: addr/data/enable all come from
                    // the same cycle, so the queue slot is cnt (not cnt+1)
                    ld_en    <= 1'b1;
                    ld_addr  <= cnt;
                    ld_data  <= {step, idx_lat, (nxt[3:0] == 4'd0) ? 8'hFF : 8'h01};
                    cnt      <= cnt + 1'b1;
                    if (j + 1'b1 >= per) begin
                        j <= 4'd0;
                        if (step == N_STEPS - 1) begin
                            ld_count  <= cnt + 8'd1;
                            load_done <= 1'b1;
                            busy      <= 1'b0;
                            ph        <= L_IDLE;
                        end else begin
                            step <= step + 1'b1;
                            ph   <= L_STEP;
                        end
                    end else begin
                        j  <= j + 1'b1;
                        ph <= L_IDX;
                    end
                end
                default: ph <= L_IDLE;
            endcase
        end
    end
endmodule
