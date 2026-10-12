// Single outstanding command bridge. Kernel CE must be tied high.
module prod_apb3_adapter(
    input wire clk,rst_n,
    input wire psel,penable,pwrite,
    input wire [7:0] paddr,
    input wire [31:0] pwdata,
    output reg [31:0] prdata,
    output wire pready, output reg pslverr,
    output reg in_valid, input wire in_ready,
    output reg [31:0] a,b,c,
    input wire out_valid, output wire out_ready,
    input wire [31:0] result,aux, input wire fault,
    output wire irq
);
reg busy,complete,failed;
reg [31:0] result_latch,aux_latch,accepted,retired;
wire transfer=psel && penable;
assign pready=1;
assign out_ready=busy && !in_valid;
assign irq=complete;
always @* begin
    prdata=0; pslverr=0;
    if(paddr[1:0]!=0) pslverr=1;
    else case(paddr)
        8'h00: prdata={29'd0,failed,complete,busy};
        8'h04: prdata=a;
        8'h08: prdata=b;
        8'h0c: prdata=c;
        8'h10: prdata=result_latch;
        8'h14: prdata=aux_latch;
        8'h18: prdata=accepted;
        8'h1c: prdata=retired;
        8'h20: prdata=32'h50323501;
        default: pslverr=1;
    endcase
    if(pwrite) begin
        if(paddr!=0 && paddr!=4 && paddr!=8 && paddr!=12) pslverr=1;
        if(busy) pslverr=1;
        if(paddr==0 && pwdata[31:2]!=0) pslverr=1;
    end
    if(!transfer) pslverr=0;
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        a<=0; b<=0; c<=0; in_valid<=0; busy<=0; complete<=0; failed<=0;
        result_latch<=0; aux_latch<=0; accepted<=0; retired<=0;
    end else begin
        if(in_valid && in_ready) begin in_valid<=0; accepted<=accepted+1; end
        if(out_valid && out_ready) begin
            result_latch<=result; aux_latch<=aux; failed<=fault;
            retired<=retired+1; complete<=1; busy<=0;
        end
        if(transfer && pwrite && !pslverr) begin
            case(paddr)
                8'h04: a<=pwdata;
                8'h08: b<=pwdata;
                8'h0c: c<=pwdata;
                8'h00: begin
                    if(pwdata[1]) begin complete<=0; failed<=0; end
                    if(pwdata[0]) begin
                        in_valid<=1; busy<=1; complete<=0; failed<=0;
                    end
                end
            endcase
        end
    end
end
endmodule
