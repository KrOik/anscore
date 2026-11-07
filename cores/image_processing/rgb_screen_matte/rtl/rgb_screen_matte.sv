// SPDX-License-Identifier: Apache-2.0
// Original integer opponent-chroma matte and green/blue excess suppression.
`timescale 1ns/1ps
module rgb_screen_matte #(parameter integer TAG_W=8)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [23:0] s_rgb,s_key,
    input wire [18:0] s_inner2,s_outer2,
    input wire [7:0] s_strength,input wire s_blue,
    input wire [15:0] s_x,s_y,input wire [TAG_W-1:0] s_tag,
    input wire s_sof,s_eol,s_last,input wire [31:0] s_user,
    output wire m_valid,input wire m_ready,
    output wire [31:0] m_rgba,output wire m_error,
    output wire [15:0] m_x,m_y,output wire [TAG_W-1:0] m_tag,
    output wire m_sof,m_eol,m_last,output wire [31:0] m_user,
    output wire pipeline_busy
);
    localparam integer STAGES=15;
    localparam integer META_W=67+TAG_W;
    reg [STAGES-1:0] valid_pipe,error_pipe;
    reg [META_W-1:0] meta_pipe[0:STAGES-1];
    reg [23:0] rgb_pipe[0:12];
    reg [18:0] inner_pipe[0:2],outer_pipe[0:2];
    reg [8:0] du0,dv0;
    reg [7:0] excess0,strength0;
    reg blue0,blue1;
    reg [17:0] su1,sv1;
    reg [15:0] spill_product1;
    reg [18:0] distance2;
    reg [26:0] remainder[0:8];
    reg [18:0] denominator[0:8];
    reg [7:0] quotient[0:8],fixed_alpha[0:8];
    reg ratio_active[0:8];
    reg [7:0] alpha12,alpha13;
    reg [15:0] red_product13,green_product13,blue_product13;
    reg [31:0] rgba14;

    wire advance=!valid_pipe[14] || m_ready;
    assign s_ready=!rst && advance;
    assign m_valid=!rst && valid_pipe[14];
    assign m_rgba=rgba14;
    assign m_error=error_pipe[14];
    assign {m_user,m_x,m_y,m_tag,m_sof,m_eol,m_last}=meta_pipe[14];
    assign pipeline_busy=!rst && (|valid_pipe);

    // Opponent values are signed9 in [-255,255]. Differences are signed10
    // in [-510,510], so their nonnegative magnitudes fit unsigned9 exactly.
    wire signed [8:0] source_u=$signed({1'b0,s_rgb[7:0]})-$signed({1'b0,s_rgb[15:8]});
    wire signed [8:0] source_v=$signed({1'b0,s_rgb[23:16]})-$signed({1'b0,s_rgb[15:8]});
    wire signed [8:0] key_u=$signed({1'b0,s_key[7:0]})-$signed({1'b0,s_key[15:8]});
    wire signed [8:0] key_v=$signed({1'b0,s_key[23:16]})-$signed({1'b0,s_key[15:8]});
    wire signed [9:0] delta_u=$signed({source_u[8],source_u})-$signed({key_u[8],key_u});
    wire signed [9:0] delta_v=$signed({source_v[8],source_v})-$signed({key_v[8],key_v});
    wire [9:0] magnitude_u=delta_u[9] ? $unsigned(-delta_u) : $unsigned(delta_u);
    wire [9:0] magnitude_v=delta_v[9] ? $unsigned(-delta_v) : $unsigned(delta_v);
    wire [7:0] other_max=s_blue ?
        (s_rgb[23:16]>s_rgb[15:8] ? s_rgb[23:16] : s_rgb[15:8]) :
        (s_rgb[23:16]>s_rgb[7:0] ? s_rgb[23:16] : s_rgb[7:0]);
    wire [7:0] screen_channel=s_blue ? s_rgb[7:0] : s_rgb[15:8];

    // Exact nearest-integer product/255. An odd denominator has no half tie.
    // product<=65025; the folded numerator fits17 bits without wrap.
    function automatic [7:0] divide255(input [15:0] product);
        reg [16:0] biased,folded;
        begin
            biased={1'b0,product}+17'd127;
            folded=biased+17'd1+(biased>>8);
            divide255=folded[15:8];
        end
    endfunction
    wire [7:0] correction1=divide255(spill_product1);
    wire [7:0] corrected_blue1=rgb_pipe[1][7:0]-correction1;
    wire [7:0] corrected_green1=rgb_pipe[1][15:8]-correction1;
    wire [18:0] interior_n=distance2-inner_pipe[2];
    wire [18:0] interval_width=outer_pipe[2]-inner_pipe[2];
    wire [26:0] ratio_numerator={interior_n,8'd0}-{8'd0,interior_n};
    wire [27:0] twice_remainder={remainder[8],1'b0};
    wire [27:0] final_denominator={9'd0,denominator[8]};
    wire ratio_round_up=(twice_remainder>final_denominator) ||
        ((twice_remainder==final_denominator) && quotient[8][0]);

    integer k;
    always @(posedge clk) begin
        if(rst) begin
            valid_pipe<=0;
        end else if(advance) begin
            valid_pipe[0]<=s_valid;
            for(k=1;k<STAGES;k=k+1) valid_pipe[k]<=valid_pipe[k-1];
            if(s_valid) begin
                meta_pipe[0]<={s_user,s_x,s_y,s_tag,s_sof,s_eol,s_last};
                error_pipe[0]<=s_outer2<s_inner2;
                rgb_pipe[0]<=s_rgb;
                inner_pipe[0]<=s_inner2;outer_pipe[0]<=s_outer2;
                du0<=magnitude_u[8:0];dv0<=magnitude_v[8:0];
                excess0<=screen_channel>other_max ? screen_channel-other_max : 8'd0;
                strength0<=s_strength;blue0<=s_blue;
            end
            for(k=1;k<STAGES;k=k+1) if(valid_pipe[k-1]) begin
                meta_pipe[k]<=meta_pipe[k-1];
                error_pipe[k]<=error_pipe[k-1];
            end
            if(valid_pipe[0]) begin
                su1<=du0*du0;sv1<=dv0*dv0;
                spill_product1<=excess0*strength0;
                blue1<=blue0;rgb_pipe[1]<=rgb_pipe[0];
                inner_pipe[1]<=inner_pipe[0];outer_pipe[1]<=outer_pipe[0];
            end
            if(valid_pipe[1]) begin
                distance2<={1'b0,su1}+{1'b0,sv1};
                rgb_pipe[2]<=blue1 ? {rgb_pipe[1][23:8],corrected_blue1} :
                    {rgb_pipe[1][23:16],corrected_green1,rgb_pipe[1][7:0]};
                inner_pipe[2]<=inner_pipe[1];outer_pipe[2]<=outer_pipe[1];
            end
            for(k=3;k<=12;k=k+1) if(valid_pipe[k-1]) rgb_pipe[k]<=rgb_pipe[k-1];
            if(valid_pipe[2]) begin
                quotient[0]<=0;remainder[0]<=0;denominator[0]<=1;
                ratio_active[0]<=0;fixed_alpha[0]<=0;
                if(outer_pipe[2]>=inner_pipe[2]) begin
                    if(outer_pipe[2]==inner_pipe[2])
                        fixed_alpha[0]<=distance2>inner_pipe[2] ? 8'd255 : 8'd0;
                    else if(distance2>=outer_pipe[2]) fixed_alpha[0]<=8'd255;
                    else if(distance2>inner_pipe[2]) begin
                        remainder[0]<=ratio_numerator;
                        denominator[0]<=interval_width;
                        ratio_active[0]<=1;
                    end
                end
            end
            if(valid_pipe[11])
                alpha12<=ratio_active[8] ? quotient[8]+{7'd0,ratio_round_up} : fixed_alpha[8];
            if(valid_pipe[12]) begin
                red_product13<=rgb_pipe[12][23:16]*alpha12;
                green_product13<=rgb_pipe[12][15:8]*alpha12;
                blue_product13<=rgb_pipe[12][7:0]*alpha12;
                alpha13<=alpha12;
            end
            if(valid_pipe[13])
                rgba14<=error_pipe[13] ? 32'd0 :
                    {divide255(red_product13),divide255(green_product13),
                     divide255(blue_product13),alpha13};
        end
    end

    // The interior numerator is <255*denominator. Eight fixed quotient bits
    // therefore suffice. These are eight physical pipeline subtract/compare
    // stages, not a shared iterative divider or a claim of free division.
    genvar g;
    generate for(g=0;g<8;g=g+1) begin: ratio_bits
        localparam integer BIT_INDEX=7-g;
        wire [26:0] trial={8'd0,denominator[g]}<<BIT_INDEX;
        wire take_bit=remainder[g]>=trial;
        always @(posedge clk) begin
            if(!rst && advance && valid_pipe[g+3]) begin
                denominator[g+1]<=denominator[g];
                ratio_active[g+1]<=ratio_active[g];
                fixed_alpha[g+1]<=fixed_alpha[g];
                remainder[g+1]<=take_bit ? remainder[g]-trial : remainder[g];
                quotient[g+1]<=take_bit ? quotient[g] | (8'd1<<BIT_INDEX) : quotient[g];
            end
        end
    end endgenerate
    initial if(TAG_W<1 || TAG_W>32) $fatal(1,"rgb_screen_matte TAG_W must be 1..32");
endmodule
