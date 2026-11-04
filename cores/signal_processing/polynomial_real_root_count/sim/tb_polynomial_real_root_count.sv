// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module tb_polynomial_real_root_count;
    parameter integer DATA_W=8,MAX_DEG=3,TAG_W=8,FRAMES=1,RESETS=1;
    localparam integer W=DATA_W,D=MAX_DEG,EW=5*W+7,CW=6*W+3+TAG_W,OW=10+TAG_W+2*W,BOUND=22*EW+100;
    localparam signed [W-1:0] LOW={1'b1,{(W-1){1'b0}}},HIGH={1'b0,{(W-1){1'b1}}};
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,m_ready=0;
    reg signed [W-1:0] s_c0=0,s_c1=0,s_c2=0,s_c3=0,s_lower=0,s_upper=0;
    reg [2:0] s_degree=0;reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid;wire [2:0] m_count,m_degree;wire [1:0] m_endpoints,m_status;
    wire [TAG_W-1:0] m_tag;wire signed [W-1:0] m_lower,m_upper;
    polynomial_real_root_count #(.DATA_W(W),.MAX_DEG(D),.TAG_W(TAG_W)) dut(.*);
    wire [CW-1:0] source_word={s_tag,s_degree,s_upper,s_lower,s_c3,s_c2,s_c1,s_c0};
    wire [OW-1:0] output_word={m_status,m_endpoints,m_count,m_degree,m_tag,m_lower,m_upper};
    reg [CW+OW-1:0] fixtures[0:FRAMES-1];reg [1023:0] fixture_path;
    reg previous_source_stall=0,previous_sink_stall=0;
    reg [CW-1:0] previous_source;reg [OW-1:0] previous_output;
    reg [2*EW-1:0] product_reference;reg signed [EW-1:0] signed_reference;
    reg product_negative=0,check_result=0,main_active=0;
    reg [16:0] seen_states=0;reg [12:0] seen_operations=0;
    integer cycle=0,accepted=0,outputs=0,source_hold=0,output_hold=0,multiply_steps=0,multiply_products=0;
    integer reset_probes=0,fresh_checks=0,queued_accepts=0,maximum_latency=0,first_edge,i,j,id,guard;
    always @(posedge clk)begin
        cycle=cycle+1;
        if(rst)begin previous_source_stall=0;previous_sink_stall=0;check_result=0;end
        else begin
            if(previous_source_stall && (!s_valid || source_word!==previous_source))$fatal(1,"source withdrew/changed before acceptance");
            if(previous_sink_stall && (!m_valid || output_word!==previous_output))$fatal(1,"held result changed");
            previous_source_stall=s_valid && !s_ready;previous_source=source_word;
            previous_sink_stall=m_valid && !m_ready;previous_output=output_word;
            if(main_active)begin
                if(s_valid && s_ready)accepted=accepted+1;
                if(m_valid && m_ready)outputs=outputs+1;
                if(s_valid && !s_ready)source_hold=source_hold+1;
                if(m_valid && !m_ready)output_hold=output_hold+1;
                seen_states[dut.state]=1;
                if(dut.state==2)seen_operations[dut.operation]=1;
            end
            if(m_valid && s_ready)$fatal(1,"command/result ownership overlap");
            if(m_valid && (m_count>m_degree || m_count>3 || (m_status!=0 && (m_count!=0 || m_endpoints!=0))))
                $fatal(1,"canonical result/count bound");
            if(check_result)begin
                if(dut.mul_result!==signed_reference)$fatal(1,"independent signed product");
                check_result=0;
            end
            if(dut.state==4)begin
                if(dut.mul_step>=EW)$fatal(1,"multiplier step ownership");
                if(dut.mul_step==0)begin
                    product_reference=dut.mul_term*dut.mul_factor;product_negative=dut.mul_negative;
                    if(product_reference[2*EW-1:EW-1]!=0)$fatal(1,"proved signed work width overflow");
                    if(main_active)multiply_products=multiply_products+1;
                end
                if(dut.mul_step==EW-1)begin
                    if(dut.mul_added!==product_reference[EW-1:0])$fatal(1,"independent magnitude product");
                    signed_reference=product_negative?-$signed(product_reference[EW-1:0]):$signed(product_reference[EW-1:0]);
                    check_result=1;
                end
                if(main_active)multiply_steps=multiply_steps+1;
            end
            if(dut.state>=10 && dut.state<=14 && (dut.poly>3 || dut.eval_index>3 || dut.eval_degree>3))
                $fatal(1,"Horner ownership");
        end
        if(cycle>6000000)$fatal(1,"finite matrix watchdog");
    end
    task drive_word;
        input [CW-1:0] word;
        begin {s_tag,s_degree,s_upper,s_lower,s_c3,s_c2,s_c1,s_c0}=word;s_valid=1;end
    endtask
    task drive_probe;
        input integer target;
        begin
            s_c0=0;s_c1=-1;s_c2=HIGH;s_c3=LOW;s_degree=1;s_tag={TAG_W{1'b1}};s_lower=LOW;s_upper=HIGH;
            if((target>=2 && target<=3) || target==7 || (target>=12 && target<=17) ||
               (target>=22 && target<=24) || target==32 || target==33 || target==35 || target==39 || target==41 || target>=42)begin
                s_degree=2;s_c0=-1;s_c1=0;s_c2=1;s_c3=0;
            end
            if(target==22)begin s_c0=0;s_c1=0;end
            if(target==23)s_c0=1;
            if((target>=25 && target<=31) || target==34 || target>=44)begin
                s_degree=3;s_c0=0;s_c1=-1;s_c2=0;s_c3=1;
            end
            if(target==25)s_c1=0;
            if(target==26)begin s_c0=1;s_c1=0;end
            if(target==27 || (target>=29 && target<=31))begin s_c0=0;s_c1=0;s_c2=-1;end
            if(target==19 || target==38)s_degree=7;
            if(target==20)begin s_lower=HIGH;s_upper=LOW;end
            if(target==21)begin s_degree=0;s_c0=0;end
            if(target==39)begin s_lower=0;s_upper=0;end
            s_valid=1;
        end
    endtask
    task push_probe;
        input integer target;output integer edge_number;
        begin
            @(negedge clk);drive_probe(target);#1;
            while(!s_ready)begin @(negedge clk);#1;end
            @(posedge clk);#1;edge_number=cycle;
        end
    endtask
    task reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;#1;
            if(s_ready!==0 || m_valid!==0)$fatal(1,"immediate reset interface gating");
            @(posedge clk);#1;
            if(dut.state!==0 || m_count!==0 || m_endpoints!==0 || m_status!==0 || m_degree!==0 ||
               m_tag!==0 || m_lower!==0 || m_upper!==0 || dut.a!==0 || dut.mul_acc!==0 || dut.eval_acc!==0)
                $fatal(1,"synchronous cancellation/reset image");
            @(negedge clk);rst=0;#1;
        end
    endtask
    task wait_output;
        integer n;
        begin
            n=0;while(!m_valid)begin @(negedge clk);#1;n=n+1;if(n>BOUND)$fatal(1,"first-valid latency bound");end
        end
    endtask
    task retire;
        begin
            m_ready=1;@(posedge clk);#1;@(negedge clk);m_ready=0;#1;
            if(m_valid)$fatal(1,"stale result after retirement");
        end
    endtask
    task fresh;
        integer e;reg [OW-1:0] held;
        begin
            push_probe(36,e);@(negedge clk);s_valid=0;#1;wait_output;
            if(m_count!==1 || m_endpoints!==(W==1?2:0) || m_status!==0 || m_degree!==1 ||
               m_tag!=={TAG_W{1'b1}} || m_lower!==LOW || m_upper!==HIGH)$fatal(1,"full analytic fresh -x");
            held=output_word;repeat(3)begin @(negedge clk);#1;if(!m_valid || output_word!==held)$fatal(1,"fresh held result");end
            retire;repeat(3)begin @(negedge clk);#1;if(m_valid)$fatal(1,"stale result after fresh");end
            fresh_checks=fresh_checks+1;
        end
    endtask
    function enabled;
        input integer target;
        begin
            case(target)
                0,1,4,5,6,8,9,10,11,18,19,20,21,36,37,38,40:enabled=1;
                2,3,7,12,13,14,15,16,17,22,23,24,32,33,35,39,41,42,43:enabled=D>=2;
                25,26,27,28,29,30,31,34,44,45,46,47,48,49,50,51:enabled=D==3;
                default:enabled=0;
            endcase
        end
    endfunction
    function target_seen;
        input integer target;
        begin
            case(target)
                0:target_seen=dut.state==0;
                1:target_seen=dut.state==1;
                2:target_seen=dut.state==2;
                3:target_seen=dut.state==3;
                4:target_seen=dut.state==4 && dut.mul_step==0;
                5:target_seen=dut.state==4 && dut.mul_step==EW/2;
                6:target_seen=dut.state==4 && dut.mul_step==EW-1;
                7:target_seen=dut.state==5;
                8:target_seen=dut.state==6;
                9:target_seen=dut.state==7;
                10:target_seen=dut.state==8;
                11:target_seen=dut.state==9;
                12:target_seen=dut.state==10;
                13:target_seen=dut.state==11;
                14:target_seen=dut.state==12;
                15:target_seen=dut.state==13;
                16:target_seen=dut.state==14;
                17:target_seen=dut.state==15;
                18:target_seen=m_valid && m_status==0;
                19:target_seen=m_valid && m_status==1;
                20:target_seen=m_valid && m_status==2;
                21:target_seen=m_valid && m_status==3;
                22:target_seen=dut.state==5 && dut.delta==0;
                23:target_seen=dut.state==5 && dut.delta<0;
                24:target_seen=dut.state==5 && dut.delta>0;
                25:target_seen=dut.state==5 && dut.aa==0 && dut.bb==0;
                26:target_seen=dut.state==5 && dut.aa==0 && dut.bb!=0;
                27:target_seen=dut.state==5 && dut.aa!=0 && dut.cc==0;
                28:target_seen=dut.state==5 && dut.aa!=0 && dut.cc!=0;
                29:target_seen=dut.state==2 && dut.operation==10;
                30:target_seen=dut.state==2 && dut.operation==11;
                31:target_seen=dut.state==2 && dut.operation==12;
                32:target_seen=dut.state==10 && dut.poly==1;
                33:target_seen=dut.state==10 && dut.poly==2;
                34:target_seen=dut.state==10 && dut.poly==3;
                35:target_seen=dut.state==10 && dut.endpoint;
                36:target_seen=dut.state==6 && dut.denominator<0;
                37:target_seen=m_valid && m_status==0 && s_valid && !s_ready;
                38:target_seen=m_valid && m_status==1 && s_valid && !s_ready;
                39:target_seen=dut.state==5 && m_lower==m_upper;
                40:target_seen=dut.state==4 && dut.mul_step==0 && dut.mul_negative;
                41:target_seen=dut.state==4 && dut.mul_step==0 && dut.mul_factor==0;
                default:target_seen=target>=42 && target<=51 && dut.state==2 && dut.operation==target-42;
            endcase
        end
    endfunction
    initial begin
        if(!$value$plusargs("FIXTURE=%s",fixture_path))$fatal(1,"fixture path missing");
        $readmemh(fixture_path,fixtures);
        @(negedge clk);reset_now;main_active=1;
        @(negedge clk);drive_word(fixtures[0][CW+OW-1:OW]);#1;
        if(!s_ready)$fatal(1,"initial ready");@(posedge clk);#1;first_edge=cycle;
        for(i=0;i<FRAMES;i=i+1)begin
            @(negedge clk);
            if(i+1<FRAMES)drive_word(fixtures[i+1][CW+OW-1:OW]);else s_valid=0;
            #1;wait_output;
            if(output_word!==fixtures[i][OW-1:0])begin
                $display("frame %0d cmd=%h expected=%h actual=%h state=%0d",i,fixtures[i][CW+OW-1:OW],fixtures[i][OW-1:0],output_word,dut.state);
                $fatal(1,"independent Descartes fixture mismatch");
            end
            if(cycle-first_edge>BOUND)$fatal(1,"transaction latency bound");
            if(cycle-first_edge>maximum_latency)maximum_latency=cycle-first_edge;
            repeat(2+i%3)begin @(negedge clk);#1;end
            retire;
            if(i+1<FRAMES)begin
                if(!s_valid || !s_ready)$fatal(1,"actual queued command did not survive retirement");
                @(posedge clk);#1;first_edge=cycle;queued_accepts=queued_accepts+1;
            end
        end
        main_active=0;
        if(accepted!=FRAMES || outputs!=FRAMES || queued_accepts!=FRAMES-1)$fatal(1,"exact main acceptance/completion counts");
        if(multiply_steps!=multiply_products*EW)$fatal(1,"exact fixed-iteration multiplier population");
        for(id=0;id<=51;id=id+1)if(enabled(id))begin
            if(id==0)begin @(negedge clk);#1;end
            else begin
                push_probe(id,first_edge);@(negedge clk);
                // A real following command is offered and held, then canceled by reset.
                drive_probe(36);#1;guard=0;
                while(!target_seen(id))begin @(negedge clk);#1;guard=guard+1;if(guard>BOUND)$fatal(1,"unreached reset target %0d",id);end
            end
            if(!target_seen(id))$fatal(1,"reset target not current");
            reset_now;reset_probes=reset_probes+1;fresh;
        end
        if(reset_probes!=RESETS || fresh_checks!=RESETS)$fatal(1,"frozen reset population");
        $display("PASS W=%0d D=%0d T=%0d frames=%0d queued=%0d resets=%0d fresh=%0d products=%0d steps=%0d source_hold=%0d output_hold=%0d max_latency=%0d states=%h operations=%h",
            W,D,TAG_W,FRAMES,queued_accepts,reset_probes,fresh_checks,multiply_products,multiply_steps,source_hold,output_hold,maximum_latency,seen_states,seen_operations);
        $finish;
    end
endmodule
`default_nettype wire
