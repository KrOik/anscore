`timescale 1ns/1ps
module tb_sb_axi4_placeholder;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,ce=1,awvalid=0,wvalid=0,wlast=0,bready=0,arvalid=0,rready=0;
    reg [7:0] awlen=0,arlen=0;reg [3:0] awid=0,arid=0;
    wire awready,wready,bvalid,arready,rvalid,rlast,protocol_error;
    wire [3:0] bid,rid;wire [1:0] bresp,rresp;wire [31:0] rdata;
    integer errors=0;
    sb_axi4_burst_bridge_placeholder dut(
        .clk(clk),.rst_n(rst_n),.clk_en(ce),
        .s_axi_awid(awid),.s_axi_awaddr(32'h1000),.s_axi_awlen(awlen),.s_axi_awsize(3'd2),
        .s_axi_awburst(2'b01),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
        .s_axi_wdata(32'h12345678),.s_axi_wstrb(4'hf),.s_axi_wlast(wlast),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
        .s_axi_bid(bid),.s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
        .s_axi_arid(arid),.s_axi_araddr(32'h2000),.s_axi_arlen(arlen),.s_axi_arsize(3'd2),
        .s_axi_arburst(2'b01),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
        .s_axi_rid(rid),.s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rlast(rlast),
        .s_axi_rvalid(rvalid),.s_axi_rready(rready),.protocol_error(protocol_error));
    always @(posedge clk) if(rst_n&&protocol_error) errors=errors+1;
    task write_burst(input integer length,input badlast);
        integer n;
        begin
            @(negedge clk);awlen=length-1;awid=9;awvalid=1;
            @(posedge clk);while(!awready)@(posedge clk);
            @(negedge clk);awvalid=0;
            for(n=0;n<length;n=n+1)begin
                @(negedge clk);wvalid=1;wlast=badlast?(n==0):(n==length-1);
                @(posedge clk);while(!wready)@(posedge clk);
                @(negedge clk);wvalid=0;
            end
            if(!bvalid||bresp!==2||bid!==9)$fatal(1,"burst B");
            ce=0;
            repeat(3)begin @(negedge clk);if(!bvalid||bresp!==2||bid!==9||awready||wready)$fatal(1,"burst B stall");end
            bready=1;@(negedge clk);if(bvalid)$fatal(1,"burst B CE drain");bready=0;ce=1;
        end
    endtask
    task read_burst(input integer length);
        integer n;
        begin
            @(negedge clk);arlen=length-1;arid=6;arvalid=1;
            @(posedge clk);while(!arready)@(posedge clk);
            @(negedge clk);arvalid=0;ce=0;
            for(n=0;n<length;n=n+1)begin
                rready=0;
                repeat(2)begin
                    @(negedge clk);
                    if(!rvalid||rdata!==0||rresp!==2||rid!==6||rlast!==(n==length-1))$fatal(1,"burst R %0d/%0d",n,length);
                end
                rready=1;@(negedge clk);rready=0;
            end
            if(rvalid)$fatal(1,"extra burst R");ce=1;
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        // W may arrive before AW; it remains unaccepted until address exists.
        @(negedge clk);wvalid=1;
        repeat(2)begin @(negedge clk);if(wready||bvalid)$fatal(1,"W before AW");end
        wvalid=0;
        write_burst(1,0);read_burst(1);
        write_burst(4,0);read_burst(4);
        write_burst(4,1);read_burst(256);
        if(errors!=2)$fatal(1,"WLAST error accounting %0d",errors);
        @(negedge clk);awvalid=1;arvalid=1;ce=0;
        repeat(2)begin @(negedge clk);if(awready||arready)$fatal(1,"burst CE input gate");end
        awvalid=0;arvalid=0;rst_n=0;#1;
        if(bvalid||rvalid||awready||arready||wready)$fatal(1,"burst reset");
        $display("PASS AXI4 placeholder: 1/4/256 beats, IDs, SLVERR, WLAST errors, CE/stall/reset");$finish;
    end
    initial begin #100000;$fatal(1,"burst watchdog");end
endmodule
