`timescale 1ns / 1ps
`include "sm3_cfg.v"
//////////////////////////////////////////////////////////////////////////////////
// sm3_top.v — 二改新增模块
// Plain-wire wrapper around the vendored SM3 pad/expnd/cmprss pipeline
// (replaces the SystemVerilog-interface sm3_core_top so the design builds
// with iverilog and the OSS yosys/nextpnr flow).
//
// Streaming input: 64-bit words, big-endian, msg_inpt_vld_byte_i marks the
// number of valid bytes minus 1... actually it is the per-word valid-byte
// count used by the padding core on the last word. See sm3_pad_core.
//////////////////////////////////////////////////////////////////////////////////
module sm3_top (
    input               clk,
    input               rst_n,

    input  [63:0]       msg_inpt_d_i,
    input  [7:0]        msg_inpt_vld_byte_i,
    input               msg_inpt_vld_i,
    input               msg_inpt_lst_i,
    output              msg_inpt_rdy_o,

    output [255:0]      cmprss_otpt_res_o,
    output              cmprss_otpt_vld_o
);

wire [63:0] pad_otpt_d;
wire        pad_otpt_lst;
wire        pad_otpt_vld;
wire        pad_otpt_ena;

wire [63:0] expnd_otpt_wj;
wire [63:0] expnd_otpt_wjj;
wire        expnd_otpt_lst;
wire        expnd_otpt_vld;

sm3_pad_core U_sm3_pad_core(
    .clk                    (clk),
    .rst_n                  (rst_n),
    .msg_inpt_d_i           (msg_inpt_d_i),
    .msg_inpt_vld_byte_i    (msg_inpt_vld_byte_i),
    .msg_inpt_vld_i         (msg_inpt_vld_i),
    .msg_inpt_lst_i         (msg_inpt_lst_i),
    .msg_inpt_rdy_o         (msg_inpt_rdy_o),
    .pad_otpt_ena_i         (pad_otpt_ena),
    .pad_otpt_d_o           (pad_otpt_d),
    .pad_otpt_lst_o         (pad_otpt_lst),
    .pad_otpt_vld_o         (pad_otpt_vld)
);

sm3_expnd_core U_sm3_expnd_core(
    .clk                    (clk),
    .rst_n                  (rst_n),
    .pad_inpt_d_i           (pad_otpt_d),
    .pad_inpt_vld_i         (pad_otpt_vld),
    .pad_inpt_lst_i         (pad_otpt_lst),
    .pad_inpt_rdy_o         (pad_otpt_ena),
    .expnd_otpt_wj_o        (expnd_otpt_wj),
    .expnd_otpt_wjj_o       (expnd_otpt_wjj),
    .expnd_otpt_lst_o       (expnd_otpt_lst),
    .expnd_otpt_vld_o       (expnd_otpt_vld)
);

sm3_cmprss_core U_sm3_cmprss_core(
    .clk                    (clk),
    .rst_n                  (rst_n),
    .expnd_inpt_wj_i        (expnd_otpt_wj),
    .expnd_inpt_wjj_i       (expnd_otpt_wjj),
    .expnd_inpt_lst_i       (expnd_otpt_lst),
    .expnd_inpt_vld_i       (expnd_otpt_vld),
    .cmprss_otpt_res_o      (cmprss_otpt_res_o),
    .cmprss_otpt_vld_o      (cmprss_otpt_vld_o)
);

endmodule
