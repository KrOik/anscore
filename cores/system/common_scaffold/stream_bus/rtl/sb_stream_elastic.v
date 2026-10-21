// functional_minimal: one-entry native stream elastic register.
// Transfer = clk_en && valid && ready; adjacent endpoints share clk_en.
module sb_stream_elastic #(
    parameter DATA_WIDTH = 32, parameter USER_WIDTH = 1,
    parameter KEEP_WIDTH = DATA_WIDTH / 8
)(
    input wire clk, rst_n, clk_en,
    input wire [DATA_WIDTH-1:0] s_data,
    input wire [KEEP_WIDTH-1:0] s_keep,
    input wire [USER_WIDTH-1:0] s_user,
    input wire s_last, s_valid, output wire s_ready,
    output reg [DATA_WIDTH-1:0] m_data,
    output reg [KEEP_WIDTH-1:0] m_keep,
    output reg [USER_WIDTH-1:0] m_user,
    output reg m_last, m_valid, input wire m_ready
);
    assign s_ready = rst_n && clk_en && (!m_valid || m_ready);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_data <= 0; m_keep <= 0; m_user <= 0; m_last <= 0; m_valid <= 0;
        end else if (clk_en && s_ready) begin
            m_valid <= s_valid;
            if (s_valid) begin
                m_data <= s_data; m_keep <= s_keep;
                m_user <= s_user; m_last <= s_last;
            end
        end
    end
    initial if (DATA_WIDTH < 8 || DATA_WIDTH % 8 || KEEP_WIDTH != DATA_WIDTH/8 || USER_WIDTH < 1)
        $fatal(1, "sb_stream_elastic: byte-aligned widths and USER_WIDTH>=1 required");
endmodule
