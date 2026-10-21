// Development draft, unverified. Native shared-clock-enable pixel protocol.
// Inputs are consumed atomically; neither stream is consumed without its peer.
module img_mf_pair_join #(
    parameter DATA_WIDTH = 24,
    parameter TAG_WIDTH = 16,
    parameter FRAME_WIDTH = 16,
    parameter CHECK_TAG = 1,
    parameter CHECK_FRAME = 1
) (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire s_valid, output wire s_ready,
    input wire [DATA_WIDTH-1:0] s_data,
    input wire s_sof, input wire s_eol,
    input wire [TAG_WIDTH-1:0] s_tag,
    input wire [FRAME_WIDTH-1:0] s_frameid,
    input wire aux_valid, output wire aux_ready,
    input wire [DATA_WIDTH-1:0] aux_data,
    input wire aux_sof, input wire aux_eol,
    input wire [TAG_WIDTH-1:0] aux_tag,
    input wire [FRAME_WIDTH-1:0] aux_frameid,
    output reg m_valid, input wire m_ready,
    output reg [DATA_WIDTH-1:0] m_data,
    output reg [DATA_WIDTH-1:0] m_aux_data,
    output reg m_sof, output reg m_eol,
    output reg [TAG_WIDTH-1:0] m_tag,
    output reg [FRAME_WIDTH-1:0] m_frameid,
    output reg [7:0] m_error,
    output reg [7:0] error_code
);
    wire room = !m_valid || m_ready;
    wire [7:0] pair_error = {
        5'b00000,
        ((CHECK_TAG != 0) && (s_tag != aux_tag)),
        ((CHECK_FRAME != 0) && (s_frameid != aux_frameid)),
        ((s_sof != aux_sof) || (s_eol != aux_eol))
    };
    assign s_ready = rst_n && clk_en && room && aux_valid;
    assign aux_ready = rst_n && clk_en && room && s_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid <= 1'b0;
            m_data <= {DATA_WIDTH{1'b0}};
            m_aux_data <= {DATA_WIDTH{1'b0}};
            m_sof <= 1'b0;
            m_eol <= 1'b0;
            m_tag <= {TAG_WIDTH{1'b0}};
            m_frameid <= {FRAME_WIDTH{1'b0}};
            m_error <= 8'd0;
            error_code <= 8'd0;
        end else if (clk_en && room) begin
            m_valid <= s_valid && aux_valid;
            if (s_valid && aux_valid) begin
                m_data <= s_data;
                m_aux_data <= aux_data;
                m_sof <= s_sof;
                m_eol <= s_eol;
                m_tag <= s_tag;
                m_frameid <= s_frameid;
                m_error <= pair_error;
                error_code <= error_code | pair_error;
            end
        end
    end
endmodule
