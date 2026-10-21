`timescale 1ns/1ps
module tb_sb_stream;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,ce=0,ready=0;
    integer sent=0,received=0,cycles=0;
    wire [31:0] s_data=32'h12340000+sent;
    wire [3:0] s_keep=sent%16;
    wire [1:0] s_user=sent%4;
    wire s_last=(sent%7==6);
    wire s_ready,a_ready,a_valid,a_last,b_ready,b_valid,b_last,m_valid,m_last;
    wire [31:0] a_data,b_data,m_data;
    wire [3:0] a_keep,b_keep,m_keep;wire [1:0] a_user,b_user,m_user;
    sb_stream_elastic #(.USER_WIDTH(2)) elastic_i(
        .clk(clk),.rst_n(rst_n),.clk_en(ce),.s_data(s_data),.s_keep(s_keep),.s_user(s_user),
        .s_last(s_last),.s_valid(sent<120),.s_ready(s_ready),.m_data(a_data),.m_keep(a_keep),
        .m_user(a_user),.m_last(a_last),.m_valid(a_valid),.m_ready(a_ready));
    sb_stream_width_adapter #(.S_WIDTH(32),.M_WIDTH(32),.USER_WIDTH(2)) equal_width_i(
        .clk(clk),.rst_n(rst_n),.clk_en(ce),.s_data(a_data),.s_keep(a_keep),.s_user(a_user),
        .s_last(a_last),.s_valid(a_valid),.s_ready(a_ready),.m_data(b_data),.m_keep(b_keep),
        .m_user(b_user),.m_last(b_last),.m_valid(b_valid),.m_ready(b_ready),.error());
    sb_stream_register_slice #(.USER_WIDTH(2),.STAGES(3)) slice_i(
        .clk(clk),.rst_n(rst_n),.clk_en(ce),.s_data(b_data),.s_keep(b_keep),.s_user(b_user),
        .s_last(b_last),.s_valid(b_valid),.s_ready(b_ready),.m_data(m_data),.m_keep(m_keep),
        .m_user(m_user),.m_last(m_last),.m_valid(m_valid),.m_ready(ready));
    reg hold_check=0;reg [39:0] saved;
    always @(posedge clk) if(rst_n) begin
        if(hold_check&&{m_valid,m_data,m_keep,m_user,m_last}!==saved)
            $fatal(1,"stream changed under stall/CE");
        hold_check=m_valid&&(!ready||!ce);
        saved={m_valid,m_data,m_keep,m_user,m_last};
        if(ce&&m_valid&&ready) begin
            if(m_data!==(32'h12340000+received)||m_keep!==(received%16)||
               m_user!==(received%4)||m_last!==(received%7==6))
                $fatal(1,"stream payload/order mismatch %0d",received);
            received=received+1;
        end
        if(ce&&s_ready&&sent<120) sent<=sent+1;
    end else hold_check=0;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        while(received<120) begin
            @(negedge clk);cycles=cycles+1;
            ce=(cycles%5!=0&&cycles%11!=0);
            ready=(cycles%7>2);
            if(cycles>2000) $fatal(1,"stream timeout");
        end
        // Refill while stalled, then reset in flight with CE disabled.
        @(negedge clk);sent=0;received=0;ready=0;ce=1;
        repeat(8) @(negedge clk);
        if(!m_valid) $fatal(1,"reset test did not fill the pipeline");
        ce=0;rst_n=0;#1;
        if(a_valid||b_valid||m_valid||s_ready) $fatal(1,"stream reset flush");
        $display("PASS stream elastic/equal-width/slice 120 beats, backpressure, CE, reset");$finish;
    end
endmodule
