// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_axil_timeout_bridge #(
    parameter ADDR_W=16, DATA_W=32, TIMEOUT_CYCLES=8
);
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg [ADDR_W-1:0] s_awaddr=0,s_araddr=0;
    reg [2:0] s_awprot=0,s_arprot=0;
    reg s_awvalid=0,s_wvalid=0,s_arvalid=0,s_bready=0,s_rready=0;
    reg [DATA_W-1:0] s_wdata=0;
    reg [DATA_W/8-1:0] s_wstrb=0;
    wire s_awready,s_wready,s_arready,s_bvalid,s_rvalid;
    wire [1:0] s_bresp,s_rresp;
    wire [DATA_W-1:0] s_rdata;
    wire [ADDR_W-1:0] m_awaddr,m_araddr;
    wire [2:0] m_awprot,m_arprot;
    wire [DATA_W-1:0] m_wdata;
    wire [DATA_W/8-1:0] m_wstrb;
    wire m_awvalid,m_wvalid,m_arvalid,m_bready,m_rready;
    reg m_awready=0,m_wready=0,m_arready=0,m_bvalid=0,m_rvalid=0;
    reg [1:0] m_bresp=0,m_rresp=0;
    reg [DATA_W-1:0] m_rdata=0;
    wire write_fault,read_fault;
    axil_timeout_bridge #(.ADDR_W(ADDR_W),.DATA_W(DATA_W),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) dut(.*);

    integer cycles=0,aw_count=0,w_count=0,ar_count=0,b_count=0,r_count=0;
    reg [ADDR_W-1:0] last_aw,last_ar;
    reg [2:0] last_awprot,last_arprot;
    reg [DATA_W-1:0] last_w;
    reg [DATA_W/8-1:0] last_strb;
    reg ah=0,wh=0,rh=0,bh=0,sh=0;
    reg [ADDR_W+2:0] aheld,rheld;
    reg [DATA_W+DATA_W/8-1:0] wheld;
    reg [1:0] bheld;
    reg [DATA_W+1:0] sheld;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>10000) $fatal(1,"cycle deadline");
        if(!rst_n) begin ah=0;wh=0;rh=0;bh=0;sh=0; end
        else begin
            if(ah && (!m_awvalid || {m_awaddr,m_awprot}!==aheld)) $fatal(1,"AW hold");
            if(wh && (!m_wvalid || {m_wdata,m_wstrb}!==wheld)) $fatal(1,"W hold");
            if(rh && (!m_arvalid || {m_araddr,m_arprot}!==rheld)) $fatal(1,"AR hold");
            if(bh && (!s_bvalid || s_bresp!==bheld)) $fatal(1,"B hold");
            if(sh && (!s_rvalid || {s_rdata,s_rresp}!==sheld)) $fatal(1,"R hold");
            ah=m_awvalid&&!m_awready; aheld={m_awaddr,m_awprot};
            wh=m_wvalid&&!m_wready; wheld={m_wdata,m_wstrb};
            rh=m_arvalid&&!m_arready; rheld={m_araddr,m_arprot};
            bh=s_bvalid&&!s_bready; bheld=s_bresp;
            sh=s_rvalid&&!s_rready; sheld={s_rdata,s_rresp};
            if(m_awvalid&&m_awready) begin aw_count=aw_count+1;last_aw=m_awaddr;last_awprot=m_awprot;end
            if(m_wvalid&&m_wready) begin w_count=w_count+1;last_w=m_wdata;last_strb=m_wstrb;end
            if(m_arvalid&&m_arready) begin ar_count=ar_count+1;last_ar=m_araddr;last_arprot=m_arprot;end
            if(s_bvalid&&s_bready) b_count=b_count+1;
            if(s_rvalid&&s_rready) r_count=r_count+1;
        end
    end
    task reset;
        begin
            @(negedge clk);rst_n=0;s_awvalid=0;s_wvalid=0;s_arvalid=0;
            s_bready=0;s_rready=0;m_awready=0;m_wready=0;m_arready=0;m_bvalid=0;m_rvalid=0;
            repeat(2) @(negedge clk);
            if(s_bvalid||s_rvalid||m_awvalid||m_wvalid||m_arvalid||write_fault||read_fault)
                $fatal(1,"reset did not clear ownership");
            rst_n=1;
        end
    endtask
    task send_aw(input [ADDR_W-1:0] addr,input integer delay_n);
        begin repeat(delay_n) @(negedge clk);@(negedge clk);s_awaddr=addr;s_awprot=3'b101;s_awvalid=1;
            @(posedge clk);while(!s_awready) @(posedge clk);@(negedge clk);s_awvalid=0;end
    endtask
    task send_w(input [DATA_W-1:0] value,input [DATA_W/8-1:0] mask,input integer delay_n);
        begin repeat(delay_n) @(negedge clk);@(negedge clk);s_wdata=value;s_wstrb=mask;s_wvalid=1;
            @(posedge clk);while(!s_wready) @(posedge clk);@(negedge clk);s_wvalid=0;end
    endtask
    task send_write(input [ADDR_W-1:0] addr,input [DATA_W-1:0] value,input [DATA_W/8-1:0] mask,
                    input integer ad,input integer wd);
        fork send_aw(addr,ad);send_w(value,mask,wd);join
    endtask
    task send_read(input [ADDR_W-1:0] addr);
        begin @(negedge clk);s_araddr=addr;s_arprot=3'b110;s_arvalid=1;
            @(posedge clk);while(!s_arready) @(posedge clk);@(negedge clk);s_arvalid=0;end
    endtask
    task slave_write(input integer ad,input integer wd,input integer bd,input [1:0] response);
        begin
            fork
                begin repeat(ad) @(negedge clk);m_awready=1;
                    @(posedge clk);while(!m_awvalid) @(posedge clk);@(negedge clk);m_awready=0;end
                begin repeat(wd) @(negedge clk);m_wready=1;
                    @(posedge clk);while(!m_wvalid) @(posedge clk);@(negedge clk);m_wready=0;end
            join
            repeat(bd) @(negedge clk);m_bresp=response;m_bvalid=1;
            @(posedge clk);while(!m_bready) @(posedge clk);@(negedge clk);m_bvalid=0;
        end
    endtask
    task slave_read(input integer ad,input integer rd,input [DATA_W-1:0] value,input [1:0] response);
        begin
            repeat(ad) @(negedge clk);m_arready=1;
            @(posedge clk);while(!m_arvalid) @(posedge clk);@(negedge clk);m_arready=0;
            repeat(rd) @(negedge clk);m_rdata=value;m_rresp=response;m_rvalid=1;
            @(posedge clk);while(!m_rready) @(posedge clk);@(negedge clk);m_rvalid=0;
        end
    endtask
    task take_b(input [1:0] response);
        begin
            @(negedge clk);while(!s_bvalid) @(negedge clk);
            if(s_bresp!==response) $fatal(1,"B expected %d got %d",response,s_bresp);
            repeat(3) @(negedge clk);s_bready=1;@(negedge clk);s_bready=0;
            if(s_bvalid) $fatal(1,"extra B response");
        end
    endtask
    task take_r(input [DATA_W-1:0] value,input [1:0] response);
        begin
            @(negedge clk);while(!s_rvalid) @(negedge clk);
            if(s_rdata!==value||s_rresp!==response) $fatal(1,"R mismatch expected %h/%d got %h/%d",value,response,s_rdata,s_rresp);
            repeat(3) @(negedge clk);s_rready=1;@(negedge clk);s_rready=0;
            if(s_rvalid) $fatal(1,"extra R response");
        end
    endtask
    integer i,bc,rc,ac,wc,arc;
    reg [DATA_W-1:0] pattern;
    initial begin
        reset();
        if(TIMEOUT_CYCLES>=8) begin
            // Independent channels, AW/W arriving in either order, all response
            // encodings and byte strobes passed bit-for-bit; no memory model needed.
            for(i=0;i<4;i=i+1) begin
                pattern={DATA_W{1'b1}} ^ (i*32'h1020304);
                fork
                    send_write(i,pattern,i, (i%2)*2,((i+1)%2)*2);
                    slave_write(i%2,(i+1)%2,0,i);
                    take_b(i);
                    send_read(~i);
                    slave_read(1,0,~pattern,3-i);
                    take_r(~pattern,3-i);
                join
                if(last_aw!==ADDR_W'(i)||last_w!==pattern||last_strb!==((DATA_W/8)'(i))||last_awprot!==3'b101)
                    $fatal(1,"write forwarding fields");
                if(last_ar!==ADDR_W'(~i)||last_arprot!==3'b110||write_fault||read_fault)
                    $fatal(1,"read forwarding fields or spurious fault");
            end
            // Final allowed edge wins over timeout, for both directions.
            fork
                send_write(1,7,0,0,0);
                slave_write(0,0,TIMEOUT_CYCLES-2,2'b00);
                take_b(0);
                send_read(1);
                slave_read(0,TIMEOUT_CYCLES-2,5,2'b00);
                take_r(5,0);
            join
            if(write_fault||read_fault) $fatal(1,"deadline response lost priority");
        end
        reset();
        // Half a write is not dispatched or timed out: counterpart can arrive later.
        send_aw({ADDR_W{1'b1}},0);
        repeat(TIMEOUT_CYCLES+2) @(negedge clk);
        if(write_fault||s_bvalid||m_awvalid||m_wvalid) $fatal(1,"unpaired write dispatched");
        fork
            begin
                send_w({DATA_W{1'b1}},{(DATA_W/8){1'b1}},0);
                while(!m_awvalid) @(negedge clk);
                i=cycles;
                while(!s_bvalid) @(negedge clk);
                if(cycles-i!=TIMEOUT_CYCLES) $fatal(1,"write deadline count");
            end
            take_b(2);
        join
        if(!write_fault||read_fault||!m_awvalid||!m_wvalid) $fatal(1,"write timeout isolation");
        ac=aw_count;wc=w_count;
        // Local quarantined requests must not replace stalled original payload.
        fork send_write(0,0,0,2,0);take_b(2);join
        if(m_awaddr!=={ADDR_W{1'b1}}||m_wdata!=={DATA_W{1'b1}}||aw_count!=ac||w_count!=wc)
            $fatal(1,"quarantine changed original transaction");
        // Read channel remains live after write fault (when deadline permits).
        if(TIMEOUT_CYCLES>=8) begin
            fork send_read(3);slave_read(0,0,9,0);take_r(9,0);join
            if(read_fault) $fatal(1,"write fault contaminated read");
        end
        bc=b_count;
        slave_write(0,2,0,0);
        repeat(3) @(negedge clk);
        if(s_bvalid||b_count!=bc||m_bready||!write_fault) $fatal(1,"late B escaped drain");
        fork send_write(0,0,0,0,0);take_b(2);join
        if(m_awvalid||m_wvalid) $fatal(1,"quarantine ended without reset");
        reset();
        fork
            begin
                send_read({ADDR_W{1'b1}});i=cycles;
                while(!s_rvalid) @(negedge clk);
                if(cycles-i!=TIMEOUT_CYCLES) $fatal(1,"read deadline count");
            end
            take_r(0,2);
        join
        if(!read_fault||write_fault||!m_arvalid) $fatal(1,"read timeout isolation");
        arc=ar_count;
        fork send_read(0);take_r(0,2);join
        if(m_araddr!=={ADDR_W{1'b1}}||ar_count!=arc) $fatal(1,"read quarantine payload overwrite");
        rc=r_count;
        slave_read(0,0,{DATA_W{1'b1}},0);
        repeat(3) @(negedge clk);
        if(s_rvalid||r_count!=rc||m_rready||!read_fault) $fatal(1,"late R escaped drain");
        if(TIMEOUT_CYCLES>=8) begin
            fork send_write(3,9,1,0,0);slave_write(0,0,0,0);take_b(0);join
            if(write_fault) $fatal(1,"read fault contaminated write");
        end
        reset();
        // Requests accepted downstream, but responses arrive after the deadline.
        bc=b_count;rc=r_count;
        fork send_write(1,7,1,0,0);slave_write(0,0,TIMEOUT_CYCLES+2,0);take_b(2);
             send_read(1);slave_read(0,TIMEOUT_CYCLES+2,7,0);take_r(0,2);join
        repeat(3) @(negedge clk);
        if(!write_fault||!read_fault||s_bvalid||s_rvalid||b_count!=bc+1||r_count!=rc+1)
            $fatal(1,"accepted requests late response duplicate");
        reset();
        // Timeout while only one downstream write channel has accepted.
        fork
            send_write(1,3,1,0,0);
            begin m_awready=1;@(posedge clk);while(!m_awvalid) @(posedge clk);@(negedge clk);m_awready=0;end
            take_b(2);
        join
        if(m_awvalid||!m_wvalid||!write_fault) $fatal(1,"split write timeout");
        reset();
        // Reset discards active requests/responses and sticky faults jointly.
        fork send_read(1);send_write(1,1,1,0,0);join
        repeat(2) @(negedge clk);
        reset();
        if(TIMEOUT_CYCLES>=8) begin
            fork send_write(0,0,0,0,0);slave_write(0,0,0,0);take_b(0);
                 send_read(0);slave_read(0,0,0,0);take_r(0,0);join
        end
        $display("PASS axil_timeout_bridge ADDR_W=%0d DATA_W=%0d TIMEOUT=%0d cycles=%0d",ADDR_W,DATA_W,TIMEOUT_CYCLES,cycles);
        $finish;
    end
endmodule
