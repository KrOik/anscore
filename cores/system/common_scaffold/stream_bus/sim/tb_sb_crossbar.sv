`timescale 1ns/1ps
module tb_sb_crossbar;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,clk_en=1;
    reg [11:0] awaddr=0,araddr=0;reg [2:0] awprot=0,arprot=0;
    reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
    reg [31:0] wdata=0;reg [3:0] wstrb=0;
    wire awready,wready,bvalid,arready,rvalid;wire [1:0] bresp,rresp;wire [31:0] rdata;
    wire [35:0] mawaddr,maraddr;wire [8:0] mawprot,marprot;
    wire [2:0] mawvalid,mawready,mwvalid,mwready,mbvalid,mbready,marvalid,marready,mrvalid,mrready;
    wire [95:0] mwdata,mrdata;wire [11:0] mwstrb;wire [5:0] mbresp,mrresp;
    integer cycles=0,aw_count=0,w_count=0,ar_count=0;
    reg [31:0] reference[0:47];
    sb_axil_crossbar_placeholder #(.ADDR_WIDTH(12),.PORTS(3),.REGION_ADDR_BITS(8)) dut(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .s_axil_awaddr(awaddr),.s_axil_awprot(awprot),.s_axil_awvalid(awvalid),.s_axil_awready(awready),
        .s_axil_wdata(wdata),.s_axil_wstrb(wstrb),.s_axil_wvalid(wvalid),.s_axil_wready(wready),
        .s_axil_bresp(bresp),.s_axil_bvalid(bvalid),.s_axil_bready(bready),
        .s_axil_araddr(araddr),.s_axil_arprot(arprot),.s_axil_arvalid(arvalid),.s_axil_arready(arready),
        .s_axil_rdata(rdata),.s_axil_rresp(rresp),.s_axil_rvalid(rvalid),.s_axil_rready(rready),
        .m_axil_awaddr(mawaddr),.m_axil_awprot(mawprot),.m_axil_awvalid(mawvalid),.m_axil_awready(mawready),
        .m_axil_wdata(mwdata),.m_axil_wstrb(mwstrb),.m_axil_wvalid(mwvalid),.m_axil_wready(mwready),
        .m_axil_bresp(mbresp),.m_axil_bvalid(mbvalid),.m_axil_bready(mbready),
        .m_axil_araddr(maraddr),.m_axil_arprot(marprot),.m_axil_arvalid(marvalid),.m_axil_arready(marready),
        .m_axil_rdata(mrdata),.m_axil_rresp(mrresp),.m_axil_rvalid(mrvalid),.m_axil_rready(mrready));
    genvar g;
    generate for(g=0;g<3;g=g+1)begin:slave
        wire awgate=(cycles+g)%5<2,wgate=(cycles+g)%7>2,argate=(cycles+g)%3==1;
        wire bank_awready,bank_wready,bank_arready;
        assign mawready[g]=bank_awready && awgate;
        assign mwready[g]=bank_wready && wgate;
        assign marready[g]=bank_arready && argate;
        sb_axil_register_bank #(.ADDR_WIDTH(12),.REG_COUNT(16)) bank(
            .clk(clk),.rst_n(rst_n),.clk_en(1'b1),
            .s_axil_awaddr(mawaddr[g*12+:12]),.s_axil_awprot(mawprot[g*3+:3]),
            .s_axil_awvalid(mawvalid[g] && awgate),.s_axil_awready(bank_awready),
            .s_axil_wdata(mwdata[g*32+:32]),.s_axil_wstrb(mwstrb[g*4+:4]),
            .s_axil_wvalid(mwvalid[g] && wgate),.s_axil_wready(bank_wready),
            .s_axil_bresp(mbresp[g*2+:2]),.s_axil_bvalid(mbvalid[g]),.s_axil_bready(mbready[g]),
            .s_axil_araddr(maraddr[g*12+:12]),.s_axil_arprot(marprot[g*3+:3]),
            .s_axil_arvalid(marvalid[g] && argate),.s_axil_arready(bank_arready),
            .s_axil_rdata(mrdata[g*32+:32]),.s_axil_rresp(mrresp[g*2+:2]),
            .s_axil_rvalid(mrvalid[g]),.s_axil_rready(mrready[g]),.register_values());
        always @(posedge clk)if(rst_n)begin
            if(mawvalid[g] && mawready[g])begin
                aw_count=aw_count+1;
                if(mawaddr[g*12+:12]>=256 || mawprot[g*3+:3]!==awprot)$fatal(1,"AW local address/protection");
            end
            if(mwvalid[g] && mwready[g])w_count=w_count+1;
            if(marvalid[g] && marready[g])begin
                ar_count=ar_count+1;
                if(maraddr[g*12+:12]>=256 || marprot[g*3+:3]!==arprot)$fatal(1,"AR local address/protection");
            end
        end
    end endgenerate
    reg bstall=0,rstall=0;reg [1:0] held_b;reg [33:0] held_r;
    always @(posedge clk)begin
        cycles<=cycles+1;
        if(rst_n)begin
            if(bstall && (!bvalid || bresp!==held_b))$fatal(1,"crossbar B unstable");
            if(rstall && (!rvalid || {rdata,rresp}!==held_r))$fatal(1,"crossbar R unstable");
            bstall<=bvalid&&!bready;held_b<=bresp;rstall<=rvalid&&!rready;held_r<={rdata,rresp};
            if((mawvalid & (mawvalid-1)) || (mwvalid & (mwvalid-1)) || (marvalid & (marvalid-1)))
                $fatal(1,"multiple slave selects");
        end else begin bstall<=0;rstall<=0;end
    end
    task aw(input integer address);
        begin
            @(negedge clk);awaddr=address;awvalid=1;awprot=address%8;
            @(posedge clk);while(!awready)@(posedge clk);
            @(negedge clk);awvalid=0;
        end
    endtask
    task wd(input [31:0] data,input [3:0] strobe);
        begin
            @(negedge clk);wdata=data;wstrb=strobe;wvalid=1;
            @(posedge clk);while(!wready)@(posedge clk);
            @(negedge clk);wvalid=0;
        end
    endtask
    task write_check(input integer address,input [31:0] data,input [3:0] strobe,input integer order,input integer response);
        integer b,idx;
        begin
            case(order%3)
            0:begin aw(address);repeat(3)@(negedge clk);wd(data,strobe);end
            1:begin wd(data,strobe);repeat(2)@(negedge clk);aw(address);end
            2:fork aw(address);wd(data,strobe);join
            endcase
            clk_en=0;
            while(!bvalid)@(negedge clk);
            if(bresp!==response[1:0])$fatal(1,"crossbar B addr=%h got=%d expected=%d",address,bresp,response);
            repeat(3)@(negedge clk);bready=1;@(negedge clk);bready=0;
            if(bvalid)$fatal(1,"crossbar B stalled with CE=0");clk_en=1;
            if(response==0)begin
                idx=(address>>8)*16+((address&255)>>2);
                for(b=0;b<4;b=b+1)if(strobe[b])reference[idx][b*8+:8]=data[b*8+:8];
            end
        end
    endtask
    task read_check(input integer address,input [31:0] expected,input integer response);
        begin
            @(negedge clk);araddr=address;arprot=address%8;arvalid=1;
            @(posedge clk);while(!arready)@(posedge clk);
            @(negedge clk);arvalid=0;clk_en=0;
            while(!rvalid)@(negedge clk);
            if(rdata!==expected || rresp!==response[1:0])$fatal(1,"crossbar R addr=%h data=%h expected=%h resp=%d",address,rdata,expected,rresp);
            repeat(4)@(negedge clk);rready=1;@(negedge clk);rready=0;
            if(rvalid)$fatal(1,"crossbar R stalled with CE=0");clk_en=1;
        end
    endtask
    integer i,p,a,before_aw,before_w,before_ar;
    initial begin
        for(i=0;i<48;i=i+1)reference[i]=0;
        repeat(3)@(negedge clk);rst_n=1;
        for(i=0;i<48;i=i+1)begin
            p=i/16;a=p*256+(i%16)*4;
            write_check(a,32'h98765432^(i*32'h01234567),15,i,0);
            read_check(a,reference[i],0);
            write_check(a,32'habcdef01^(i*17),5,i+1,0);
            read_check(a,reference[i],0);
        end
        // One outstanding read and write may progress independently.
        fork
            begin aw(256);wd(32'h11223344,15);while(!bvalid)@(negedge clk);bready=1;@(negedge clk);bready=0;end
            read_check(4,reference[1],0);
        join
        clk_en=1;read_check(256,32'h11223344,0);
        write_check(1,32'hffffffff,15,0,2);read_check(1,0,2);
        write_check(64,32'hffffffff,15,1,2);read_check(64,0,2);
        before_aw=aw_count;before_w=w_count;before_ar=ar_count;
        write_check(768,32'hffffffff,15,2,3);read_check(768,0,3);
        write_check(4092,32'hffffffff,15,0,3);read_check(4092,0,3);
        if(aw_count!=before_aw || w_count!=before_w || ar_count!=before_ar)$fatal(1,"decode error reached a slave");
        @(negedge clk);clk_en=0;awvalid=1;wvalid=1;arvalid=1;
        repeat(3)begin @(negedge clk);if(awready || wready || arready)$fatal(1,"CE accepted new request");end
        awvalid=0;wvalid=0;arvalid=0;clk_en=1;
        aw(0);@(negedge clk);rst_n=0;#1;
        if(bvalid || rvalid || |mawvalid || |mwvalid || |marvalid)$fatal(1,"crossbar reset active");
        repeat(2)@(negedge clk);rst_n=1;read_check(0,0,0);
        $display("PASS AXIL crossbar three-slave routing local-address AW/W order independent stalls CE decode reset");$finish;
    end
    initial begin #1000000;$fatal(1,"crossbar watchdog");end
endmodule
