// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Endpoint-aligned exact tetrahedral interpolation; independent authored RTL.
module tetrahedral_rgb_grade #(
    parameter integer WIDTH=128, HEIGHT=64, BITS=8, GRID_LOG2=3, TAG_W=8
)(
    input wire clk, rst,
    input wire cfg_begin_valid, output wire cfg_begin_ready,
    input wire lut_valid, output wire lut_ready,
    input wire [3*BITS-1:0] lut_rgb, input wire lut_last,
    output reg cfg_rsp_valid, input wire cfg_rsp_ready,
    output reg [1:0] cfg_rsp_error,
    output wire configured, output wire table_pending,
    input wire c_valid, output wire c_ready, input wire [TAG_W-1:0] c_tag,
    input wire s_valid, output wire s_ready, input wire [3*BITS-1:0] s_rgb,
    input wire s_sof, s_eol, s_last,
    output wire m_valid, input wire m_ready, output reg [3*BITS-1:0] m_rgb,
    output wire m_sof, m_eol, m_last, output wire [15:0] m_x, m_y,
    output wire [TAG_W-1:0] m_tag,
    output wire d_valid, input wire d_ready, output reg [1:0] d_error,
    output wire [TAG_W-1:0] d_tag
);
    localparam integer K=1<<GRID_LOG2, N=K+1, DEPTH=N*N*N;
    localparam integer AW=$clog2(DEPTH), XW=WIDTH<2?1:$clog2(WIDTH);
    localparam integer YW=HEIGHT<2?1:$clog2(HEIGHT);
    localparam [BITS-1:0] D={BITS{1'b1}}, HALF=D>>1;
    localparam [3:0] IDLE=0, PIXEL=1, CLASSIFY=2, READ=3, CAPTURE=4,
        MULTIPLY=5, ACCUMULATE=6, ROUND=7, OUTPUT=8, DONE=9;
    reg [3:0] state;
    reg [3*BITS-1:0] bank0[0:DEPTH-1], bank1[0:DEPTH-1];
    reg [3*BITS-1:0] read_q, vertex;
    reg active_bank, active_valid, load_bank, frame_bank, loading, pending;
    reg [AW-1:0] load_addr;
    reg [GRID_LOG2-1:0] lower_r, lower_g, lower_b;
    reg [BITS-1:0] fr, fg, fb, w0, w1, w2, w3, weight;
    reg [BITS-1:0] fmax, fmid, fmin;
    reg [2:0] mask1, mask2, next_mask1, next_mask2;
    reg [1:0] vi;
    reg [2*BITS-1:0] pr, pg, pb, ar, ag, ab;
    reg [XW-1:0] x;
    reg [YW-1:0] y;
    reg [TAG_W-1:0] tag;
    wire [2:0] offset=vi==0?3'b000:vi==1?mask1:vi==2?mask2:3'b111;
    wire [GRID_LOG2:0] vr={1'b0,lower_r}+offset[2];
    wire [GRID_LOG2:0] vg={1'b0,lower_g}+offset[1];
    wire [GRID_LOG2:0] vb={1'b0,lower_b}+offset[0];
    wire [AW-1:0] ra={{(AW-GRID_LOG2-1){1'b0}},vr};
    wire [AW-1:0] ga={{(AW-GRID_LOG2-1){1'b0}},vg};
    wire [AW-1:0] ba={{(AW-GRID_LOG2-1){1'b0}},vb};
    wire [AW-1:0] read_addr=ra+(ga<<GRID_LOG2)+ga+
        (ba<<(2*GRID_LOG2))+(ba<<(GRID_LOG2+1))+ba;
    wire at_eol=x==WIDTH-1, at_last=at_eol&&y==HEIGHT-1;
    assign configured=!rst&&active_valid;
    assign table_pending=!rst&&pending;
    assign cfg_begin_ready=!rst&&!loading&&!pending&&!cfg_rsp_valid;
    assign lut_ready=!rst&&loading&&!cfg_rsp_valid;
    assign c_ready=!rst&&state==IDLE;
    assign s_ready=!rst&&state==PIXEL;
    assign m_valid=!rst&&state==OUTPUT;
    assign m_sof=x==0&&y==0;
    assign m_eol=at_eol; assign m_last=at_last;
    assign m_x={{(16-XW){1'b0}},x}; assign m_y={{(16-YW){1'b0}},y};
    assign m_tag=tag; assign d_tag=tag;
    assign d_valid=!rst&&state==DONE;

    // Exact normalized coordinate: q=x>> (BITS-G), remainder=(x mod 2^(BITS-G))*2^G+q.
    // This chooses the final cell at x=D with remainder=D, rather than a nonexistent cell K.
    function [BITS-1:0] fraction;
        input [BITS-1:0] value;
        begin fraction={value[BITS-GRID_LOG2-1:0],{GRID_LOG2{1'b0}}}+
            {{(BITS-GRID_LOG2){1'b0}},value[BITS-1:BITS-GRID_LOG2]}; end
    endfunction
    // For 0<=sum<=D^2, y=sum+floor(D/2)<2^(2*BITS).
    // y=q*2^BITS+r=q*D+(q+r), and q+r<2D, so one correction suffices.
    function [BITS-1:0] normalize;
        input [2*BITS-1:0] sum;
        reg [2*BITS-1:0] biased;
        reg [BITS:0] folded, quotient;
        begin
            biased=sum+{{BITS{1'b0}},HALF};
            folded={1'b0,biased[2*BITS-1:BITS]}+{1'b0,biased[BITS-1:0]};
            quotient={1'b0,biased[2*BITS-1:BITS]}+{{BITS{1'b0}},folded>={1'b0,D}};
            normalize=quotient[BITS-1:0];
        end
    endfunction
    always @* begin
        // Descending fractions, deterministic R then G then B for ties.
        fmax=fr; fmid=fg; fmin=fb; next_mask1=3'b100; next_mask2=3'b110;
        if(fr>=fg) begin
            if(fg>=fb) begin fmax=fr; fmid=fg; fmin=fb; next_mask1=3'b100; next_mask2=3'b110; end
            else if(fr>=fb) begin fmax=fr; fmid=fb; fmin=fg; next_mask1=3'b100; next_mask2=3'b101; end
            else begin fmax=fb; fmid=fr; fmin=fg; next_mask1=3'b001; next_mask2=3'b101; end
        end else begin
            if(fr>=fb) begin fmax=fg; fmid=fr; fmin=fb; next_mask1=3'b010; next_mask2=3'b110; end
            else if(fg>=fb) begin fmax=fg; fmid=fb; fmin=fr; next_mask1=3'b010; next_mask2=3'b011; end
            else begin fmax=fb; fmid=fg; fmin=fr; next_mask1=3'b001; next_mask2=3'b011; end
        end
    end
    always @(posedge clk) begin
        if(!rst) begin
            if(lut_valid&&lut_ready) begin
                if(load_bank) bank1[load_addr]<=lut_rgb; else bank0[load_addr]<=lut_rgb;
            end
            if(state==READ) begin
                if(frame_bank) read_q<=bank1[read_addr]; else read_q<=bank0[read_addr];
            end
        end
    end
    initial begin
        if(WIDTH<1||WIDTH>4096||HEIGHT<1||HEIGHT>4096||BITS<8||BITS>12||
            GRID_LOG2<1||GRID_LOG2>4||TAG_W<1||TAG_W>32) $fatal(1,"invalid tetrahedral grade parameters");
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE; active_bank<=0; active_valid<=0; load_bank<=1; frame_bank<=0;
            loading<=0; pending<=0; load_addr<=0; cfg_rsp_valid<=0; cfg_rsp_error<=0;
            lower_r<=0; lower_g<=0; lower_b<=0; fr<=0; fg<=0; fb<=0;
            w0<=0; w1<=0; w2<=0; w3<=0; weight<=0; mask1<=0; mask2<=0; vi<=0;
            vertex<=0; pr<=0; pg<=0; pb<=0; ar<=0; ag<=0; ab<=0;
            x<=0; y<=0; tag<=0; m_rgb<=0; d_error<=0;
        end else begin
            if(cfg_rsp_valid&&cfg_rsp_ready) cfg_rsp_valid<=0;
            if(cfg_begin_valid&&cfg_begin_ready) begin
                loading<=1; load_bank<=!active_bank; load_addr<=0; cfg_rsp_error<=0;
            end
            if(lut_valid&&lut_ready) begin
                if(lut_last!=(load_addr==DEPTH-1)) begin
                    loading<=0; cfg_rsp_valid<=1; cfg_rsp_error<=1;
                end else if(load_addr==DEPTH-1) begin
                    loading<=0; pending<=1; cfg_rsp_valid<=1; cfg_rsp_error<=0;
                end else load_addr<=load_addr+1'b1;
            end
            case(state)
                IDLE: if(c_valid&&c_ready) begin
                    tag<=c_tag; x<=0; y<=0; d_error<=0;
                    if(pending) begin
                        active_bank<=load_bank; active_valid<=1; frame_bank<=load_bank; pending<=0;
                    end else frame_bank<=active_bank;
                    if(!active_valid&&!pending) begin d_error<=1; state<=DONE; end
                    else state<=PIXEL;
                end
                PIXEL: if(s_valid&&s_ready) begin
                    if(s_sof!=(x==0&&y==0)||s_eol!=at_eol||s_last!=at_last) begin
                        d_error<=2; state<=DONE;
                    end else begin
                        lower_r<=s_rgb[3*BITS-1:3*BITS-GRID_LOG2];
                        lower_g<=s_rgb[2*BITS-1:2*BITS-GRID_LOG2];
                        lower_b<=s_rgb[BITS-1:BITS-GRID_LOG2];
                        fr<=fraction(s_rgb[3*BITS-1:2*BITS]);
                        fg<=fraction(s_rgb[2*BITS-1:BITS]); fb<=fraction(s_rgb[BITS-1:0]);
                        state<=CLASSIFY;
                    end
                end
                CLASSIFY: begin
                    w0<=D-fmax; w1<=fmax-fmid; w2<=fmid-fmin; w3<=fmin;
                    mask1<=next_mask1; mask2<=next_mask2; vi<=0; ar<=0; ag<=0; ab<=0; state<=READ;
                end
                READ: state<=CAPTURE;
                CAPTURE: begin
                    vertex<=read_q;
                    case(vi) 0:weight<=w0; 1:weight<=w1; 2:weight<=w2; default:weight<=w3; endcase
                    state<=MULTIPLY;
                end
                MULTIPLY: begin
                    pr<=vertex[3*BITS-1:2*BITS]*weight;
                    pg<=vertex[2*BITS-1:BITS]*weight; pb<=vertex[BITS-1:0]*weight;
                    state<=ACCUMULATE;
                end
                ACCUMULATE: begin
                    ar<=ar+pr; ag<=ag+pg; ab<=ab+pb;
                    if(vi==3) state<=ROUND; else begin vi<=vi+1'b1; state<=READ; end
                end
                ROUND: begin m_rgb<={normalize(ar),normalize(ag),normalize(ab)}; state<=OUTPUT; end
                OUTPUT: if(m_ready) begin
                    if(at_last) state<=DONE;
                    else begin
                        if(at_eol) begin x<=0; y<=y+1'b1; end else x<=x+1'b1;
                        state<=PIXEL;
                    end
                end
                DONE: if(d_ready) state<=IDLE;
                default: begin d_error<=3; state<=DONE; end
            endcase
        end
    end
endmodule
