// Radix-2 DIT block FFT/IFFT, natural input/output order, 2..256 points.
// Single serial multiplier and synchronous single-port complex state RAM.
// Forward is unscaled; inverse is divided by N on output, rounding down.
module cip_dsp_fft #(
    parameter integer DATA_W=16, LOG_N=6,
    parameter integer OUT_W=DATA_W+LOG_N+2
)(
    input wire clk,rst_n,clk_en,
    input wire s_valid,
    output wire s_ready,
    input wire s_inverse,s_last,
    input wire signed [DATA_W-1:0] s_re,s_im,
    output reg m_valid,
    input wire m_ready,
    output reg m_last,m_error,
    output reg signed [OUT_W-1:0] m_re,m_im
);
localparam integer N=1<<LOG_N, IW=OUT_W, PW=IW+17;
localparam LOAD=0,READ_A=1,CAP_A=2,CAP_B=3,MUL_SETUP=4,MUL_PART=5,MUL_JOIN=6,MUL_APPLY=7,
 SCALE_REAL=8,SCALE_IMAG=9,WRITE_A=10,WRITE_B=11,OUT_READ=12,OUT_CAPTURE=13,OUT_HOLD=14,ERROR_HOLD=15,MUL_JOIN_FINAL=16;
reg [4:0] state;
reg [LOG_N-1:0] load_index,bf,out_index;
reg [3:0] stage;
reg inverse;
reg signed [IW-1:0] ar,ai,br,bi,tr,ti;
reg signed [PW-1:0] saved_product;
wire [31:0] half=32'd1<<(stage-1);
wire [31:0] position=bf & (half-1);
wire [LOG_N-1:0] addr_a=((bf>>(stage-1))<<stage)|position;
wire [LOG_N-1:0] addr_b=addr_a+half;
wire [6:0] twiddle_addr=position<<(8-stage);
wire signed [16:0] wr,wi_forward;
cip_dsp_fft_twiddle twiddle(twiddle_addr,wr,wi_forward);
wire signed [16:0] wi=inverse ? -wi_forward : wi_forward;
// Four registered IW x5 partial products, followed by two registered joins.
// Unsigned low nibbles and signed high five bits preserve the exact IW x17 product.
localparam PART_W=IW+5;
reg [1:0] mul_index;
reg signed [IW-1:0] mul_a;
reg signed [16:0] mul_b;
reg signed [PART_W-1:0] p0,p1,p2,p3;
reg signed [PW-1:0] join_low,join_high,product_reg;
reg signed [PW:0] complex_product;
wire signed [PW-1:0] e0={{(PW-PART_W){p0[PART_W-1]}},p0};
wire signed [PW-1:0] e1={{(PW-PART_W){p1[PART_W-1]}},p1};
wire signed [PW-1:0] e2={{(PW-PART_W){p2[PART_W-1]}},p2};
wire signed [PW-1:0] e3={{(PW-PART_W){p3[PART_W-1]}},p3};
wire signed [PW:0] saved_ext={saved_product[PW-1],saved_product};
wire signed [PW:0] product_ext={product_reg[PW-1],product_reg};
function [LOG_N-1:0] reverse_bits;
    input [LOG_N-1:0] address;
    integer j;
    begin for(j=0;j<LOG_N;j=j+1) reverse_bits[j]=address[LOG_N-1-j];end
endfunction
wire bad_length=s_last!=(load_index==N-1);
wire signed [IW-1:0] load_re=s_re,load_im=s_im;
wire signed [IW-1:0] add_re=ar+tr,add_im=ai+ti;
wire signed [IW-1:0] sub_re=ar-tr,sub_im=ai-ti;
wire ram_we=(state==LOAD && s_valid && !bad_length)||state==WRITE_A||state==WRITE_B;
wire ram_re=state==READ_A||state==CAP_A||state==OUT_READ;
wire [LOG_N-1:0] waddr=state==LOAD ? reverse_bits(load_index) : state==WRITE_A ? addr_a : addr_b;
wire [LOG_N-1:0] raddr=state==OUT_READ ? out_index : state==READ_A ? addr_a : addr_b;
wire [2*IW-1:0] wdata=state==LOAD ? {load_re,load_im} : state==WRITE_A ? {add_re,add_im} : {sub_re,sub_im};
reg [2*IW-1:0] memory [0:N-1];
reg [2*IW-1:0] q;
wire signed [IW-1:0] q_re=q[2*IW-1:IW],q_im=q[IW-1:0];
// No reset on coefficient/state RAM: every complete input block overwrites it.
always @(posedge clk) if(clk_en) begin
    if(ram_we && rst_n) memory[waddr]<=wdata;
    if(ram_re) q<=memory[raddr];
