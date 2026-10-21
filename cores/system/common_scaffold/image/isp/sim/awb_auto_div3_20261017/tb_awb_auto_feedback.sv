`timescale 1ns/1ps
module tb_awb_auto_feedback;
parameter WIDTH=48;
reg clk=0;
always #5 clk=~clk;
reg rst_n=1,manual_ce=1,manual_ready=1,pattern_enable=0;
reg pattern_ce=1,pattern_ready=1;
wire ce=pattern_enable ? pattern_ce : manual_ce;
wire m_ready=pattern_enable ? pattern_ready : manual_ready;
reg [23:0] s_data=0;
reg s_valid=0,s_sof=0,s_eol=0,stats_flush=0;
wire s_ready,stats_flush_ready;
wire [23:0] m_data;
wire m_valid,m_sof,m_eol;
reg [15:0] cfg_min=0,cfg_max=1024;
wire [15:0] applied_r,applied_g,applied_b;
wire [31:0] applied_frame;
wire [7:0] error_code;
wire update_pending;
integer cycle=0,phase=0,trace_fd,i,j,k,guard,accepted,fill_count;
integer immediate_async_reset_checks=0;
reg seed_valid=0;
reg [31:0] seed_value=0;
reg [31:0] rng=32'h6a09e667;
string trace_path;
img_isp_awb_auto #(.SUM_WIDTH(WIDTH)) dut(
    .clk(clk),.rst_n(rst_n),.clk_en(ce),
    .s_data(s_data),.s_valid(s_valid),.s_sof(s_sof),.s_eol(s_eol),.s_ready(s_ready),
    .m_data(m_data),.m_valid(m_valid),.m_sof(m_sof),.m_eol(m_eol),.m_ready(m_ready),
    .stats_flush(stats_flush),.stats_flush_ready(stats_flush_ready),
    .cfg_min_gain(cfg_min),.cfg_max_gain(cfg_max),
    .applied_gain_r(applied_r),.applied_gain_g(applied_g),.applied_gain_b(applied_b),
    .applied_statistics_frame(applied_frame),.error_code(error_code),
    .update_pending(update_pending));
always @(negedge clk) begin
    pattern_ce=((cycle%13)!=3 && (cycle%13)!=4);
    pattern_ready=((cycle%17)!=1 && (cycle%17)!=2 && (cycle%17)!=3 && (cycle%17)!=4);
end
always @(posedge clk) begin
    cycle=cycle+1;
        $fwrite(trace_fd,"%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,",
            cycle,phase,rst_n,ce,seed_valid,seed_value,s_valid,s_ready,s_data,s_sof,s_eol,m_valid,m_ready,m_data,m_sof,m_eol,stats_flush,stats_flush_ready,cfg_min,cfg_max,dut.stat_valid,dut.stat_ready,dut.stat_data,dut.stat_sof,dut.stat_eol,dut.stats_valid,dut.stats_ready,dut.stats_sum_r,dut.stats_sum_g,dut.stats_sum_b,dut.stats_count,dut.stats_lines,dut.stats_frame,dut.stats_overflow,dut.stats_protocol_error,dut.result_valid,dut.result_r,dut.result_g,dut.result_b,dut.result_frame,dut.result_error,dut.gain_cfg_pending,dut.gain_cfg_ready,dut.apply_update);
    #1;
        $fwrite(trace_fd,"%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h\n",
            applied_r,applied_g,applied_b,applied_frame,error_code,update_pending,dut.latest_valid,dut.latest_r,dut.latest_g,dut.latest_b,dut.latest_frame,dut.staged_r,dut.staged_g,dut.staged_b,dut.staged_frame,dut.gain_cfg_pending,m_valid,m_data,m_sof,m_eol);
end
task idle;
    input integer n;
    integer t;
    begin
        for(t=0;t<n;t=t+1) begin @(posedge clk);#2;end
        @(negedge clk);
    end
endtask
task reset_path;
    begin
        @(negedge clk);pattern_enable=0;manual_ce=0;manual_ready=0;
        rst_n=0;s_valid=0;stats_flush=0;seed_valid=0;cfg_min=0;cfg_max=1024;
        // Assert between clock edges: this distinguishes asynchronous clear
        // from a merely CE-independent synchronous reset at the next edge.
        #1;
        if(m_valid || dut.stat_valid || dut.stats_valid || dut.result_valid || update_pending ||
           {applied_r,applied_g,applied_b}!=={16'd256,16'd256,16'd256} ||
           applied_frame!==0 || error_code!==0)
            $fatal(1,"asynchronous reset did not clear feedback before next clock");
        immediate_async_reset_checks=immediate_async_reset_checks+1;
        idle(3);
        rst_n=1;
        idle(3);
        manual_ce=1;manual_ready=1;
        idle(2);
    end
endtask
task send_pixel;
    input [23:0] pixel;
    input integer sof,eol;
    begin
        @(negedge clk);s_valid=1;s_data=pixel;s_sof=sof;s_eol=eol;
        accepted=0;guard=0;
        while(!accepted) begin
            @(posedge clk);
            if(rst_n && ce && s_ready) accepted=1;
            #2;guard=guard+1;
            if(guard>3000)$fatal(1,"input timeout phase=%0d WIDTH=%0d",phase,WIDTH);
        end
        @(negedge clk);s_valid=0;
    end
endtask
task flush_frame;
    begin
        @(negedge clk);s_valid=0;stats_flush=1;
        accepted=0;guard=0;
        while(!accepted) begin
            @(posedge clk);
            if(rst_n && ce && stats_flush_ready)accepted=1;
            #2;guard=guard+1;
            if(guard>3000)$fatal(1,"flush timeout phase=%0d",phase);
        end
        @(negedge clk);stats_flush=0;
    end
endtask
task fill_output;
    begin
        @(negedge clk);manual_ready=0;fill_count=0;
        #1;
        while(s_ready) begin
            send_pixel(24'h020304,0,1);
            fill_count=fill_count+1;
            #1;
            if(fill_count>8)$fatal(1,"gain pipe failed to fill");
        end
        if(fill_count==0)$fatal(1,"no pipeline fill pixel accepted");
    end
endtask
task release_one_sof;
    input [23:0] pixel;
    begin
        @(negedge clk);manual_ready=1;s_valid=1;s_data=pixel;s_sof=1;s_eol=1;
        @(posedge clk);
        if(!ce || !s_ready)$fatal(1,"single-slot SOF not accepted");
        #2;
        @(negedge clk);manual_ready=0;s_valid=0;
    end
endtask
// Explicit TB-only counter boundary seam, used immediately after reset.
// This exercises full-width association and wrap without billions of frames.
task seed_frame_counter;
    input [31:0] value;
    begin
        @(negedge clk);
        if(dut.statistics.frame_open || dut.stats_valid || dut.result_valid ||
           update_pending || s_valid || m_valid)$fatal(1,"nonquiescent frame seed");
        seed_value=value;seed_valid=1;dut.statistics.frame_id=value;
        @(posedge clk);#2;
        @(negedge clk);seed_valid=0;
    end
endtask
initial begin
    if(!$value$plusargs("TRACE_FILE=%s",trace_path))$fatal(1,"missing TRACE_FILE");
    trace_fd=$fopen(trace_path,"w");
    if(!trace_fd)$fatal(1,"trace open failed");
    $fwrite(trace_fd,"cycle,phase,rst,ce,seed,seedvalue,sv,sready,sdata,ssof,seol,mv,mready,mdata,msof,meol,flush,flushready,minimum,maximum,statv,statr,statdata,statsof,stateol,statsv,statsr,sumr,sumg,sumb,count,lines,sframe,overflow,protocol,resultv,resultr,resultg,resultb,rframe,rerror,pending,cfgready,apply,ar,ag,ab,af,error,update,latestv,latestr,latestg,latestb,latestframe,stagedr,stagedg,stagedb,stagedframe,postpending,postmv,postmdata,postmsof,postmeol\n");
    #1;rst_n=0;
    reset_path();
    phase=1;pattern_enable=1;
    // Mixed chromaticities; every accepted frame is checked, with no fixed
    // assumption about which later SOF receives a newly computed result.
    for(i=0;i<48;i=i+1) begin
        for(j=0;j<(2+i%6);j=j+1) begin
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            send_pixel(rng[23:0]^(24'h102941+i*24'h030507+j),j==0,j==(1+i%6));
        end
    end
    flush_frame();idle(1800);
    @(negedge clk);pattern_enable=0;manual_ce=1;manual_ready=1;
    idle(20);
    phase=2;reset_path();
    send_pixel(24'h06090c,1,1);
    send_pixel(24'h080c10,1,1);
    fill_output();idle(900);
    if(!dut.gain_cfg_pending)$fatal(1,"first gain not staged before mailbox test");
    // Old body pixel advances, leaving the new SOF stranded in stats bypass.
    // Its predecessor publishes B, and flushing the open frame publishes C.
    release_one_sof(24'h0a050f);
    flush_frame();idle(1500);
    if(!dut.latest_valid || !dut.gain_cfg_pending)$fatal(1,"latest mailbox did not block");
    manual_ce=0;manual_ready=1;idle(5);
    manual_ce=1;manual_ready=1;idle(12);
    send_pixel(24'h0d0703,1,1);flush_frame();idle(900);idle(12);
    phase=3;reset_path();
    send_pixel(24'h142850,1,1);
    send_pixel(24'h0f1e3c,1,1);idle(10);
    // A was captured with valid bounds; changing live bounds while it is
    // busy must not poison its eventual result. B then captures bad bounds.
    cfg_min=65535;cfg_max=0;idle(690);
    // Config is snapped at stats acceptance, not at source-pixel SOF.
    cfg_min=65535;cfg_max=0;
    send_pixel(24'h030609,1,1);idle(80);
    flush_frame();idle(80);
    cfg_min=500;cfg_max=500;
    send_pixel(24'h000000,1,1);flush_frame();idle(700);
    cfg_min=0;cfg_max=1024;
    send_pixel(24'h000a14,1,1);flush_frame();idle(700);
    send_pixel(24'hff1e0a,1,1);
    send_pixel(24'hc8beb4,1,1);
    send_pixel(24'h646464,0,1);
    flush_frame();idle(1100);
    // Header frame id high bits, carry chains, sign-bit crossing and wrap.
    for(k=0;k<3;k=k+1) begin
        phase=4+k;reset_path();
        case(k)
            0:seed_frame_counter(32'h0000fffe);
            1:seed_frame_counter(32'h7ffffffe);
            2:seed_frame_counter(32'hfffffffe);
        endcase
        for(i=0;i<6;i=i+1) begin
            send_pixel(24'h07111f+i*24'h010303,1,1);idle(320);
        end
        flush_frame();idle(900);
    end
    phase=7;reset_path();
    send_pixel(24'h09111b,1,1);
    send_pixel(24'h020508,1,1);
    fill_output();idle(12);
    // CE=0 asynchronous reset discards pixels, unfinished solver and stats.
    reset_path();idle(900);
    // Stray pixels bypass unmodified while raising sticky protocol error.
    send_pixel(24'h718293,0,1);
    stats_flush=1;idle(4);stats_flush=0;
    // A simultaneous source VALID must defer flush rather than double-publish.
    stats_flush=1;send_pixel(24'h0a141e,1,1);stats_flush=0;
    send_pixel(24'h010203,0,1);flush_frame();idle(800);
    // Reset a staged result and recover using a fresh epoch/frame0.
    reset_path();
    send_pixel(24'h102030,1,1);flush_frame();idle(800);
    if(!update_pending)$fatal(1,"pending reset stimulus not established");
    reset_path();idle(850);
    send_pixel(24'h0a1e32,1,1);flush_frame();idle(900);idle(15);
    phase=8;reset_path();
    send_pixel(24'h06090c,1,1);
    send_pixel(24'h080c10,1,1);
    fill_output();idle(900);
    release_one_sof(24'h0a050f);flush_frame();
    // Align an output release with the final solver completion edge. This is
    // a TB-only timing trigger, not an expected-result shortcut: the integer
    // scoreboard still derives all payloads and mailbox events independently.
    // A commits as C completes; next edge stages old latest B and retains C.
    guard=0;
    while(!(dut.gain_solver.gain_frame_id==32'd2 &&
            dut.gain_solver.state==dut.gain_solver.DIVIDE &&
            dut.gain_solver.channel==2 && dut.gain_solver.divider_done)) begin
        @(negedge clk);#2;guard=guard+1;
        if(guard>1500)$fatal(1,"simultaneous mailbox trigger unreachable");
    end
    if(!dut.latest_valid || !dut.gain_cfg_pending)$fatal(1,"mailbox trigger prerequisites missing");
    manual_ready=1;idle(10);
    send_pixel(24'h0d0703,1,1);idle(3);
    send_pixel(24'h09060c,1,1);flush_frame();idle(1500);idle(15);
    $display("AWB_AUTO_FEEDBACK_TRACE_PASS WIDTH=%0d cycles=%0d immediate_async_reset_checks=%0d",WIDTH,cycle,immediate_async_reset_checks);
    $fclose(trace_fd);
    $finish;
end
initial begin #15000000;$fatal(1,"feedback test timeout");end
endmodule

