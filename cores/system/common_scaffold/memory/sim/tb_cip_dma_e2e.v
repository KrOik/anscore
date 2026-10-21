`timescale 1ns/1ps
// One group regression: real byte-oracle transfers plus stalls, CE and faults.
module dma_test_memory #(parameter DW=32, AW=12)(
    input wire clk,rst_n,ce,
    input wire qv, output wire qr, input wire qw,
    input wire [AW-1:0] qa, input wire [DW-1:0] qd,
    input wire [DW/8-1:0] qs,
    output reg rv=0, input wire rr,
    output reg [DW-1:0] rd=0, output reg re=0,
    input wire inject_error, input wire [AW-1:0] error_addr
);
    reg [7:0] memory[0:(1<<AW)-1];
    reg pending=0;
    integer timer=0,cycle=0,requests=0,i;
    assign qr=rst_n && !pending && !rv && cycle%5!=1;
    initial for(i=0;i<(1<<AW);i=i+1) memory[i]=8'ha5;
    always @(posedge clk) begin
        if(!rst_n) begin rv<=0; pending<=0; timer<=0; cycle<=0; requests<=0; end
        else if(ce) begin
            cycle<=cycle+1;
            if(rv&&rr) rv<=0;
            if(pending) begin
                if(timer==0) begin rv<=1; pending<=0; end
                else timer<=timer-1;
            end
            if(qv&&qr) begin
                pending<=1; timer<=cycle%3+1; requests<=requests+1;
                re<=inject_error && qa==error_addr;
                for(i=0;i<DW/8;i=i+1) begin
                    rd[8*i+:8]<=memory[qa+i];
                    if(qw&&qs[i]&&!(inject_error&&qa==error_addr)) memory[qa+i]<=qd[8*i+:8];
                end
            end
        end
    end
endmodule

module dma_roundtrip_case #(parameter DW=32, USE_NATIVE=0)(output reg finished=0);
    localparam AW=12,LW=16,TW=8,B=DW/8;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0,ce=1,abort_write=0,abort_read=0;
    integer cycles=0;
    always @(negedge clk) begin cycles=cycles+1; ce=(cycles%7!=2 && cycles%7!=3); end
    reg wcv=0,wrr=0,sv=0,sl=0,rcv=0,rrr=0,mr=0;
    reg [AW-1:0] wa=0,ra=0;
    reg [LW-1:0] wl=0,rl=0;
    reg [TW-1:0] wt=0,rt=0;
    reg [DW-1:0] sd=0;
    reg [B-1:0] sk=0;
    wire wcr,wrv,we,sr,wbusy,wdone,wirq,rcr,rrv,re,rmv,rml,rbusy,rdone,rirq;
    wire [7:0] ws,rs;
    wire [TW-1:0] wtag,rtag;
    wire [LW-1:0] wb,rb;
    wire [DW-1:0] rmd;
    wire [B-1:0] rmk;
    wire [1:0] qv,qr,qw,mrv,mrr,mer;
    wire [2*AW-1:0] qa;
    wire [2*DW-1:0] qd,mrd;
    wire [2*B-1:0] qs;
    reg inject_w=0,inject_r=0;
    reg [AW-1:0] error_w=0,error_r=0;
    generate if(USE_NATIVE) begin: native
        cip_dma_stream_native #(.DATA_WIDTH(DW),.ADDR_WIDTH(AW),.LEN_WIDTH(LW),.TAG_WIDTH(TW),.DIRECTION(0)) write_dma(
            .clk(clk),.rst_n(rst_n),.clk_en(ce),.abort(abort_write),
            .cmd_valid(wcv),.cmd_ready(wcr),.cmd_addr(wa),.cmd_byte_len(wl),.cmd_tag(wt),
            .rsp_valid(wrv),.rsp_ready(wrr),.rsp_error(we),.rsp_status(ws),.rsp_tag(wtag),.rsp_bytes(wb),
            .busy(wbusy),.done(wdone),.irq(wirq),.s_valid(sv),.s_ready(sr),.s_data(sd),.s_keep(sk),.s_last(sl),
            .m_valid(),.m_ready(1'b0),.m_data(),.m_keep(),.m_last(),
            .mem_req_valid(qv[0]),.mem_req_ready(qr[0]),.mem_req_write(qw[0]),.mem_req_addr(qa[0+:AW]),
            .mem_req_wdata(qd[0+:DW]),.mem_req_wstrb(qs[0+:B]),
            .mem_rsp_valid(mrv[0]),.mem_rsp_ready(mrr[0]),.mem_rsp_rdata(mrd[0+:DW]),.mem_rsp_error(mer[0]));
        cip_dma_stream_native #(.DATA_WIDTH(DW),.ADDR_WIDTH(AW),.LEN_WIDTH(LW),.TAG_WIDTH(TW),.DIRECTION(1)) read_dma(
            .clk(clk),.rst_n(rst_n),.clk_en(ce),.abort(abort_read),
            .cmd_valid(rcv),.cmd_ready(rcr),.cmd_addr(ra),.cmd_byte_len(rl),.cmd_tag(rt),
            .rsp_valid(rrv),.rsp_ready(rrr),.rsp_error(re),.rsp_status(rs),.rsp_tag(rtag),.rsp_bytes(rb),
            .busy(rbusy),.done(rdone),.irq(rirq),.s_valid(1'b0),.s_ready(),.s_data({DW{1'b0}}),.s_keep({B{1'b0}}),.s_last(1'b0),
            .m_valid(rmv),.m_ready(mr),.m_data(rmd),.m_keep(rmk),.m_last(rml),
            .mem_req_valid(qv[1]),.mem_req_ready(qr[1]),.mem_req_write(qw[1]),.mem_req_addr(qa[AW+:AW]),
            .mem_req_wdata(qd[DW+:DW]),.mem_req_wstrb(qs[B+:B]),
            .mem_rsp_valid(mrv[1]),.mem_rsp_ready(mrr[1]),.mem_rsp_rdata(mrd[DW+:DW]),.mem_rsp_error(mer[1]));
    end else begin: compatible
        cip_dma_stream_to_memory_stub #(.DATA_WIDTH(DW),.ADDR_WIDTH(AW),.LEN_WIDTH(LW),.TAG_WIDTH(TW)) write_dma(
            .clk(clk),.rst_n(rst_n),.clk_en(ce),
            .cmd_valid(wcv),.cmd_ready(wcr),.cmd_addr(wa),.cmd_byte_len(wl),.cmd_tag(wt),
            .rsp_valid(wrv),.rsp_ready(wrr),.rsp_error(we),.rsp_status(ws),.rsp_tag(wtag),.rsp_bytes(wb),
            .busy(wbusy),.done(wdone),.irq(wirq),.s_valid(sv),.s_ready(sr),.s_data(sd),.s_keep(sk),.s_last(sl),
            .mem_req_valid(qv[0]),.mem_req_ready(qr[0]),.mem_req_write(qw[0]),.mem_req_addr(qa[0+:AW]),
            .mem_req_wdata(qd[0+:DW]),.mem_req_wstrb(qs[0+:B]),
            .mem_rsp_valid(mrv[0]),.mem_rsp_ready(mrr[0]),.mem_rsp_rdata(mrd[0+:DW]),.mem_rsp_error(mer[0]));
        cip_dma_memory_to_stream_stub #(.DATA_WIDTH(DW),.ADDR_WIDTH(AW),.LEN_WIDTH(LW),.TAG_WIDTH(TW)) read_dma(
            .clk(clk),.rst_n(rst_n),.clk_en(ce),
            .cmd_valid(rcv),.cmd_ready(rcr),.cmd_addr(ra),.cmd_byte_len(rl),.cmd_tag(rt),
            .rsp_valid(rrv),.rsp_ready(rrr),.rsp_error(re),.rsp_status(rs),.rsp_tag(rtag),.rsp_bytes(rb),
            .busy(rbusy),.done(rdone),.irq(rirq),.m_valid(rmv),.m_ready(mr),.m_data(rmd),.m_keep(rmk),.m_last(rml),
            .mem_req_valid(qv[1]),.mem_req_ready(qr[1]),.mem_req_write(qw[1]),.mem_req_addr(qa[AW+:AW]),
            .mem_req_wdata(qd[DW+:DW]),.mem_req_wstrb(qs[B+:B]),
            .mem_rsp_valid(mrv[1]),.mem_rsp_ready(mrr[1]),.mem_rsp_rdata(mrd[DW+:DW]),.mem_rsp_error(mer[1]));
    end endgenerate
    dma_test_memory #(.DW(DW),.AW(AW)) write_mem(clk,rst_n,ce,qv[0],qr[0],qw[0],qa[0+:AW],qd[0+:DW],qs[0+:B],mrv[0],mrr[0],mrd[0+:DW],mer[0],inject_w,error_w);
    dma_test_memory #(.DW(DW),.AW(AW)) read_mem(clk,rst_n,ce,qv[1],qr[1],qw[1],qa[AW+:AW],qd[DW+:DW],qs[B+:B],mrv[1],mrr[1],mrd[DW+:DW],mer[1],inject_r,error_r);
    task write_command(input integer a,n,t);
        begin
            @(negedge clk); wa=a; wl=n; wt=t; wcv=1;
            do @(posedge clk); while(!(ce&&wcr));
            @(negedge clk); wcv=0;
        end
    endtask
    task read_command(input integer a,n,t);
        begin
            @(negedge clk); ra=a; rl=n; rt=t; rcv=1;
            do @(posedge clk); while(!(ce&&rcr));
            @(negedge clk); rcv=0;
        end
    endtask
    task put_beat(input [DW-1:0] data,input [B-1:0] keep,input last);
        begin
            @(negedge clk);sd=data;sk=keep;sl=last;sv=1;
            do @(posedge clk); while(!(ce&&sr));
            @(negedge clk);sv=0;
        end
    endtask
    task write_reply(input integer status,bytes,tag);
        begin
            while(!wrv) @(negedge clk);
            repeat(5) begin
                @(negedge clk);
                if(!wrv||ws!==status||wb!==bytes||wtag!==tag||we!==(status!=0))
                    $fatal(1,"write reply DW=%0d expected=%0d/%0d got=%0d/%0d",DW,status,bytes,ws,wb);
            end
            wrr=1; do @(posedge clk); while(!ce);
            @(negedge clk);wrr=0;
        end
    endtask
    task read_reply(input integer status,bytes,tag);
        begin
            while(!rrv) @(negedge clk);
            repeat(5) begin
                @(negedge clk);
                if(!rrv||rs!==status||rb!==bytes||rtag!==tag||re!==(status!=0))
                    $fatal(1,"read reply DW=%0d expected=%0d/%0d got=%0d/%0d",DW,status,bytes,rs,rb);
            end
            rrr=1; do @(posedge clk); while(!ce);
            @(negedge clk);rrr=0;
        end
    endtask
    function [7:0] payload_byte(input integer i);
        payload_byte=(i*29+17)%256;
    endfunction
    integer n,off,j,valid_bytes,count_before;
    reg [DW-1:0] pack,held;
    reg [B-1:0] keep;
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        // Partial tail strobes and independent byte oracle, at both bus widths.
        n=3*B+3;
        write_command(128,n,8'h31);
        for(off=0;off<n;off=off+B) begin
            pack=0;keep=0;
            for(j=0;j<B;j=j+1) if(off+j<n) begin pack[j*8+:8]=payload_byte(off+j);keep[j]=1;end
            put_beat(pack,keep,off+B>=n);
        end
        write_reply(0,n,8'h31);
        for(j=0;j<n;j=j+1) begin
            if(write_mem.memory[128+j]!==payload_byte(j)) $fatal(1,"write byte mismatch");
            read_mem.memory[128+j]=write_mem.memory[128+j];
        end
        if(write_mem.memory[127]!==8'ha5||write_mem.memory[128+n]!==8'ha5) $fatal(1,"tail strobe corrupted neighbour");
        read_command(128,n,8'h42);
        for(off=0;off<n;off=off+B) begin
            while(!rmv) @(negedge clk);
            held=rmd;
            repeat(4)begin @(negedge clk);if(!rmv||rmd!==held)$fatal(1,"output changed while stalled");end
            valid_bytes=n-off>=B?B:n-off;
            for(j=0;j<B;j=j+1) begin
                if(rmk[j] !== (j<valid_bytes))$fatal(1,"read keep mismatch");
                if(rmd[j*8+:8] !== (j<valid_bytes?payload_byte(off+j):8'd0))$fatal(1,"read data mismatch");
            end
            if(rml!==(off+B>=n))$fatal(1,"read last mismatch");
            mr=1;do @(posedge clk);while(!ce);@(negedge clk);mr=0;
        end
        read_reply(0,n,8'h42);
        // Zero-length is a successful no-op; invalid address range never accesses memory.
        count_before=write_mem.requests;
        write_command(3,0,1);write_reply(0,0,1);
        write_command(1,4,2);write_reply(2,0,2);
        write_command((1<<AW)-B,2*B,3);write_reply(2,0,3);
        if(write_mem.requests!=count_before)$fatal(1,"invalid/empty command accessed memory");
        read_command(7,0,4);read_reply(0,0,4);
        read_command(1,4,5);read_reply(2,0,5);
        // Bad keep and early last reject the malformed beat before any write.
        write_command(256,B,6);put_beat(0,0,1);write_reply(3,0,6);
        write_command(256,2*B,7);put_beat(0,{B{1'b1}},1);write_reply(3,0,7);
        // Fail the second write: only first acknowledged beat is counted.
        inject_w=1;error_w=256+B;
        write_command(256,2*B,8);put_beat({DW{1'b1}},{B{1'b1}},0);put_beat(0,{B{1'b1}},1);
        write_reply(4,B,8);inject_w=0;
        inject_r=1;error_r=256;
        read_command(256,B,9);read_reply(4,0,9);inject_r=0;
        if(rmv)$fatal(1,"bus error produced a stream output");
        if(USE_NATIVE)begin
            // Abort a write while waiting for stream input.
            write_command(384,B,10);@(negedge clk);abort_write=1;
            do @(posedge clk);while(!ce);@(negedge clk);abort_write=0;
            write_reply(5,0,10);
            // Abort an outstanding read; its response is drained before next command.
            read_command(128,B,11);
            do @(posedge clk);while(!(ce&&qv[1]&&qr[1]));
            @(negedge clk);abort_read=1;do @(posedge clk);while(!ce);@(negedge clk);abort_read=0;
            read_reply(5,0,11);
            // Visible stalled output must be held and delivered on abort.
            read_command(128,2*B,12);while(!rmv)@(negedge clk);held=rmd;
            abort_read=1;repeat(5)begin @(negedge clk);if(!rmv||rmd!==held)$fatal(1,"abort withdrew pending output");end
            mr=1;do @(posedge clk);while(!ce);@(negedge clk);mr=0;abort_read=0;
            read_reply(5,B,12);
        end
        // Synchronous domain reset cancels a buffered completion and permits reuse.
        write_command(0,0,13);while(!wrv)@(negedge clk);
        rst_n=0;repeat(2)@(negedge clk);rst_n=1;
        write_command(0,0,14);write_reply(0,0,14);
        $display("PASS DMA stream group DW=%0d native_abort=%0d",DW,USE_NATIVE);
        finished=1;
    end
endmodule

module dma_chain_case(output reg finished=0);
    localparam DW=32,AW=12,LW=16,TW=8,B=4;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,ce=1,abort=0,cv=0,rr=0;
    integer cycles=0;
    always @(negedge clk)begin cycles=cycles+1;ce=(cycles%6!=2);end
    reg [AW-1:0] head=0;
    reg [TW-1:0] tag=0;
    wire cr,rv,err,terminal,busy,done,irq;
    wire [7:0] status;
    wire [TW-1:0] rtag,dtag;
    wire [AW-1:0] rhead;
    wire [LW-1:0] bytes;
    wire [31:0] descriptors;
    wire dqv,dqr,drv,drr;
    wire [AW-1:0] dqa;
    reg [AW-1:0] ds=0,dd=0,dn=0;
    reg [LW-1:0] dl=0;
    reg dlast=0,de=0;
    reg [TW-1:0] dt=0;
    reg desc_pending=0,desc_valid=0;
    integer desc_timer=0,desc_requests=0,mode=0;
    wire qv,qr,qw,mrv,mrr,mer;
    wire [AW-1:0] qa;
    wire [DW-1:0] qd,mrd;
    wire [B-1:0] qs;
    reg inject_error=0;reg [AW-1:0] error_addr=0;
    cip_dma_descriptor_chain #(.DATA_WIDTH(DW),.ADDR_WIDTH(AW),.LEN_WIDTH(LW),.TAG_WIDTH(TW),.MAX_DESCRIPTORS(3)) dut(
        .clk(clk),.rst_n(rst_n),.clk_en(ce),.abort(abort),.cmd_valid(cv),.cmd_ready(cr),.cmd_head_addr(head),.cmd_tag(tag),
        .rsp_valid(rv),.rsp_ready(rr),.rsp_error(err),.rsp_status(status),.rsp_tag(rtag),.rsp_head_addr(rhead),.rsp_bytes(bytes),
        .rsp_descriptor_tag(dtag),.rsp_descriptors(descriptors),.rsp_terminal(terminal),.busy(busy),.done(done),.irq(irq),
        .desc_req_valid(dqv),.desc_req_ready(dqr),.desc_req_addr(dqa),
        .desc_rsp_valid(drv),.desc_rsp_ready(drr),.desc_rsp_src(ds),.desc_rsp_dst(dd),.desc_rsp_byte_len(dl),
        .desc_rsp_next(dn),.desc_rsp_last(dlast),.desc_rsp_tag(dt),.desc_rsp_error(de),
        .mem_req_valid(qv),.mem_req_ready(qr),.mem_req_write(qw),.mem_req_addr(qa),.mem_req_wdata(qd),.mem_req_wstrb(qs),
        .mem_rsp_valid(mrv),.mem_rsp_ready(mrr),.mem_rsp_rdata(mrd),.mem_rsp_error(mer));
    dma_test_memory #(.DW(DW),.AW(AW)) memory(clk,rst_n,ce,qv,qr,qw,qa,qd,qs,mrv,mrr,mrd,mer,inject_error,error_addr);
    assign dqr=rst_n&&!desc_pending&&!desc_valid&&cycles%4!=0;
    assign drv=desc_valid;
    always @(posedge clk)begin
        if(!rst_n)begin desc_pending<=0;desc_valid<=0;desc_timer<=0;desc_requests<=0;end
        else if(ce)begin
            if(desc_valid&&drr)desc_valid<=0;
            if(desc_pending)begin
                if(desc_timer==0)begin desc_pending<=0;desc_valid<=1;end
                else desc_timer<=desc_timer-1;
            end
            if(dqv&&dqr)begin
                desc_pending<=1;desc_timer<=2;desc_requests<=desc_requests+1;
                de<=0;ds<=64;dd<=256;dl<=11;dn<=20;dlast<=0;dt<=8'ha1;
                if(mode==0 && dqa==20)begin ds<=128;dd<=384;dl<=5;dlast<=1;dt<=8'ha2;end
                if(mode==1)begin dl<=0;dn<=dqa;end // cyclic chain must hit bound
                if(mode==2)begin de<=1;end
                if(mode==3)begin ds<=65;dlast<=1;end
                if(mode==4)begin dd<=68;dlast<=1;end
                if(mode==5)begin ds<=64;dd<=256;dl<=8;dlast<=1;end
                if(mode==6)begin dl<=0;dlast<=1;end
            end
        end
    end
    task command(input integer h,t);
        begin @(negedge clk);head=h;tag=t;cv=1;
            do @(posedge clk);while(!(ce&&cr));@(negedge clk);cv=0;
        end
    endtask
    task reply(input integer st,nb,nd,t);
        begin
            while(!rv)@(negedge clk);
            repeat(5)begin
                @(negedge clk);
                if(!rv||status!==st||bytes!==nb||descriptors!==nd||rtag!==t||rhead!==head||!terminal||err!==(st!=0))
                    $fatal(1,"chain reply expected %0d/%0d/%0d got %0d/%0d/%0d",st,nb,nd,status,bytes,descriptors);
            end
            rr=1;do @(posedge clk);while(!ce);@(negedge clk);rr=0;
        end
    endtask
    integer i,before_requests;
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        for(i=0;i<32;i=i+1)begin memory.memory[64+i]=i*3+1;memory.memory[128+i]=i*7+2;end
        command(16,1);reply(0,16,2,1);
        for(i=0;i<11;i=i+1)if(memory.memory[256+i]!==memory.memory[64+i])$fatal(1,"chain descriptor1 byte");
        for(i=0;i<5;i=i+1)if(memory.memory[384+i]!==memory.memory[128+i])$fatal(1,"chain descriptor2 byte");
        if(memory.memory[267]!==8'ha5||memory.memory[389]!==8'ha5||dtag!==8'ha2)$fatal(1,"chain tail/descriptor metadata");
        mode=1;before_requests=desc_requests;command(32,2);reply(8,0,3,2);
        if(desc_requests-before_requests!=3)$fatal(1,"chain bound did not stop cycle");
        mode=2;command(48,3);reply(7,0,0,3);
        mode=3;command(48,4);reply(2,0,0,4);
        mode=4;command(48,5);reply(9,0,0,5);
        mode=5;inject_error=1;error_addr=260;command(48,6);reply(4,4,0,6);inject_error=0;
        // Abort while decoded descriptor response is outstanding: drain it first.
        mode=0;command(16,7);
        do @(posedge clk);while(!(ce&&dqv&&dqr));
        @(negedge clk);abort=1;do @(posedge clk);while(!ce);@(negedge clk);abort=0;
        reply(5,0,0,7);
        mode=6;command(64,8);reply(0,0,1,8);
        $display("PASS DMA descriptor group chain/copy/partial/error/bound/abort");finished=1;
    end
endmodule

module tb_cip_dma_e2e;
    wire a,b,c;
    dma_roundtrip_case #(.DW(32),.USE_NATIVE(0)) r32(a);
    dma_roundtrip_case #(.DW(64),.USE_NATIVE(1)) r64(b);
    dma_chain_case chain(c);
    initial begin wait(a&&b&&c);$display("PASS DMA E2E GROUP");$finish;end
    initial begin #2000000;$fatal(1,"DMA group timeout");end
endmodule
