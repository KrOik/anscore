// SPDX-License-Identifier: Apache-2.0
// Connect synchronized trigger/return pulses; output units are reference clocks.
module trigger_return_intervals(
 input wire clk,rst,arm_valid,output wire arm_ready,
 input wire [31:0] arm_window,input wire [7:0] arm_tag,
 input wire reference_event,observation_event,stop,output wire busy,running,
 output wire m_valid,input wire m_ready,output wire [31:0] m_interval,
 output wire [15:0] m_epoch,output wire [1:0] m_status,output wire [7:0] m_tag,
 output wire done_valid,input wire done_ready,output wire done_error,
 output wire [31:0] done_dropped,output wire done_drop_saturated,
 output wire [7:0] done_tag
);
 event_interval_recorder dut(.*);
endmodule
