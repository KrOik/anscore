`timescale 1ns/1ps
module tb_img_hist_lut_map_bram;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, clk_en=1;
    reg cfg_begin_valid=0;
    wire cfg_begin_ready;
    reg [15:0] cfg_begin_tag=0;
    reg cfg_wr_valid=0;
    wire cfg_wr_ready;
    reg [7:0] cfg_wr_addr=0, cfg_wr_data=0;
    reg cfg_wr_last=0;
    reg [15:0] cfg_wr_tag=0;
    reg cfg_commit_valid=0;
    wire cfg_commit_ready;
    reg cfg_commit_error=0;
    wire cfg_done_valid;
    reg cfg_done_ready=0;
    wire cfg_done_error;
    wire [7:0] cfg_done_error_code;
    wire [8:0] cfg_done_count;
    wire [15:0] cfg_done_tag;
    reg s_valid=0;
    wire s_ready;
    reg [7:0] s_gray=0;
    reg s_sof=0, s_eol=0;
    reg [15:0] s_tag=0;
    wire m_valid;
    reg m_ready=0;
    wire [7:0] m_gray;
    wire m_sof,m_eol;
    wire [15:0] m_tag,m_lut_tag;
    wire m_error,active_lut_valid;

    img_hist_lut_map #(.TAG_WIDTH(16)) dut (.*);

    integer cycles=0;
    reg m_hold=0, done_hold=0;
    reg [55:0] previous_m;
    reg [39:0] previous_done;
    always @(posedge clk) begin
        cycles <= cycles+1;
        if (cycles>100000) $fatal(1,"lut map timeout");
        if (!rst_n) begin
            m_hold<=0; done_hold<=0;
        end else begin
            if (m_hold && (!m_valid ||
                {m_gray,m_sof,m_eol,m_tag,m_lut_tag,m_error} !== previous_m))
                $fatal(1,"mapped output changed under CE/backpressure");
            if (done_hold && (!cfg_done_valid ||
                {cfg_done_error,cfg_done_error_code,cfg_done_count,cfg_done_tag} !== previous_done))
                $fatal(1,"config completion changed under CE/backpressure");
            m_hold <= m_valid && (!m_ready || !clk_en);
            done_hold <= cfg_done_valid && (!cfg_done_ready || !clk_en);
            previous_m <= {m_gray,m_sof,m_eol,m_tag,m_lut_tag,m_error};
            previous_done <= {cfg_done_error,cfg_done_error_code,cfg_done_count,cfg_done_tag};
            if (!clk_en && (cfg_begin_ready || cfg_wr_ready || cfg_commit_ready || s_ready))
                $fatal(1,"ready asserted while clk_en=0");
        end
    end

    function automatic [7:0] lut_a(input [7:0] x);
        lut_a=x ^ 8'hA5;
    endfunction
    function automatic [7:0] lut_b(input [7:0] x);
        lut_b=x + 8'h31;
    endfunction
    function automatic [7:0] lut_c(input [7:0] x);
        lut_c={x[3:0],x[7:4]};
    endfunction

    task automatic begin_cfg(input [15:0] tag_value);
        begin
            @(negedge clk); cfg_begin_valid=1; cfg_begin_tag=tag_value;
            do @(posedge clk); while (!(clk_en && cfg_begin_ready));
            @(negedge clk); cfg_begin_valid=0;
        end
    endtask

    task automatic write_cfg(input [7:0] addr_value, input [7:0] data_value,
                             input last_value, input [15:0] tag_value);
        begin
            @(negedge clk); cfg_wr_valid=1; cfg_wr_addr=addr_value;
            cfg_wr_data=data_value; cfg_wr_last=last_value; cfg_wr_tag=tag_value;
            do @(posedge clk); while (!(clk_en && cfg_wr_ready));
            @(negedge clk); cfg_wr_valid=0;
        end
    endtask

    task automatic write_full(input [15:0] tag_value, input integer which_lut);
        integer i;
        reg [7:0] d;
        begin
            for(i=0;i<256;i=i+1) begin
                case(which_lut)
                    0:d=lut_a(i[7:0]);
                    1:d=lut_b(i[7:0]);
                    default:d=lut_c(i[7:0]);
                endcase
                write_cfg(i[7:0],d,(i==255),tag_value);
            end
        end
    endtask

    task automatic commit_cfg;
        begin
            @(negedge clk); cfg_commit_valid=1;
            do @(posedge clk); while (!(clk_en && cfg_commit_ready));
            @(negedge clk); cfg_commit_valid=0;
        end
    endtask

    task automatic consume_cfg_done(input error_value,
                                    input [7:0] code_value,
                                    input [8:0] count_value,
                                    input [15:0] tag_value);
        begin
            do @(posedge clk); while (!cfg_done_valid);
            if ({cfg_done_error,cfg_done_error_code,cfg_done_count,cfg_done_tag} !==
                {error_value,code_value,count_value,tag_value})
                $fatal(1,"cfg done got=%h/%h/%0d/%h expected=%b/%h/%0d/%h",
                    cfg_done_error,cfg_done_error_code,cfg_done_count,cfg_done_tag,
                    error_value,code_value,count_value,tag_value);
            repeat(3) @(posedge clk);
            if (!cfg_done_valid) $fatal(1,"cfg completion did not hold");
            @(negedge clk); cfg_done_ready=1;
            do @(posedge clk); while (!(clk_en && cfg_done_valid && cfg_done_ready));
            @(negedge clk); cfg_done_ready=0;
        end
    endtask

    task automatic send_and_expect(input [7:0] gray_value,input sof_value,
                                   input [15:0] stream_tag,
                                   input [7:0] mapped_value,
                                   input [15:0] map_tag,
                                   input error_value);
        begin
            @(negedge clk); s_valid=1; s_gray=gray_value; s_sof=sof_value;
            s_eol=1; s_tag=stream_tag; m_ready=1;
            do @(posedge clk); while (!(clk_en && s_ready));
            @(negedge clk); s_valid=0;
            do @(posedge clk); while (!(clk_en && m_valid && m_ready));
            if ({m_gray,m_sof,m_eol,m_tag,m_lut_tag,m_error} !==
                {mapped_value,sof_value,1'b1,stream_tag,map_tag,error_value})
                $fatal(1,"map got=%h/%b/%b/%h/%h/%b expected=%h/%b/1/%h/%h/%b",
                    m_gray,m_sof,m_eol,m_tag,m_lut_tag,m_error,
                    mapped_value,sof_value,stream_tag,map_tag,error_value);
            @(negedge clk); m_ready=0;
        end
    endtask

    task automatic reject_one(input [7:0] addr_value,
                              input [7:0] data_value,
                              input last_value,
                              input [15:0] write_tag,
                              input [15:0] begin_tag);
        begin
            begin_cfg(begin_tag);
            write_cfg(addr_value,data_value,last_value,write_tag);
            commit_cfg();
            // A rejected first write sets BUILD_BAD; no accepted entries then
            // makes the commit report both malformed sequence and short LUT.
            consume_cfg_done(1,8'h03,9'd0,begin_tag);
        end
    endtask

    integer i, config_count, stream_count, output_count;
    reg [7:0] expected_stream [0:255];
    integer prng=32'h76105A3D;
    initial begin
        repeat(4) @(negedge clk); rst_n=1;

        // Before the first valid LUT, mapping is identity plus explicit error.
        send_and_expect(8'h28,1,16'h0001,8'h28,16'h0000,1);

        // First complete bank is bank 1 and becomes active only at SOF.
        begin_cfg(16'hA001);
        write_full(16'hA001,0);
        commit_cfg();
        if (cfg_done_valid || active_lut_valid)
            $fatal(1,"commit activated without an accepted SOF");
        send_and_expect(8'h19,1,16'h0100,lut_a(8'h19),16'hA001,0);
        if (!active_lut_valid) $fatal(1,"first SOF did not activate LUT");
        consume_cfg_done(0,0,9'd256,16'hA001);

        // Each address, tag, and last marker is independently rejected.
        reject_one(8'd1,lut_b(0),0,16'hA002,16'hA002); // bad address
        reject_one(8'd0,lut_b(0),0,16'hDEAD,16'hA003); // bad tag
        reject_one(8'd0,lut_b(0),1,16'hA004,16'hA004); // bad last

        // Build LUT B in the inactive bank. A non-SOF pixel must still use A;
        // the following accepted SOF activates B without a read/output bubble.
        begin_cfg(16'hB001);
        write_full(16'hB001,1);
        commit_cfg();
        if (cfg_done_valid) $fatal(1,"successful commit completed before SOF");
        send_and_expect(8'h47,0,16'h0101,lut_a(8'h47),16'hA001,0);
        send_and_expect(8'h52,1,16'h0102,lut_b(8'h52),16'hB001,0);
        consume_cfg_done(0,0,9'd256,16'hB001);

        // Simultaneously read the active B bank and write every entry in the
        // inactive A bank. CE stalls and output backpressure are deterministic.
        begin_cfg(16'hC001);
        config_count=0; stream_count=0; output_count=0;
        m_ready=0;
        while(config_count<256 || stream_count<256 || output_count<256) begin
            @(negedge clk);
            prng = (prng*1664525 + 1013904223) & 32'h7fffffff;
            clk_en = (prng[2:0] != 0);
            m_ready = (cycles>12) || (prng[5:4] == 2'b11);
            cfg_wr_valid = (config_count<256);
            cfg_wr_addr = config_count[7:0];
            cfg_wr_data = lut_c(config_count[7:0]);
            cfg_wr_last = (config_count==255);
            cfg_wr_tag = 16'hC001;
            s_valid = (stream_count<256);
            s_gray = stream_count[7:0];
            s_sof = 0;
            s_eol = (stream_count[3:0]==4'hF);
            s_tag = 16'h0200;
            @(posedge clk);
            if (clk_en) begin
                if (cfg_wr_valid && cfg_wr_ready) config_count=config_count+1;
                if (s_valid && s_ready) begin
                    expected_stream[stream_count]=lut_b(s_gray);
                    stream_count=stream_count+1;
                end
                if (m_valid && m_ready) begin
                    if (output_count>=stream_count)
                        $fatal(1,"output escaped accepted input");
                    if (m_gray !== expected_stream[output_count] ||
                        m_lut_tag !== 16'hB001 || m_tag !== 16'h0200 || m_error)
                        $fatal(1,"concurrent bank read/write mismatch index=%0d got=%h tag=%h err=%b expected=%h",
                            output_count,m_gray,m_lut_tag,m_error,expected_stream[output_count]);
                    output_count=output_count+1;
                end
            end
        end
        @(negedge clk); cfg_wr_valid=0; s_valid=0; clk_en=1; m_ready=0;
        commit_cfg();
        if (cfg_done_valid) $fatal(1,"background build committed before SOF");
        send_and_expect(8'hA3,1,16'h0201,lut_c(8'hA3),16'hC001,0);
        consume_cfg_done(0,0,9'd256,16'hC001);

        $display("PASS tb_img_hist_lut_map_bram cycles=%0d",cycles);
        $finish;
    end
endmodule
