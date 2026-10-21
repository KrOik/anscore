// Functional one-initiator AXI-Lite address crossbar (legacy module name).
// Uniform power-of-two windows, stripped local addresses; independent AW/W.
// CE gates NEW upstream requests only. Buffered AXI traffic runs every clock.
module sb_axil_crossbar_placeholder #(
    parameter ADDR_WIDTH=16,parameter DATA_WIDTH=32,parameter PORTS=4,
    parameter REGION_ADDR_BITS=ADDR_WIDTH-((PORTS>1)?$clog2(PORTS):0)
)(
    input wire clk,rst_n,clk_en,
    input wire [ADDR_WIDTH-1:0] s_axil_awaddr,input wire [2:0] s_axil_awprot,
    input wire s_axil_awvalid,output wire s_axil_awready,
    input wire [DATA_WIDTH-1:0] s_axil_wdata,input wire [DATA_WIDTH/8-1:0] s_axil_wstrb,
    input wire s_axil_wvalid,output wire s_axil_wready,
    output wire [1:0] s_axil_bresp,output wire s_axil_bvalid,input wire s_axil_bready,
    input wire [ADDR_WIDTH-1:0] s_axil_araddr,input wire [2:0] s_axil_arprot,
    input wire s_axil_arvalid,output wire s_axil_arready,
    output wire [DATA_WIDTH-1:0] s_axil_rdata,output wire [1:0] s_axil_rresp,
    output wire s_axil_rvalid,input wire s_axil_rready,
    output wire [PORTS*ADDR_WIDTH-1:0] m_axil_awaddr,output wire [PORTS*3-1:0] m_axil_awprot,
    output wire [PORTS-1:0] m_axil_awvalid,input wire [PORTS-1:0] m_axil_awready,
    output wire [PORTS*DATA_WIDTH-1:0] m_axil_wdata,output wire [PORTS*(DATA_WIDTH/8)-1:0] m_axil_wstrb,
    output wire [PORTS-1:0] m_axil_wvalid,input wire [PORTS-1:0] m_axil_wready,
    input wire [PORTS*2-1:0] m_axil_bresp,input wire [PORTS-1:0] m_axil_bvalid,
    output wire [PORTS-1:0] m_axil_bready,
    output wire [PORTS*ADDR_WIDTH-1:0] m_axil_araddr,output wire [PORTS*3-1:0] m_axil_arprot,
    output wire [PORTS-1:0] m_axil_arvalid,input wire [PORTS-1:0] m_axil_arready,
    input wire [PORTS*DATA_WIDTH-1:0] m_axil_rdata,input wire [PORTS*2-1:0] m_axil_rresp,
    input wire [PORTS-1:0] m_axil_rvalid,output wire [PORTS-1:0] m_axil_rready
);
    localparam STRB_WIDTH=DATA_WIDTH/8;
    reg aw_hold,w_hold,write_busy,aw_pending,w_pending;
    reg [ADDR_WIDTH-1:0] awaddr_reg,araddr_reg;
    reg [2:0] awprot_reg,arprot_reg;
    reg [DATA_WIDTH-1:0] wdata_reg,rdata_reg;
    reg [STRB_WIDTH-1:0] wstrb_reg;
    reg [1:0] bresp_reg,rresp_reg,read_state;
    reg bvalid_reg,rvalid_reg;
    integer write_select,read_select;
    wire write_sending=write_busy && (aw_pending || w_pending);
    wire write_waiting=write_busy && !aw_pending && !w_pending;
    assign s_axil_awready=rst_n && clk_en && !aw_hold && !write_busy && !bvalid_reg;
    assign s_axil_wready=rst_n && clk_en && !w_hold && !write_busy && !bvalid_reg;
    assign s_axil_bvalid=bvalid_reg;assign s_axil_bresp=bresp_reg;
    assign s_axil_arready=rst_n && clk_en && read_state==0 && !rvalid_reg;
    assign s_axil_rvalid=rvalid_reg;assign s_axil_rdata=rdata_reg;assign s_axil_rresp=rresp_reg;
    genvar k;
    generate for(k=0;k<PORTS;k=k+1)begin:ports
        assign m_axil_awaddr[k*ADDR_WIDTH+:ADDR_WIDTH]=awaddr_reg;
        assign m_axil_awprot[k*3+:3]=awprot_reg;
        assign m_axil_awvalid[k]=rst_n && write_sending && aw_pending && write_select==k;
        assign m_axil_wdata[k*DATA_WIDTH+:DATA_WIDTH]=wdata_reg;
        assign m_axil_wstrb[k*STRB_WIDTH+:STRB_WIDTH]=wstrb_reg;
        assign m_axil_wvalid[k]=rst_n && write_sending && w_pending && write_select==k;
        assign m_axil_bready[k]=rst_n && write_waiting && write_select==k;
        assign m_axil_araddr[k*ADDR_WIDTH+:ADDR_WIDTH]=araddr_reg;
        assign m_axil_arprot[k*3+:3]=arprot_reg;
        assign m_axil_arvalid[k]=rst_n && read_state==1 && read_select==k;
        assign m_axil_rready[k]=rst_n && read_state==2 && read_select==k;
    end endgenerate
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            aw_hold<=0;w_hold<=0;write_busy<=0;aw_pending<=0;w_pending<=0;
            awaddr_reg<=0;araddr_reg<=0;awprot_reg<=0;arprot_reg<=0;
            wdata_reg<=0;wstrb_reg<=0;rdata_reg<=0;bresp_reg<=0;rresp_reg<=0;
            bvalid_reg<=0;rvalid_reg<=0;read_state<=0;write_select<=0;read_select<=0;
        end else begin
            if(bvalid_reg && s_axil_bready)bvalid_reg<=0;
            if(rvalid_reg && s_axil_rready)rvalid_reg<=0;
            if(s_axil_awvalid && s_axil_awready)begin
                aw_hold<=1;write_select<=s_axil_awaddr>>REGION_ADDR_BITS;
                awaddr_reg<=s_axil_awaddr & ({ADDR_WIDTH{1'b1}}>>(ADDR_WIDTH-REGION_ADDR_BITS));
                awprot_reg<=s_axil_awprot;
            end
            if(s_axil_wvalid && s_axil_wready)begin w_hold<=1;wdata_reg<=s_axil_wdata;wstrb_reg<=s_axil_wstrb;end
            if(aw_hold && w_hold && !write_busy && !bvalid_reg)begin
                aw_hold<=0;w_hold<=0;
                if(write_select>=PORTS)begin bvalid_reg<=1;bresp_reg<=2'b11;end
                else begin write_busy<=1;aw_pending<=1;w_pending<=1;end
            end
            if(write_sending)begin
                if(aw_pending && m_axil_awready[write_select])aw_pending<=0;
                if(w_pending && m_axil_wready[write_select])w_pending<=0;
            end
            if(write_waiting && m_axil_bvalid[write_select])begin
                bvalid_reg<=1;bresp_reg<=m_axil_bresp[write_select*2+:2];write_busy<=0;
            end
            if(s_axil_arvalid && s_axil_arready)begin
                read_select<=s_axil_araddr>>REGION_ADDR_BITS;
                araddr_reg<=s_axil_araddr & ({ADDR_WIDTH{1'b1}}>>(ADDR_WIDTH-REGION_ADDR_BITS));
                arprot_reg<=s_axil_arprot;
                if((s_axil_araddr>>REGION_ADDR_BITS)>=PORTS)begin
                    rvalid_reg<=1;rresp_reg<=2'b11;rdata_reg<=0;
                end else read_state<=1;
            end
            if(read_state==1 && m_axil_arready[read_select])read_state<=2;
            if(read_state==2 && m_axil_rvalid[read_select])begin
                rdata_reg<=m_axil_rdata[read_select*DATA_WIDTH+:DATA_WIDTH];
                rresp_reg<=m_axil_rresp[read_select*2+:2];rvalid_reg<=1;read_state<=0;
            end
        end
    end
    initial if(PORTS<1 || ADDR_WIDTH<1 || ADDR_WIDTH>32 || DATA_WIDTH<8 || DATA_WIDTH%8 ||
        REGION_ADDR_BITS<1 || REGION_ADDR_BITS>ADDR_WIDTH ||
        PORTS>(64'd1<<(ADDR_WIDTH-REGION_ADDR_BITS)))
        $fatal(1,"sb_axil_crossbar_placeholder: invalid parameters");
endmodule
