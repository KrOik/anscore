// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_soupbintcp_ouch42_rx;
    parameter integer D=128,T=8;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,sv=0,rr=0;reg [7:0] sd=0;reg [T-1:0] st=0;
    wire sr,rv;wire [2:0] ss,os;wire [7:0] sk,reason,okind;
    wire [15:0] len,olen;wire [63:0] seq,nxt;wire [79:0] session;
    wire [T-1:0] tag;wire logged,closed,faulted,exhausted,is_ouch;wire [719:0] event_data;
    soupbintcp_ouch42_rx #(.FIFO_DEPTH(D),.TAG_W(T)) dut (
        .clk(clk),.rst(rst),.s_valid(sv),.s_ready(sr),.s_data(sd),.s_tag(st),
        .r_valid(rv),.r_ready(rr),.r_soup_status(ss),.r_soup_type(sk),
        .r_soup_reason(reason),.r_soup_length(len),.r_sequence(seq),.r_next(nxt),
        .r_session(session),.r_tag(tag),.r_logged(logged),.r_closed(closed),
        .r_faulted(faulted),.r_exhausted(exhausted),.r_is_ouch(is_ouch),
        .r_ouch_status(os),.r_ouch_type(okind),.r_ouch_length(olen),.r_event(event_data));
    integer fd,rc,n,i,h,j,limit,cases=0,checks=0,bytes=0,resets=0,holds=0,payload=0;
    integer er,ess,esk,ereason,elen,elog,eclosed,efault,eexhaust,eis,eos,eok,eolen;
    reg [63:0] eseq,enxt;reg [79:0] esession;
    reg [T-1:0] owner;reg [719:0] expected;reg [7:0] b;reg [4095:0] path;
    always @(posedge clk) if(!rst) begin
        if(sv && sr) bytes=bytes+1;
        if(dut.mv && dut.mr) payload=payload+1;
    end
    task reset_now;
        begin
            @(negedge clk);rst=1;sv=0;rr=0;resets=resets+1;
            #1;if(sr || rv) $fatal(1,"reset masking");
            @(posedge clk);#1;@(negedge clk);rst=0;
            #1;if(!sr || rv) $fatal(1,"reset owner");
        end
    endtask
    task send_byte(input [7:0] value,input [T-1:0] byte_tag);
        begin
            @(negedge clk);sv=1;sd=value;st=byte_tag;limit=0;
            while(!sr) begin
                @(posedge clk);#1;limit=limit+1;
                if(limit>32) $fatal(1,"unexpected Soup input stall");
                @(negedge clk);
            end
            @(posedge clk);#1;
        end
    endtask
    task check_snapshot;
        begin
            if(!rv || sr || ss!==ess[2:0] || sk!==esk[7:0] || reason!==ereason[7:0] ||
               len!==elen[15:0] || seq!==eseq || nxt!==enxt || session!==esession ||
               tag!==owner || logged!==elog[0] || closed!==eclosed[0] || faulted!==efault[0] ||
               exhausted!==eexhaust[0] || is_ouch!==eis[0] || os!==eos[2:0] ||
               okind!==eok[7:0] || olen!==eolen[15:0] || event_data!==expected)
                $fatal(1,"Soup join mismatch case=%0d ss=%0d os=%0d sk=%h seq=%0d next=%0d",cases,ss,os,sk,seq,nxt);
        end
    endtask
    task wait_join;
        begin
            @(negedge clk);sv=0;limit=0;
            while(!rv) begin
                @(posedge clk);#1;limit=limit+1;
                if(limit>2*D+64) $fatal(1,"manual join missing");
            end
        end
    endtask
    task retire_manual;
        begin
            @(negedge clk);rr=1;@(posedge clk);#1;checks=checks+1;
            @(negedge clk);rr=0;sv=0;
        end
    endtask
    task send_system;
        begin
            send_byte(0,17);send_byte(11,0);send_byte(8'h53,0);send_byte(8'h53,0);
            for(j=1;j<=8;j=j+1) send_byte(j[7:0],0);
            send_byte(8'h45,0);
            @(negedge clk);sv=0;
        end
    endtask
    task recovery;
        begin
            send_byte(0,17);send_byte(31,0);send_byte(8'h41,0);
            send_byte(8'h53,0);send_byte(8'h45,0);send_byte(8'h53,0);send_byte(8'h53,0);
            send_byte(8'h49,0);send_byte(8'h4f,0);send_byte(8'h4e,0);
            send_byte(8'h30,0);send_byte(8'h30,0);send_byte(8'h31,0);
            for(j=0;j<19;j=j+1) send_byte(8'h20,0);
            send_byte(8'h31,0);wait_join();
            if(ss!==0 || sk!==8'h41 || !logged || nxt!==64'd1 || is_ouch ||
               event_data!==720'd0 || tag!==T'(17)) $fatal(1,"login recovery");
            retire_manual();send_system();wait_join();
            expected=0;expected[719:656]=64'h0102030405060708;expected[79:72]=8'h45;
            if(ss!==0 || os!==0 || !is_ouch || okind!==8'h53 || olen!==16'd10 ||
               seq!==64'd1 || nxt!==64'd2 || event_data!==expected || tag!==T'(17))
                $fatal(1,"event recovery");
            retire_manual();
        end
    endtask
    initial begin
        if(!$value$plusargs("vectors=%s",path)) $fatal(1,"vectors missing");
        fd=$fopen(path,"r");if(!fd) $fatal(1,"vector open");
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%d %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
                n,owner,er,ess,esk,ereason,elen,eseq,enxt,esession,elog,eclosed,efault,
                eexhaust,eis,eos,eok,eolen,expected);
            if(rc==19) begin
                if(er) reset_now();
                for(i=0;i<n;i=i+1) begin
                    rc=$fscanf(fd,"%h",b);if(rc!=1) $fatal(1,"vector byte");
                    if((i+cases)%13==0) begin @(negedge clk);sv=0;@(posedge clk);#1;end
                    send_byte(b,i==0 ? owner : ~owner);
                end
                @(negedge clk);sv=0;rr=0;limit=0;
                while(!rv) begin
                    @(posedge clk);#1;limit=limit+1;
                    if(limit>2*D+64) $fatal(1,"Soup join result missing");
                end
                for(h=0;h<4;h=h+1) begin
                    // First prefix byte of a future heartbeat must not enter.
                    @(negedge clk);sv=1;sd=0;st=~owner;#1;check_snapshot();
                    @(posedge clk);#1;holds=holds+1;
                end
                @(negedge clk);rr=1;@(posedge clk);#1;checks=checks+1;
                @(negedge clk);sv=0;rr=0;#1;if(rv) $fatal(1,"double retirement");
                cases=cases+1;
            end else if(rc!=-1) $fatal(1,"vector header rc=%0d",rc);
        end
        $fclose(fd);
        // Reset must cancel an uncommitted Soup frame, a partial decoder frame,
        // and a joined public result. Each phase has a real login/event recovery.
        reset_now();
        send_byte(0,17);send_byte(11,0);send_byte(8'h53,0);
        send_byte(8'h53,0);send_byte(1,0);send_byte(2,0);
        reset_now();recovery();
        send_system();limit=0;
        while(dut.decoder.count!=16'd1) begin
            @(posedge clk);#1;limit=limit+1;
            if(limit>32 || dut.dv) $fatal(1,"partial decoder cancellation setup");
        end
        reset_now();recovery();
        send_system();wait_join();reset_now();recovery();
        if(cases!=29 || checks!=35 || resets!=9 || holds!=116 || payload!=669)
            $fatal(1,"coverage counters payload=%0d",payload);
        $display("B46_A_SOUP_PASS D=%0d T=%0d cases=%0d checks=%0d bytes=%0d payload=%0d resets=%0d canceled=3 holds=%0d",D,T,cases,checks,bytes,payload,resets,holds);
        $finish;
    end
    initial begin #20000000;$fatal(1,"finite simulation watchdog");end
endmodule
