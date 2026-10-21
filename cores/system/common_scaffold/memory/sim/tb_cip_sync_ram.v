`timescale 1ns/1ps
module tb_cip_sync_ram;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, clk_en=1;
    reg sv=0, sw=0, sr=0;
    reg [3:0] sa=0, ss=0;
    reg [31:0] sd=0;
    wire sq,srv,se; wire [31:0] sdata;
    reg av=0,aw=0,ar=0,bv=0,bw=0,br=0;
    reg [3:0] aa=0,ast=0,ba=0,bst=0;
    reg [31:0] ad=0,bd=0;
    wire aq,arv,bq,brv; wire [1:0] ae,be; wire [31:0] ado,bdo;
    reg [7:0] smodel[0:39], dmodel[0:39];
    integer i,j,n,checks=0;
    cip_sync_sp_ram #(.ADDR_WIDTH(4),.DEPTH(10)) sp(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.req_valid(sv),.req_ready(sq),
        .req_write(sw),.req_addr(sa),.req_wdata(sd),.req_wstrb(ss),
        .rsp_valid(srv),.rsp_ready(sr),.rsp_rdata(sdata),.rsp_error(se));
    cip_sync_tdp_ram #(.ADDR_WIDTH(4),.DEPTH(10)) dp(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .a_req_valid(av),.a_req_ready(aq),.a_req_write(aw),.a_req_addr(aa),
        .a_req_wdata(ad),.a_req_wstrb(ast),.a_rsp_valid(arv),.a_rsp_ready(ar),
        .a_rsp_rdata(ado),.a_rsp_error(ae),
        .b_req_valid(bv),.b_req_ready(bq),.b_req_write(bw),.b_req_addr(ba),
        .b_req_wdata(bd),.b_req_wstrb(bst),.b_rsp_valid(brv),.b_rsp_ready(br),
        .b_rsp_rdata(bdo),.b_rsp_error(be));

    task sp_access;
        input wr; input [3:0] addr; input [31:0] data; input [3:0] strobe;
        reg [31:0] expected, held; reg error_expected; integer k;
        begin
            expected=0; error_expected=addr>=10;
            if (addr<10) for(k=0;k<4;k=k+1) expected[k*8+:8]=smodel[addr*4+k];
            @(negedge clk); clk_en=1; sv=1; sw=wr;sa=addr;sd=data;ss=strobe;sr=0;
            @(posedge clk);
            if(sq!==1) $fatal(1,"SP unexpected backpressure");
            #1;
            if(srv!==1 || se!==error_expected || sdata!==expected)
                $fatal(1,"SP mismatch addr=%d data=%h expected=%h",addr,sdata,expected);
            if(wr&&addr<10) for(k=0;k<4;k=k+1) if(strobe[k]) smodel[addr*4+k]=data[k*8+:8];
            held=sdata;
            // Hold the response, including a clk_en pause while ready is high.
            @(negedge clk); sv=0; clk_en=0; sr=1;
            repeat(3) begin @(posedge clk); #1;
                if(srv!==1 || sdata!==held) $fatal(1,"SP pause lost response");
            end
            @(negedge clk); clk_en=1; sr=0;
            repeat(2) begin @(posedge clk); #1;
                if(srv!==1 || sdata!==held || sq!==0) $fatal(1,"SP hold violation");
            end
            @(negedge clk); sr=1;
            @(posedge clk); #1; if(srv!==0) $fatal(1,"SP consume failure");
            checks=checks+1;
        end
    endtask

    task dp_access;
        input va,wa;input [3:0] adda;input [31:0] da;input [3:0] sta;
        input vb,wb;input [3:0] addb;input [31:0] db;input [3:0] stb;
        reg [31:0] expa,expb;reg [1:0] erra,errb;integer k;
        begin
            erra=adda>=10 ? 1:0;
            errb=addb>=10 ? 1 : ((va&&vb&&adda<10&&adda==addb&&(wa||wb))?2:0);
            expa=0;expb=0;
            if(adda<10&&!wa) for(k=0;k<4;k=k+1) expa[k*8+:8]=dmodel[adda*4+k];
            if(errb==0&&!wb) for(k=0;k<4;k=k+1) expb[k*8+:8]=dmodel[addb*4+k];
            @(negedge clk);clk_en=1;av=va;aw=wa;aa=adda;ad=da;ast=sta;
            bv=vb;bw=wb;ba=addb;bd=db;bst=stb;ar=0;br=0;
            @(posedge clk);if(aq!==1||bq!==1) $fatal(1,"DP unexpected backpressure");
            #1;
            if(arv!==va||brv!==vb) $fatal(1,"DP valid mismatch");
            if(va&&(ae!==erra||ado!==expa)) $fatal(1,"DP A mismatch %d",adda);
            if(vb&&(be!==errb||bdo!==expb)) $fatal(1,"DP B mismatch %d err=%d exp=%d",addb,be,errb);
            if(va&&wa&&erra==0)for(k=0;k<4;k=k+1)if(sta[k])dmodel[adda*4+k]=da[k*8+:8];
            if(vb&&wb&&errb==0)for(k=0;k<4;k=k+1)if(stb[k])dmodel[addb*4+k]=db[k*8+:8];
            @(negedge clk);av=0;bv=0;clk_en=0;ar=1;br=1;
            repeat(2) begin @(posedge clk);#1;
                if(arv!==va||brv!==vb) $fatal(1,"DP pause changed valid");
                if(va&&ado!==expa) $fatal(1,"DP pause changed A");
                if(vb&&bdo!==expb) $fatal(1,"DP pause changed B");
            end
            @(negedge clk);clk_en=1;ar=1;br=0;
            @(posedge clk);#1;
            if(arv!==0||brv!==vb) $fatal(1,"DP independent responses failed");
            @(negedge clk);br=1;
            @(posedge clk);#1;if(brv!==0) $fatal(1,"DP B consume failed");
            checks=checks+1;
        end
    endtask

    initial begin
        // Oracle is byte-addressed and independent of DUT word storage.
        for(i=0;i<40;i=i+1) begin smodel[i]=8'hxx;dmodel[i]=8'hxx;end
        repeat(3)@(negedge clk);rst_n=1;
        for(i=0;i<10;i=i+1)sp_access(1,i,32'h81020304+i,4'hf);
        for(i=0;i<10;i=i+1)dp_access(1,1,i,32'habcd0000+i,4'hf,0,0,0,0,0);
        for(i=0;i<100;i=i+1)begin
            sp_access($urandom_range(0,1),$urandom_range(0,15),$urandom,$urandom);
            dp_access(1,$urandom_range(0,1),$urandom_range(0,15),$urandom,$urandom,
                      1,$urandom_range(0,1),$urandom_range(0,15),$urandom,$urandom);
        end
        // Three collision classes plus permitted dual read.
        dp_access(1,1,3,32'h11223344,15,1,1,3,32'h55667788,15);
        dp_access(1,1,3,32'h01020304,15,1,0,3,0,0);
        dp_access(1,0,3,0,0,1,1,3,32'hbad0bad0,15);
        dp_access(1,0,3,0,0,1,0,3,0,0);
        // Reset aborts pending responses but preserves RAM contents.
        @(negedge clk);sv=1;sw=0;sa=0;sr=0;av=1;aw=0;aa=3;ar=0;
        @(posedge clk);#1;if(srv!==1||arv!==1)$fatal(1,"reset setup failed");
        @(negedge clk);rst_n=0;sv=0;av=0;clk_en=0;
        #1;if(srv!==0||arv!==0||brv!==0)$fatal(1,"async reset failed");
        repeat(2)@(negedge clk);rst_n=1;
        sp_access(0,0,0,0);
        dp_access(1,0,3,0,0,1,0,3,0,0);
        $display("PASS RAM checks=%0d byte oracle, masks, bounds, collisions, pause, reset",checks);
        $finish;
    end
    initial begin #1000000;$fatal(1,"RAM timeout");end
endmodule
