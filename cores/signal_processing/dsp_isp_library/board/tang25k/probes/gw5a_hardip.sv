// Throwaway probe: what does synth_gowin -family gw5a actually infer on
// GW5A-LV25MG121NES?  Each construct is isolated so yosys `stat` and the
// nextpnr device-utilisation table can be read per feature instead of as one
// blended number.  Not a deliverable core.
`default_nettype none

module mul12(input wire clk, input wire signed [11:0] a, input wire signed [11:0] b,
             output reg signed [23:0] p);
    always @(posedge clk) p <= a * b;
endmodule

module mul18(input wire clk, input wire signed [17:0] a, input wire signed [17:0] b,
             output reg signed [35:0] p);
    always @(posedge clk) p <= a * b;
endmodule

// mul then add in the same cycle: candidate for the DSP pre-adder
// (MULTADDALU12X12 / MULTALU27X18)
module mac12(input wire clk, input wire signed [11:0] a, input wire signed [11:0] b,
             input wire signed [11:0] c, output reg signed [24:0] y);
    always @(posedge clk) y <= a * b + c;
endmodule

module sp256x16(input wire clk, input wire en, input wire we,
                input wire [7:0] addr, input wire [15:0] din,
                output reg [15:0] dout);
    reg [15:0] mem [0:255];
    always @(posedge clk) begin
        if (en) begin
            if (we) mem[addr] <= din;
            dout <= mem[addr];
        end
    end
endmodule

module dp1024x16(input wire clk,
                 input wire wea, input wire [9:0] addra, input wire [15:0] dina,
                 input wire enb, input wire [9:0] addrb, output reg [15:0] dinb,
                 output reg [15:0] douta);
    reg [15:0] mem [0:1023];
    always @(posedge clk) begin
        if (wea) mem[addra] <= dina;
        douta <= mem[addra];
    end
    always @(posedge clk) if (enb) dinb <= mem[addrb];
endmodule

module gw5a_hardip(input wire clk, input wire rst_n, output wire [1:0] mon);
    // drive every instance from a small counter so nothing is pruned
    reg [17:0] cnt = 18'd0;
    always @(posedge clk) if (!rst_n) cnt <= 18'd0; else cnt <= cnt + 18'd1;

    wire signed [23:0] p12; wire signed [35:0] p18; wire signed [24:0] ymac;
    wire [15:0] rd16; wire [15:0] rd16b; wire [15:0] rd16a;

    mul12   u12 (.clk(clk), .a(cnt[11:0]), .b(~cnt[11:0]), .p(p12));
    mul18   u18 (.clk(clk), .a(cnt), .b(cnt ^ 18'h2b5), .p(p18));
    mac12   umac(.clk(clk), .a(cnt[11:0]), .b(cnt[11:0]), .c(cnt[11:0]), .y(ymac));

    sp256x16 u_ram (.clk(clk), .en(1'b1), .we(cnt[0]), .addr(cnt[7:0]),
                    .din(cnt[15:0]), .dout(rd16));
    dp1024x16 u_dp (.clk(clk), .wea(cnt[1]), .addra(cnt[9:0]), .dina(cnt[15:0]),
                    .enb(1'b1), .addrb(cnt[9:0] ^ 10'd7), .dinb(rd16b), .douta(rd16a));

    // XOR-reduce keeps EVERY product bit live; a bit-slice would let wreduce
// shrink the multiplier to 1x1 and hide the very cell we are probing.
wire [3:0] g = {^p12, ^p18, ^ymac, ^rd16};
wire [3:0] h = {^rd16b, ^rd16a, ^cnt, ~(^cnt)};
assign mon = g ^ h;
endmodule
