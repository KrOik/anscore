`timescale 1ns/1ps
module tb_sb_arbiter;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,ce=0,ready=0;
    integer sent0=0,sent1=0,sent2=0,received=0,cycles=0;
    wire [23:0] in_data={8'(8'hc0+sent2),8'(8'hb0+sent1),8'(8'ha0+sent0)};
    // Pause the selected port after its first beat; other ports cannot steal.
    wire [2:0] valid={sent2<4,sent1<4,((sent0<4)&&!(sent0==1&&cycles<12))};
    wire [2:0] last={sent2%2==1,sent1%2==1,sent0%2==1};
    wire [2:0] in_ready;wire [7:0] out_data;wire out_keep,out_user,out_last,out_valid;
    sb_stream_rr_arbiter #(.PORTS(3),.DATA_WIDTH(8)) dut(
        .clk(clk),.rst_n(rst_n),.clk_en(ce),.s_data(in_data),.s_keep(3'b111),.s_user(3'b000),
        .s_last(last),.s_valid(valid),.s_ready(in_ready),.m_data(out_data),.m_keep(out_keep),
        .m_user(out_user),.m_last(out_last),.m_valid(out_valid),.m_ready(ready));
    reg [7:0] expected;reg hold_check=0;reg [8:0] saved;
    always @(posedge clk) if(rst_n) begin
        if(hold_check&&{out_valid,out_data}!==saved) $fatal(1,"arbiter stall stability");
        hold_check=out_valid&&(!ready||!ce);saved={out_valid,out_data};
        if(ce&&out_valid&&ready) begin
            expected=8'ha0+16*((received/2)%3)+2*(received/6)+received%2;
            if(out_data!==expected||out_last!==(received%2==1)||!out_keep)
                $fatal(1,"arbiter order/frame %0d got=%h expected=%h",received,out_data,expected);
            received=received+1;
        end
        if(ce) begin
            if(in_ready[0]&&valid[0]) sent0<=sent0+1;
            if(in_ready[1]&&valid[1]) sent1<=sent1+1;
            if(in_ready[2]&&valid[2]) sent2<=sent2+1;
        end
    end else hold_check=0;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        while(received<12) begin
            @(negedge clk);cycles=cycles+1;ce=(cycles%5!=0);ready=(cycles%4>0);
            if(cycles>200) $fatal(1,"arbiter timeout");
        end
        @(negedge clk);rst_n=0;ce=0;#1;
        if(out_valid||in_ready) $fatal(1,"arbiter reset");
        $display("PASS arbiter 3 ports, packet lock/gap, round robin, CE/stall/reset");$finish;
    end
endmodule
