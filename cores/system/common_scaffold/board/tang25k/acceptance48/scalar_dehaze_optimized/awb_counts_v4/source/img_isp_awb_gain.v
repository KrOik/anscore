// RGB888 unsigned Q8.8 gain application, v65 three-stage elastic pipeline.
// Stage 0 captures the accepted pixel and its SOF-selected gain; stage 1
// registers unsigned 8x16 products; stage 2 rounds, saturates and registers
// the output. Each stage holds under downstream backpressure or !clk_en.
// Configuration still commits only on the accepted input SOF, independent
// of the extra output latency. Both endpoints use clk_en for transfers.
module img_isp_awb_gain (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire [23:0] s_data, input wire s_valid, output wire s_ready,
    input wire s_sof, input wire s_eol,
    output reg [23:0] m_data, output reg m_valid, input wire m_ready,
    output reg m_sof, output reg m_eol,
    input wire cfg_we, input wire cfg_commit,
    input wire [15:0] cfg_gain_r, cfg_gain_g, cfg_gain_b,
    output wire cfg_ready, output reg cfg_pending
);
    reg [15:0] shadow_r,shadow_g,shadow_b;
    reg [15:0] active_r,active_g,active_b;
    wire apply=cfg_pending && s_sof;
    wire [15:0] gain_r=apply ? shadow_r : active_r;
    wire [15:0] gain_g=apply ? shadow_g : active_g;
    wire [15:0] gain_b=apply ? shadow_b : active_b;
    reg selected_valid,selected_sof,selected_eol;
    reg [23:0] selected_pixel;
    reg [15:0] selected_r,selected_g,selected_b;
    reg product_valid,product_sof,product_eol;
    reg [23:0] product_r,product_g,product_b;
    wire output_slot_ready=!m_valid || m_ready;
    wire product_slot_ready=!product_valid || output_slot_ready;
    wire selected_slot_ready=!selected_valid || product_slot_ready;
    assign s_ready=clk_en && selected_slot_ready;
    assign cfg_ready=clk_en && !cfg_pending;
    function [7:0] finish_gain;
        input [23:0] product;
        reg [24:0] scaled;
        begin
            // Unsigned product is exact in 24 bits (255*65535 < 2^24).
            // Keep the original 25-bit +128, right shift and clamp.
            scaled=({1'b0,product}+25'd128)>>8;
            finish_gain=(scaled>255) ? 8'hff : scaled[7:0];
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            m_data<=0;m_valid<=0;m_sof<=0;m_eol<=0;
            shadow_r<=256;shadow_g<=256;shadow_b<=256;
            active_r<=256;active_g<=256;active_b<=256;cfg_pending<=0;
            selected_valid<=0;selected_sof<=0;selected_eol<=0;selected_pixel<=0;
            selected_r<=256;selected_g<=256;selected_b<=256;
            product_valid<=0;product_sof<=0;product_eol<=0;
            product_r<=0;product_g<=0;product_b<=0;
        end else if(clk_en) begin
            if(cfg_we && cfg_ready) begin
                shadow_r<=cfg_gain_r;shadow_g<=cfg_gain_g;shadow_b<=cfg_gain_b;
            end
            if(cfg_commit && cfg_ready) cfg_pending<=1;
            if(selected_slot_ready) begin
                selected_valid<=s_valid;
                if(s_valid) begin
                    selected_pixel<=s_data;
                    selected_r<=gain_r;selected_g<=gain_g;selected_b<=gain_b;
                    selected_sof<=s_sof;selected_eol<=s_eol;
                    if(apply) begin
                        active_r<=shadow_r;active_g<=shadow_g;active_b<=shadow_b;
                        cfg_pending<=0;
                    end
                end
            end
            if(product_slot_ready) begin
                product_valid<=selected_valid;
                if(selected_valid) begin
                    product_r<=selected_pixel[23:16]*selected_r;
                    product_g<=selected_pixel[15:8]*selected_g;
                    product_b<=selected_pixel[7:0]*selected_b;
                    product_sof<=selected_sof;product_eol<=selected_eol;
                end
            end
            if(output_slot_ready) begin
                m_valid<=product_valid;
                if(product_valid) begin
                    m_data<={finish_gain(product_r),finish_gain(product_g),finish_gain(product_b)};
                    m_sof<=product_sof;m_eol<=product_eol;
                end
            end
        end
    end
endmodule
