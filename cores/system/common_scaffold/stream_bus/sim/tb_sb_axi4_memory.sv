`timescale 1ns/1ps
module tb_sb_axi4_memory;
    parameter EXTERNAL_NATIVE=0;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,clk_en=1;
    reg [3:0] awid=0,arid=0;
    reg [15:0] awaddr=0,araddr=0;
    reg [7:0] awlen=0,arlen=0;
    reg [2:0] awsize=2,arsize=2;
    reg [1:0] awburst=1,arburst=1;
    reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0,wlast=0;
    reg [31:0] wdata=0;reg [3:0] wstrb=0;
    wire awready,wready,bvalid,arready,rvalid,rlast,protocol_error;
    wire [3:0] bid,rid;wire [1:0] bresp,rresp;wire [31:0] rdata;
    integer errors=0,cycles=0,requests=0;
    reg [31:0] expected_mem[0:2047];
    wire req_valid,req_ready,req_write,rsp_ready;
    wire [15:0] req_addr;wire [31:0] req_wdata;wire [3:0] req_wstrb;
    reg rsp_valid=0,rsp_error=0,pending=0;reg [31:0] rsp_data=0;
    integer delay_count=0;
    reg [31:0] model_mem[0:2047];
    assign req_ready=rst_n && !pending && !rsp_valid && cycles%5!=1 && cycles%5!=2;
`define AXI_CONNECTIONS \
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en), \
        .s_axi_awid(awid),.s_axi_awaddr(awaddr),.s_axi_awlen(awlen),.s_axi_awsize(awsize),.s_axi_awburst(awburst),.s_axi_awvalid(awvalid),.s_axi_awready(awready), \
        .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wlast(wlast),.s_axi_wvalid(wvalid),.s_axi_wready(wready), \
        .s_axi_bid(bid),.s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready), \
        .s_axi_arid(arid),.s_axi_araddr(araddr),.s_axi_arlen(arlen),.s_axi_arsize(arsize),.s_axi_arburst(arburst),.s_axi_arvalid(arvalid),.s_axi_arready(arready), \
        .s_axi_rid(rid),.s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rlast(rlast),.s_axi_rvalid(rvalid),.s_axi_rready(rready),.protocol_error(protocol_error)
    generate if(EXTERNAL_NATIVE)begin:external_port
        sb_axi4_native_bridge #(.ADDR_WIDTH(16)) dut(`AXI_CONNECTIONS,
            .mem_req_valid(req_valid),.mem_req_ready(req_ready),.mem_req_write(req_write),
            .mem_req_addr(req_addr),.mem_req_wdata(req_wdata),.mem_req_wstrb(req_wstrb),
            .mem_rsp_valid(rsp_valid),.mem_rsp_ready(rsp_ready),.mem_rsp_rdata(rsp_data),.mem_rsp_error(rsp_error));
    end else begin:internal_ram
        sb_axi4_burst_bridge_placeholder #(.ADDR_WIDTH(16),.MEM_WORDS(2048)) dut(`AXI_CONNECTIONS);
        assign req_valid=0;assign req_write=0;assign req_addr=0;assign req_wdata=0;assign req_wstrb=0;assign rsp_ready=0;
    end endgenerate