end
assign s_ready=state==LOAD;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state<=LOAD;load_index<=0;bf<=0;out_index<=0;stage<=1;inverse<=0;
        ar<=0;ai<=0;br<=0;bi<=0;tr<=0;ti<=0;saved_product<=0;mul_index<=0;mul_a<=0;mul_b<=0;p0<=0;p1<=0;p2<=0;p3<=0;join_low<=0;join_high<=0;product_reg<=0;complex_product<=0;
        m_valid<=0;m_last<=0;m_error<=0;m_re<=0;m_im<=0;
    end else if(clk_en) begin
        case(state)
        LOAD: if(s_valid) begin
            if(load_index==0) inverse<=s_inverse;
            if(bad_length) begin
                m_valid<=1;m_last<=1;m_error<=1;m_re<=0;m_im<=0;
                state<=ERROR_HOLD;load_index<=0;
            end else if(load_index==N-1) begin
                stage<=1;bf<=0;state<=READ_A;
            end else load_index<=load_index+1'b1;
        end
        READ_A:state<=CAP_A;
        CAP_A:begin ar<=q_re;ai<=q_im;state<=CAP_B;end
        CAP_B:begin br<=q_re;bi<=q_im;mul_index<=0;state<=MUL_SETUP;end
        MUL_SETUP:begin
            case(mul_index)
             0:begin mul_a<=br;mul_b<=wr;end
             1:begin mul_a<=bi;mul_b<=wi;end
             2:begin mul_a<=br;mul_b<=wi;end
             3:begin mul_a<=bi;mul_b<=wr;end
            endcase
            state<=MUL_PART;
        end
        MUL_PART:begin
            p0<=mul_a*$signed({1'b0,mul_b[3:0]});
            p1<=mul_a*$signed({1'b0,mul_b[7:4]});
            p2<=mul_a*$signed({1'b0,mul_b[11:8]});
            p3<=mul_a*$signed(mul_b[16:12]);state<=MUL_JOIN;
        end
        MUL_JOIN:begin join_low<=e0+(e1<<<4);join_high<=e2+(e3<<<4);state<=MUL_JOIN_FINAL;end
        MUL_JOIN_FINAL:begin product_reg<=join_low+(join_high<<<8);state<=MUL_APPLY;end
        MUL_APPLY:begin
            case(mul_index)
             0:begin saved_product<=product_reg;mul_index<=1;state<=MUL_SETUP;end
             1:begin complex_product<=saved_ext-product_ext;state<=SCALE_REAL;end
             2:begin saved_product<=product_reg;mul_index<=3;state<=MUL_SETUP;end
             3:begin complex_product<=saved_ext+product_ext;state<=SCALE_IMAG;end
            endcase
        end
        SCALE_REAL:begin tr<=complex_product>>>15;mul_index<=2;state<=MUL_SETUP;end
        SCALE_IMAG:begin ti<=complex_product>>>15;state<=WRITE_A;end
        WRITE_A:state<=WRITE_B;
        WRITE_B:begin
            if(bf==N/2-1) begin
                bf<=0;
                if(stage==LOG_N) begin out_index<=0;state<=OUT_READ;end
                else begin stage<=stage+1'b1;state<=READ_A;end
            end else begin bf<=bf+1'b1;state<=READ_A;end
        end
        OUT_READ:state<=OUT_CAPTURE;
        OUT_CAPTURE:begin
            m_re<=inverse ? q_re>>>LOG_N : q_re;
            m_im<=inverse ? q_im>>>LOG_N : q_im;
            m_error<=0;m_last<=out_index==N-1;m_valid<=1;state<=OUT_HOLD;
        end
        OUT_HOLD:if(m_ready) begin
            m_valid<=0;
            if(m_last) begin state<=LOAD;load_index<=0;end
            else begin out_index<=out_index+1'b1;state<=OUT_READ;end
        end
        ERROR_HOLD:if(m_ready) begin m_valid<=0;state<=LOAD;end
        default:state<=LOAD;
        endcase
    end
end
endmodule
