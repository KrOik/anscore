`timescale 1ns/1ps
// Exact unsigned floor(n / 3), two dividend bits per CE-enabled work edge.
// WIDTH >= 1. No multiplier, reciprocal approximation, or wide subtractor.
// start is sampled only on start && start_ready; busy starts are ignored.
// result_valid and its payload remain stable until a CE-qualified ready edge.
// A result can retire on the same edge that a fresh start is accepted.
module awb_constant_div3_radix4 #(parameter WIDTH=50)(
    input wire clk,rst_n,clk_en,
    input wire start,
    output wire start_ready,
    input wire [WIDTH-1:0] numerator_in,
    output reg busy,
    output reg result_valid,
    input wire result_ready,
    output reg [WIDTH-1:0] quotient_out,
    output reg [1:0] remainder_out
);
localparam DIGITS=(WIDTH+1)/2;
localparam PAD_WIDTH=2*DIGITS;
localparam COUNT_WIDTH=(DIGITS<=1)?1:$clog2(DIGITS+1);
reg [PAD_WIDTH-1:0] input_shift;
reg [COUNT_WIDTH-1:0] digits_left;
wire [3:0] trial={remainder_out,input_shift[PAD_WIDTH-1 -: 2]};
reg [1:0] quotient_digit,remainder_next;

// Given remainder < 3, trial is in [0,11]. These twelve transitions
// preserve processed_prefix = 3*quotient_prefix + remainder.
always @* begin
    if(trial>=4'd9) begin
        quotient_digit=2'd3;remainder_next=trial-4'd9;
    end else if(trial>=4'd6) begin
        quotient_digit=2'd2;remainder_next=trial-4'd6;
    end else if(trial>=4'd3) begin
        quotient_digit=2'd1;remainder_next=trial-4'd3;
    end else begin
        quotient_digit=2'd0;remainder_next=trial;
    end
end

assign start_ready=rst_n && clk_en && !busy && (!result_valid || result_ready);
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        busy<=0;result_valid<=0;quotient_out<=0;remainder_out<=0;
        input_shift<=0;digits_left<=0;
    end else if(clk_en) begin
        if(result_valid && result_ready) result_valid<=0;
        if(!busy) begin
            if(start && start_ready) begin
                input_shift<={{(PAD_WIDTH-WIDTH){1'b0}},numerator_in};
                quotient_out<=0;remainder_out<=0;digits_left<=DIGITS;
                busy<=1;result_valid<=0;
            end
        end else begin
            input_shift<=input_shift<<2;
            quotient_out<=(quotient_out<<2)|quotient_digit;
            remainder_out<=remainder_next;
            digits_left<=digits_left-1'b1;
            if(digits_left==1) begin busy<=0;result_valid<=1;end
        end
    end
end
endmodule
