`timescale 1ns/1ps
// Four-neighbor Jacobi PM variant. Exact quantization is specified in README.
module grayscale_anisotropic_diffusion #(
    parameter WIDTH=16, HEIGHT=16, TAG_W=8
)(
    input wire clk, rst,
    input wire s_valid, output wire s_ready,
    input wire [7:0] s_pixel, s_k,
    input wire [4:0] s_iterations,
    input wire s_sof, s_eol, s_last,
    input wire [TAG_W-1:0] s_tag,
    output wire m_valid, input wire m_ready,
    output reg [7:0] m_pixel,
    output reg [15:0] m_value_q8,
    output reg [((WIDTH<2)?1:$clog2(WIDTH))-1:0] m_x,
    output reg [((HEIGHT<2)?1:$clog2(HEIGHT))-1:0] m_y,
    output reg m_sof, m_eol, m_last, m_keep,
    output reg [4:0] m_errors,
    output reg [TAG_W-1:0] m_tag
);
    localparam LEGAL=(WIDTH>=1 && WIDTH<=32 && HEIGHT>=1 && HEIGHT<=32 && TAG_W>=1 && TAG_W<=32);
    localparam N=LEGAL?WIDTH*HEIGHT:1;
    localparam AW=(N<2)?1:$clog2(N);
    localparam XW=(WIDTH<2)?1:$clog2(WIDTH), YW=(HEIGHT<2)?1:$clog2(HEIGHT);
    generate if(!LEGAL) begin: invalid_parameter
        grayscale_anisotropic_diffusion_invalid_parameters__see_README invalid_configuration();
    end endgenerate

    localparam [4:0] CAPTURE=0,CHECK_FRAME=1,K_SQUARE=2,K_TAKE=3,
        A_SQUARE=4,A_TAKE=5,DIV_ISSUE=6,DIV_WAIT=7,LUT_WRITE=8,
        PIX_READ=9,PIX_TAKE=10,NEIGH_SELECT=11,NEIGH_READ=12,NEIGH_TAKE=13,
        COEFF_READ=14,COEFF_TAKE=15,FLUX_MULT=16,FLUX_TAKE=17,ACCUM=18,
        UPDATE=19,WRITE_PIXEL=20,NEXT_PIXEL=21,ITER_SWAP=22,
        OUT_READ=23,OUT_TAKE=24,OUT_HOLD=25,ERROR_HOLD=26;
    reg [4:0] state;
    reg [AW-1:0] capture_index,pixel_index;
    reg [XW-1:0] capture_x,x;
    reg [YW-1:0] y;
    reg [7:0] frame_k,table_index;
    reg [4:0] frame_iterations,iteration;
    reg [TAG_W-1:0] frame_tag;
    reg [4:0] errors;
    reg source_bank;
    reg [1:0] direction;
    reg [15:0] center,abs_delta,updated,k_square;
    reg delta_negative;
    reg [16:0] denominator;
    reg [8:0] coefficient,table_value;
    reg [24:0] product;
    reg signed [24:0] flux;
    reg signed [26:0] flux_sum;
    reg [15:0] bank_a[0:N-1],bank_b[0:N-1];
    reg [8:0] conductance[0:255];
    reg [15:0] read_q;
    reg [8:0] coefficient_q;
    reg [AW-1:0] neighbor_address;
    wire [AW-1:0] read_address=(state==NEIGH_READ)?neighbor_address:pixel_index;
    wire [16:0] index_rounded={1'b0,abs_delta}+17'd128;
    wire [7:0] coefficient_index=index_rounded[15:8];
    wire [15:0] multiply_a=(state==K_SQUARE)?{8'b0,frame_k}:
                              (state==A_SQUARE)?{8'b0,table_index}:abs_delta;
    wire [8:0] multiply_b=(state==K_SQUARE)?{1'b0,frame_k}:
                             (state==A_SQUARE)?{1'b0,table_index}:coefficient;
    wire [26:0] sum_magnitude=flux_sum[26]?$unsigned(-flux_sum):$unsigned(flux_sum);
    wire [26:0] rounded_magnitude=(sum_magnitude+27'd1024)>>11;
    wire signed [27:0] signed_step=flux_sum[26]?-$signed({1'b0,rounded_magnitude}):$signed({1'b0,rounded_magnitude});
    wire signed [27:0] new_value=$signed({12'b0,center})+signed_step;
    wire [16:0] final_rounded={1'b0,read_q}+17'd128;
    wire [4:0] marker_errors={2'b0,(s_last!=(capture_index==N-1)),
                                  (s_eol!=(capture_x==WIDTH-1)),(s_sof!=(capture_index==0))};
    wire [4:0] first_config_errors={(s_iterations>16),(s_k==0),3'b0};
    wire divider_ready,divider_valid,divider_zero;
    wire [23:0] divider_quotient,divider_remainder;
    integer_divider #(.W(24)) u_divider(
        .clk(clk),.rst(rst),.s_valid(state==DIV_ISSUE),.s_ready(divider_ready),
        .s_numerator({k_square,8'b0}),.s_denominator({7'b0,denominator}),
        .m_valid(divider_valid),.m_ready(state==DIV_WAIT),
        .m_quotient(divider_quotient),.m_remainder(divider_remainder),.m_divzero(divider_zero));
    assign s_ready=!rst && state==CAPTURE;
    assign m_valid=!rst && (state==OUT_HOLD || state==ERROR_HOLD);

    always @* begin
        neighbor_address=pixel_index;
        case(direction)
            0: if(y!=0) neighbor_address=pixel_index-WIDTH;
            1: if(y!=HEIGHT-1) neighbor_address=pixel_index+WIDTH;
            2: if(x!=0) neighbor_address=pixel_index-1'b1;
            3: if(x!=WIDTH-1) neighbor_address=pixel_index+1'b1;
            default: neighbor_address=pixel_index;
        endcase
    end
    // Payload/read registers have no reset. Each read belongs to a completed bank.
    always @(posedge clk) begin
        if(!rst) begin
            if(s_valid && s_ready) bank_a[capture_index]<={s_pixel,8'b0};
            if(state==WRITE_PIXEL) begin
                if(source_bank) bank_a[pixel_index]<=updated;
                else bank_b[pixel_index]<=updated;
            end
            if(state==PIX_READ || state==NEIGH_READ || state==OUT_READ) begin
                if(source_bank) read_q<=bank_b[read_address];
                else read_q<=bank_a[read_address];
            end
            if(state==LUT_WRITE) conductance[table_index]<=table_value;
            if(state==COEFF_READ) coefficient_q<=conductance[coefficient_index];
            if(state==K_SQUARE || state==A_SQUARE || state==FLUX_MULT)
                product<=multiply_a*multiply_b;
        end
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=CAPTURE;capture_index<=0;capture_x<=0;pixel_index<=0;x<=0;y<=0;
            frame_k<=0;frame_iterations<=0;frame_tag<=0;errors<=0;iteration<=0;
            source_bank<=0;direction<=0;table_index<=0;k_square<=0;denominator<=0;
            center<=0;abs_delta<=0;updated<=0;delta_negative<=0;coefficient<=0;
            table_value<=0;flux<=0;flux_sum<=0;
            m_pixel<=0;m_value_q8<=0;m_x<=0;m_y<=0;m_sof<=0;m_eol<=0;
            m_last<=0;m_keep<=0;m_errors<=0;m_tag<=0;
        end else case(state)
            CAPTURE: if(s_valid && s_ready) begin
                errors<=errors|marker_errors|((capture_index==0)?first_config_errors:5'b0);
                if(capture_index==0) begin
                    frame_k<=s_k;frame_iterations<=s_iterations;frame_tag<=s_tag;
                end
                if(capture_index==N-1) state<=CHECK_FRAME;
                else begin
                    capture_index<=capture_index+1'b1;
                    if(capture_x==WIDTH-1) capture_x<=0;else capture_x<=capture_x+1'b1;
                end
            end
            CHECK_FRAME: begin
                source_bank<=0;iteration<=0;pixel_index<=0;x<=0;y<=0;direction<=0;
                if(errors!=0) begin
                    m_pixel<=0;m_value_q8<=0;m_x<=0;m_y<=0;m_sof<=0;m_eol<=0;
                    m_last<=1;m_keep<=0;m_errors<=errors;m_tag<=frame_tag;state<=ERROR_HOLD;
                end else if(frame_iterations==0) state<=OUT_READ;
                else state<=K_SQUARE;
            end
            K_SQUARE: state<=K_TAKE;
            K_TAKE: begin k_square<=product[15:0];table_index<=0;state<=A_SQUARE;end
            A_SQUARE: state<=A_TAKE;
            A_TAKE: begin denominator<={1'b0,k_square}+{1'b0,product[15:0]};state<=DIV_ISSUE;end
            DIV_ISSUE: if(divider_ready) state<=DIV_WAIT;
            DIV_WAIT: if(divider_valid) begin table_value<=divider_quotient[8:0];state<=LUT_WRITE;end
            LUT_WRITE: if(table_index==255) state<=PIX_READ;
                else begin table_index<=table_index+1'b1;state<=A_SQUARE;end
            PIX_READ: state<=PIX_TAKE;
            PIX_TAKE: begin center<=read_q;flux_sum<=0;direction<=0;state<=NEIGH_SELECT;end
            NEIGH_SELECT: state<=NEIGH_READ;
            NEIGH_READ: state<=NEIGH_TAKE;
            NEIGH_TAKE: begin
                delta_negative<=(read_q<center);
                abs_delta<=(read_q<center)?center-read_q:read_q-center;
                state<=COEFF_READ;
            end
            COEFF_READ: state<=COEFF_TAKE;
            COEFF_TAKE: begin coefficient<=coefficient_q;state<=FLUX_MULT;end
            FLUX_MULT: state<=FLUX_TAKE;
            FLUX_TAKE: begin flux<=delta_negative?-$signed(product):$signed(product);state<=ACCUM;end
            ACCUM: begin
                flux_sum<=flux_sum+$signed({{2{flux[24]}},flux});
                if(direction==3) state<=UPDATE;
                else begin direction<=direction+1'b1;state<=NEIGH_SELECT;end
            end
            UPDATE: begin updated<=new_value[15:0];state<=WRITE_PIXEL;end
            WRITE_PIXEL: state<=NEXT_PIXEL;
            NEXT_PIXEL: if(pixel_index==N-1) state<=ITER_SWAP;
                else begin
                    pixel_index<=pixel_index+1'b1;
                    if(x==WIDTH-1) begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
                    state<=PIX_READ;
                end
            ITER_SWAP: begin
                source_bank<=!source_bank;iteration<=iteration+1'b1;
                pixel_index<=0;x<=0;y<=0;
                if(iteration+1'b1==frame_iterations) state<=OUT_READ;else state<=PIX_READ;
            end
            OUT_READ: state<=OUT_TAKE;
            OUT_TAKE: begin
                m_pixel<=final_rounded[15:8];m_value_q8<=read_q;m_x<=x;m_y<=y;
                m_sof<=(pixel_index==0);m_eol<=(x==WIDTH-1);m_last<=(pixel_index==N-1);
                m_keep<=1;m_errors<=0;m_tag<=frame_tag;state<=OUT_HOLD;
            end
            OUT_HOLD: if(m_ready) begin
                if(pixel_index==N-1) begin capture_index<=0;capture_x<=0;errors<=0;state<=CAPTURE;end
                else begin
                    pixel_index<=pixel_index+1'b1;
                    if(x==WIDTH-1) begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
                    state<=OUT_READ;
                end
            end
            ERROR_HOLD: if(m_ready) begin capture_index<=0;capture_x<=0;errors<=0;state<=CAPTURE;end
            default: state<=CAPTURE;
        endcase
    end
endmodule
