// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_tetrahedral_grade;
    parameter integer W=5,H=3,B=10,G=2,T=8,WRAP=0;
    localparam integer PIX=W*H,K=1<<G,DEPTH=(K+1)*(K+1)*(K+1);
    reg clk=0; always #5 clk=~clk;
    reg rst=1, cfg_begin_valid=0,lut_valid=0,lut_last=0,cfg_rsp_ready=0;
    wire cfg_begin_ready,lut_ready,cfg_rsp_valid,configured,table_pending;
    wire [1:0] cfg_rsp_error;
    reg [3*B-1:0] lut_rgb=0;
    reg c_valid=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,d_ready=0;
    reg [T-1:0] c_tag=0;
    reg [3*B-1:0] s_rgb=0;
    wire c_ready,s_ready,m_valid,m_sof,m_eol,m_last,d_valid;
    wire [3*B-1:0] m_data;
    wire [15:0] m_x,m_y;
    wire [T-1:0] m_tag,d_tag;
    wire [1:0] d_error;
    reg m_ready=0,force_hold=0;
    wire [3:0] phase;
    wire gray_slot;
    generate if(WRAP) begin: actual
        wire [7:0] luma;
        graded_luma_preview #(.WIDTH(W),.HEIGHT(H),.GRID_LOG2(G),.TAG_W(T)) dut(
            .clk(clk),.rst(rst),.cfg_begin_valid(cfg_begin_valid),.cfg_begin_ready(cfg_begin_ready),
            .lut_valid(lut_valid),.lut_ready(lut_ready),.lut_rgb(lut_rgb),.lut_last(lut_last),
            .cfg_rsp_valid(cfg_rsp_valid),.cfg_rsp_ready(cfg_rsp_ready),.cfg_rsp_error(cfg_rsp_error),
            .configured(configured),.table_pending(table_pending),.c_valid(c_valid),.c_ready(c_ready),.c_tag(c_tag),
            .s_valid(s_valid),.s_ready(s_ready),.s_rgb(s_rgb),.s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),
            .m_valid(m_valid),.m_ready(m_ready),.m_luma(luma),.m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),
            .m_x(m_x),.m_y(m_y),.m_tag(m_tag),.d_valid(d_valid),.d_ready(d_ready),.d_error(d_error),.d_tag(d_tag));
        assign m_data={{(3*B-8){1'b0}},luma}; assign phase=dut.grade.state; assign gray_slot=dut.gray_valid;
    end else begin: core
        tetrahedral_rgb_grade #(.WIDTH(W),.HEIGHT(H),.BITS(B),.GRID_LOG2(G),.TAG_W(T)) dut(
            .clk(clk),.rst(rst),.cfg_begin_valid(cfg_begin_valid),.cfg_begin_ready(cfg_begin_ready),
            .lut_valid(lut_valid),.lut_ready(lut_ready),.lut_rgb(lut_rgb),.lut_last(lut_last),
            .cfg_rsp_valid(cfg_rsp_valid),.cfg_rsp_ready(cfg_rsp_ready),.cfg_rsp_error(cfg_rsp_error),
            .configured(configured),.table_pending(table_pending),.c_valid(c_valid),.c_ready(c_ready),.c_tag(c_tag),
            .s_valid(s_valid),.s_ready(s_ready),.s_rgb(s_rgb),.s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),
            .m_valid(m_valid),.m_ready(m_ready),.m_rgb(m_data),.m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),
            .m_x(m_x),.m_y(m_y),.m_tag(m_tag),.d_valid(d_valid),.d_ready(d_ready),.d_error(d_error),.d_tag(d_tag));
        assign phase=dut.state; assign gray_slot=0;
    end endgenerate
    reg [3*B-1:0] tables[0:3*DEPTH-1],pixels[0:PIX-1],expected[0:3*PIX-1];
    integer cycles=0,frames=0,faults=0,config_faults=0,invalids=0,resets=0,outputs=0;
    integer early=0,holds=0,done_holds=0,config_holds=0,gaps=0,futures=0;
    integer selected=0,out_index=0,in_count=0;
    reg checking=0;
    reg [T-1:0] expected_tag=0;
    reg held=0,dh=0,ch=0,seen=0;
    reg [3*B+T+34:0] saved;
    reg [T+1:0] saved_done;
    reg [1:0] saved_config;
    wire [3*B+T+34:0] payload={m_data,m_sof,m_eol,m_last,m_x,m_y,m_tag};
    always @(negedge clk) begin
        m_ready=!rst&&!force_hold&&(cycles%9!=0)&&(cycles%9!=1);
        if(rst) seen=0;
        else begin
            if(m_valid&&!seen&&checking&&in_count<PIX) early=early+1;
            seen=m_valid;
        end
    end
    always @(posedge clk) begin
        cycles=cycles+1; if(cycles>1500000) $fatal(1,"watchdog");
        if(rst) begin held=0;dh=0;ch=0;end
        else begin
            if(held&&(!m_valid||payload!==saved)) $fatal(1,"held output changed");
            if(dh&&(!d_valid||{d_tag,d_error}!==saved_done)) $fatal(1,"held done changed");
            if(ch&&(!cfg_rsp_valid||cfg_rsp_error!==saved_config)) $fatal(1,"held config changed");
            held=m_valid&&!m_ready; saved=payload;
            dh=d_valid&&!d_ready; saved_done={d_tag,d_error};
            ch=cfg_rsp_valid&&!cfg_rsp_ready; saved_config=cfg_rsp_error;
            if(held) holds=holds+1;if(dh)done_holds=done_holds+1;if(ch)config_holds=config_holds+1;
            if(c_valid&&!c_ready) futures=futures+1;
            if(s_valid&&!s_ready) gaps=gaps+1;
            if(s_valid&&s_ready&&checking) in_count=in_count+1;
            if(m_valid&&m_ready) begin
                if(!checking||out_index>=PIX) $fatal(1,"unowned output");
                if(m_data!==expected[selected*PIX+out_index]||m_tag!==expected_tag||
                    m_x!==out_index%W||m_y!==out_index/W||
                    m_sof!==(out_index==0)||m_eol!==(out_index%W==W-1)||m_last!==(out_index==PIX-1))
                    $fatal(1,"exact output table=%0d i=%0d got=%h expected=%h",selected,out_index,m_data,expected[selected*PIX+out_index]);
                out_index=out_index+1; outputs=outputs+1;
            end
        end
    end
    task begin_load;
        begin @(negedge clk);cfg_begin_valid=1;do @(posedge clk);while(!cfg_begin_ready);
            @(negedge clk);cfg_begin_valid=0;end
    endtask
    task table_word(input integer address,input integer table_id,input integer last_value);
        begin @(negedge clk);lut_valid=1;lut_rgb=tables[table_id*DEPTH+address];lut_last=last_value;
            do @(posedge clk);while(!lut_ready);@(negedge clk);lut_valid=0;lut_last=0;end
    endtask
    task config_result(input integer error);
        begin while(!cfg_rsp_valid)@(negedge clk);repeat(4)@(negedge clk);
            if(cfg_rsp_error!==error)$fatal(1,"config status");
            cfg_rsp_ready=1;@(posedge clk);@(negedge clk);cfg_rsp_ready=0;end
    endtask
    task load_table(input integer table_id);
        integer j;begin begin_load();for(j=0;j<DEPTH;j=j+1)table_word(j,table_id,j==DEPTH-1);config_result(0);end
    endtask
    task bad_load;
        begin begin_load();table_word(0,1,1);config_result(1);config_faults=config_faults+1;end
    endtask
    task command(input integer value);
        begin @(negedge clk);c_valid=1;c_tag=value;do @(posedge clk);while(!c_ready);
            @(negedge clk);c_valid=0;end
    endtask
    task pixel(input integer index,input integer corrupt);
        begin
            repeat(index%3)@(negedge clk);
            @(negedge clk);s_valid=1;s_rgb=pixels[index];s_sof=(index==0)^corrupt;
            s_eol=index%W==W-1;s_last=index==PIX-1;
            do @(posedge clk);while(!s_ready);@(negedge clk);s_valid=0;
        end
    endtask
    task finish_done(input integer error,input integer count);
        begin
            while(!d_valid)@(negedge clk);repeat(5)@(negedge clk);
            if(d_error!==error||d_tag!==expected_tag||out_index!=count)$fatal(1,"DONE mismatch");
            d_ready=1;@(posedge clk);@(negedge clk);d_ready=0;checking=0;
        end
    endtask
    task setup_score(input integer table_id,input integer value);
        begin selected=table_id;expected_tag=value;out_index=0;in_count=0;checking=1;end
    endtask
    task empty_command;
        begin setup_score(0,7);command(7);finish_done(1,0);invalids=invalids+1;end
    endtask
    task good_frame(input integer table_id,input integer value);
        integer j;begin setup_score(table_id,value);command(value);
            for(j=0;j<PIX;j=j+1)pixel(j,0);finish_done(0,PIX);frames=frames+1;end
    endtask
    task two_atomic_frames;
        integer j;begin
            setup_score(0,3);command(3);force_hold=1;pixel(0,0);
            load_table(1);if(!table_pending||!m_valid)$fatal(1,"background load not pending at held output");
            c_valid=1;c_tag=5;repeat(5)begin @(negedge clk);if(c_ready)$fatal(1,"future command crossed output");end
            force_hold=0;for(j=1;j<PIX;j=j+1)pixel(j,0);finish_done(0,PIX);frames=frames+1;
            setup_score(1,5);do @(posedge clk);while(!c_ready);@(negedge clk);c_valid=0;
            for(j=0;j<PIX;j=j+1)pixel(j,0);finish_done(0,PIX);frames=frames+1;
        end
    endtask
    task marker_fault;
        integer prefix;begin prefix=PIX>1?1:0;setup_score(1,9);command(9);
            if(prefix)pixel(0,0);pixel(prefix,1);finish_done(2,prefix);faults=faults+1;end
    endtask
    task reset_now;
        begin
            checking=0;rst=1;c_valid=0;s_valid=0;cfg_begin_valid=0;lut_valid=0;
            cfg_rsp_ready=0;d_ready=0;force_hold=0;
            repeat(3)@(negedge clk);rst=0;repeat(2)@(negedge clk);
            if(configured||table_pending||cfg_rsp_valid||m_valid||d_valid)$fatal(1,"reset fence");
            resets=resets+1;empty_command();load_table(0);good_frame(0,11);
        end
    endtask
    integer target;
    initial begin
        $readmemh("tables.hex",tables);$readmemh("pixels.hex",pixels);$readmemh("expected.hex",expected);
        repeat(4)@(negedge clk);rst=0;
        empty_command();bad_load();load_table(0);two_atomic_frames();marker_fault();
        load_table(2);good_frame(2,13);bad_load();good_frame(2,15);
        begin_load();table_word(0,0,0);reset_now();
        load_table(0);reset_now();
        for(target=2;target<=8;target=target+1)begin
            force_hold=1;command(17);pixel(0,0);
            while(phase!=target)@(negedge clk);reset_now();
        end
        if(WRAP)begin
            force_hold=1;command(19);pixel(0,0);
            while(!gray_slot)@(negedge clk);reset_now();
        end
        if(frames!=13+WRAP||faults!=1||config_faults!=2||invalids!=10+WRAP||resets!=9+WRAP||
            outputs!=(13+WRAP)*PIX+(PIX>1)||early!=(13+WRAP)*(PIX-1)+(PIX>1)||
            holds==0||done_holds==0||config_holds==0||futures==0)$fatal(1,"finite coverage counters");
        $display("B44_C_PASS frames=%0d faults=%0d config_faults=%0d invalids=%0d resets=%0d outputs=%0d early=%0d holds=%0d done_holds=%0d config_holds=%0d futures=%0d gaps=%0d",frames,faults,config_faults,invalids,resets,outputs,early,holds,done_holds,config_holds,futures,gaps);
        $finish;
    end
endmodule
