// Passive debug fanout. Configuration must be synchronous to clk.
// Every output is registered: one clk edge of observation latency.
module logic_probe8 (
    input wire clk,
    input wire rst_n,
    input wire [2:0] probe_page,
    input wire [7:0] stream_signals,
    input wire [7:0] serial_signals,
    input wire [7:0] motor_signals,
    input wire [7:0] data_signals,
    output reg [7:0] probe
);
    reg [7:0] selected;
    always @* begin
        case (probe_page)
            3'd0: selected = stream_signals;
            3'd1: selected = serial_signals;
            3'd2: selected = motor_signals;
            3'd3: selected = data_signals;
            default: selected = 8'b0;
        endcase
    end
    always @(posedge clk or negedge rst_n)
        if (!rst_n) probe <= 8'b0;
        else probe <= selected;
endmodule
