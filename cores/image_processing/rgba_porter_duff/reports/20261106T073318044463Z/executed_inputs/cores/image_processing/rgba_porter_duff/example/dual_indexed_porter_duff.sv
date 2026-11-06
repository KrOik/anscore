// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module dual_indexed_porter_duff #(
    parameter integer TEX_WIDTH=8,TEX_HEIGHT=8,TAG_W=8
)(
    input wire clk,rst,
    input wire c_valid,output wire c_ready,input wire c_bank,input wire [1:0] c_op,input wire [TAG_W-1:0] c_tag,
    output wire r_valid,input wire r_ready,output wire r_bank,output wire [1:0] r_status,
    output wire [TAG_W-1:0] r_tag,output wire [16:0] r_tex_count,output wire [8:0] r_pal_count,
    input wire load_bank,input wire t_valid,output wire t_ready,input wire [7:0] t_index,
    input wire p_valid,output wire p_ready,input wire [31:0] p_argb,
    input wire s_valid,output wire s_ready,input wire [7:0] s_src_u,s_src_v,s_dst_u,s_dst_v,
    input wire [3:0] s_mode,input wire [15:0] s_x,s_y,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,output wire [31:0] m_rgba,
    output wire [1:0] m_error,output wire [3:0] m_mode,
    output wire [15:0] m_x,m_y,output wire [TAG_W-1:0] m_tag,
    output wire resident,pipeline_busy
);
    localparam integer ST=TAG_W+4;
    reg cmd_pending,cmd_bank;
    reg [3:0] owned;
    wire a_cr,b_cr,a_rv,b_rv,a_tr,b_tr,a_pr,b_pr,a_sr,b_sr;
    wire [1:0] a_status,b_status;
    wire [ST-1:0] a_rtag,b_rtag,a_tag,b_tag;
    wire [16:0] a_tc,b_tc;
    wire [8:0] a_pc,b_pc;
    wire a_mv,b_mv,a_mr,b_mr,a_res,b_res,a_busy,b_busy,pre_busy,core_busy;
    wire [23:0] a_rgb,b_rgb;
    wire [7:0] a_alpha,b_alpha;
    wire [15:0] a_x,a_y,b_x,b_y;
    wire drained=owned==0 && !a_busy && !b_busy && !pre_busy && !core_busy;
    wire management=drained && !cmd_pending;
    wire a_cv=c_valid && management && !c_bank;
    wire b_cv=c_valid && management && c_bank;
    wire query_gate=!rst && !c_valid && !cmd_pending && a_res && b_res;
    wire a_sv=s_valid && query_gate && b_sr;
    wire b_sv=s_valid && query_gate && a_sr;
    wire load_gate=management && !c_valid;
    assign c_ready=!rst && management && (c_bank ? b_cr : a_cr);
    assign r_valid=!rst && cmd_pending && (cmd_bank ? b_rv : a_rv);
    assign r_bank=cmd_bank;
    assign r_status=cmd_bank ? b_status : a_status;
    assign r_tag=cmd_bank ? b_rtag[TAG_W-1:0] : a_rtag[TAG_W-1:0];
    assign r_tex_count=cmd_bank ? b_tc : a_tc;
    assign r_pal_count=cmd_bank ? b_pc : a_pc;
    assign t_ready=!rst && load_gate && (load_bank ? b_tr : a_tr);
    assign p_ready=!rst && load_gate && (load_bank ? b_pr : a_pr);
    assign s_ready=query_gate && a_sr && b_sr;
    assign resident=!rst && a_res && b_res;
    assign pipeline_busy=!rst && owned!=0;
    wire a_q_fire=a_sv && a_sr;
    wire b_q_fire=b_sv && b_sr;
    indexed_texture_sampler #(.TEX_WIDTH(TEX_WIDTH),.TEX_HEIGHT(TEX_HEIGHT),.TAG_W(ST)) src_sampler(
        .clk(clk),.rst(rst),.c_valid(a_cv),.c_ready(a_cr),.c_op(c_op),.c_tag({4'b0,c_tag}),
        .r_valid(a_rv),.r_ready(r_ready && cmd_pending && !cmd_bank),.r_status(a_status),.r_tag(a_rtag),.r_tex_count(a_tc),.r_pal_count(a_pc),
        .t_valid(t_valid && load_gate && !load_bank),.t_ready(a_tr),.t_index(t_index),
        .p_valid(p_valid && load_gate && !load_bank),.p_ready(a_pr),.p_rgba(p_argb),
        .s_valid(a_sv),.s_ready(a_sr),.s_u(s_src_u),.s_v(s_src_v),.s_x(s_x),.s_y(s_y),.s_tag({s_mode,s_tag}),
        .m_valid(a_mv),.m_ready(a_mr),.m_rgb(a_rgb),.m_alpha(a_alpha),.m_visible(),.m_reason(),
        .m_x(a_x),.m_y(a_y),.m_tag(a_tag),.resident(a_res),.pipeline_busy(a_busy));
    indexed_texture_sampler #(.TEX_WIDTH(TEX_WIDTH),.TEX_HEIGHT(TEX_HEIGHT),.TAG_W(ST)) dst_sampler(
        .clk(clk),.rst(rst),.c_valid(b_cv),.c_ready(b_cr),.c_op(c_op),.c_tag({4'b0,c_tag}),
        .r_valid(b_rv),.r_ready(r_ready && cmd_pending && cmd_bank),.r_status(b_status),.r_tag(b_rtag),.r_tex_count(b_tc),.r_pal_count(b_pc),
        .t_valid(t_valid && load_gate && load_bank),.t_ready(b_tr),.t_index(t_index),
        .p_valid(p_valid && load_gate && load_bank),.p_ready(b_pr),.p_rgba(p_argb),
        .s_valid(b_sv),.s_ready(b_sr),.s_u(s_dst_u),.s_v(s_dst_v),.s_x(s_x),.s_y(s_y),.s_tag({s_mode,s_tag}),
        .m_valid(b_mv),.m_ready(b_mr),.m_rgb(b_rgb),.m_alpha(b_alpha),.m_visible(),.m_reason(),
        .m_x(b_x),.m_y(b_y),.m_tag(b_tag),.resident(b_res),.pipeline_busy(b_busy));
    wire pre_sr,pre_mv,pre_mr;
    wire [31:0] pre_src,pre_dst;
    wire [3:0] pre_mode;
    wire [15:0] pre_x,pre_y;
    wire [TAG_W-1:0] pre_tag;
    // Both samples, including alpha-zero and out-of-range transparent samples, are owned.
    assign a_mr=pre_sr && b_mv;
    assign b_mr=pre_sr && a_mv;
    rgba_pair_premultiply #(.TAG_W(TAG_W)) premultiply(
        .clk(clk),.rst(rst),.s_valid(a_mv && b_mv),.s_ready(pre_sr),
        .s_src({a_rgb,a_alpha}),.s_dst({b_rgb,b_alpha}),.s_mode(a_tag[ST-1:TAG_W]),
        .s_x(a_x),.s_y(a_y),.s_tag(a_tag[TAG_W-1:0]),
        .m_valid(pre_mv),.m_ready(pre_mr),.m_src(pre_src),.m_dst(pre_dst),.m_mode(pre_mode),
        .m_x(pre_x),.m_y(pre_y),.m_tag(pre_tag),.pipeline_busy(pre_busy));
    rgba_porter_duff #(.TAG_W(TAG_W)) compose(
        .clk(clk),.rst(rst),.s_valid(pre_mv),.s_ready(pre_mr),.s_src(pre_src),.s_dst(pre_dst),
        .s_mode(pre_mode),.s_x(pre_x),.s_y(pre_y),.s_tag(pre_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_rgba(m_rgba),.m_error(m_error),.m_mode(m_mode),
        .m_x(m_x),.m_y(m_y),.m_tag(m_tag),.pipeline_busy(core_busy));
    initial if(TAG_W<1 || TAG_W>28) $fatal(1,"dual_indexed_porter_duff TAG_W must be 1..28");
    always @(posedge clk)begin
        if(rst)begin owned<=0;cmd_pending<=0;cmd_bank<=0;end
        else begin
            case({s_valid && s_ready,m_valid && m_ready})
                2'b10:owned<=owned+1'b1;
                2'b01:owned<=owned-1'b1;
                default:owned<=owned;
            endcase
            if(c_valid && c_ready)begin cmd_pending<=1;cmd_bank<=c_bank;end
            else if(r_valid && r_ready)cmd_pending<=0;
        end
    end
endmodule
