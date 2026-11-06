// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Real stream_atan2 -> wrapped phase OLS, with exactly one I/Q vector in flight.
module iq_group_delay_fit #(
    parameter integer IN_W=16,PHASE_W=16,ITER=24,MAX_BINS=64,TAG_W=8,MAX_FFT_LOG2=16,
    parameter integer L=$clog2(MAX_BINS),CW=$clog2(MAX_BINS+1),
    parameter integer BW=PHASE_W+3*L+CW+2,CWIDE=2*PHASE_W+3*L+CW+1,
    parameter integer DW=3*L+CW+1,RW=((CWIDE+DW>2*BW)?CWIDE+DW:2*BW)+1,
    parameter integer DELAY_W=MAX_FFT_LOG2+17
)(
    input wire clk,rst,c_valid,output wire c_ready,
    input wire [31:0] c_count,c_first_bin,c_fft_log2,input wire [TAG_W-1:0] c_tag,
    input wire s_valid,output wire s_ready,
    input wire signed [IN_W-1:0] s_i,s_q,input wire s_last,
    output wire m_valid,input wire m_ready,output wire [2:0] m_status,
    output wire signed [DELAY_W-1:0] m_delay_q16,output wire signed [BW-1:0] m_b,
    output wire [CWIDE-1:0] m_c,output wire [DW-1:0] m_d,output wire [RW-1:0] m_residual_numerator,
    output wire [31:0] m_count,m_first_bin,m_fft_log2,m_received,
    output wire [TAG_W-1:0] m_tag,output wire busy
);
    reg angle_pending;
    initial if(L!=$clog2(MAX_BINS) || CW!=$clog2(MAX_BINS+1) ||
        BW!=PHASE_W+3*L+CW+2 || CWIDE!=2*PHASE_W+3*L+CW+1 || DW!=3*L+CW+1 ||
        RW!=((CWIDE+DW>2*BW)?CWIDE+DW:2*BW)+1 || DELAY_W!=MAX_FFT_LOG2+17)
        $fatal(1,"iq_group_delay_fit derived width override");
    wire angle_ready,angle_valid,angle_zero,angle_last,phase_ready;
    wire [PHASE_W-1:0] angle;
    assign s_ready=!rst && phase_ready && angle_ready && !angle_pending;
    stream_atan2 #(.IN_W(IN_W),.PHASE_W(PHASE_W),.ITER(ITER),.TAG_W(1)) atan(
        .clk(clk),.rst(rst),.s_valid(s_valid && phase_ready && !angle_pending && !rst),.s_ready(angle_ready),
        .s_x(s_i),.s_y(s_q),.s_last(s_last),.s_tag(1'b0),
        .m_valid(angle_valid),.m_ready(phase_ready && angle_pending && !rst),
        .m_phase(angle),.m_zero(angle_zero),.m_last(angle_last),.m_tag());
    spectral_group_delay_fit #(.PHASE_W(PHASE_W),.MAX_BINS(MAX_BINS),.TAG_W(TAG_W),.MAX_FFT_LOG2(MAX_FFT_LOG2)) fit(
        .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),
        .c_count(c_count),.c_first_bin(c_first_bin),.c_fft_log2(c_fft_log2),.c_tag(c_tag),
        .s_valid(angle_valid && angle_pending),.s_ready(phase_ready),.s_phase(angle),.s_last(angle_last),.s_invalid(angle_zero),
        .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_delay_q16(m_delay_q16),
        .m_b(m_b),.m_c(m_c),.m_d(m_d),.m_residual_numerator(m_residual_numerator),
        .m_count(m_count),.m_first_bin(m_first_bin),.m_fft_log2(m_fft_log2),.m_received(m_received),.m_tag(m_tag),.busy(busy));
    always @(posedge clk)begin
        if(rst)angle_pending<=0;
        else begin
            if(s_valid && s_ready)angle_pending<=1;
            if(angle_valid && phase_ready && angle_pending)angle_pending<=0;
        end
    end
endmodule
