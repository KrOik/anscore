`timescale 1ns/1ps
`default_nettype none
module tb_call_auction_clear;
    parameter integer N=9,P=12,Q=8,T=5;
    localparam integer W=Q+$clog2(N+1),MAX_CASES=256,MAX_ITEMS=16384;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,a_valid=0,s_valid=0,m_ready=0,s_side=0;
    wire a_ready,s_ready,m_valid;
    reg [31:0] a_rows=0;
    reg [P-1:0] a_reference=0,s_price=0;
    reg [Q-1:0] s_quantity=0;
    reg [T-1:0] a_tag=0;
    wire [1:0] m_status;
    wire [31:0] m_rows;
    wire [P-1:0] m_price;
    wire [W-1:0] m_matched,m_buy,m_sell;
    wire signed [W:0] m_imbalance;
    wire [T-1:0] m_tag;
    call_auction_clear #(.MAX_ROWS(N),.PRICE_W(P),.QTY_W(Q),.TAG_W(T)) dut(.*);
    reg [63:0] counts[0:MAX_CASES-1],refs[0:MAX_CASES-1],tags[0:MAX_CASES-1];
    reg [63:0] statuses[0:MAX_CASES-1],prices[0:MAX_CASES-1],matched[0:MAX_CASES-1],buys[0:MAX_CASES-1],sells[0:MAX_CASES-1];
    reg signed [63:0] imbalances[0:MAX_CASES-1];
    reg [63:0] row_side[0:MAX_ITEMS-1],row_price[0:MAX_ITEMS-1],row_qty[0:MAX_ITEMS-1];
    integer starts[0:MAX_CASES-1];
    integer fd,cases,k,j,ret,total_rows=0,checks=0,holds=0,futures=0,waits,live_resets=0,recoveries=0;
    reg [2047:0] filename;
    task reset_now;
        begin
            @(negedge clk);rst_n=0;a_valid=0;s_valid=0;m_ready=0;
            #1;if(a_ready||s_ready||m_valid)$fatal(1,"reset masks");
            repeat(2)@(negedge clk);
            rst_n=1;live_resets=live_resets+1;
        end
    endtask
    task offer(input integer index);
        begin a_rows=counts[index];a_reference=refs[index];a_tag=tags[index];a_valid=1;end
    endtask
    task accept_header(input integer index,input integer preoffered);
        begin
            if(!preoffered) begin @(negedge clk);offer(index);end
            waits=0;
            begin: header_wait
                forever begin
                    @(posedge clk);waits=waits+1;
                    if(a_ready)disable header_wait;
                    if(waits>50000)$fatal(1,"header timeout");
                end
            end
            if(preoffered)futures=futures+1;
            @(negedge clk);a_valid=0;
        end
    endtask
    task check_result(input integer index);
        begin
            if(m_status!==statuses[index]||m_rows!==counts[index]||m_tag!==tags[index]||
               m_price!==prices[index]||m_matched!==matched[index]||m_buy!==buys[index]||m_sell!==sells[index]||
               $signed(m_imbalance)!==imbalances[index])
                $fatal(1,"core case=%0d status=%0d price=%0d matched=%0d buy=%0d sell=%0d imbalance=%0d",index,m_status,m_price,m_matched,m_buy,m_sell,m_imbalance);
            if(a_ready||s_ready)$fatal(1,"result ownership");
        end
    endtask
    task empty_recovery;
        begin
            @(negedge clk);a_valid=1;a_rows=0;a_reference=0;a_tag=0;
            @(posedge clk);if(!a_ready)$fatal(1,"recovery header");
            @(negedge clk);a_valid=0;
            if(!m_valid||m_status!=1||m_rows!=0||m_price!=0||m_matched!=0||m_buy!=0||m_sell!=0||m_imbalance!=0||m_tag!=0)$fatal(1,"recovery result");
            m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;recoveries=recoveries+1;
        end
    endtask
    task one_header;
        begin
            @(negedge clk);a_valid=1;a_rows=1;a_reference=0;a_tag=0;
            @(posedge clk);if(!a_ready)$fatal(1,"live header");
            @(negedge clk);a_valid=0;
        end
    endtask
    initial begin
        if(!$value$plusargs("vectors=%s",filename))$fatal(1,"missing vector file");
        fd=$fopen(filename,"r");if(!fd)$fatal(1,"open vectors");
        ret=$fscanf(fd,"%d",cases);if(ret!=1||cases<1||cases>MAX_CASES)$fatal(1,"case count");
        for(k=0;k<cases;k=k+1)begin
            ret=$fscanf(fd,"%d %d %d %d %d %d %d %d %d",counts[k],refs[k],tags[k],statuses[k],prices[k],matched[k],buys[k],sells[k],imbalances[k]);
            if(ret!=9)$fatal(1,"header parse");starts[k]=total_rows;
            if(counts[k]<=N)for(j=0;j<counts[k];j=j+1)begin
                if(total_rows>=MAX_ITEMS)$fatal(1,"row capacity");
                ret=$fscanf(fd,"%d %d %d",row_side[total_rows],row_price[total_rows],row_qty[total_rows]);
                if(ret!=3)$fatal(1,"row parse");total_rows=total_rows+1;
            end
        end
        $fclose(fd);reset_now();
        for(k=0;k<cases;k=k+1)begin
            accept_header(k,k!=0);
            if(counts[k]<=N)for(j=0;j<counts[k];j=j+1)begin
                if(j%3==1)repeat(2)@(negedge clk);
                s_valid=1;s_side=row_side[starts[k]+j];s_price=row_price[starts[k]+j];s_quantity=row_qty[starts[k]+j];
                @(posedge clk);if(!s_ready)$fatal(1,"row ownership");
                @(negedge clk);s_valid=0;
            end
            if(k+1<cases)offer(k+1);
            waits=0;
            while(!m_valid)begin
                if(a_ready)$fatal(1,"future accepted during compute");
                @(negedge clk);waits=waits+1;
                if(waits>50000)$fatal(1,"result timeout");
            end
            repeat(4)begin
                check_result(k);holds=holds+1;@(negedge clk);
            end
            check_result(k);m_ready=1;@(posedge clk);checks=checks+1;
            @(negedge clk);m_ready=0;
        end
        // Cancel a header awaiting its first row, then a partially computed row,
        // then a held response. Fresh empty transactions prove recovery each time.
        one_header();reset_now();empty_recovery();
        one_header();s_valid=1;s_side=0;s_price={P{1'b1}};s_quantity={Q{1'b1}};
        @(posedge clk);if(!s_ready)$fatal(1,"live row");
        @(negedge clk);s_valid=0;
        reset_now();empty_recovery();
        @(negedge clk);a_valid=1;a_rows=0;a_reference=0;a_tag=0;
        @(posedge clk);if(!a_ready)$fatal(1,"held header");
        @(negedge clk);a_valid=0;if(!m_valid)$fatal(1,"held reset target");
        reset_now();empty_recovery();
        if(checks!=cases||futures!=cases-1||holds!=4*cases||live_resets!=4||recoveries!=3)$fatal(1,"coverage");
        $display("B44_A_CORE_PASS N=%0d P=%0d Q=%0d T=%0d cases=%0d rows=%0d checks=%0d holds=%0d future_accepts=%0d resets=%0d cancelled=3 recoveries=%0d",N,P,Q,T,cases,total_rows,checks,holds,futures,live_resets,recoveries);
        $finish;
    end
    initial begin #500000000;$fatal(1,"testbench deadline");end
endmodule
`default_nettype wire
