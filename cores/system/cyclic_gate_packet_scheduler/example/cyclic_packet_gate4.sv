// SPDX-License-Identifier: Apache-2.0
// Complete default four-queue launch-controller example.
`default_nettype none
module cyclic_packet_gate4(
    input wire clk,input wire rst_n,
    input wire c_valid,output wire c_ready,input wire [2:0] c_op,
    input wire [31:0] c_queue,c_slot,
    input wire [16-1:0] c_duration,c_cost,
    input wire [4-1:0] c_mask,
    input wire [32-1:0] c_data,input wire [8-1:0] c_tag,
    input wire c_enable,
    output wire r_valid,input wire r_ready,
    output wire [2:0] r_op,output wire [3:0] r_status,
    output wire [31:0] r_queue,r_slot,output wire [8-1:0] r_tag,
    output wire [31:0] r_count,
    output wire [16-1:0] r_head_cost,
    output wire [32-1:0] r_head_data,
    output wire [8-1:0] r_head_tag,
    output wire [31:0] r_active_slot,
    output wire [16-1:0] r_ticks_left,
    output wire r_running,r_busy,
    // Native irrevocable launch pulse, NOT a held ready/valid offer.
    input wire launch_accept,output wire launch,
    output wire [31:0] launch_queue,
    output wire [16-1:0] launch_cost,
    output wire [32-1:0] launch_data,
    output wire [8-1:0] launch_tag,
    output wire [31:0] launch_slot,
    output wire [16-1:0] launch_ticks_left,
    output wire running,
    output wire [31:0] active_slot,
    output wire [16-1:0] ticks_left,service_left,
    output wire [4-1:0] gate_mask,
    output wire [4*((4<2)?1:$clog2(4+1))-1:0] levels
);
    cyclic_gate_packet_scheduler scheduler (.*);
endmodule
`default_nettype wire
