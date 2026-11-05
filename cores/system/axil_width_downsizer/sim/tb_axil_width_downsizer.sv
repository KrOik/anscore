// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_axil_width_downsizer #(
    parameter ADDR_W=16,S_DATA_W=32,M_DATA_W=8
);
    localparam SB=S_DATA_W/8,MB=M_DATA_W/8,RATIO=S_DATA_W/M_DATA_W;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg [ADDR_W-1:0] s_awaddr=0,s_araddr=0;
    reg [2:0] s_awprot=0,s_arprot=0;
    reg s_awvalid=0,s_wvalid=0,s_arvalid=0,s_bready=0,s_rready=0;
    reg [S_DATA_W-1:0] s_wdata=0;
    reg [SB-1:0] s_wstrb=0;
    wire s_awready,s_wready,s_arready,s_bvalid,s_rvalid;
    wire [1:0] s_bresp,s_rresp;
    wire [S_DATA_W-1:0] s_rdata;
    wire [ADDR_W-1:0] m_awaddr,m_araddr;
    wire [2:0] m_awprot,m_arprot;
    wire [M_DATA_W-1:0] m_wdata;
    wire [MB-1:0] m_wstrb;
    wire m_awvalid,m_wvalid,m_arvalid,m_bready,m_rready;
    reg m_awready=0,m_wready=0,m_arready=0,m_bvalid=0,m_rvalid=0;
    reg [1:0] m_bresp=0,m_rresp=0;
    reg [M_DATA_W-1:0] m_rdata=0;
    axil_width_downsizer #(.ADDR_W(ADDR_W),.S_DATA_W(S_DATA_W),.M_DATA_W(M_DATA_W)) dut(.*);
    integer cycles=0,aw_count=0,w_count=0,ar_count=0,b_count=0,r_count=0;
    reg ah=0,wh=0,rh=0,bh=0,sh=0;
    reg [ADDR_W+2:0] aheld,rheld;
    reg [M_DATA_W+MB-1:0] wheld;
    reg [1:0] bheld;
    reg [S_DATA_W+1:0] sheld;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>20000) $fatal(1,"bounded cycle deadline");
        if(rst) begin ah=0;wh=0;rh=0;bh=0;sh=0;end
        else begin
            if(ah&&(!m_awvalid||{m_awaddr,m_awprot}!==aheld)) $fatal(1,"AW hold");
            if(wh&&(!m_wvalid||{m_wdata,m_wstrb}!==wheld)) $fatal(1,"W hold");
            if(rh&&(!m_arvalid||{m_araddr,m_arprot}!==rheld)) $fatal(1,"AR hold");
            if(bh&&(!s_bvalid||s_bresp!==bheld)) $fatal(1,"B hold");
            if(sh&&(!s_rvalid||{s_rdata,s_rresp}!==sheld)) $fatal(1,"R hold");
            ah=m_awvalid&&!m_awready;aheld={m_awaddr,m_awprot};
            wh=m_wvalid&&!m_wready;wheld={m_wdata,m_wstrb};
            rh=m_arvalid&&!m_arready;rheld={m_araddr,m_arprot};
            bh=s_bvalid&&!s_bready;bheld=s_bresp;
            sh=s_rvalid&&!s_rready;sheld={s_rdata,s_rresp};
            if(m_awvalid&&m_awready) aw_count=aw_count+1;
            if(m_wvalid&&m_wready) w_count=w_count+1;
            if(m_arvalid&&m_arready) ar_count=ar_count+1;
            if(s_bvalid&&s_bready) b_count=b_count+1;
            if(s_rvalid&&s_rready) r_count=r_count+1;
        end
    end
    function [7:0] memory_byte(input [ADDR_W-1:0] address);
        integer j;
        begin
            memory_byte=8'ha7;
            for(j=0;j<ADDR_W;j=j+8) memory_byte=memory_byte ^ (address>>j);
        end
    endfunction
    function [1:0] target_response(input integer mode,input integer part);
        begin
            if(mode==4) target_response=(part==0)?2:0;
            else if(mode==5) target_response=(part==RATIO-1)?3:2;
            else target_response=mode;
        end
    endfunction
    function [1:0] expected_response(input integer mode,input [SB-1:0] mask);
        integer j;
        reg [1:0] response;
        begin
            expected_response=0;
            for(j=0;j<RATIO;j=j+1) if(|mask[j*MB+:MB]) begin
                response=target_response(mode,j);
                case(response)
                    3: expected_response=3;
                    2: if(expected_response!=3) expected_response=2;
                    1: if(expected_response==0) expected_response=1;
                    default: begin end
                endcase
            end
        end
    endfunction
    function [S_DATA_W-1:0] expected_word(input [ADDR_W-1:0] address);
        integer j;
        begin for(j=0;j<SB;j=j+1) expected_word[j*8+:8]=memory_byte(address+j);end
    endfunction
    task reset_core;
        begin
            @(negedge clk);rst=1;s_awvalid=0;s_wvalid=0;s_arvalid=0;s_bready=0;s_rready=0;
            m_awready=0;m_wready=0;m_arready=0;m_bvalid=0;m_rvalid=0;
            repeat(2) @(negedge clk);
            if(s_bvalid||s_rvalid||m_awvalid||m_wvalid||m_arvalid||s_awready||s_wready||s_arready)
                $fatal(1,"reset qualification");
            rst=0;
        end
    endtask
    task send_aw(input [ADDR_W-1:0] address,input integer delay_n);
        begin repeat(delay_n) @(negedge clk);@(negedge clk);s_awaddr=address;s_awprot=5;s_awvalid=1;
            @(posedge clk);while(!s_awready) @(posedge clk);@(negedge clk);s_awvalid=0;end
    endtask
    task send_w(input [S_DATA_W-1:0] data,input [SB-1:0] mask,input integer delay_n);
        begin repeat(delay_n) @(negedge clk);@(negedge clk);s_wdata=data;s_wstrb=mask;s_wvalid=1;
            @(posedge clk);while(!s_wready) @(posedge clk);@(negedge clk);s_wvalid=0;end
    endtask
    task send_write(input [ADDR_W-1:0] address,input [S_DATA_W-1:0] data,input [SB-1:0] mask,input integer order);
        fork send_aw(address,order%3);send_w(data,mask,2-order%3);join
    endtask
    task send_read(input [ADDR_W-1:0] address);
        begin @(negedge clk);s_araddr=address;s_arprot=6;s_arvalid=1;
            @(posedge clk);while(!s_arready) @(posedge clk);@(negedge clk);s_arvalid=0;end
    endtask
    task target_write(input [ADDR_W-1:0] address,input [S_DATA_W-1:0] data,input [SB-1:0] mask,input integer mode);
        integer j;
        begin
            for(j=0;j<RATIO;j=j+1) if(|mask[j*MB+:MB]) begin
                fork
                    begin
                        repeat(j%3) @(negedge clk);m_awready=1;
                        @(posedge clk);while(!m_awvalid) @(posedge clk);
                        if(m_awaddr!==ADDR_W'(address+j*MB)||m_awprot!==3'd5) $fatal(1,"AW address/protection split");
                        @(negedge clk);m_awready=0;
                    end
                    begin
                        repeat((j+1)%3) @(negedge clk);m_wready=1;
                        @(posedge clk);while(!m_wvalid) @(posedge clk);
                        if(m_wdata!==data[j*M_DATA_W+:M_DATA_W]||m_wstrb!==mask[j*MB+:MB])
                            $fatal(1,"W data/strobe split");
                        @(negedge clk);m_wready=0;
                    end
                join
                repeat(j%2) @(negedge clk);m_bresp=target_response(mode,j);m_bvalid=1;
                @(posedge clk);while(!m_bready) @(posedge clk);@(negedge clk);m_bvalid=0;
            end
        end
    endtask
    task target_read(input [ADDR_W-1:0] address,input integer mode);
        integer j,k;
        begin
            for(j=0;j<RATIO;j=j+1) begin
                repeat(j%3) @(negedge clk);m_arready=1;
                @(posedge clk);while(!m_arvalid) @(posedge clk);
                if(m_araddr!==ADDR_W'(address+j*MB)||m_arprot!==3'd6) $fatal(1,"AR address/protection split");
                @(negedge clk);m_arready=0;
                for(k=0;k<MB;k=k+1) m_rdata[k*8+:8]=memory_byte(address+j*MB+k);
                repeat(j%2) @(negedge clk);m_rresp=target_response(mode,j);m_rvalid=1;
                @(posedge clk);while(!m_rready) @(posedge clk);@(negedge clk);m_rvalid=0;
            end
        end
    endtask
    task take_b(input [1:0] response);
        begin @(negedge clk);while(!s_bvalid) @(negedge clk);
            if(s_bresp!==response) $fatal(1,"B response aggregate expected %d got %d",response,s_bresp);
            repeat(4) @(negedge clk);s_bready=1;@(negedge clk);s_bready=0;
            if(s_bvalid) $fatal(1,"duplicate B");end
    endtask
    task take_r(input [S_DATA_W-1:0] data,input [1:0] response);
        begin @(negedge clk);while(!s_rvalid) @(negedge clk);
            if(s_rdata!==data||s_rresp!==response) $fatal(1,"R assembly expected %h/%d got %h/%d",data,response,s_rdata,s_rresp);
            repeat(4) @(negedge clk);s_rready=1;@(negedge clk);s_rready=0;
            if(s_rvalid) $fatal(1,"duplicate R");end
    endtask
    integer i,j,ac,wc,rc;
    reg [SB-1:0] mask;
    reg [S_DATA_W-1:0] pattern;
    reg [ADDR_W-1:0] base;
    initial begin
        reset_core();
        for(i=0;i<6;i=i+1) begin
            base=ADDR_W'((i+1)*SB);pattern=0;
            for(j=0;j<SB;j=j+1) pattern[j*8+:8]=8'h81+j*17+i;
            mask={SB{1'b1}};
            fork send_write(base,pattern,mask,i);target_write(base,pattern,mask,i);take_b(expected_response(i,mask));
                 send_read(base);target_read(base,i);take_r(expected_word(base),expected_response(i,mask));join
        end
        // Each byte enable in isolation and alternating masks skip inactive words.
        for(i=0;i<SB+2;i=i+1) begin
            mask=(i<SB)?(SB'(1)<<i):((i==SB)?SB'(85):SB'(170));
            fork send_write(0,pattern,mask,i);target_write(0,pattern,mask,0);take_b(0);join
        end
        ac=aw_count;wc=w_count;
        fork send_write(0,0,0,0);take_b(0);join
        if(aw_count!=ac||w_count!=wc) $fatal(1,"zero strobe had side effects");
        rc=ar_count;
        // Misalignment is a local decode error, including a zero-strobe write.
        fork send_write(1,pattern,{SB{1'b1}},1);take_b(3);send_read(1);take_r(0,3);join
        fork send_write(1,0,0,2);take_b(3);join
        if(aw_count!=ac||w_count!=wc||ar_count!=rc) $fatal(1,"misaligned access dispatched");
        // Last aligned wide word of the full address domain, no address wrap.
        base={ADDR_W{1'b1}} & ~ADDR_W'(SB-1);mask={SB{1'b1}};
        fork send_write(base,{S_DATA_W{1'b1}},mask,0);target_write(base,{S_DATA_W{1'b1}},mask,0);take_b(0);
             send_read(base);target_read(base,0);take_r(expected_word(base),0);join
        // One incomplete write must not dispatch. Reset cancels either half.
        send_aw(0,0);repeat(5) @(negedge clk);
        if(m_awvalid||m_wvalid||s_bvalid) $fatal(1,"unpaired AW dispatched");
        reset_core();send_w(0,1,0);reset_core();
        fork send_write(0,pattern,mask,0);send_read(0);join
        repeat(3) @(negedge clk);reset_core();
        // Held responses remain owned, then shared reset discards them.
        fork send_write(0,pattern,mask,0);target_write(0,pattern,mask,0);
             send_read(0);target_read(0,0);join
        while(!s_bvalid||!s_rvalid) @(negedge clk);
        repeat(4) @(negedge clk);reset_core();
        fork send_write(0,pattern,mask,0);target_write(0,pattern,mask,0);take_b(0);
             send_read(0);target_read(0,0);take_r(expected_word(0),0);join
        $display("PASS axil_width_downsizer A=%0d S=%0d M=%0d AW=%0d W=%0d AR=%0d B=%0d R=%0d cycles=%0d",ADDR_W,S_DATA_W,M_DATA_W,aw_count,w_count,ar_count,b_count,r_count,cycles);
        $finish;
    end
endmodule
