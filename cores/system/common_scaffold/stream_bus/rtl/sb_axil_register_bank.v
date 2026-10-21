// functional_minimal: one outstanding read and write; independent AW/W capture.
// Standard AXI-Lite handshake on every clock. clk_en only gates new requests.
module sb_axil_register_bank #(
    parameter ADDR_WIDTH=16,parameter DATA_WIDTH=32,parameter REG_COUNT=8,
    parameter ERROR_ONLY=0
)(
    input wire clk,rst_n,clk_en,
    input wire [ADDR_WIDTH-1:0] s_axil_awaddr,input wire [2:0] s_axil_awprot,
    input wire s_axil_awvalid,output wire s_axil_awready,
    input wire [DATA_WIDTH-1:0] s_axil_wdata,input wire [DATA_WIDTH/8-1:0] s_axil_wstrb,
    input wire s_axil_wvalid,output wire s_axil_wready,
    output reg [1:0] s_axil_bresp,output reg s_axil_bvalid,input wire s_axil_bready,
    input wire [ADDR_WIDTH-1:0] s_axil_araddr,input wire [2:0] s_axil_arprot,
    input wire s_axil_arvalid,output wire s_axil_arready,
    output reg [DATA_WIDTH-1:0] s_axil_rdata,output reg [1:0] s_axil_rresp,
    output reg s_axil_rvalid,input wire s_axil_rready,
    output wire [REG_COUNT*DATA_WIDTH-1:0] register_values
);
    localparam BYTES=DATA_WIDTH/8;
    localparam SHIFT=$clog2(BYTES);
    reg aw_have,w_have;
    reg [ADDR_WIDTH-1:0] awaddr;
    reg [DATA_WIDTH-1:0] wdata;
    reg [BYTES-1:0] wstrb;
    reg [DATA_WIDTH-1:0] regs [0:REG_COUNT-1];
    integer i,b;
    wire write_legal=!ERROR_ONLY&&((awaddr&(BYTES-1))==0)&&((awaddr>>SHIFT)<REG_COUNT);
    wire read_legal=!ERROR_ONLY&&((s_axil_araddr&(BYTES-1))==0)&&((s_axil_araddr>>SHIFT)<REG_COUNT);
    assign s_axil_awready=rst_n&&clk_en&&!aw_have&&!s_axil_bvalid;
    assign s_axil_wready=rst_n&&clk_en&&!w_have&&!s_axil_bvalid;
    assign s_axil_arready=rst_n&&clk_en&&!s_axil_rvalid;
    genvar g;
    generate for(g=0;g<REG_COUNT;g=g+1) begin: expose
        assign register_values[g*DATA_WIDTH+:DATA_WIDTH]=regs[g];
    end endgenerate
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            aw_have<=0;w_have<=0;awaddr<=0;wdata<=0;wstrb<=0;
            s_axil_bresp<=0;s_axil_bvalid<=0;s_axil_rdata<=0;s_axil_rresp<=0;s_axil_rvalid<=0;
            for(i=0;i<REG_COUNT;i=i+1) regs[i]<=0;
        end else begin
            if(s_axil_bvalid&&s_axil_bready) s_axil_bvalid<=0;
            if(s_axil_rvalid&&s_axil_rready) s_axil_rvalid<=0;
            if(s_axil_awvalid&&s_axil_awready) begin aw_have<=1;awaddr<=s_axil_awaddr;end
            if(s_axil_wvalid&&s_axil_wready) begin w_have<=1;wdata<=s_axil_wdata;wstrb<=s_axil_wstrb;end
            if(aw_have&&w_have&&!s_axil_bvalid) begin
                aw_have<=0;w_have<=0;s_axil_bvalid<=1;
                s_axil_bresp<=write_legal?2'b00:2'b10;
                if(write_legal) for(b=0;b<BYTES;b=b+1)
                    if(wstrb[b]) regs[awaddr>>SHIFT][b*8+:8]<=wdata[b*8+:8];
            end
            if(s_axil_arvalid&&s_axil_arready) begin
                s_axil_rvalid<=1;s_axil_rresp<=read_legal?2'b00:2'b10;
                s_axil_rdata<=read_legal?regs[s_axil_araddr>>SHIFT]:{DATA_WIDTH{1'b0}};
            end
        end
    end
    // AWPROT/ARPROT accepted but no protection filtering in this minimal bank.
    initial if(REG_COUNT<1||(DATA_WIDTH!=32&&DATA_WIDTH!=64)||ADDR_WIDTH<SHIFT+1)
        $fatal(1,"sb_axil_register_bank: DATA_WIDTH 32/64, positive count/address required");
endmodule
