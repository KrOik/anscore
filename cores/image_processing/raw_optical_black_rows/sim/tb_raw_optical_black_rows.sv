// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_raw_optical_black_rows;
    parameter integer W=7,H=5,B=10,L=3,R=4,T=8,WRAP=0;
    localparam integer C=16,SW=L+W+R,SN=SW*H,AN=W*H,CW=3*B+8+T,OW=2*B+37+T,RW=3*B+18+T;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,cv=0,sv=0,mr=0,dr=0,rc_ready=0,rf_ready=0;
    reg [CW-1:0] cfg=0;reg [B+2:0] sensor=0;
    wire cr,sr,mv,dv,busy,rc_valid,rf_valid;
    wire [OW-1:0] output_word;wire [RW-1:0] row_word;
    wire [3:0] error;wire [9:0] drows;wire [16:0] dpixels;wire [T-1:0] dtag;
    wire [31:0] clip_low,clip_high;wire [3:0] core_state;wire actual_rc_ready;
    reg [CW-1:0] configs[0:C-1];reg [B+2:0] sensors[0:C*SN-1];
    reg [OW-1:0] golden[0:C*AN-1];reg [RW-1:0] row_golden[0:C*H-1];reg [82+T:0] dones[0:C-1];reg [31:0] counts[0:3];
    generate if(WRAP==0)begin: plain
        raw_optical_black_rows #(.WIDTH(W),.HEIGHT(H),.BITS(B),.OB_LEFT(L),.OB_RIGHT(R),.TAG_W(T)) dut(
            .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_low(cfg[B-1:0]),.c_high(cfg[2*B-1:B]),.c_target(cfg[3*B-1:2*B]),.c_min_count(cfg[3*B+5:3*B]),.c_pattern(cfg[3*B+7:3*B+6]),.c_tag(cfg[CW-1:3*B+8]),
            .s_valid(sv),.s_ready(sr),.s_data(sensor[B-1:0]),.s_sof(sensor[B]),.s_eol(sensor[B+1]),.s_last(sensor[B+2]),
            .row_valid(rc_valid),.row_ready(rc_ready),.row_black0(row_word[B-1:0]),.row_black1(row_word[2*B-1:B]),.row_target(row_word[3*B-1:2*B]),.row_y(row_word[3*B+17:3*B+2]),.row_pattern(row_word[3*B+1:3*B]),.row_tag(row_word[RW-1:3*B+18]),
            .row_end_valid(rf_valid),.row_end_ready(rf_ready),
            .m_valid(mv),.m_ready(mr),.m_data(output_word[B-1:0]),.m_black(output_word[2*B-1:B]),.m_sof(output_word[2*B]),.m_eol(output_word[2*B+1]),.m_last(output_word[2*B+2]),
            .m_x(output_word[2*B+18:2*B+3]),.m_y(output_word[2*B+34:2*B+19]),.m_pattern(output_word[2*B+36:2*B+35]),.m_tag(output_word[OW-1:2*B+37]),
            .d_valid(dv),.d_ready(dr),.d_error(error),.d_rows(drows),.d_pixels(dpixels),.d_tag(dtag),.busy(busy));
        assign clip_low=0;assign clip_high=0;assign core_state=dut.state;assign actual_rc_ready=rc_ready;
    end else begin: actual
        raw_ob_black_frontend #(.WIDTH(W),.HEIGHT(H),.BITS(B),.OB_LEFT(L),.OB_RIGHT(R),.TAG_W(T)) dut(
            .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_low(cfg[B-1:0]),.c_high(cfg[2*B-1:B]),.c_target(cfg[3*B-1:2*B]),.c_min_count(cfg[3*B+5:3*B]),.c_pattern(cfg[3*B+7:3*B+6]),.c_tag(cfg[CW-1:3*B+8]),
            .s_valid(sv),.s_ready(sr),.s_data(sensor[B-1:0]),.s_sof(sensor[B]),.s_eol(sensor[B+1]),.s_last(sensor[B+2]),
            .m_valid(mv),.m_ready(mr),.m_data(output_word[B-1:0]),.m_black(output_word[2*B-1:B]),.m_sof(output_word[2*B]),.m_eol(output_word[2*B+1]),.m_last(output_word[2*B+2]),
            .m_x(output_word[2*B+18:2*B+3]),.m_y(output_word[2*B+34:2*B+19]),.m_pattern(output_word[2*B+36:2*B+35]),.m_tag(output_word[OW-1:2*B+37]),
            .d_valid(dv),.d_ready(dr),.d_error(error),.d_rows(drows),.d_pixels(dpixels),.d_tag(dtag),.clip_low_count(clip_low),.clip_high_count(clip_high),.busy(busy));
        assign core_state=dut.calibrate.state;assign rc_valid=dut.row_valid;assign rf_valid=dut.row_end_valid;assign actual_rc_ready=dut.row_ready;
        assign row_word={dut.tag,dut.row_y,dut.pattern,dut.target,dut.black1,dut.black0};
        always @(posedge clk)if(!rst)begin
            if(dut.owned>1)$fatal(1,"BLC ownership capacity");
            if(dut.row_valid&&dut.row_ready&&(dut.owned!=0||dut.blc_mv||dut.row_active))$fatal(1,"row config crossed owned output");
            if(dut.row_end_valid&&dut.row_end_ready&&(dut.owned!=0||dut.blc_mv))$fatal(1,"row fence crossed owned output");
            if(dv&&(dut.owned!=0||dut.blc_mv||dut.row_active))$fatal(1,"DONE before BLC drain");
            if(mv&&dut.blc_frame!==16'(dut.tag))$fatal(1,"old BLC frame metadata");
        end
    end endgenerate
    integer checked=0,commands=0,done_count=0,resets=0,cancelled=0,holds=0,gaps=0,row_checks=0,watchdog=0;
    integer live_case=0;reg checking_rows=0;
    reg oh=0,rh=0;reg [OW-1:0] held_o;reg [RW-1:0] held_r;
    always @(posedge clk)begin
        watchdog=watchdog+1;if(watchdog>1000000)$fatal(1,"finite watchdog");
        if(rst)begin oh=0;rh=0;end
        else begin
            if(oh&&(!mv||output_word!==held_o))$fatal(1,"held pixel changed");
            if(rh&&(!rc_valid||row_word!==held_r))$fatal(1,"held row config changed");
            oh=mv&&!mr;held_o=output_word;rh=rc_valid&&!actual_rc_ready;held_r=row_word;
            if(mv&&!mr)holds=holds+1;
            if(checking_rows&&rc_valid&&actual_rc_ready)begin
                if(row_word!==row_golden[live_case*H+row_word[3*B+17:3*B+2]])$fatal(1,"row calibration/phase mismatch case=%0d",live_case);
                row_checks=row_checks+1;
            end
        end
    end
    task launch(input integer scene);
        begin
            @(negedge clk);cv=1;cfg=configs[scene];dr=0;live_case=scene;
            @(posedge clk);if(!cr)$fatal(1,"command ownership");commands=commands+1;
            @(negedge clk);cv=0;cfg=~configs[scene];
        end
    endtask
    task reset_now;
        begin
            @(negedge clk);rst=1;cv=0;sv=0;dr=0;checking_rows=0;
            @(negedge clk);rst=0;mr=1;rc_ready=1;rf_ready=1;resets=resets+1;
            repeat(3)begin @(posedge clk);if(mv||dv||busy)$fatal(1,"reset flush");end
        end
    endtask
    task frame(input integer scene,input integer pattern_mode);
        integer sent,received,ticks,pending_source;reg [82+T:0] expect_done;
        begin
            launch(scene);sent=0;received=0;ticks=0;pending_source=0;expect_done=dones[scene];checking_rows=1;
            while(!dv)begin
                @(negedge clk);mr=pattern_mode==0||ticks%11>=4;rc_ready=pattern_mode==0||ticks%7>=2;rf_ready=pattern_mode==0||ticks%5!=0;
                if(!pending_source)begin
                    sv=sent<SN&&(pattern_mode==0||ticks%7!=1&&ticks%7!=2);
                    if(sv)sensor=sensors[scene*SN+sent];else if(sent<SN)gaps=gaps+1;
                end
                @(posedge clk);
                if(sv&&sr)begin sent=sent+1;pending_source=0;end else pending_source=sv;
                if(mv&&mr)begin
                    if(received>=expect_done[30:14]||output_word!==golden[scene*AN+received])$fatal(1,"pixel mismatch scene=%0d index=%0d got=%h expected=%h",scene,received,output_word,golden[scene*AN+received]);
                    received=received+1;checked=checked+1;
                end
                ticks=ticks+1;if(ticks>100*(SN+AN+H+10))$fatal(1,"frame service watchdog");
            end
            @(negedge clk);sv=0;checking_rows=0;
            if({dtag,dpixels,drows,error}!={expect_done[82+T:83],expect_done[30:14],expect_done[13:4],expect_done[3:0]}||sent!=expect_done[48:31]||received!=expect_done[30:14]||clip_low!=expect_done[65:49]||clip_high!=expect_done[82:66])
                $fatal(1,"DONE mismatch scene=%0d err=%0d rows=%0d pixels=%0d sent=%0d low/high=%0d/%0d",scene,error,drows,dpixels,sent,clip_low,clip_high);
            repeat(4)begin @(posedge clk);if(!dv||cr||mv)$fatal(1,"held DONE ownership");end
            @(negedge clk);dr=1;@(posedge clk);done_count=done_count+1;
            @(negedge clk);dr=0;mr=1;rc_ready=1;rf_ready=1;
        end
    endtask
    task reset_cut(input integer phase);
        integer sent;
        begin
            launch(phase==3?6:0);sent=0;mr=0;rc_ready=1;rf_ready=0;
            if(phase<3)begin
                while(sent<(phase==0?1:SW))begin
                    @(negedge clk);sv=1;sensor=sensors[sent];@(posedge clk);if(sr)sent=sent+1;
                end
                @(negedge clk);sv=0;
                if(phase==1)wait(core_state==4);
                if(phase==2)begin wait(mv);repeat(3)@(negedge clk);end
            end else begin wait(dv);repeat(3)@(negedge clk);end
            reset_now();cancelled=cancelled+1;frame(0,1);
        end
    endtask
    integer i,p;
    initial begin
        $readmemh("config.hex",configs);$readmemh("sensor.hex",sensors);$readmemh("golden.hex",golden);
        $readmemh("rows.hex",row_golden);$readmemh("done.hex",dones);$readmemh("counts.hex",counts);
        reset_now();for(p=0;p<2;p=p+1)for(i=0;i<C;i=i+1)frame(i,p);
        for(i=0;i<4;i=i+1)reset_cut(i);
        if(checked!=counts[3]||commands!=40||done_count!=36||resets!=5||cancelled!=4||holds==0||gaps==0||row_checks==0)$fatal(1,"coverage counters");
        $display("PASS RAW_OB W=%0d H=%0d B=%0d L=%0d R=%0d T=%0d WRAP=%0d checked=%0d commands=%0d done=%0d resets=%0d cancelled=%0d holds=%0d gaps=%0d rows=%0d",W,H,B,L,R,T,WRAP,checked,commands,done_count,resets,cancelled,holds,gaps,row_checks);$finish;
    end
endmodule
