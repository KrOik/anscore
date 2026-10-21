`timescale 1ns/1ps
module tb_sb_invalid_width;
    // Deliberate unsupported non-integer ratio: reject instead of dropping data.
    sb_stream_width_adapter #(.S_WIDTH(24),.M_WIDTH(16)) dut(
        .clk(1'b0),.rst_n(1'b0),.clk_en(1'b0),.s_data(24'b0),.s_keep(3'b0),
        .s_user(1'b0),.s_last(1'b0),.s_valid(1'b0),.s_ready(),
        .m_data(),.m_keep(),.m_user(),.m_last(),.m_valid(),.m_ready(1'b0),.error());
    initial begin #10;$fatal(1,"unsupported parameter was silently accepted");end
endmodule
