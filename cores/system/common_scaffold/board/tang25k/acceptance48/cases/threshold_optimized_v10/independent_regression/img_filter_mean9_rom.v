// Candidate-only exact unsigned /9 lookup. This registered ROM REPLACES
// the third elastic mean stage; it does not add a fourth stage.
// Reachable rounded GRAY8 sums are 4..2299. All 4096 addresses are defined
// as (index / 9) modulo 256, matching truncation at the original 8-bit port.
module img_filter_mean9_rom (
    input wire clk, rst_n, clk_en,
    input wire [11:0] s_index,
    input wire s_valid, s_sof, s_eol,
    output wire s_ready,
    output reg [7:0] m_data,
    output reg m_valid, m_sof, m_eol,
    input wire m_ready
);
    (* rom_style="block", ram_style="block", syn_romstyle="block_rom" *)
    reg [7:0] quotient_rom [0:4095];
    integer i;
    initial begin
        for (i=0; i<4096; i=i+1)
            quotient_rom[i] = (i / 9) & 255;
    end
    wire slot_ready = !m_valid || m_ready;
    assign s_ready = rst_n && clk_en && slot_ready;

    // No reset on the ROM or its read register: infer synchronous BSRAM.
    // Invalid output data after reset is unspecified; valid and markers reset.
    always @(posedge clk) begin
        if (rst_n && clk_en && slot_ready && s_valid)
            m_data <= quotient_rom[s_index];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid <= 1'b0;
            m_sof <= 1'b0;
            m_eol <= 1'b0;
        end else if (clk_en && slot_ready) begin
            m_valid <= s_valid;
            if (s_valid) begin
                m_sof <= s_sof;
                m_eol <= s_eol;
            end
        end
    end
endmodule
