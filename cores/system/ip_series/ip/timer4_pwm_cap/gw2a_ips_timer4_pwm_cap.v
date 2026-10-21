// ---------------------------------------------------------------------------
// gw2a_ips_timer4_pwm_cap : packaged, licensable wrapper for the ips_timer4_pwm_cap core.
// Family ctrl.  Four-channel timer block: period PWM with duty update glitch-free, plus input capture and compare IRQ
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_timer4_pwm_cap (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire [3:0] ch_sel,
    input wire cap_pin,
    input wire [3:0] run_req,
    input wire [3:0] wr_addr,
    input wire wr_stb,
    input wire [7:0] wr_data,
    output wire [3:0] pwm_out,
    output wire [7:0] rd_data,
    output wire [3:0] cap_pend,
    output wire [3:0] ovf_pend,
    output wire [3:0] trans_pend,
    output wire [3:0] run_r,
    output wire [3:0] arm_r,
    output wire cap_busy,
    output wire [3:0] ph_r,
    output wire [3:0] vec_out,
    output wire [1:0] cap_hold,
    output wire [1:0] cur_ch,
    output wire [7:0] tick_count,
    output wire [7:0] cap_count,
    output wire [3:0] cap_max,
    output wire [3:0] cap_min,
    output wire [3:0] last_width,
    output wire [3:0] err_count,
    output wire err_sticky,
    output wire cmp_irq
);

    ips_timer4_pwm_cap u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .ch_sel(ch_sel),
        .cap_pin(cap_pin),
        .run_req(run_req),
        .wr_addr(wr_addr),
        .wr_stb(wr_stb),
        .wr_data(wr_data),
        .pwm_out(pwm_out),
        .rd_data(rd_data),
        .cap_pend(cap_pend),
        .ovf_pend(ovf_pend),
        .trans_pend(trans_pend),
        .run_r(run_r),
        .arm_r(arm_r),
        .cap_busy(cap_busy),
        .ph_r(ph_r),
        .vec_out(vec_out),
        .cap_hold(cap_hold),
        .cur_ch(cur_ch),
        .tick_count(tick_count),
        .cap_count(cap_count),
        .cap_max(cap_max),
        .cap_min(cap_min),
        .last_width(last_width),
        .err_count(err_count),
        .err_sticky(err_sticky),
        .cmp_irq(cmp_irq)
    );

endmodule
