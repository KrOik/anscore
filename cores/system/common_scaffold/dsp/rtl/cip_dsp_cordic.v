// Iterative circular CORDIC, 16 iterations, native shared-CE handshake.
// Coordinates are signed integers; angles are signed radians * 16384.
// Gain is NOT compensated: x/y outputs contain the CORDIC gain (~1.64676).
module cip_dsp_cordic(
    input wire clk, rst_n, clk_en,
    input wire s_valid,
    output wire s_ready,
    input wire s_vectoring, s_last,
    input wire signed [15:0] s_x, s_y,
    input wire signed [17:0] s_z,
    output reg m_valid,
    input wire m_ready,
    output reg m_last,
    output reg signed [19:0] m_x, m_y,
    output reg signed [17:0] m_z
);
reg signed [19:0] x,y,z;
reg [3:0] step;
reg busy,vectoring,packet_last,zero_vector;
wire signed [19:0] x_ext={{4{s_x[15]}},s_x};
wire signed [19:0] y_ext={{4{s_y[15]}},s_y};
wire signed [19:0] z_ext={{2{s_z[17]}},s_z};
function signed [19:0] normalize;
    input signed [19:0] angle;
    begin
        if(angle>20'sd51472) normalize=angle-20'sd102944;
        else if(angle< -20'sd51472) normalize=angle+20'sd102944;
        else normalize=angle;
    end
endfunction
function signed [19:0] atan_lut;
    input [3:0] index;
    begin
        case(index)
        0:atan_lut=12868; 1:atan_lut=7596; 2:atan_lut=4014;
        3:atan_lut=2037; 4:atan_lut=1023; 5:atan_lut=512;
        6:atan_lut=256; 7:atan_lut=128; 8:atan_lut=64;
        9:atan_lut=32; 10:atan_lut=16; 11:atan_lut=8;
        12:atan_lut=4; 13:atan_lut=2; 14:atan_lut=1;
        default:atan_lut=0;
        endcase
    end
endfunction
wire signed [19:0] zn=normalize(z_ext);
wire positive_turn=vectoring ? y<0 : z>=0;
wire signed [19:0] xn=positive_turn ? x-(y>>>step) : x+(y>>>step);
wire signed [19:0] yn=positive_turn ? y+(x>>>step) : y-(x>>>step);
wire signed [19:0] next_z=positive_turn ? z-atan_lut(step) : z+atan_lut(step);
wire signed [19:0] result_z=normalize(zero_vector ? z : next_z);
assign s_ready=!busy && (!m_valid || m_ready);
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        x<=0;y<=0;z<=0;step<=0;busy<=0;vectoring<=0;packet_last<=0;zero_vector<=0;
        m_valid<=0;m_last<=0;m_x<=0;m_y<=0;m_z<=0;
    end else if(clk_en) begin
        if(m_valid && m_ready) m_valid<=0;
        if(s_valid && s_ready) begin
            busy<=1;step<=0;vectoring<=s_vectoring;packet_last<=s_last;
            zero_vector<=s_vectoring && s_x==0 && s_y==0;
            x<=x_ext;y<=y_ext;z<=zn;
            if(s_vectoring) begin
                if(s_x<0) begin
                    x<=-x_ext;y<=-y_ext;
                    z<=zn+(s_y<0 ? -20'sd51472 : 20'sd51472);
                end
            end else if(zn>20'sd25736) begin
                x<=-x_ext;y<=-y_ext;z<=zn-20'sd51472;
            end else if(zn< -20'sd25736) begin
                x<=-x_ext;y<=-y_ext;z<=zn+20'sd51472;
            end
        end else if(busy) begin
            if(!zero_vector) begin x<=xn;y<=yn;z<=next_z; end
            if(step==15) begin
                busy<=0;m_valid<=1;m_last<=packet_last;
                m_x<=zero_vector ? 20'sd0 : xn;
                m_y<=zero_vector ? 20'sd0 : yn;
                // Rotation reports residual angle; vectoring reports phase.
                m_z<=vectoring ? result_z[17:0] : next_z[17:0];
            end else step<=step+1'b1;
        end
    end
end
endmodule
