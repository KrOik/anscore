// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Raster causal two-level palette quantizer. No frame or output image memory.
module causal_palette_diffusion #(
    parameter integer WIDTH=128, HEIGHT=64, BITS=8, TAG_W=8
)(
    input wire clk,rst,
    input wire c_valid,output wire c_ready,
    input wire [BITS-1:0] c_low,c_high,input wire [TAG_W-1:0] c_tag,
    input wire s_valid,output wire s_ready,input wire [BITS-1:0] s_data,
    input wire s_sof,s_eol,s_last,
    output wire m_valid,input wire m_ready,output reg [BITS-1:0] m_data,
    output reg m_code,output wire m_sof,m_eol,m_last,
    output wire [15:0] m_x,m_y,output wire [TAG_W-1:0] m_tag,
    output wire d_valid,input wire d_ready,output reg [1:0] d_error,
    output wire [TAG_W-1:0] d_tag
);
    localparam integer EW=BITS+6;
    localparam [3:0] IDLE=0,CLEAR=1,INPUT=2,READ=3,QUANT=4,
        SELECT=5,NREAD=6,NWRITE=7,HOLD=8,DONE=9;
    localparam [EW-1:0] MAX_Q4=((1<<BITS)-1)*16;
    reg [3:0] state;
    reg signed [EW-1:0] errors[0:2*WIDTH-1],error_q,carry,residual;
    reg [BITS-1:0] raw,low_level,high_level;
    reg [TAG_W-1:0] tag;
    reg [15:0] x,y,clear_address;
    reg [1:0] neighbor;
    wire [16:0] current_address=(y[0]?WIDTH:0)+x;
    wire [16:0] next_base=y[0]?0:WIDTH;
    wire [16:0] neighbor_address=next_base+x+(neighbor==0?-17'sd1:neighbor==2?17'sd1:17'sd0);
    wire neighbor_ok=(neighbor==0?x!=0:neighbor==2?x!=WIDTH-1:1'b1);
    wire signed [EW-1:0] raw_q4=$signed({2'b00,raw,4'b0000});
    wire signed [EW-1:0] combined=raw_q4+error_q+carry;
    wire [EW-1:0] corrected=combined<0?{EW{1'b0}}:
        combined>$signed(MAX_Q4)?MAX_Q4:combined;
    wire [BITS:0] level_sum={1'b0,low_level}+{1'b0,high_level};
    wire choose_high=({1'b0,corrected}<<1)>={2'b00,level_sum,4'b0000};
    wire [BITS-1:0] selected_level=choose_high?high_level:low_level;
    wire signed [EW-1:0] selected_q4=$signed({2'b00,selected_level,4'b0000});
    wire signed [EW-1:0] quant_error=$signed(corrected)-selected_q4;
    function automatic signed [EW-1:0] weighted;
        input signed [EW-1:0] value;
        input [3:0] weight;
        reg [EW-1:0] magnitude;
        reg [EW+3:0] scaled;
        begin
            magnitude=value<0?-value:value;
            scaled=magnitude*weight+{{EW{1'b0}},4'd8};
            weighted=value<0?-$signed(scaled>>4):$signed(scaled>>4);
        end
    endfunction
    wire [3:0] neighbor_weight=neighbor==0?4'd3:neighbor==1?4'd5:4'd1;
    assign c_ready=!rst&&state==IDLE;
    assign s_ready=!rst&&state==INPUT;
    assign m_valid=!rst&&state==HOLD;
    assign m_x=x;assign m_y=y;assign m_tag=tag;assign d_tag=tag;
    assign m_sof=x==0&&y==0;assign m_eol=x==WIDTH-1;
    assign m_last=x==WIDTH-1&&y==HEIGHT-1;
    assign d_valid=!rst&&state==DONE;
    // At most one read or write per edge. Opposite row is updated only after
    // current-row fetch, and every consumed location is cleared for reuse.
    always @(posedge clk) if(!rst) begin
        if(state==CLEAR) errors[clear_address]<=0;
        if(state==READ) error_q<=errors[current_address];
        if(state==QUANT) errors[current_address]<=0;
        if(state==NREAD) error_q<=errors[neighbor_address];
        if(state==NWRITE) errors[neighbor_address]<=error_q+weighted(residual,neighbor_weight);
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;raw<=0;low_level<=0;high_level<=0;tag<=0;
            x<=0;y<=0;clear_address<=0;neighbor<=0;carry<=0;residual<=0;
            m_data<=0;m_code<=0;d_error<=0;
        end else case(state)
            IDLE:if(c_valid) begin
                low_level<=c_low;high_level<=c_high;tag<=c_tag;
                x<=0;y<=0;clear_address<=0;carry<=0;
                if(c_low>=c_high)begin d_error<=1;state<=DONE;end
                else begin d_error<=0;state<=CLEAR;end
            end
            CLEAR:if(clear_address==2*WIDTH-1)state<=INPUT;
                else clear_address<=clear_address+1'b1;
            INPUT:if(s_valid)begin
                if(s_sof!=(x==0&&y==0)||s_eol!=(x==WIDTH-1)||s_last!=(x==WIDTH-1&&y==HEIGHT-1))begin
                    d_error<=2;state<=DONE;
                end else begin raw<=s_data;state<=READ;end
            end
            READ:state<=QUANT;
            QUANT:begin
                m_data<=selected_level;m_code<=choose_high;residual<=quant_error;
                carry<=x==WIDTH-1?{EW{1'b0}}:weighted(quant_error,4'd7);
                neighbor<=0;state<=y==HEIGHT-1?HOLD:SELECT;
            end
            SELECT:if(neighbor==3)state<=HOLD;
                else if(neighbor_ok)state<=NREAD;
                else neighbor<=neighbor+1'b1;
            NREAD:state<=NWRITE;
            NWRITE:begin neighbor<=neighbor+1'b1;state<=SELECT;end
            HOLD:if(m_ready)begin
                if(x==WIDTH-1&&y==HEIGHT-1)state<=DONE;
                else begin
                    if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end
                    else x<=x+1'b1;
                    state<=INPUT;
                end
            end
            DONE:if(d_ready)state<=IDLE;
            default:begin d_error<=3;state<=DONE;end
        endcase
    end
    initial if(WIDTH<1||WIDTH>4096||HEIGHT<1||HEIGHT>4096||
        (BITS!=8&&BITS!=10&&BITS!=12)||TAG_W<1||TAG_W>32)
        $fatal(1,"causal_palette_diffusion invalid parameters");
endmodule
