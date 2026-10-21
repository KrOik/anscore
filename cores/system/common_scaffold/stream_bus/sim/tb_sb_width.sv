`timescale 1ns/1ps
module tb_sb_width;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,ce=0,ready=0;
    integer sent=0,words=0,received=0,cycles=0,errors=0;
    wire [7:0] in_data=sent;
    wire [2:0] in_user=(sent==2)?2:((sent<3)?1:4);
    wire in_last=(sent==2||sent==7);
    wire in_ready;
    wire [31:0] word_data;wire [3:0] word_keep;wire [2:0] word_user;
    wire word_last,word_valid,word_ready,up_error,down_error;
    wire [7:0] out_data;wire out_keep;wire [2:0] out_user;wire out_last,out_valid;
    sb_stream_width_adapter #(.S_WIDTH(8),.M_WIDTH(32),.USER_WIDTH(3)) up_i(
        .clk(clk),.rst_n(rst_n),.clk_en(ce),.s_data(in_data),.s_keep(1'b1),.s_user(in_user),
        .s_last(in_last),.s_valid(sent<8),.s_ready(in_ready),.m_data(word_data),.m_keep(word_keep),
        .m_user(word_user),.m_last(word_last),.m_valid(word_valid),.m_ready(word_ready),.error(up_error));
    sb_stream_width_adapter #(.S_WIDTH(32),.M_WIDTH(8),.USER_WIDTH(3)) down_i(
        .clk(clk),.rst_n(rst_n),.clk_en(ce),.s_data(word_data),.s_keep(word_keep),.s_user(word_user),
        .s_last(word_last),.s_valid(word_valid),.s_ready(word_ready),.m_data(out_data),.m_keep(out_keep),
        .m_user(out_user),.m_last(out_last),.m_valid(out_valid),.m_ready(ready),.error(down_error));
    reg [31:0] expected_word;reg [3:0] expected_keep;
    reg [7:0] expected_byte;reg expected_byte_keep;
    reg hold_check=0;reg [13:0] saved;
    always @(posedge clk) if(rst_n) begin
        if(up_error) errors=errors+1;
        if(down_error) $fatal(1,"unexpected narrowing error");
        if(hold_check&&{out_valid,out_data,out_keep,out_user,out_last}!==saved)
            $fatal(1,"width output changed under stall/CE");
        hold_check=out_valid&&(!ready||!ce);
        saved={out_valid,out_data,out_keep,out_user,out_last};
        if(ce&&word_valid&&word_ready) begin
            case(words)
                0:begin expected_word=32'h00020100;expected_keep=7;end
                1:begin expected_word=32'h06050403;expected_keep=15;end
                2:begin expected_word=32'h00000007;expected_keep=1;end
                default:$fatal(1,"extra width word");
            endcase
            if(word_data!==expected_word||word_keep!==expected_keep||word_last!==(words!=1)||
               word_user!==((words==0)?3'd1:3'd4)) $fatal(1,"packed word mismatch %0d",words);
            words=words+1;
        end
        if(ce&&out_valid&&ready) begin
            expected_byte_keep=(received<3||(received>=4&&received<=8));
            expected_byte=(received<3)?received:((received>=4&&received<=8)?received-1:0);
            if(out_data!==expected_byte||out_keep!==expected_byte_keep||
               out_last!==(received==3||received==11)||out_user!==((received<4)?3'd1:3'd4))
                $fatal(1,"narrowed byte mismatch %0d",received);
            received=received+1;
        end
        if(ce&&in_ready&&sent<8) sent<=sent+1;
    end else hold_check=0;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        while(received<12) begin
            @(negedge clk);cycles=cycles+1;ce=(cycles%4!=0);ready=(cycles%5>1);
            if(cycles>400) $fatal(1,"width timeout");
        end
        if(words!=3||errors!=1) $fatal(1,"width accounting words=%0d errors=%0d",words,errors);
        @(negedge clk);ce=0;rst_n=0;#1;
        if(out_valid||word_valid||in_ready) $fatal(1,"width reset");
        $display("PASS width 8/32 conversion, partial frames, KEEP, USER error, CE/stall/reset");$finish;
    end
endmodule
