`timescale 1ns/1ps
module dma_stub_case #(parameter DW=32,AW=32,LW=32,TW=16)(output reg finished=0);
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,ce=1,cv=0,rr=0;
    reg [AW-1:0] ca=0;
    reg [LW-1:0] len=0;
    reg [TW-1:0] tag=0;
    wire [2:0] cr,rv,err,busy,done,irq,mv,mrr,mw;
    wire [23:0] status;
    wire [3*TW-1:0] rtag;
    wire [3*LW-1:0] bytes;
    wire [3*AW-1:0] ma;
    wire [3*DW-1:0] md;
    wire [3*(DW/8)-1:0] ms;
    wire sr,sv,sl,drv,drr,term;
    wire [DW-1:0] stream_data;
    wire [DW/8-1:0] stream_keep;
    wire [AW-1:0] rh,da;
    reg exp_valid=0,last_accept=0;
    reg [TW-1:0] exp_tag=0;
    reg [AW-1:0] exp_head=0;
    integer i,k,accepted=0,completed=0;
    cip_dma_stream_to_memory_stub #(.DATA_WIDTH(DW),.ADDR_WIDTH(AW),.LEN_WIDTH(LW),.TAG_WIDTH(TW)) s2m(
        .clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr[0]),
        .cmd_addr(ca),.cmd_byte_len(len),.cmd_tag(tag),.rsp_valid(rv[0]),.rsp_ready(rr),
        .rsp_error(err[0]),.rsp_status(status[7:0]),.rsp_tag(rtag[0+:TW]),.rsp_bytes(bytes[0+:LW]),
        .busy(busy[0]),.done(done[0]),.irq(irq[0]),.s_valid(1'b1),.s_ready(sr),
        .s_data({DW{1'b1}}),.s_keep({DW/8{1'b1}}),.s_last(1'b1),
        .mem_req_valid(mv[0]),.mem_req_ready(1'b1),.mem_req_write(mw[0]),
        .mem_req_addr(ma[0+:AW]),.mem_req_wdata(md[0+:DW]),.mem_req_wstrb(ms[0+:DW/8]),
        .mem_rsp_valid(1'b1),.mem_rsp_ready(mrr[0]),.mem_rsp_rdata({DW{1'b1}}),.mem_rsp_error(1'b1));
    cip_dma_memory_to_stream_stub #(.DATA_WIDTH(DW),.ADDR_WIDTH(AW),.LEN_WIDTH(LW),.TAG_WIDTH(TW)) m2s(
        .clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr[1]),
        .cmd_addr(ca),.cmd_byte_len(len),.cmd_tag(tag),.rsp_valid(rv[1]),.rsp_ready(rr),
        .rsp_error(err[1]),.rsp_status(status[15:8]),.rsp_tag(rtag[TW+:TW]),.rsp_bytes(bytes[LW+:LW]),
        .busy(busy[1]),.done(done[1]),.irq(irq[1]),.m_valid(sv),.m_ready(1'b1),
        .m_data(stream_data),.m_keep(stream_keep),.m_last(sl),
        .mem_req_valid(mv[1]),.mem_req_ready(1'b1),.mem_req_write(mw[1]),
        .mem_req_addr(ma[AW+:AW]),.mem_req_wdata(md[DW+:DW]),.mem_req_wstrb(ms[DW/8+:DW/8]),
        .mem_rsp_valid(1'b1),.mem_rsp_ready(mrr[1]),.mem_rsp_rdata({DW{1'b1}}),.mem_rsp_error(1'b1));
    cip_dma_descriptor_chain_stub #(.DATA_WIDTH(DW),.ADDR_WIDTH(AW),.LEN_WIDTH(LW),.TAG_WIDTH(TW)) chain(
        .clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr[2]),
        .cmd_head_addr(ca),.cmd_tag(tag),.rsp_valid(rv[2]),.rsp_ready(rr),
        .rsp_error(err[2]),.rsp_status(status[23:16]),.rsp_tag(rtag[2*TW+:TW]),.rsp_bytes(bytes[2*LW+:LW]),
        .rsp_head_addr(rh),.rsp_terminal(term),.busy(busy[2]),.done(done[2]),.irq(irq[2]),
        .desc_req_valid(drv),.desc_req_ready(1'b1),.desc_req_addr(da),
        .desc_rsp_valid(1'b1),.desc_rsp_ready(drr),.desc_rsp_src({AW{1'b1}}),
        .desc_rsp_dst({AW{1'b1}}),.desc_rsp_byte_len({LW{1'b1}}),.desc_rsp_next({AW{1'b1}}),
        .desc_rsp_last(1'b0),.desc_rsp_tag({TW{1'b1}}),.desc_rsp_error(1'b1),
        .mem_req_valid(mv[2]),.mem_req_ready(1'b1),.mem_req_write(mw[2]),
        .mem_req_addr(ma[2*AW+:AW]),.mem_req_wdata(md[2*DW+:DW]),.mem_req_wstrb(ms[2*(DW/8)+:DW/8]),
        .mem_rsp_valid(1'b1),.mem_rsp_ready(mrr[2]),.mem_rsp_rdata({DW{1'b1}}),.mem_rsp_error(1'b1));
    always @(posedge clk) begin
        last_accept=0;
        if(!rst_n)exp_valid=0;
        else begin
            if(mv!==0||mrr!==0||sr!==0||sv!==0||sl!==0||drv!==0||drr!==0||ms!==0)
                $fatal(1,"DMA placeholder performed data activity");
            if(rv!=={3{exp_valid}}||busy!==rv)$fatal(1,"DMA valid/accounting mismatch");
            if(done!=={3{ce&&exp_valid&&rr}}||irq!==done)$fatal(1,"DMA completion event mismatch");
            if(exp_valid)begin
                if(err!==3'b111||status!==24'h010101||bytes!==0||term!==1||rh!==exp_head)
                    $fatal(1,"DMA false success or bad metadata");
                for(k=0;k<3;k=k+1)if(rtag[k*TW+:TW]!==exp_tag)$fatal(1,"DMA tag mismatch");
            end
            if(cr!=={3{!exp_valid||rr}})$fatal(1,"DMA backpressure mismatch");
            if(ce)begin
                if(exp_valid&&rr)completed=completed+1;
                if(cr[0])begin
                    exp_valid=cv;
                    if(cv)begin exp_tag=tag;exp_head=ca;accepted=accepted+1;last_accept=1;end
                end
            end
        end
    end
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        // Includes zero length, unaligned address, maximum length, and long response stalls.
        @(negedge clk);cv=1;ca=3;len=0;tag=1;rr=0;
        @(negedge clk);cv=0;ce=0;rr=1;
        repeat(8)@(negedge clk);
        ce=1;rr=0;
        repeat(8)@(negedge clk);
        for(i=0;i<1000;i=i+1)begin
            @(negedge clk);
            if(!cv||last_accept)begin cv=$urandom_range(0,4)!=0;ca=$urandom;len=$urandom;tag=tag+1'b1;end
            ce=$urandom_range(0,3)!=0;rr=$urandom_range(0,3)!=0;
        end
        @(negedge clk);ce=1;rr=1;
        while(cv&&!last_accept)@(negedge clk);
        cv=0;
        repeat(4)@(negedge clk);
        if(accepted!=completed||accepted<100)$fatal(1,"DMA request/response mismatch %d %d",accepted,completed);
        cv=1;rr=0;len={LW{1'b1}};
        @(negedge clk);cv=0;ce=0;rst_n=0;
        #1;if(rv!==0)$fatal(1,"DMA asynchronous reset failed");
        repeat(3)@(negedge clk);rst_n=1;ce=1;rr=1;
        repeat(3)@(negedge clk);
        $display("PASS DMA placeholders DW=%0d AW=%0d tags=%0d completed=%0d",DW,AW,TW,completed);
        finished=1;
    end
endmodule
module tb_cip_dma_stubs;
    wire a,b;
    dma_stub_case standard(a);
    dma_stub_case #(.DW(64),.AW(24),.LW(16),.TW(8))alternate(b);
    initial begin wait(a&&b);$display("PASS DMA all three explicitly UNSUPPORTED");$finish;end
    initial begin #1000000;$fatal(1,"DMA timeout");end
endmodule
