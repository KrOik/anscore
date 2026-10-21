`timescale 1ns/1ps
`default_nettype none
module tb_common_serial_group;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0;
    reg [3:0] ce=4'hf,cv=0,cw=0,rr=0;
    wire [3:0] cr,rv;
    reg [7:0] ca[0:3];reg [31:0] wd[0:3];wire [31:0] rd[0:3];wire [1:0] er[0:3];
    reg urx=1;wire utx;
    wire ss,sm;reg si=1;wire [1:0] scs;
    wire isl,idl;reg ssl=0,ssd=0;wire scl=!(isl|ssl),sda=!(idl|ssd);
    wire qcs,qs;wire [3:0] qo,qe;reg [3:0] qi=0;
    common_uart #(.CLOCK_HZ(1600),.BAUD(100)) u(.clk(clk),.rst_n(rst_n),.clk_en(ce[0]),
        .cmd_valid(cv[0]),.cmd_ready(cr[0]),.cmd_write(cw[0]),.cmd_addr(ca[0]),.cmd_wdata(wd[0]),
        .rsp_valid(rv[0]),.rsp_ready(rr[0]),.rsp_rdata(rd[0]),.rsp_error(er[0]),.uart_rx(urx),.uart_tx(utx));
    common_spi_master #(.NUM_CS(2),.CLOCK_DIV(2)) s(.clk(clk),.rst_n(rst_n),.clk_en(ce[1]),
        .cmd_valid(cv[1]),.cmd_ready(cr[1]),.cmd_write(cw[1]),.cmd_addr(ca[1]),.cmd_wdata(wd[1]),
        .rsp_valid(rv[1]),.rsp_ready(rr[1]),.rsp_rdata(rd[1]),.rsp_error(er[1]),
        .spi_sclk(ss),.spi_mosi(sm),.spi_miso(si),.spi_cs_n(scs));
    common_i2c_master #(.CLOCK_DIV(4),.STRETCH_TIMEOUT_TICKS(40)) i(.clk(clk),.rst_n(rst_n),.clk_en(ce[2]),
        .cmd_valid(cv[2]),.cmd_ready(cr[2]),.cmd_write(cw[2]),.cmd_addr(ca[2]),.cmd_wdata(wd[2]),
        .rsp_valid(rv[2]),.rsp_ready(rr[2]),.rsp_rdata(rd[2]),.rsp_error(er[2]),
        .i2c_scl_in(scl),.i2c_sda_in(sda),.i2c_scl_drive_low(isl),.i2c_sda_drive_low(idl));
    common_qspi_controller #(.CLOCK_DIV(2)) q(.clk(clk),.rst_n(rst_n),.clk_en(ce[3]),
        .cmd_valid(cv[3]),.cmd_ready(cr[3]),.cmd_write(cw[3]),.cmd_addr(ca[3]),.cmd_wdata(wd[3]),
        .rsp_valid(rv[3]),.rsp_ready(rr[3]),.rsp_rdata(rd[3]),.rsp_error(er[3]),
        .qspi_cs_n(qcs),.qspi_sclk(qs),.qspi_dq_in(qi),.qspi_dq_out(qo),.qspi_dq_oe(qe));
    integer transactions=0,n,m;
    reg [31:0] result;
    task automatic csr(input integer port,input bit write,input [7:0] addr,input [31:0] data,
                       input [1:0] error,input [31:0] mask,input [31:0] expected);
        reg [31:0] hold_data;reg [1:0] hold_error;
        begin
            @(negedge clk);while(!cr[port] || !ce[port]) @(negedge clk);
            cv[port]=1;cw[port]=write;ca[port]=addr;wd[port]=data;
            @(negedge clk);cv[port]=0;
            while(!rv[port]) @(negedge clk);
            hold_data=rd[port];hold_error=er[port];
            repeat(3) begin
                @(negedge clk);
                if(rv[port]!==1 || rd[port]!==hold_data || er[port]!==hold_error)
                    $fatal(1,"response backpressure changed port=%0d",port);
            end
            if(hold_error!==error || (hold_data & mask)!==expected)
                $fatal(1,"CSR p=%0d wr=%0d addr=%h got=%h/%0d expected=%h/%0d",port,write,addr,hold_data,hold_error,expected,error);
            result=hold_data;
            while(!ce[port]) @(negedge clk);
            rr[port]=1;@(negedge clk);rr[port]=0;
            transactions=transactions+1;
        end
    endtask
    task automatic uart_send(input [7:0] value,input bit good_stop);
        integer b;
        begin
            @(negedge clk);urx=0;repeat(16) @(negedge clk);
            for(b=0;b<8;b=b+1) begin urx=value[b];repeat(16) @(negedge clk);end
            urx=good_stop;repeat(16) @(negedge clk);urx=1;repeat(20) @(negedge clk);
        end
    endtask
    task automatic uart_expect(input [7:0] value);
        integer b;
        begin
            @(negedge utx);repeat(8) @(negedge clk);
            if(utx!==0) $fatal(1,"UART start");
            for(b=0;b<8;b=b+1) begin repeat(16) @(negedge clk);if(utx!==value[b]) $fatal(1,"UART TX bit %0d",b);end
            repeat(16) @(negedge clk);if(utx!==1) $fatal(1,"UART stop");
        end
    endtask
    reg sp=0,sh=0;integer sb=0;reg [7:0] captured_spi=0;time last_spi_edge=0;
    always @(negedge scs[0]) begin sb=0;captured_spi=0;si=1'b1;last_spi_edge=0;end
    always @(ss) if(!scs[0] && rst_n) begin
        if(last_spi_edge!=0 && $time-last_spi_edge!=20) $fatal(1,"SPI physical clock stretched by CE");
        last_spi_edge=$time;
        if(ss!=sp) begin
            if(sh) si=(8'h96>>(7-sb))&1;
            else captured_spi={captured_spi[6:0],sm};
        end else begin
            if(sh) captured_spi={captured_spi[6:0],sm};
            sb=sb+1;
            if(!sh && sb<8) si=(8'h96>>(7-sb))&1;
        end
    end
    integer ib=0,istarts=0,istops=0;reg ia=0,ir=0,inack=0;reg [7:0] icap=0;
    always @(negedge sda) if(scl && rst_n) begin ia=1;ib=0;icap=0;istarts=istarts+1;end
    always @(posedge sda) if(scl && rst_n) begin ia=0;istops=istops+1;end
    always @(posedge scl) if(ia && rst_n) begin
        if(ib<8) icap={icap[6:0],sda};
        else if(ir && sda!==1) $fatal(1,"I2C final read NACK missing");
        ib=ib+1;
    end
    always @(negedge scl) if(ia && rst_n) begin
        if(ib==9) begin ib=0;ssd=0;end
        else if(ir) begin
            if(ib<8) ssd=!((8'hd2>>(7-ib))&1);else ssd=0;
        end else ssd=(ib==8 && !inack);
    end
    reg [63:0] qcap=0;integer qb=0;integer qmodel=0;reg [31:0] qseq=32'habcdef01;
    always @(negedge qcs) begin qb=0;qcap=0;qi=0;end
    always @(posedge qs) if(!qcs) begin
        if(qmodel==0 || qb<32) begin
            if(qe[0]!==1) $fatal(1,"QSPI command/address output enable");
            qcap={qcap[62:0],qo[0]};
        end else if(qmodel==3) begin
            if(qe!==4'hf) $fatal(1,"QSPI quad write output enable");
            qcap={qcap[59:0],qo};
        end else if(qe!==0) $fatal(1,"QSPI read/dummy must release DQ");
        qb=qb+1;
    end
    always @(negedge qs) if(!qcs) begin
        if(qmodel==1 && qb>=34 && qb<42) qi=(qseq>>(28-(qb-34)*4))&15;
        if(qmodel==2 && qb>=32 && qb<64) qi={2'b0,((qseq>>(31-(qb-32)))&1'b1),1'b0};
    end
    initial begin
        for(n=0;n<4;n=n+1) begin ca[n]=0;wd[n]=0;end
        repeat(5) @(negedge clk);rst_n=1;repeat(5) @(negedge clk);
        // UART uses independent serial source and sink, including CE pause.
        fork csr(0,1,0,8'ha6,0,0,0);uart_expect(8'ha6);
            begin repeat(25) @(negedge clk);ce[0]=0;repeat(70) @(negedge clk);ce[0]=1;end
        join
        fork uart_send(8'h3c,1);begin ce[0]=0;repeat(180) @(negedge clk);ce[0]=1;end join
        csr(0,0,4,0,0,32'hff,32'h3c);
        uart_send(8'ha5,1);uart_send(8'h5a,1);
        csr(0,0,8,0,0,32'h6,32'h6);csr(0,0,4,0,0,32'hff,32'ha5);
        uart_send(8'h11,0);csr(0,0,8,0,0,32'hc,32'hc);
        csr(0,1,8,12,0,0,0);csr(0,0,8,0,0,12,0);csr(0,1,12,3,3,0,0);
        // Real slave feeds 0x96 independently of MOSI in all four modes.
        for(m=0;m<4;m=m+1) begin
            sp=m&1;sh=(m>>1)&1;csr(1,1,0,m,0,0,0);
            fork csr(1,1,12,8'ha0+m,0,32'hff,32'h96);
                begin repeat(8) @(negedge clk);ce[1]=0;repeat(40) @(negedge clk);ce[1]=1;end
            join
            if(captured_spi!==(8'ha0+m) || sb!=8 || scs!==2'b11) $fatal(1,"SPI slave capture mode=%0d got=%h bits=%0d",m,captured_spi,sb);
        end
        csr(1,1,0,4,0,0,0);csr(1,1,12,8'h55,0,255,150);
        if(scs!==2'b10) $fatal(1,"SPI held CS");csr(1,1,20,0,0,0,0);
        // I2C address + repeated START address + read + STOP; clock stretching.
        csr(2,1,4,8'ha0,0,0,0);
        fork csr(2,1,0,1,0,32'hf00,0);
            begin wait(isl===1);ssl=1;repeat(15) @(negedge clk);ssl=0;end
            begin repeat(10) @(negedge clk);ce[2]=0;repeat(150) @(negedge clk);ce[2]=1;end
        join
        if(icap!==8'ha0 || !isl) $fatal(1,"I2C write or held bus got=%h",icap);
        csr(2,1,4,8'ha1,0,0,0);csr(2,1,0,1,0,32'hf00,0);
        if(icap!==8'ha1) $fatal(1,"I2C repeated address");
        ir=1;csr(2,1,0,14,0,32'hfff,32'h0d2);ir=0;
        if(isl || idl || istarts!=2 || istops!=1) $fatal(1,"I2C STOP/start count");
        inack=1;csr(2,1,4,8'ha0,0,0,0);csr(2,1,0,3,3,32'hf00,32'h100);inack=0;
        fork csr(2,1,0,3,3,32'hf00,32'h400);
            begin wait(isl===1);ssl=1;repeat(70) @(negedge clk);ssl=0;end
        join
        // QSPI 1-1-1 write, 1-1-4 read and 1-1-1 read from flash model.
        csr(3,1,8'h40,32'h44332211,0,0,0);csr(3,1,0,2,0,0,0);
        csr(3,1,4,32'h123456,0,0,0);csr(3,1,8,32'h403,0,0,0);
        csr(3,1,16,1,0,255,4);
        if(qcap!==64'h0212345611223344 || qb!=64) $fatal(1,"QSPI single write capture=%h edges=%0d",qcap,qb);
        qmodel=1;csr(3,1,0,8'h6b,0,0,0);csr(3,1,8,32'h41b,0,0,0);csr(3,1,20,2,0,0,0);
        fork csr(3,1,16,1,0,255,4);begin repeat(10) @(negedge clk);ce[3]=0;repeat(100) @(negedge clk);ce[3]=1;end join
        if(qcap[31:0]!==32'h6b123456 || qb!=42) $fatal(1,"QSPI quad read command capture=%h edges=%0d",qcap,qb);
        csr(3,0,8'h40,0,0,32'hffffffff,32'h01efcdab);
        qmodel=2;csr(3,1,0,3,0,0,0);csr(3,1,8,32'h413,0,0,0);csr(3,1,20,0,0,0,0);
        csr(3,1,16,1,0,255,4);csr(3,0,8'h40,0,0,32'hffffffff,32'h01efcdab);
        qmodel=3;csr(3,1,8'h40,32'h44332211,0,0,0);csr(3,1,0,8'h32,0,0,0);csr(3,1,8,32'h40b,0,0,0);
        csr(3,1,16,1,0,255,4);
        if(qcap!==64'h3212345611223344 || qb!=40) $fatal(1,"QSPI quad write capture=%h edges=%0d",qcap,qb);
        qmodel=1;csr(3,1,0,8'h6b,0,0,0);csr(3,1,8,32'h11b,0,0,0);csr(3,1,20,2,0,0,0);
        csr(3,1,16,1,0,255,1);csr(3,0,8'h40,0,0,32'hffffffff,32'h000000ab);
        // Final finite access/config errors and reset abort of a serial transaction.
        csr(3,1,8,32'h485,3,0,0);csr(1,0,8'hfe,0,1,0,0);
        @(negedge clk);cv[1]=1;cw[1]=1;ca[1]=12;wd[1]=8'h88;
        @(negedge clk);cv[1]=0;repeat(5) @(negedge clk);rst_n=0;
        repeat(3) @(negedge clk);
        if(rv!==0 || utx!==1 || scs!==3 || isl || idl || !qcs) $fatal(1,"reset must release pins and abort responses");
        rst_n=1;repeat(5) @(negedge clk);
        $display("COMMON_SERIAL_GROUP PASS modules=4 transactions=%0d physical_clock_ce_independent=1",transactions);$finish;
    end
    initial begin #20000000;$fatal(1,"group watchdog");end
endmodule
`default_nettype wire
