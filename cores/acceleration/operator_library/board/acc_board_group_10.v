// Generated wiring/ROM; expected data comes from the family models.
module acc_board_group_10 #(parameter INJECT_ERROR=0)(
    input wire clk, rst_n,
    output reg done, output reg [7:0] pass_mask,
    output reg [31:0] errors, count, digest, max_latency,
    output reg [31:0] stalled_beats
);
reg [160:0] rom[0:1023];
initial $readmemh("board/group_10.mem",rom);
reg [160:0] word;
reg [9:0] addr;
reg [2:0] state;
reg [3:0] divider;
reg [31:0] beat, issue_beat, watch;
reg [1:0] hold_beats;
wire ce=(divider==15);
wire [2:0] unit=addr[9:7];
wire [31:0] a=word[160:129], b=word[128:97], c=word[96:65];
wire [7:0] ready,valid,err;
wire [255:0] results,auxs;
wire request=(state==2);
wire consume=(state==3 && hold_beats==0);
acc_gf256_poly_eval u0(.clk(clk),.rst_n(rst_n),.clk_en(ce),.in_valid(request && unit==0),.in_ready(ready[0]),.a(a),.b(b),.c(c),.out_valid(valid[0]),.out_ready(consume),.result(results[0+:32]),.aux(auxs[0+:32]),.fault(err[0]));
acc_aes_key_schedule u1(.clk(clk),.rst_n(rst_n),.clk_en(ce),.in_valid(request && unit==1),.in_ready(ready[1]),.a(a),.b(b),.c(c),.out_valid(valid[1]),.out_ready(consume),.result(results[32+:32]),.aux(auxs[32+:32]),.fault(err[1]));
acc_ipi_pid_s12 u2(.clk(clk),.rst_n(rst_n),.clk_en(ce),.in_valid(request && unit==2),.in_ready(ready[2]),.a(a),.b(b),.c(c),.out_valid(valid[2]),.out_ready(consume),.result(results[64+:32]),.aux(auxs[64+:32]),.fault(err[2]));
acc_biquad_df1_s12 u3(.clk(clk),.rst_n(rst_n),.clk_en(ce),.in_valid(request && unit==3),.in_ready(ready[3]),.a(a),.b(b),.c(c),.out_valid(valid[3]),.out_ready(consume),.result(results[96+:32]),.aux(auxs[96+:32]),.fault(err[3]));
acc_karplus_strong u4(.clk(clk),.rst_n(rst_n),.clk_en(ce),.in_valid(request && unit==4),.in_ready(ready[4]),.a(a),.b(b),.c(c),.out_valid(valid[4]),.out_ready(consume),.result(results[128+:32]),.aux(auxs[128+:32]),.fault(err[4]));
acc_r4_bfly_s12 u5(.clk(clk),.rst_n(rst_n),.clk_en(ce),.in_valid(request && unit==5),.in_ready(ready[5]),.a(a),.b(b),.c(c),.out_valid(valid[5]),.out_ready(consume),.result(results[160+:32]),.aux(auxs[160+:32]),.fault(err[5]));
acc_onewire_slot u6(.clk(clk),.rst_n(rst_n),.clk_en(ce),.in_valid(request && unit==6),.in_ready(ready[6]),.a(a),.b(b),.c(c),.out_valid(valid[6]),.out_ready(consume),.result(results[192+:32]),.aux(auxs[192+:32]),.fault(err[6]));
acc_complex_add_sat u7(.clk(clk),.rst_n(rst_n),.clk_en(ce),.in_valid(request && unit==7),.in_ready(ready[7]),.a(a),.b(b),.c(c),.out_valid(valid[7]),.out_ready(consume),.result(results[224+:32]),.aux(auxs[224+:32]),.fault(err[7]));
wire [31:0] result=results[unit*32+:32];
wire [31:0] aux=auxs[unit*32+:32];
wire fault=err[unit];
wire bad=({result,aux,fault}!=word[64:0]) || (INJECT_ERROR && addr==0);
wire [31:0] latency=beat-issue_beat;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        addr<=0; state<=0; divider<=0; done<=0; pass_mask<=255;
        errors<=0; count<=0; digest<=0; max_latency<=0;
        stalled_beats<=0; beat<=0; issue_beat<=0; hold_beats<=0;
        word<=0; watch<=0;
    end else begin
        divider<=divider+1'b1;
        if(!done) begin
            watch<=watch+1;
            if(watch==32'd2000000) begin
                done<=1; errors<=errors+1; pass_mask<=0; state<=4;
            end else case(state)
                0: begin word<=rom[addr]; state<=1; end
                1: if(ce) state<=2;
                2: if(ce && ready[unit]) begin
                    issue_beat<=beat; hold_beats<=addr[1:0]; state<=3;
                end
                3: if(ce) begin
                    if(hold_beats!=0) begin
                        hold_beats<=hold_beats-1'b1;
                        if(valid[unit]) stalled_beats<=stalled_beats+1;
                    end else if(valid[unit]) begin
                        count<=count+1;
                        digest<={digest[30:0],digest[31]}^result^{aux[24:0],aux[31:25]}^{31'd0,fault};
                        if(latency>max_latency) max_latency<=latency;
                        if(bad) begin errors<=errors+1; pass_mask[unit]<=0; end
                        if(addr==1023) begin done<=1; state<=4; end
                        else begin addr<=addr+1'b1; state<=0; end
                    end
                end
                default: state<=4;
            endcase
        end
        if(ce) beat<=beat+1;
    end
end
endmodule
