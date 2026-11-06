// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_nasdaq_ouch42_server_rx;
    parameter integer T=8;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,sv=0,sl=0,rr=0;
    reg [7:0] sd=0;reg [T-1:0] st=0;
    wire sr,rv;wire [2:0] rs;wire [7:0] rt;
    wire [15:0] rl;wire [T-1:0] rtag;wire [719:0] revent;
    nasdaq_ouch42_server_rx #(.TAG_W(T)) dut (
        .clk(clk),.rst(rst),.s_valid(sv),.s_ready(sr),.s_data(sd),.s_last(sl),.s_tag(st),
        .r_valid(rv),.r_ready(rr),.r_status(rs),.r_type(rt),.r_length(rl),.r_tag(rtag),.r_event(revent));
    integer fd,rc,n,i,j,h,limit,es,et,cases=0,checks=0,bytes=0,resets=0,holds=0;
    reg [7:0] b;reg [T-1:0] owner;reg [719:0] expected;
    reg [4095:0] path;
    always @(posedge clk) if (!rst && sv && sr) bytes=bytes+1;
    task reset_now;
        begin
            @(negedge clk);rst=1;sv=0;rr=0;resets=resets+1;
            #1;if(sr || rv) $fatal(1,"reset masking");
            @(posedge clk);#1;
            @(negedge clk);rst=0;
            #1;if(!sr || rv) $fatal(1,"reset did not cancel owner");
        end
    endtask
    task send_byte(input [7:0] value,input last,input [T-1:0] tag);
        begin
            @(negedge clk);sv=1;sd=value;sl=last;st=tag;
            limit=0;
            while(!sr) begin
                @(posedge clk);#1;limit=limit+1;
                if(limit>8) $fatal(1,"unexpected receive backpressure");
                @(negedge clk);
            end
            @(posedge clk);#1;
        end
    endtask
    task check_result(input integer status,input integer kind,input integer length,
                      input [T-1:0] tag,input [719:0] event_value);
        begin
            @(negedge clk);sv=0;rr=0;limit=0;
            while(!rv) begin
                @(posedge clk);#1;limit=limit+1;
                if(limit>8) $fatal(1,"result missing");
            end
            for(h=0;h<4;h=h+1) begin
                @(negedge clk);sv=1;sd=8'hd7;sl=1;st=~tag;
                #1;
                if(!rv || sr || rs!==status[2:0] || rt!==kind[7:0] ||
                   rl!==length[15:0] || rtag!==tag || revent!==event_value)
                    $fatal(1,"atomic result mismatch case=%0d hold=%0d status=%0d expected=%0d type=%h length=%0d",cases,h,rs,status,rt,rl);
                @(posedge clk);#1;holds=holds+1;
            end
            @(negedge clk);rr=1;
            @(posedge clk);#1;checks=checks+1;
            @(negedge clk);sv=0;rr=0;
            #1;if(rv || !sr) $fatal(1,"retirement ownership");
        end
    endtask
    task recovery;
        begin
            send_byte(8'h53,0,17);
            for(j=1;j<=8;j=j+1) send_byte(j[7:0],0,~owner);
            send_byte(8'h45,1,~owner);
            expected=0;expected[719:656]=64'h0102030405060708;expected[79:72]=8'h45;
            check_result(0,8'h53,10,17,expected);
        end
    endtask
    initial begin
        if(!$value$plusargs("vectors=%s",path)) $fatal(1,"vectors missing");
        fd=$fopen(path,"r");if(!fd) $fatal(1,"vector open");
        reset_now();
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%d %d %h %h %h",n,es,et,owner,expected);
            if(rc==5) begin
                for(i=0;i<n;i=i+1) begin
                    rc=$fscanf(fd,"%h",b);if(rc!=1) $fatal(1,"vector byte");
                    if((i+cases)%11==0) begin @(negedge clk);sv=0;@(posedge clk);#1;end
                    send_byte(b,i==n-1,i==0 ? owner : ~owner);
                end
                check_result(es,et,n>65535 ? 65535:n,owner,expected);cases=cases+1;
            end else if(rc!=-1) $fatal(1,"vector header rc=%0d",rc);
        end
        $fclose(fd);
        // Reset cancels partial frame, CHECK, and a held result independently.
        send_byte(8'h55,0,1);send_byte(1,0,0);send_byte(2,0,0);
        reset_now();recovery();
        send_byte(8'h4a,1,1);reset_now();recovery();
        send_byte(8'h53,1,1);@(negedge clk);sv=0;
        @(posedge clk);#1;if(!rv) $fatal(1,"held cancellation setup");
        reset_now();recovery();
        if(cases!=2557 || checks!=2560 || resets!=4 || holds!=10240)
            $fatal(1,"coverage counters");
        $display("B46_A_CORE_PASS T=%0d cases=%0d checks=%0d bytes=%0d resets=%0d canceled=3 holds=%0d",T,cases,checks,bytes,resets,holds);
        $finish;
    end
    initial begin #20000000;$fatal(1,"finite simulation watchdog");end
endmodule