`undef AXI_CONNECTIONS
    integer lane;
    always @(posedge clk)begin
        cycles<=cycles+1;
        if(protocol_error)errors<=errors+1;
        if(!rst_n)begin rsp_valid<=0;pending<=0;end
        else if(EXTERNAL_NATIVE)begin
            if(rsp_valid && rsp_ready)rsp_valid<=0;
            if(req_valid && req_ready)begin
                requests<=requests+1;pending<=1;delay_count<=cycles%4+1;
                rsp_error<=(req_addr>=8192);
                if(req_addr<8192)begin
                    rsp_data<=model_mem[req_addr>>2];
                    if(req_write)for(lane=0;lane<4;lane=lane+1)
                        if(req_wstrb[lane])model_mem[req_addr>>2][lane*8+:8]<=req_wdata[lane*8+:8];
                end else rsp_data<=0;
            end
            if(pending)begin
                if(delay_count==0)begin pending<=0;rsp_valid<=1;end
                else delay_count<=delay_count-1;
            end
        end
    end
    reg prior_bstall=0,prior_rstall=0,prior_nstall=0;
    reg [5:0] prior_b;
    reg [38:0] prior_r;
    reg [52:0] prior_n;
    always @(posedge clk)if(rst_n)begin
        if(prior_bstall && (!bvalid || {bid,bresp}!==prior_b))$fatal(1,"B unstable under backpressure");
        if(prior_rstall && (!rvalid || {rid,rdata,rresp,rlast}!==prior_r))$fatal(1,"R unstable under backpressure");
        if(prior_nstall && (!req_valid || {req_write,req_addr,req_wdata,req_wstrb}!==prior_n))$fatal(1,"native request changed while stalled");
        prior_bstall<=bvalid&&!bready;prior_b<={bid,bresp};
        prior_rstall<=rvalid&&!rready;prior_r<={rid,rdata,rresp,rlast};
        prior_nstall<=req_valid&&!req_ready;prior_n<={req_write,req_addr,req_wdata,req_wstrb};
    end else begin prior_bstall<=0;prior_rstall<=0;prior_nstall<=0;end
    task send_aw(input integer address,input integer beats,input integer size,input integer burst,input integer ident);
        begin
            @(negedge clk);awaddr=address;awlen=beats-1;awsize=size;awburst=burst;awid=ident;awvalid=1;
            @(posedge clk);while(!awready)@(posedge clk);
            @(negedge clk);awvalid=0;
        end
    endtask
    task send_data(input integer address,input integer beats,input integer burst,input integer seed,
                   input integer strobe,input integer badlast,input integer updates);
        integer k,a,b;reg [31:0] value;
        begin
            for(k=0;k<beats;k=k+1)begin
                repeat(k%3)@(negedge clk);
                @(negedge clk);value=32'h31415926^(seed*32'h01010101)^(k*32'h02030405);
                wdata=value;wstrb=strobe;wlast=(k==beats-1);
                if(badlast==1 && k==0)wlast=1;
                if(badlast==2 && k==beats-1)wlast=0;
                wvalid=1;@(posedge clk);while(!wready)@(posedge clk);
                if(updates)begin
                    a=(address+((burst==1)?k*4:0))/4;
                    if(a<2048)for(b=0;b<4;b=b+1)if(strobe&(1<<b))expected_mem[a][b*8+:8]=value[b*8+:8];
                end
                @(negedge clk);wvalid=0;
            end
        end
    endtask
    task check_b(input integer ident,input integer resp);
        begin
            while(!bvalid)@(negedge clk);
            if(bid!==ident[3:0] || bresp!==resp[1:0])$fatal(1,"B mismatch id=%d resp=%d expected=%d",bid,bresp,resp);
            repeat(4)@(negedge clk);
            bready=1;@(negedge clk);bready=0;
            if(bvalid)$fatal(1,"B response failed to drain");
        end
    endtask
    task write_burst(input integer address,input integer beats,input integer size,input integer burst,
                     input integer seed,input integer strobe,input integer badlast,input integer resp,input integer updates);
        begin
            send_aw(address,beats,size,burst,seed&15);
            // Existing traffic must complete with CE=0; no new AW/AR accepted.
            clk_en=0;send_data(address,beats,burst,seed,strobe,badlast,updates);
            check_b(seed&15,resp);clk_en=1;
        end
    endtask
    task read_burst(input integer address,input integer beats,input integer size,input integer burst,input integer resp,input integer ident);
        integer k,a;reg [31:0] expected;
        begin
            @(negedge clk);araddr=address;arlen=beats-1;arsize=size;arburst=burst;arid=ident;arvalid=1;
            @(posedge clk);while(!arready)@(posedge clk);
            @(negedge clk);arvalid=0;clk_en=0;
            for(k=0;k<beats;k=k+1)begin
                while(!rvalid)@(negedge clk);
                a=(address+((burst==1)?4*k:0))/4;expected=(resp==0)?expected_mem[a]:32'd0;
                if(rdata!==expected || rresp!==resp[1:0] || rid!==ident[3:0] || rlast!==(k==beats-1))
                    $fatal(1,"R mismatch beat=%d addr=%h data=%h expected=%h resp=%d",k,address,rdata,expected,rresp);
                repeat(k%4+1)@(negedge clk);
                rready=1;@(negedge clk);rready=0;
            end
            clk_en=1;
        end
    endtask
    integer i,req_before;
    initial begin
        for(i=0;i<2048;i=i+1)begin expected_mem[i]=0;model_mem[i]=0;end
        repeat(3)@(negedge clk);rst_n=1;
        write_burst(0,1,2,1,1,15,0,0,1);read_burst(0,1,2,1,0,4);
        write_burst(0,1,2,1,2,5,0,0,1);read_burst(0,1,2,1,0,5);
        write_burst(64,4,2,1,3,15,0,0,1);read_burst(64,4,2,1,0,6);
        write_burst(128,16,2,0,4,15,0,0,1);read_burst(128,16,2,0,0,7);
        write_burst(1024,256,2,1,5,15,0,0,1);read_burst(1024,256,2,1,0,8);
        // Simultaneous independent read/write; arbiter alternates native beats.
        fork
            begin send_aw(2048,32,2,1,9);send_data(2048,32,1,9,15,0,1);check_b(9,0);end
            read_burst(1024,32,2,1,0,10);
        join
        clk_en=1;read_burst(2048,32,2,1,0,11);
        write_burst(256,4,2,1,12,15,1,2,1);read_burst(256,4,2,1,0,12);
        write_burst(288,1,2,1,13,15,2,2,1);read_burst(288,1,2,1,0,13);
        if(errors!=2)$fatal(1,"WLAST diagnostic count %d",errors);
        req_before=requests;
        // Unsupported requests drain the exact advertised count without a native access.
        write_burst(0,4,2,2,1,15,0,2,0);read_burst(0,4,2,2,2,1);
        write_burst(1,1,2,1,1,15,0,2,0);read_burst(1,1,2,1,2,1);
        write_burst(0,2,1,1,1,15,0,2,0);read_burst(0,2,1,1,2,1);
        write_burst(4092,2,2,1,1,15,0,2,0);read_burst(4092,2,2,1,2,1);
        write_burst(0,17,2,0,1,15,0,2,0);read_burst(0,17,2,0,2,1);
        if(EXTERNAL_NATIVE && requests!=req_before)$fatal(1,"unsupported burst reached memory");
        read_burst(0,1,2,1,0,2);
        write_burst(8192,2,2,1,1,15,0,2,0);read_burst(8192,2,2,1,2,3);
        // Reset aborts partially received traffic; RAM contents survive.
        send_aw(0,4,2,1,1);@(negedge clk);rst_n=0;#1;
        if(bvalid || rvalid || wready || awready || arready)$fatal(1,"reset did not abort AXI");
        repeat(2)@(negedge clk);rst_n=1;read_burst(0,1,2,1,0,4);
        $display("PASS AXI4 memory native=%d FIXED/INCR byte-strobes IDs stalls CE errors reset",EXTERNAL_NATIVE);$finish;
    end
    initial begin #2000000;$fatal(1,"AXI memory watchdog");end
endmodule
