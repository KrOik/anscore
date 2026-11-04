// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Selective packet multicast, standard ready/valid (no clock enable).
module stream_multicast #(
    parameter PORTS = 3,
    parameter DATA_WIDTH = 32,
    parameter USER_WIDTH = 1
)(
    input wire clk,
    input wire rst_n,
    input wire [DATA_WIDTH-1:0] s_data,
    input wire [DATA_WIDTH/8-1:0] s_keep,
    input wire [USER_WIDTH-1:0] s_user,
    input wire s_last,
    input wire [PORTS-1:0] s_mask,
    input wire s_valid,
    output wire s_ready,
    output wire [PORTS*DATA_WIDTH-1:0] m_data,
    output wire [PORTS*(DATA_WIDTH/8)-1:0] m_keep,
    output wire [PORTS*USER_WIDTH-1:0] m_user,
    output wire [PORTS-1:0] m_last,
    output wire [PORTS-1:0] m_valid,
    input wire [PORTS-1:0] m_ready
);
    reg [DATA_WIDTH-1:0] data_r;
    reg [DATA_WIDTH/8-1:0] keep_r;
    reg [USER_WIDTH-1:0] user_r;
    reg last_r;
    reg [PORTS-1:0] pending;
    reg in_packet;
    reg [PORTS-1:0] packet_mask;

    wire [PORTS-1:0] remaining = pending & ~m_ready;
    wire [PORTS-1:0] accepted_mask = in_packet ? packet_mask : s_mask;
    // A new beat can replace the stored beat on the edge that drains its
    // final copies. Each destination's consumed bit stays cleared meanwhile.
    assign s_ready = rst_n && !(|remaining);
    assign m_valid = pending;
    assign m_data = {PORTS{data_r}};
    assign m_keep = {PORTS{keep_r}};
    assign m_user = {PORTS{user_r}};
    assign m_last = {PORTS{last_r}};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending <= {PORTS{1'b0}};
            in_packet <= 1'b0;
            packet_mask <= {PORTS{1'b0}};
            data_r <= {DATA_WIDTH{1'b0}};
            keep_r <= {(DATA_WIDTH/8){1'b0}};
            user_r <= {USER_WIDTH{1'b0}};
            last_r <= 1'b0;
        end else begin
            pending <= remaining;
            if (s_valid && s_ready) begin
                data_r <= s_data;
                keep_r <= s_keep;
                user_r <= s_user;
                last_r <= s_last;
                pending <= accepted_mask;
                if (!in_packet)
                    packet_mask <= s_mask;
                in_packet <= !s_last;
            end
        end
    end

    // Elaboration guards only; no simulation task is in the datapath.
    initial begin
        if (PORTS < 1 || DATA_WIDTH < 8 || DATA_WIDTH % 8 != 0 || USER_WIDTH < 1)
            $fatal(1, "stream_multicast: invalid parameters");
    end
endmodule
