// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_stream_multicast;
    parameter PORTS=3, DATA_WIDTH=16, USER_WIDTH=4;
    localparam KEEP_WIDTH=DATA_WIDTH/8, DEPTH=1024;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg [DATA_WIDTH-1:0] s_data=0;
    reg [KEEP_WIDTH-1:0] s_keep=0;
    reg [USER_WIDTH-1:0] s_user=0;
    reg s_last=0, s_valid=0;
    reg [PORTS-1:0] s_mask=0, m_ready=0;
    wire s_ready;
    wire [PORTS*DATA_WIDTH-1:0] m_data;
    wire [PORTS*KEEP_WIDTH-1:0] m_keep;
    wire [PORTS*USER_WIDTH-1:0] m_user;
    wire [PORTS-1:0] m_last,m_valid;
    stream_multicast #(.PORTS(PORTS),.DATA_WIDTH(DATA_WIDTH),.USER_WIDTH(USER_WIDTH)) dut(.*);

    reg [DATA_WIDTH+KEEP_WIDTH+USER_WIDTH:0] expected [0:PORTS*DEPTH-1];
    reg [DATA_WIDTH+KEEP_WIDTH+USER_WIDTH:0] stalled_payload [0:PORTS-1];
    reg [PORTS-1:0] was_stalled=0, model_mask=0;
    reg model_packet=0;
    integer wr[0:PORTS-1],rd[0:PORTS-1];
    integer p,cycle=0,mode=1,total_input=0,total_output=0;
    reg [PORTS-1:0] route;
    reg [DATA_WIDTH+KEEP_WIDTH+USER_WIDTH:0] observed;

    always @(negedge clk) begin
        cycle=cycle+1;
        for(integer j=0;j<PORTS;j=j+1)
            case(mode)
                0: m_ready[j]=0;
                1: m_ready[j]=1;
                3: m_ready[j]=(j==0);
                default: m_ready[j]=((cycle+j*3)%(j+3)!=0) && ((cycle/7+j)%5!=0);
            endcase
    end

    // Independent per-output FIFO oracle: duplicate accepted input into the
    // packet-selected destination queues, then compare each observed transfer.
    always @(posedge clk) begin
        if(!rst_n) begin
            for(p=0;p<PORTS;p=p+1) begin wr[p]=0;rd[p]=0;end
            model_packet=0; model_mask=0;was_stalled=0;
        end else begin
            if(s_valid&&s_ready) begin
                route=model_packet?model_mask:s_mask;
                if(!model_packet) model_mask=s_mask;
                model_packet=!s_last;
                total_input=total_input+1;
                for(p=0;p<PORTS;p=p+1) if(route[p]) begin
                    if(wr[p]>=DEPTH) $fatal(1,"oracle capacity");
                    expected[p*DEPTH+wr[p]]={s_data,s_keep,s_user,s_last};
                    wr[p]=wr[p]+1;
                end
            end
            for(p=0;p<PORTS;p=p+1) begin
                observed={m_data[p*DATA_WIDTH+:DATA_WIDTH],m_keep[p*KEEP_WIDTH+:KEEP_WIDTH],
                          m_user[p*USER_WIDTH+:USER_WIDTH],m_last[p]};
                if(was_stalled[p] && (!m_valid[p] || observed!==stalled_payload[p]))
                    $fatal(1,"payload changed while stalled port=%0d",p);
                if(m_valid[p]&&m_ready[p]) begin
                    if(rd[p]>=wr[p]) $fatal(1,"unexpected duplicate output port=%0d",p);
                    if(observed!==expected[p*DEPTH+rd[p]])
                        $fatal(1,"output mismatch port=%0d index=%0d got=%h want=%h",
                               p,rd[p],observed,expected[p*DEPTH+rd[p]]);
                    rd[p]=rd[p]+1;total_output=total_output+1;
                end
                was_stalled[p]=m_valid[p]&&!m_ready[p];
                stalled_payload[p]=observed;
            end
        end
    end

    task beat(input integer value, input bit last, input [PORTS-1:0] mask);
        begin
            @(negedge clk);
            s_data=value*251+19;s_keep=(value%5==0)?0:((1<<KEEP_WIDTH)-1);
            s_user=value^7;s_last=last;s_mask=mask;s_valid=1;
            do @(posedge clk); while(!s_ready);
        end
    endtask
    task idle;
        begin @(negedge clk);s_valid=0;end
    endtask
    task drained;
        integer waiting;
        begin
            waiting=1;
            while(waiting) begin
                @(negedge clk);waiting=(|m_valid);
                for(integer k=0;k<PORTS;k=k+1) if(rd[k]!=wr[k]) waiting=1;
            end
        end
    endtask
    integer packet,b,n;
    reg [PORTS-1:0] mask;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        // Simultaneous all-ready consumers, and replacement every cycle.
        for(n=0;n<24;n=n+1) beat(n,n%4==3,{PORTS{1'b1}});
        idle();drained();
        // Unselected consumers held permanently not-ready cannot block port 0.
        mode=3;
        for(n=0;n<12;n=n+1) beat(600+n,n==11,(n==0)?1:{PORTS{1'b1}});
        idle();drained();
        // Empty selection must drain an entire packet with every sink stopped.
        mode=0;
        for(n=0;n<6;n=n+1) beat(700+n,n==5,(n==0)?0:{PORTS{1'b1}});
        idle();drained();
        // Partial delivery followed by reset cancels all remaining copies
        // and also forgets the old packet destination selection.
        mode=0;beat(777,0,{PORTS{1'b1}});idle();mode=3;
        repeat(4) @(negedge clk);
        rst_n=0;repeat(3) @(negedge clk);rst_n=1;mode=2;
        // Different masks, zero destination drop, in-packet mask mutation,
        // KEEP=0, one-beat packets, independent stalls and back-to-back LAST.
        for(packet=0;packet<40;packet=packet+1) begin
            case(packet%4)
                0:mask=0;
                1:mask={PORTS{1'b1}};
                2:mask=1<<(packet%PORTS);
                3:mask=({PORTS{1'b1}} ^ (1<<(packet%PORTS)));
            endcase
            for(b=0;b<(packet%6+1);b=b+1)
                beat(100+packet*6+b,b==packet%6,(b==0)?mask:~mask);
        end
        idle();drained();
        if(total_input<170 || total_output<40) $fatal(1,"insufficient traffic");
        $display("PASS stream_multicast ports=%0d width=%0d accepted=%0d delivered=%0d reset/drop/stall/mask/keep/last",
                 PORTS,DATA_WIDTH,total_input,total_output);
        $finish;
    end
    initial begin #200000;$fatal(1,"test timeout");end
endmodule
