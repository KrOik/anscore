// ============================================================================
// pwm_gen -- 4-channel PWM generator.
//
// reg_wr/reg_addr/reg_data register port:
//   addr 0        period (clk_en beats per PWM period)
//   addr 1..4     duty for channel 0..3
// Output pwm[i] = en && (cnt < duty[i]); duty==0 -> always low,
// duty==period -> always high. Counter resets while !en.
// All registers clk_en gated; outputs combinational.
// ============================================================================
module pwm_gen #(
    parameter [15:0] PERIOD_D = 16'd100,
    parameter [63:0] DUTY_D   = 64'd0     // {d3,d2,d1,d0}, 16b each
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        reg_wr,
    input  wire [2:0]  reg_addr,
    input  wire [15:0] reg_data,
    input  wire        en,
    output wire [3:0]  pwm
);

reg [15:0] period;
reg [63:0] dutyf;                       // ch i duty at dutyf[16*i +: 16]
reg [15:0] cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        period <= PERIOD_D;
        dutyf  <= DUTY_D;
        cnt    <= 16'd0;
    end else if (clk_en) begin
        if (reg_wr) begin
            case (reg_addr)
                3'd0:    period              <= reg_data;
                3'd1:    dutyf[15:0]         <= reg_data;
                3'd2:    dutyf[31:16]        <= reg_data;
                3'd3:    dutyf[47:32]        <= reg_data;
                3'd4:    dutyf[63:48]        <= reg_data;
                default: ;
            endcase
        end
        if (!en) cnt <= 16'd0;
        else     cnt <= (cnt >= period - 16'd1) ? 16'd0 : cnt + 16'd1;
    end
end

assign pwm[0] = en && (cnt < dutyf[15:0]);
assign pwm[1] = en && (cnt < dutyf[31:16]);
assign pwm[2] = en && (cnt < dutyf[47:32]);
assign pwm[3] = en && (cnt < dutyf[63:48]);

endmodule
