// Bounded AXI4 burst to one-outstanding native memory port.
// Native addresses are BYTE addresses; every accepted request needs one response.
// AXI AW/AR acceptance is CE-gated. Once accepted, all channels run every clock.
module sb_axi4_native_bridge #(
    parameter ADDR_WIDTH=32, DATA_WIDTH=32, ID_WIDTH=4
)(
    input wire clk,rst_n,clk_en,
    input wire [ID_WIDTH-1:0] s_axi_awid,input wire [ADDR_WIDTH-1:0] s_axi_awaddr,
    input wire [7:0] s_axi_awlen,input wire [2:0] s_axi_awsize,input wire [1:0] s_axi_awburst,
    input wire s_axi_awvalid,output wire s_axi_awready,
    input wire [DATA_WIDTH-1:0] s_axi_wdata,input wire [DATA_WIDTH/8-1:0] s_axi_wstrb,
    input wire s_axi_wlast,s_axi_wvalid,output wire s_axi_wready,
    output reg [ID_WIDTH-1:0] s_axi_bid,output reg [1:0] s_axi_bresp,
    output reg s_axi_bvalid,input wire s_axi_bready,
    input wire [ID_WIDTH-1:0] s_axi_arid,input wire [ADDR_WIDTH-1:0] s_axi_araddr,
    input wire [7:0] s_axi_arlen,input wire [2:0] s_axi_arsize,input wire [1:0] s_axi_arburst,
    input wire s_axi_arvalid,output wire s_axi_arready,
    output reg [ID_WIDTH-1:0] s_axi_rid,output reg [DATA_WIDTH-1:0] s_axi_rdata,
    output reg [1:0] s_axi_rresp,output wire s_axi_rlast,
    output reg s_axi_rvalid,input wire s_axi_rready,output reg protocol_error,
    output wire mem_req_valid,input wire mem_req_ready,output reg mem_req_write,
    output reg [ADDR_WIDTH-1:0] mem_req_addr,output reg [DATA_WIDTH-1:0] mem_req_wdata,
    output reg [DATA_WIDTH/8-1:0] mem_req_wstrb,
    input wire mem_rsp_valid,output wire mem_rsp_ready,
    input wire [DATA_WIDTH-1:0] mem_rsp_rdata,input wire mem_rsp_error
);
    localparam BYTES=DATA_WIDTH/8, SIZE=$clog2(BYTES);
    localparam N_IDLE=0,N_SEND=1,N_WAIT=2;
    reg write_active,write_bad,write_error,write_buffer,write_incr;
    reg [ADDR_WIDTH-1:0] write_addr,read_addr;
    reg [DATA_WIDTH-1:0] write_data;
    reg [BYTES-1:0] write_strb;
    reg [7:0] write_left,read_left;
    reg read_active,read_bad,read_incr;
    reg [1:0] native_state;
    reg native_owner_write,prefer_read;
    function unsupported;
        input [ADDR_WIDTH-1:0] addr;
        input [7:0] len;
        input [2:0] size;
        input [1:0] burst;
        reg [63:0] first_byte,last_byte;
        begin
            first_byte=addr;
            last_byte=first_byte+((burst==2'b01)?((len+64'd1)*BYTES):BYTES)-1;
            unsupported=(size!=SIZE || (addr & (BYTES-1))!=0 || burst>2'b01 ||
                         (burst==0 && len>15) || (first_byte>>12)!=(last_byte>>12) ||
                         (last_byte>>ADDR_WIDTH)!=0);
        end
    endfunction
    assign s_axi_awready=rst_n && clk_en && !write_active && !s_axi_bvalid;
    // A W beat is accepted only after its AW, including during CE=0.
    assign s_axi_wready=rst_n && write_active && !write_buffer;
    assign s_axi_arready=rst_n && clk_en && !read_active && !s_axi_rvalid;
    assign s_axi_rlast=(read_left==0);
    assign mem_req_valid=rst_n && native_state==N_SEND;
    assign mem_rsp_ready=rst_n && native_state==N_WAIT;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            write_active<=0;write_bad<=0;write_error<=0;write_buffer<=0;write_incr<=0;
            write_addr<=0;write_data<=0;write_strb<=0;write_left<=0;
            read_active<=0;read_bad<=0;read_incr<=0;read_addr<=0;read_left<=0;
            s_axi_bid<=0;s_axi_bresp<=0;s_axi_bvalid<=0;s_axi_rid<=0;
            s_axi_rdata<=0;s_axi_rresp<=0;s_axi_rvalid<=0;protocol_error<=0;
            native_state<=N_IDLE;native_owner_write<=0;prefer_read<=0;
            mem_req_write<=0;mem_req_addr<=0;mem_req_wdata<=0;mem_req_wstrb<=0;
        end else begin
            protocol_error<=0;
            if(s_axi_bvalid && s_axi_bready)s_axi_bvalid<=0;
            if(s_axi_awvalid && s_axi_awready)begin
                write_active<=1;write_addr<=s_axi_awaddr;write_left<=s_axi_awlen;
                write_incr<=(s_axi_awburst==1);s_axi_bid<=s_axi_awid;write_error<=0;
                write_bad<=unsupported(s_axi_awaddr,s_axi_awlen,s_axi_awsize,s_axi_awburst);
            end
            if(s_axi_wvalid && s_axi_wready)begin
                if(s_axi_wlast!=(write_left==0))begin protocol_error<=1;write_error<=1;end
                if(write_bad)begin
                    if(write_left==0)begin write_active<=0;s_axi_bvalid<=1;s_axi_bresp<=2'b10;end
                    else write_left<=write_left-1'b1;
                end else begin write_buffer<=1;write_data<=s_axi_wdata;write_strb<=s_axi_wstrb;end
            end
            if(s_axi_arvalid && s_axi_arready)begin
                read_active<=1;read_addr<=s_axi_araddr;read_left<=s_axi_arlen;
                read_incr<=(s_axi_arburst==1);s_axi_rid<=s_axi_arid;
                read_bad<=unsupported(s_axi_araddr,s_axi_arlen,s_axi_arsize,s_axi_arburst);
            end
            if(read_active && read_bad && !s_axi_rvalid)begin
                s_axi_rvalid<=1;s_axi_rdata<=0;s_axi_rresp<=2'b10;
            end
            if(s_axi_rvalid && s_axi_rready)begin
                s_axi_rvalid<=0;
                if(read_left==0)read_active<=0;
                else begin read_left<=read_left-1'b1;if(read_incr)read_addr<=read_addr+BYTES;end
            end
            case(native_state)
            N_IDLE:begin
                // Register the entire request before asserting VALID: it cannot
                // change if the other AXI direction arrives during a stall.
                if(write_buffer && (!(read_active && !read_bad && !s_axi_rvalid) || !prefer_read))begin
                    native_owner_write<=1;mem_req_write<=1;mem_req_addr<=write_addr;
                    mem_req_wdata<=write_data;mem_req_wstrb<=write_strb;native_state<=N_SEND;
                end else if(read_active && !read_bad && !s_axi_rvalid)begin
                    native_owner_write<=0;mem_req_write<=0;mem_req_addr<=read_addr;
                    mem_req_wdata<=0;mem_req_wstrb<=0;native_state<=N_SEND;
                end
            end
            N_SEND:if(mem_req_ready)native_state<=N_WAIT;
            N_WAIT:if(mem_rsp_valid)begin
                native_state<=N_IDLE;prefer_read<=native_owner_write;
                if(native_owner_write)begin
                    write_buffer<=0;
                    if(mem_rsp_error)write_error<=1;
                    if(write_left==0)begin
                        write_active<=0;s_axi_bvalid<=1;
                        s_axi_bresp<=(write_error || mem_rsp_error)?2'b10:2'b00;
                    end else begin write_left<=write_left-1'b1;if(write_incr)write_addr<=write_addr+BYTES;end
                end else begin
                    s_axi_rvalid<=1;s_axi_rdata<=mem_rsp_error?{DATA_WIDTH{1'b0}}:mem_rsp_rdata;
                    s_axi_rresp<=mem_rsp_error?2'b10:2'b00;
                end
            end
            default:native_state<=N_IDLE;
            endcase
        end
    end
    initial if(ADDR_WIDTH<1 || ADDR_WIDTH>32 || DATA_WIDTH<8 || DATA_WIDTH>1024 ||
        DATA_WIDTH%8 || (BYTES & (BYTES-1))!=0 || ID_WIDTH<1)
        $fatal(1,"sb_axi4_native_bridge: power-of-two byte width and ADDR_WIDTH<=32 required");
endmodule
