`timescale 1ns/1ps
`define AXIL_PORTS \
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en), \
 .s_axil_awaddr(awaddr),.s_axil_awprot(3'b0),.s_axil_awvalid(awvalid),.s_axil_awready(awready), \
 .s_axil_wdata(wdata),.s_axil_wstrb(wstrb),.s_axil_wvalid(wvalid),.s_axil_wready(wready), \
 .s_axil_bresp(bresp),.s_axil_bvalid(bvalid),.s_axil_bready(bready), \
 .s_axil_araddr(araddr),.s_axil_arprot(3'b0),.s_axil_arvalid(arvalid),.s_axil_arready(arready), \
 .s_axil_rdata(rdata),.s_axil_rresp(rresp),.s_axil_rvalid(rvalid),.s_axil_rready(rready)
module tb_sb_axil;
    parameter PLACEHOLDER=0;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,clk_en=1;
    reg [15:0] awaddr=0,araddr=0;reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
    reg [31:0] wdata=0;reg [3:0] wstrb=0;
    wire awready,wready,bvalid,arready,rvalid;wire [1:0] bresp,rresp;wire [31:0] rdata;
    wire [3:0] forward_awvalid,forward_wvalid,forward_arvalid,forward_bready,forward_rready;
    generate if(PLACEHOLDER) begin: stub
        sb_axil_crossbar_placeholder dut(`AXIL_PORTS,
            .m_axil_awvalid(forward_awvalid),.m_axil_wvalid(forward_wvalid),.m_axil_arvalid(forward_arvalid),
            .m_axil_bready(forward_bready),.m_axil_rready(forward_rready),
            .m_axil_awready(4'b1111),.m_axil_wready(4'b1111),.m_axil_arready(4'b1111),
            .m_axil_bvalid(4'b1111),.m_axil_rvalid(4'b1111),.m_axil_bresp(8'b0),
            .m_axil_rresp(8'b0),.m_axil_rdata(128'b0));
    end else begin: bank
        sb_axil_register_bank #(.REG_COUNT(4)) dut(`AXIL_PORTS,.register_values());
        assign forward_awvalid=0;assign forward_wvalid=0;assign forward_arvalid=0;
        assign forward_bready=0;assign forward_rready=0;
    end endgenerate
    always @(posedge clk) if(rst_n&&PLACEHOLDER)
        if(|{forward_awvalid,forward_wvalid,forward_arvalid,forward_bready,forward_rready})
            $fatal(1,"placeholder forwarded a transaction");
    task send_aw(input [15:0] address);
        begin
            @(negedge clk);awaddr=address;awvalid=1;
            @(posedge clk);while(!awready) @(posedge clk);
            @(negedge clk);awvalid=0;
        end
    endtask
    task send_w(input [31:0] data,input [3:0] strobe);
        begin
            @(negedge clk);wdata=data;wstrb=strobe;wvalid=1;
            @(posedge clk);while(!wready) @(posedge clk);
            @(negedge clk);wvalid=0;
        end
    endtask
    task check_b(input [1:0] response);
        integer t;
        begin
            t=0;while(!bvalid) begin @(negedge clk);t=t+1;if(t>20)$fatal(1,"B timeout");end
            if(bresp!==response) $fatal(1,"B response got=%b expected=%b",bresp,response);
            clk_en=0;
            repeat(3) begin @(negedge clk);if(!bvalid||bresp!==response||awready||wready||arready)$fatal(1,"B/CE stall");end
            bready=1;@(negedge clk);if(bvalid)$fatal(1,"B must drain with CE=0");
            bready=0;clk_en=1;
        end
    endtask
    task read_check(input [15:0] address,input [31:0] expected,input [1:0] response);
        begin
            @(negedge clk);araddr=address;arvalid=1;
            @(posedge clk);while(!arready) @(posedge clk);
            @(negedge clk);arvalid=0;
            if(!rvalid||rdata!==expected||rresp!==response)$fatal(1,"R mismatch addr=%h data=%h",address,rdata);
            clk_en=0;
            repeat(3)begin @(negedge clk);if(!rvalid||rdata!==expected||rresp!==response)$fatal(1,"R stall");end
            rready=1;@(negedge clk);if(rvalid)$fatal(1,"R must drain with CE=0");
            rready=0;clk_en=1;
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        // AW and W are accepted independently, in either order.
        send_aw(4);repeat(2)@(negedge clk);if(bvalid)$fatal(1,"early B");
        send_w(32'h11223344,15);check_b(PLACEHOLDER?2:0);
        read_check(4,PLACEHOLDER?0:32'h11223344,PLACEHOLDER?2:0);
        send_w(32'haabbccdd,5);repeat(2)@(negedge clk);if(bvalid)$fatal(1,"early B before AW");
        send_aw(4);check_b(PLACEHOLDER?2:0);
        read_check(4,PLACEHOLDER?0:32'h11bb33dd,PLACEHOLDER?2:0);
        fork send_aw(8);send_w(32'hcafefeed,15);join
        check_b(PLACEHOLDER?2:0);read_check(8,PLACEHOLDER?0:32'hcafefeed,PLACEHOLDER?2:0);
        send_aw(1);send_w(32'hffffffff,15);check_b(2);
        read_check(16,0,2);read_check(1,0,2);
        // No request acceptance while CE is low.
        @(negedge clk);clk_en=0;awvalid=1;wvalid=1;arvalid=1;
        repeat(3)begin @(negedge clk);if(awready||wready||arready||bvalid||rvalid)$fatal(1,"CE request gate");end
        awvalid=0;wvalid=0;arvalid=0;clk_en=1;
        send_aw(0);@(negedge clk);clk_en=0;rst_n=0;#1;
        if(bvalid||rvalid||awready||wready||arready)$fatal(1,"AXIL reset");
        @(negedge clk);rst_n=1;clk_en=1;
        read_check(4,0,PLACEHOLDER?2:0);
        $display("PASS AXIL placeholder=%0d AW/W order, WSTRB, error, B/R stalls, CE, reset",PLACEHOLDER);$finish;
    end
    initial begin #50000;$fatal(1,"AXIL watchdog");end
endmodule
`undef AXIL_PORTS
