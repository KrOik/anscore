`timescale 1ns/1ps
// Cross-group DMA -> shared-CE adapter -> ordinary byte RAM round-trip.
module tb_cip_dma_ce_memory;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,freeze=0,mode=0,cv=0,rr=0,sv=0,sl=0,mr=1;
reg [31:0] sd=0;reg [3:0] sk=0;integer cycle=0,received=0,physical_paused=0;
wire [1:0] cr,rv,re,sr,mv,ml,qv,qr,qw,pv,pr,pe;
wire [15:0] status,tag;
wire [31:0] bytes,qa;
wire [63:0] md,qd,pd;
wire [7:0] mk,qs;
wire av,ar,aw,bv,br,be;wire [15:0] aa;wire [31:0] ad,bd;wire [3:0] ast;
genvar g;
generate for(g=0;g<2;g=g+1)begin:engines
    cip_dma_stream_native #(.DATA_WIDTH(32),.ADDR_WIDTH(16),.LEN_WIDTH(16),.TAG_WIDTH(8),.DIRECTION(g)) dma(
        .clk(clk),.rst_n(rst_n),.clk_en(ce),.abort(1'b0),
        .cmd_valid(cv && mode==g),.cmd_ready(cr[g]),.cmd_addr(16'd0),.cmd_byte_len(16'd11),.cmd_tag(g==0?8'h91:8'h92),
        .rsp_valid(rv[g]),.rsp_ready(rr && mode==g),.rsp_error(re[g]),.rsp_status(status[g*8+:8]),
        .rsp_tag(tag[g*8+:8]),.rsp_bytes(bytes[g*16+:16]),.busy(),.done(),.irq(),
        .s_valid(sv && g==0),.s_ready(sr[g]),.s_data(sd),.s_keep(sk),.s_last(sl),
        .m_valid(mv[g]),.m_ready(mr),.m_data(md[g*32+:32]),.m_keep(mk[g*4+:4]),.m_last(ml[g]),
        .mem_req_valid(qv[g]),.mem_req_ready(qr[g]),.mem_req_write(qw[g]),.mem_req_addr(qa[g*16+:16]),
        .mem_req_wdata(qd[g*32+:32]),.mem_req_wstrb(qs[g*4+:4]),
        .mem_rsp_valid(pv[g]),.mem_rsp_ready(pr[g]),.mem_rsp_rdata(pd[g*32+:32]),.mem_rsp_error(pe[g]));
end endgenerate
wire req_ready,rsp_valid,rsp_error;wire [31:0] rsp_data;
assign qr=mode?{req_ready,1'b0}:{1'b0,req_ready};
assign pv=mode?{rsp_valid,1'b0}:{1'b0,rsp_valid};
assign pe={2{rsp_error}};assign pd={2{rsp_data}};
cip_native_ce_adapter #(.ADDR_WIDTH(16)) adapter(
    .clk(clk),.rst_n(rst_n),.clk_en(ce),
    .s_req_valid(qv[mode]),.s_req_ready(req_ready),.s_req_write(qw[mode]),
    .s_req_addr(qa[mode*16+:16]),.s_req_wdata(qd[mode*32+:32]),.s_req_wstrb(qs[mode*4+:4]),
    .s_rsp_valid(rsp_valid),.s_rsp_ready(pr[mode]),.s_rsp_rdata(rsp_data),.s_rsp_error(rsp_error),
    .m_req_valid(av),.m_req_ready(ar),.m_req_write(aw),.m_req_addr(aa),.m_req_wdata(ad),.m_req_wstrb(ast),
    .m_rsp_valid(bv),.m_rsp_ready(br),.m_rsp_rdata(bd),.m_rsp_error(be));
cip_native_byte_ram #(.ADDR_WIDTH(16),.WORDS(16)) ram(
    .clk(clk),.rst_n(rst_n),.req_valid(av),.req_ready(ar),.req_write(aw),.req_addr(aa),
    .req_wdata(ad),.req_wstrb(ast),.rsp_valid(bv),.rsp_ready(br),.rsp_rdata(bd),.rsp_error(be));
always @(negedge clk)begin cycle=cycle+1;ce=!freeze && cycle%7!=0;mr=(cycle%5>1);end
reg held=0;reg [36:0] saved;
always @(posedge clk)if(rst_n)begin
    if(bv && br && !ce)physical_paused=physical_paused+1;
    if(held && (!mv[1] || {ml[1],mk[7:4],md[63:32]}!==saved))$fatal(1,"DMA output unstable");
    held=mv[1] && (!ce || !mr);saved={ml[1],mk[7:4],md[63:32]};
    if(ce && mv[1] && mr)begin
        case(received)
          0:if(md[63:32]!==32'h44332211 || mk[7:4]!==15 || ml[1])$fatal(1,"DMA read0");
          1:if(md[63:32]!==32'h88776655 || mk[7:4]!==15 || ml[1])$fatal(1,"DMA read1");
          2:if(md[63:32]!==32'h00bbaa99 || mk[7:4]!==7 || !ml[1])$fatal(1,"DMA read tail");
          default:$fatal(1,"extra DMA output");
        endcase
        received=received+1;
    end
end
task command;
begin @(negedge clk);cv=1;do @(posedge clk);while(!ce || !cr[mode]);@(negedge clk);cv=0;end
endtask
task beat(input [31:0] value,input [3:0] keep,input last);
begin @(negedge clk);sd=value;sk=keep;sl=last;sv=1;
do @(posedge clk);while(!ce || !sr[0]);@(negedge clk);sv=0;end
endtask
task response;
begin wait(rv[mode]);repeat(5)@(negedge clk);
if(re[mode] || status[mode*8+:8]!==0 || bytes[mode*16+:16]!==11 ||
   tag[mode*8+:8] !== (mode?8'h92:8'h91))$fatal(1,"DMA completion");
rr=1;do @(posedge clk);while(!ce);@(negedge clk);rr=0;end
endtask
initial begin
    #21;rst_n=1;command;
    fork
      begin wait(av);@(negedge clk);freeze=1;repeat(8)@(negedge clk);freeze=0;end
      begin beat(32'h44332211,15,0);beat(32'h88776655,15,0);beat(32'hccbbaa99,7,1);end
    join
    response;mode=1;command;response;
    if(received!=3 || physical_paused==0)$fatal(1,"missing paused-clock response/data");
    $display("DMA_CE_MEMORY PASS bytes=11 physical_replies_while_ce0=%0d",physical_paused);$finish;
end
initial begin #200000;$fatal(1,"DMA CE integration timeout");end
endmodule
