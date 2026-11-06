// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module three_field_deinterlace #(
    parameter integer WIDTH=128, HEIGHT=64, BITS=8
)(
    input wire clk, rst, ce,
    input wire cfg_first_parity,
    input wire [BITS-1:0] cfg_threshold,
    input wire s_valid,
    output wire s_ready,
    input wire [BITS-1:0] s_pixel,
    input wire s_field_sof, s_eol, s_parity,
    output wire m_valid,
    input wire m_ready,
    output reg [BITS-1:0] m_pixel,
    output reg [1:0] m_source,
    output reg signed [2:0] m_dir,
    output reg m_sof, m_eol, m_last,
    output wire done_valid,
    input wire done_ready,
    output reg [1:0] done_error,
    output wire busy
);
    localparam integer FIELD_ROWS=HEIGHT/2, FIELD_PIXELS=WIDTH*FIELD_ROWS;
    localparam integer AW=(FIELD_PIXELS>1)?$clog2(FIELD_PIXELS):1;
    localparam integer XW=(WIDTH>1)?$clog2(WIDTH):1;
    localparam integer YW=(HEIGHT>1)?$clog2(HEIGHT):1;
    localparam integer CW=$clog2(WIDTH+6);
    localparam [63:0] PIXELS64=64'(WIDTH)*64'(HEIGHT);
    localparam [1:0] CAPTURE=0, RUN=1, STATUS=2;
    initial begin
        if(WIDTH<1 || WIDTH>512 || HEIGHT<2 || HEIGHT>512 || HEIGHT%2!=0 ||
           PIXELS64>65536 || BITS<8 || BITS>12)
            $fatal(1,"three_field_deinterlace invalid parameters");
    end

    reg [1:0] state, field_id;
    reg [AW-1:0] in_index;
    reg [XW-1:0] in_x;
    reg first_parity;
    reg [BITS-1:0] threshold;
    reg out_valid;
    wire first_pixel=(field_id==0 && in_index==0);
    wire expected_parity=first_pixel ? cfg_first_parity :
                              ((field_id==1)?~first_parity:first_parity);
    wire marker_bad=(s_field_sof!=(in_index==0)) ||
                    (s_eol!=(in_x==WIDTH-1)) || (s_parity!=expected_parity);
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && out_valid;
    assign done_valid=!rst && state==STATUS;
    assign busy=!rst && (state!=CAPTURE || field_id!=0 || in_index!=0);
    wire capture_good=ce && s_valid && s_ready && !marker_bad;
    // A held output freezes every pipeline register, RAM request and coordinate.
    wire advance=ce && (!out_valid || m_ready);
    reg issue_active;
    reg [CW-1:0] req_col;
    reg [YW-1:0] req_y;
    wire read_en=!rst && state==RUN && advance && issue_active;
    wire req_preserved=(req_y[0]!=first_parity);
    wire [XW-1:0] read_x=(req_col<3)?XW'(0):
                       (req_col>WIDTH+2)?XW'(WIDTH-1):XW'(req_col-3);
    wire [YW-1:0] upper_row=req_preserved ? (req_y>>1) :
                              (req_y==0)?YW'(0):((req_y-1'b1)>>1);
    wire [YW-1:0] lower_row=req_preserved ? (req_y>>1) :
                              (req_y==HEIGHT-1)?YW'(FIELD_ROWS-1):((req_y+1'b1)>>1);
    // WIDTH is an elaboration constant, not a data multiplier.
    wire [AW-1:0] pn_addr=AW'((req_y>>1)*WIDTH+read_x);
    wire [AW-1:0] cu_addr=AW'(upper_row*WIDTH+read_x);
    wire [AW-1:0] cl_addr=AW'(lower_row*WIDTH+read_x);
    reg [BITS-1:0] p_mem[0:FIELD_PIXELS-1];
    reg [BITS-1:0] c_mem[0:FIELD_PIXELS-1];
    reg [BITS-1:0] n_mem[0:FIELD_PIXELS-1];
    reg [BITS-1:0] p_q,n_q,u_q,l_q;
    // Capture and replay never overlap. P/N use one port each; C uses two.
    always @(posedge clk) begin
        if(!rst) begin
            if(capture_good && field_id==0) p_mem[in_index]<=s_pixel;
            else if(read_en) p_q<=p_mem[pn_addr];
            if(capture_good && field_id==1) c_mem[in_index]<=s_pixel;
            else if(read_en) u_q<=c_mem[cu_addr];
            if(read_en) l_q<=c_mem[cl_addr];
            if(capture_good && field_id==2) n_mem[in_index]<=s_pixel;
            else if(read_en) n_q<=n_mem[pn_addr];
        end
    end

    reg r_valid, r_preserved;
    reg [CW-1:0] r_col;
    reg [YW-1:0] r_y;
    reg [BITS-1:0] wp[0:6],wn[0:6],wu[0:6],wl[0:6];
    wire [BITS-1:0] np[0:6],nn[0:6],nu[0:6],nl[0:6];
    genvar g;
    generate for(g=0;g<7;g=g+1) begin: next_window
        if(g==6) begin
            assign np[g]=p_q; assign nn[g]=n_q;
            assign nu[g]=u_q; assign nl[g]=l_q;
        end else begin
            assign np[g]=wp[g+1]; assign nn[g]=wn[g+1];
            assign nu[g]=wu[g+1]; assign nl[g]=wl[g+1];
        end
    end endgenerate

    function automatic [BITS-1:0] difference(input [BITS-1:0] a,b);
        begin difference=(a>=b)?a-b:b-a; end
    endfunction
    function automatic [BITS-1:0] mean_up(input [BITS-1:0] a,b);
        reg [BITS:0] sum;
        begin
            sum={1'b0,a}+{1'b0,b}+{{BITS{1'b0}},1'b1};
            mean_up=sum[BITS:1];
        end
    endfunction
    function automatic integer direction(input integer index);
        begin
            case(index)
                0:direction=0; 1:direction=-1; 2:direction=1;
                3:direction=-2; default:direction=2;
            endcase
        end
    endfunction
    reg [BITS+1:0] costs[0:4];
    reg [BITS-1:0] candidates[0:4];
    reg [BITS-1:0] temporal_motion,temporal_mean,preserved_pixel;
    reg score_valid,score_preserved,score_sof,score_eol,score_last;
    wire [BITS-1:0] dm0=difference(np[2],nn[2]);
    wire [BITS-1:0] dm1=difference(np[3],nn[3]);
    wire [BITS-1:0] dm2=difference(np[4],nn[4]);
    wire [BITS-1:0] dm01=(dm0>dm1)?dm0:dm1;
    wire [BITS-1:0] motion_now=(dm01>dm2)?dm01:dm2;
    reg [BITS+1:0] best_cost;
    reg [2:0] best_index;
    integer j;
    always @* begin
        best_cost=costs[0]; best_index=0;
        for(j=1;j<5;j=j+1) begin
            if(costs[j]<best_cost) begin best_cost=costs[j];best_index=3'(j);end
        end
    end
    integer i;
    always @(posedge clk) begin
        if(rst) begin
            state<=CAPTURE;field_id<=0;in_index<=0;in_x<=0;
            first_parity<=0;threshold<=0;done_error<=0;
            issue_active<=0;req_col<=0;req_y<=0;
            r_valid<=0;r_col<=0;r_y<=0;r_preserved<=0;
            score_valid<=0;score_preserved<=0;score_sof<=0;score_eol<=0;score_last<=0;
            out_valid<=0;m_pixel<=0;m_source<=0;m_dir<=0;m_sof<=0;m_eol<=0;m_last<=0;
        end else if(ce) begin
            case(state)
                CAPTURE: if(s_valid && s_ready) begin
                    if(marker_bad) begin
                        state<=STATUS;done_error<=1;
                    end else begin
                        if(first_pixel) begin first_parity<=cfg_first_parity;threshold<=cfg_threshold;end
                        if(in_x==WIDTH-1) in_x<=0;else in_x<=in_x+1'b1;
                        if(in_index==FIELD_PIXELS-1) begin
                            in_index<=0;
                            if(field_id==2) begin
                                state<=RUN;issue_active<=1;req_col<=0;req_y<=0;
                                r_valid<=0;score_valid<=0;out_valid<=0;
                            end else field_id<=field_id+1'b1;
                        end else in_index<=in_index+1'b1;
                    end
                end
                RUN: if(advance) begin
                    r_valid<=issue_active;
                    if(issue_active) begin
                        r_col<=req_col;r_y<=req_y;r_preserved<=req_preserved;
                        if(req_col==WIDTH+5) begin
                            req_col<=0;
                            if(req_y==HEIGHT-1) issue_active<=0;
                            else req_y<=req_y+1'b1;
                        end else req_col<=req_col+1'b1;
                    end
                    score_valid<=r_valid && r_col>=6;
                    if(r_valid) begin
                        for(i=0;i<7;i=i+1) begin
                            wp[i]<=np[i];wn[i]<=nn[i];wu[i]<=nu[i];wl[i]<=nl[i];
                        end
                        if(r_col>=6) begin
                            score_preserved<=r_preserved;
                            score_sof<=(r_y==0 && r_col==6);
                            score_eol<=(r_col==WIDTH+5);
                            score_last<=(r_y==HEIGHT-1 && r_col==WIDTH+5);
                            preserved_pixel<=nu[3];
                            temporal_mean<=mean_up(np[3],nn[3]);temporal_motion<=motion_now;
                            for(i=0;i<5;i=i+1) begin
                                costs[i]<=
                                    {{2{1'b0}},difference(nu[2-direction(i)],nl[2+direction(i)])}+
                                    {{2{1'b0}},difference(nu[3-direction(i)],nl[3+direction(i)])}+
                                    {{2{1'b0}},difference(nu[4-direction(i)],nl[4+direction(i)])};
                                candidates[i]<=mean_up(nu[3-direction(i)],nl[3+direction(i)]);
                            end
                        end
                    end
                    out_valid<=score_valid;
                    if(score_valid) begin
                        m_sof<=score_sof;m_eol<=score_eol;m_last<=score_last;
                        if(score_preserved) begin m_pixel<=preserved_pixel;m_source<=0;m_dir<=0;end
                        else if(temporal_motion<=threshold) begin m_pixel<=temporal_mean;m_source<=1;m_dir<=0;end
                        else begin m_pixel<=candidates[best_index];m_source<=2;m_dir<=3'(direction(best_index));end
                    end
                    if(out_valid && m_ready && m_last) begin
                        out_valid<=0;r_valid<=0;score_valid<=0;issue_active<=0;
                        state<=STATUS;done_error<=0;
                    end
                end
                STATUS: if(done_ready) begin
                    state<=CAPTURE;field_id<=0;in_index<=0;in_x<=0;done_error<=0;
                end
                default: begin
                    state<=STATUS;done_error<=2;out_valid<=0;
                    r_valid<=0;score_valid<=0;issue_active<=0;
                end
            endcase
        end
    end
endmodule
