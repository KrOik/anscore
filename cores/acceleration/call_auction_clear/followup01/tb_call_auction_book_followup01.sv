`timescale 1ns/1ps
`default_nettype none
module tb_call_auction_book;
    parameter integer L=8,P=32,Q=32,T=8;
    localparam integer W=Q+$clog2(2*L+1),MAX_CASES=256;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,c_valid=0,a_valid=0,r_ready=0,m_ready=0;
    wire c_ready,a_ready,r_valid,m_valid;
    reg [3:0] c_op=0;reg c_side=0;
    reg [P-1:0] c_price=0,a_reference=0;reg [Q-1:0] c_quantity=0;
    reg [31:0] c_rank=0;reg [T-1:0] c_tag=0,a_tag=0;
    wire [3:0] r_op;wire r_side;wire [2:0] r_status;wire r_found;
    wire [P-1:0] r_price;wire [Q-1:0] r_quantity,r_previous;
    wire [31:0] r_bid_levels,r_ask_levels;wire [T-1:0] r_tag;
    wire [1:0] m_status;wire [31:0] m_rows,m_bid_levels,m_ask_levels;
    wire [P-1:0] m_price;wire [W-1:0] m_matched,m_buy,m_sell;
    wire signed [W:0] m_imbalance;wire [T-1:0] m_tag;
    call_auction_book #(.LEVELS(L),.PRICE_W(P),.QTY_W(Q),.TAG_W(T)) dut(.*);
    reg signed [63:0] v[0:MAX_CASES-1][0:19];
    reg signed [63:0] parsed_field;
    reg [2047:0] filename;
    integer fd,ret,cases,k,j,waits,checks=0,maintenance=0,snapshots=0,holds=0,futures=0;
    integer resets=0,vector_resets=0,recoveries=0,priority_checks=0;
    reg preoffered=0;
    task reset_now;
        begin
            @(negedge clk);rst_n=0;c_valid=0;a_valid=0;r_ready=0;m_ready=0;
            #1;if(c_ready||a_ready||r_valid||m_valid)$fatal(1,"reset masks");
            repeat(2)@(negedge clk);rst_n=1;resets=resets+1;
        end
    endtask
    task offer(input integer index);
        begin
            c_valid=(v[index][0]==0);a_valid=(v[index][0]==1);
            c_op=v[index][1];c_side=v[index][2];c_price=v[index][3];c_quantity=v[index][4];
            c_rank=v[index][5];a_reference=v[index][6];c_tag=v[index][7];a_tag=v[index][7];
        end
    endtask
    task check_result(input integer index);
        begin
            if(c_ready||a_ready)$fatal(1,"public ownership");
            if(v[index][0]==0)begin
                if(!r_valid||m_valid||r_op!==v[index][1]||r_side!==v[index][2]||r_tag!==v[index][7]||
                   r_status!==v[index][8]||r_found!==v[index][9]||r_price!==v[index][10]||
                   r_quantity!==v[index][11]||r_previous!==v[index][12]||r_bid_levels!==v[index][13]||r_ask_levels!==v[index][14])
                    $fatal(1,"book maintenance case=%0d op=%0d status=%0d qty=%0d previous=%0d counts=%0d,%0d",index,r_op,r_status,r_quantity,r_previous,r_bid_levels,r_ask_levels);
            end else if(!m_valid||r_valid||m_status!==v[index][8]||m_price!==v[index][10]||
                m_bid_levels!==v[index][13]||m_ask_levels!==v[index][14]||m_rows!==v[index][15]||
                m_matched!==v[index][16]||m_buy!==v[index][17]||m_sell!==v[index][18]||
                $signed(m_imbalance)!==v[index][19]||m_tag!==v[index][7])
                $fatal(1,"book auction case=%0d status=%0d price=%0d matched=%0d buy=%0d sell=%0d imbalance=%0d rows=%0d",index,m_status,m_price,m_matched,m_buy,m_sell,m_imbalance,m_rows);
        end
    endtask
    task wait_maintenance;
        begin
            waits=0;while(!r_valid)begin
                @(negedge clk);waits=waits+1;if(waits>50000)$fatal(1,"maintenance timeout");
            end
        end
    endtask
    task wait_auction;
        begin
            waits=0;while(!m_valid)begin
                @(negedge clk);waits=waits+1;if(waits>50000)$fatal(1,"auction timeout");
            end
        end
    endtask
    task send_maintenance(input [3:0] op,input side,input [P-1:0] price,input [Q-1:0] quantity);
        begin
            @(negedge clk);c_valid=1;c_op=op;c_side=side;c_price=price;c_quantity=quantity;c_rank=0;c_tag=0;
            waits=0;begin: admit_c
                forever begin @(posedge clk);waits=waits+1;if(c_ready)disable admit_c;if(waits>50000)$fatal(1,"admit maintenance");end
            end
            @(negedge clk);c_valid=0;wait_maintenance();
        end
    endtask
    task retire_maintenance;
        begin r_ready=1;@(posedge clk);@(negedge clk);r_ready=0;end
    endtask
    task send_auction;
        begin
            @(negedge clk);a_valid=1;a_reference=0;a_tag=0;
            waits=0;begin: admit_a
                forever begin @(posedge clk);waits=waits+1;if(a_ready)disable admit_a;if(waits>50000)$fatal(1,"admit auction");end
            end
            @(negedge clk);a_valid=0;
        end
    endtask
    task retire_auction;
        begin m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;end
    endtask
    task seed(input side);
        begin
            send_maintenance(0,side,side?{P{1'b0}}:{P{1'b1}},{{(Q-1){1'b0}},1'b1});
            if(r_status!=0||r_quantity!=1||r_previous!=0)$fatal(1,"seed");retire_maintenance();
        end
    endtask
    task empty_recovery;
        begin
            send_maintenance(4,0,0,0);
            if(r_status!=1||r_found||r_price!=0||r_quantity!=0||r_previous!=0||r_bid_levels!=0||r_ask_levels!=0)$fatal(1,"book reset did not empty");
            retire_maintenance();send_auction();wait_auction();
            if(m_status!=1||m_rows!=0||m_price!=0||m_matched!=0||m_buy!=0||m_sell!=0||m_imbalance!=0||m_bid_levels!=0||m_ask_levels!=0||m_tag!=0)$fatal(1,"auction recovery");
            retire_auction();recoveries=recoveries+1;
        end
    endtask
    initial begin
        if(!$value$plusargs("vectors=%s",filename))$fatal(1,"missing vectors");
        fd=$fopen(filename,"r");if(!fd)$fatal(1,"open vectors");
        ret=$fscanf(fd,"%d",cases);if(ret!=1||cases<1||cases>MAX_CASES)$fatal(1,"case count");
        for(k=0;k<cases;k=k+1)for(j=0;j<20;j=j+1)begin ret=$fscanf(fd,"%d",parsed_field);if(ret!=1)$fatal(1,"parse vector");v[k][j]=parsed_field;end
        $fclose(fd);reset_now();
        for(k=0;k<cases;k=k+1)begin
            if(v[k][0]==2)begin reset_now();preoffered=0;vector_resets=vector_resets+1;end
            else begin
                if(!preoffered)begin @(negedge clk);offer(k);end
                waits=0;begin: admit_vector
                    forever begin
                        @(posedge clk);waits=waits+1;
                        if((v[k][0]==0&&c_ready)||(v[k][0]==1&&a_ready))disable admit_vector;
                        if(waits>50000)$fatal(1,"vector admit");
                    end
                end
                if(preoffered)futures=futures+1;
                @(negedge clk);c_valid=0;a_valid=0;preoffered=0;
                if(k+1<cases&&v[k+1][0]!=2)begin offer(k+1);preoffered=1;end
                waits=0;
                while(!(v[k][0]==0?r_valid:m_valid))begin
                    if(c_ready||a_ready)$fatal(1,"accepted future before result");
                    if((v[k][0]==0&&m_valid)||(v[k][0]==1&&r_valid))$fatal(1,"wrong output owner");
                    @(negedge clk);waits=waits+1;if(waits>50000)$fatal(1,"vector result timeout");
                end
                repeat(4)begin check_result(k);holds=holds+1;@(negedge clk);end
                check_result(k);
                if(v[k][0]==0)begin r_ready=1;maintenance=maintenance+1;end
                else begin m_ready=1;snapshots=snapshots+1;end
                @(posedge clk);checks=checks+1;@(negedge clk);r_ready=0;m_ready=0;
            end
        end
        // Private count, private depth, computation, held indication and already
        // committed held maintenance all cancel on the common reset edge.
        seed(0);send_auction();waits=0;
        while(dut.state!=3)begin @(negedge clk);waits=waits+1;if(waits>50000)$fatal(1,"count reset target");end
        reset_now();empty_recovery();
        seed(0);seed(1);send_auction();waits=0;
        while(dut.state!=6)begin @(negedge clk);waits=waits+1;if(waits>50000)$fatal(1,"depth reset target");end
        reset_now();empty_recovery();
        seed(0);send_auction();waits=0;
        while(dut.engine.state!=4)begin @(negedge clk);waits=waits+1;if(waits>50000)$fatal(1,"compute reset target");end
        reset_now();empty_recovery();
        send_auction();wait_auction();reset_now();empty_recovery();
        send_maintenance(0,0,{P{1'b1}},{{(Q-1){1'b0}},1'b1});
        if(r_status!=0||r_quantity!=1)$fatal(1,"held commit target");
        reset_now();empty_recovery();
        // Both valid in idle: auction wins, maintenance remains actually pending
        // until the empty snapshot retires, then is accepted exactly once.
        @(negedge clk);a_valid=1;a_reference=0;a_tag=0;c_valid=1;c_op=0;c_side=0;c_price={P{1'b1}};c_quantity=1;c_rank=0;c_tag=0;
        @(posedge clk);if(!a_ready||c_ready)$fatal(1,"auction priority");
        @(negedge clk);a_valid=0;wait_auction();
        repeat(3)begin if(c_ready||m_status!=1||m_rows!=0)$fatal(1,"priority snapshot isolation");@(negedge clk);end
        retire_auction();@(posedge clk);if(!c_ready)$fatal(1,"pending maintenance not admitted");
        @(negedge clk);c_valid=0;wait_maintenance();
        if(r_status!=0||r_quantity!=1||r_previous!=0||r_bid_levels!=1||r_ask_levels!=0)$fatal(1,"priority maintenance result");
        retire_maintenance();priority_checks=1;
        if(checks!=cases-1||snapshots!=33||maintenance!=68+4*L||futures!=cases-3||holds!=4*(cases-1)||vector_resets!=1||resets!=7||recoveries!=5)$fatal(1,"coverage");
        $display("B44_A_BOOK_PASS L=%0d P=%0d Q=%0d T=%0d cases=%0d checks=%0d maintenance=%0d snapshots=%0d holds=%0d future_accepts=%0d vector_resets=%0d resets=%0d cancelled=5 recoveries=%0d priority=%0d",L,P,Q,T,cases,checks,maintenance,snapshots,holds,futures,vector_resets,resets,recoveries,priority_checks);
        $finish;
    end
    initial begin #500000000;$fatal(1,"testbench deadline");end
endmodule
`default_nettype wire
