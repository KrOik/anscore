// Two RGB LUT banks, synchronous read; covered by ISP group regression.
// Reset starts in bypass. Every enabled-bank commit requires all 256 entries
// of each channel to have been loaded, in increasing address order.
module img_isp_gamma_lut (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire [23:0] s_data, input wire s_valid, output wire s_ready,
    input wire s_sof, input wire s_eol,
    output wire [23:0] m_data, output reg m_valid, input wire m_ready,
    output reg m_sof, output reg m_eol,
    input wire cfg_we, input wire [1:0] cfg_channel,
    input wire [7:0] cfg_addr, input wire [7:0] cfg_value,
    input wire cfg_commit, input wire cfg_enable,
    output wire cfg_ready, output reg cfg_pending,
    output reg cfg_error, output wire [2:0] cfg_lut_complete,
    output reg active_enable
);
    // No memory reset: table contents are used only after a complete load.
    (* ram_style="block", syn_ramstyle="block_ram" *) reg [7:0] lut_r [0:511];
    (* ram_style="block", syn_ramstyle="block_ram" *) reg [7:0] lut_g [0:511];
    (* ram_style="block", syn_ramstyle="block_ram" *) reg [7:0] lut_b [0:511];
    // Dedicated synchronous RAM output registers stay separate from bypass
    // data. The output mux is downstream of these registers so the RAM read
    // port remains a registered, enable-qualified simple-dual-port pattern.
    reg [7:0] lut_r_read_q, lut_g_read_q, lut_b_read_q;
    reg [23:0] bypass_data_q;
    reg read_enable_q;
    reg active_bank, shadow_enable;
    reg [8:0] next_r, next_g, next_b;
    wire complete = (next_r == 256) && (next_g == 256) && (next_b == 256);
    wire apply = cfg_pending && s_sof;
    wire read_enable = apply ? shadow_enable : active_enable;
    wire read_bank = (apply && shadow_enable) ? !active_bank : active_bank;
    wire [8:0] write_addr = {!active_bank, cfg_addr};
    wire input_fire = s_valid && s_ready;
    wire lut_read_fire = input_fire && read_enable;
    wire address_r_ok = (next_r < 256) && ({1'b0, cfg_addr} == next_r);
    wire address_g_ok = (next_g < 256) && ({1'b0, cfg_addr} == next_g);
    wire address_b_ok = (next_b < 256) && ({1'b0, cfg_addr} == next_b);
    assign cfg_lut_complete = {next_r == 256, next_g == 256, next_b == 256};
    assign cfg_ready = clk_en && !cfg_pending;
    assign s_ready = clk_en && (!m_valid || m_ready);
    assign m_data = read_enable_q ? {lut_r_read_q,lut_g_read_q,lut_b_read_q} : bypass_data_q;

    // Kept separate from asynchronous-reset control to permit block RAM
    // inference. RAM output registers have no reset. The independent bypass
    // path and selector update on exactly the same real input transfer.
    always @(posedge clk) begin
        if (rst_n && clk_en) begin
            if (cfg_we && cfg_ready) begin
                case (cfg_channel)
                    0: if (address_r_ok) lut_r[write_addr] <= cfg_value;
                    1: if (address_g_ok) lut_g[write_addr] <= cfg_value;
                    2: if (address_b_ok) lut_b[write_addr] <= cfg_value;
                    3: if (address_r_ok && address_g_ok && address_b_ok) begin
                        lut_r[write_addr] <= cfg_value;
                        lut_g[write_addr] <= cfg_value;
                        lut_b[write_addr] <= cfg_value;
                    end
                endcase
            end
            if (lut_read_fire) begin
                lut_r_read_q <= lut_r[{read_bank, s_data[23:16]}];
                lut_g_read_q <= lut_g[{read_bank, s_data[15:8]}];
                lut_b_read_q <= lut_b[{read_bank, s_data[7:0]}];
            end
            if (input_fire) begin
                bypass_data_q <= s_data;
                read_enable_q <= read_enable;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid <= 0; m_sof <= 0; m_eol <= 0;
            cfg_pending <= 0; cfg_error <= 0;
            active_bank <= 0; active_enable <= 0; shadow_enable <= 0;
            next_r <= 0; next_g <= 0; next_b <= 0;
        end else if (clk_en) begin
            if (cfg_we && cfg_ready) begin
                case (cfg_channel)
                    0: if (address_r_ok) next_r <= next_r + 1'b1;
                       else cfg_error <= 1;
                    1: if (address_g_ok) next_g <= next_g + 1'b1;
                       else cfg_error <= 1;
                    2: if (address_b_ok) next_b <= next_b + 1'b1;
                       else cfg_error <= 1;
                    3: if (address_r_ok && address_g_ok && address_b_ok) begin
                        next_r <= next_r + 1'b1;
                        next_g <= next_g + 1'b1;
                        next_b <= next_b + 1'b1;
                    end else cfg_error <= 1;
                endcase
            end
            // Commit must be a separate cycle after the final LUT write.
            if (cfg_commit && cfg_ready) begin
                if ((!cfg_enable || complete) && !cfg_we) begin
                    shadow_enable <= cfg_enable;
                    cfg_pending <= 1;
                end else cfg_error <= 1;
            end
            if (s_ready) begin
                m_valid <= s_valid;
                if (s_valid) begin
                    m_sof <= s_sof; m_eol <= s_eol;
                    if (apply) begin
                        active_enable <= shadow_enable;
                        if (shadow_enable) active_bank <= !active_bank;
                        next_r <= 0; next_g <= 0; next_b <= 0;
                        cfg_pending <= 0;
                    end
                end
            end
        end
    end
endmodule
