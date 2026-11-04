// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module tb_integer_polynomial_resultant;
    parameter integer DATA_W=8,MAX_DEG=2,TAG_W=8,FRAMES=1,BEATS=1,TERMS=0,FACTORS=0,MUL_STEPS=0;
    localparam integer W=DATA_W,D=MAX_DEG,CW=$clog2(D+3),NMAX=2*D,
        NB=2*D*W+$clog2(D==1?2:D==2?24:720)+1,OW=9+TAG_W+CW+NB,
        BOUND=3+(D==1?2:D==2?24:720)*(NMAX*(W+3)+NMAX+2);
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_last=0,m_ready=0;
    reg signed [W-1:0] s_a=0,s_b=0;
    reg [2:0] s_degree_a=0,s_degree_b=0;reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_common_root;wire [CW-1:0] m_count;
    wire [2:0] m_degree_a,m_degree_b;wire [TAG_W-1:0] m_tag;wire [1:0] m_status;
    wire signed [NB-1:0] m_resultant;
    integer_polynomial_resultant #(.DATA_W(W),.MAX_DEG(D),.TAG_W(TAG_W)) dut(.*);
    wire [OW-1:0] word={m_status,m_common_root,m_tag,m_count,m_degree_a,m_degree_b,m_resultant};
    reg [OW-1:0] expected[0:FRAMES-1];reg [31:0] bounds[0:FRAMES-1];
    reg [719:0] seen_permutations=0;
    integer permutation_count=0,cycle=0,held_cycles=0,source_stalls=0,read_checks=0,multiply_checks=0;
    integer main_terms=0,main_factors=0,main_mul_steps=0,reset_probes=0,fresh_checks=0,queued_checks=0;
    integer accepted=0,outputs=0,maximum_latency=0,ii1_checks=0,i,j,rank_value,less_value,parity_value;
    reg main_active=1,previous_sink_stall=0,previous_source_stall=0;
    reg [OW-1:0] previous_word;reg [2*W+TAG_W+6:0] previous_source;
    function integer factorial;
        input integer n;integer k;
        begin factorial=1;for(k=2;k<=n;k=k+1)factorial=factorial*k;end
    endfunction
    always @(posedge clk)begin
        cycle=cycle+1;
        if(rst)begin previous_sink_stall=0;previous_source_stall=0;seen_permutations=0;permutation_count=0;end
        else begin
            if(previous_sink_stall && (!m_valid || word!==previous_word))$fatal(1,"held output changed");
            if(previous_source_stall && (!s_valid || {s_tag,s_a,s_b,s_degree_a,s_degree_b,s_last}!==previous_source))
                $fatal(1,"source changed before acceptance");
            if(m_valid && !m_ready)held_cycles=held_cycles+1;
            if(s_valid && !s_ready)source_stalls=source_stalls+1;
            previous_sink_stall=m_valid && !m_ready;previous_word=word;
            previous_source_stall=s_valid && !s_ready;previous_source={s_tag,s_a,s_b,s_degree_a,s_degree_b,s_last};
            if(dut.state==2)begin seen_permutations=0;permutation_count=0;end
            if(dut.state==3)begin
                rank_value=0;parity_value=0;
                for(i=0;i<dut.dimension;i=i+1)begin
                    if(dut.permutation[i]>=dut.dimension)$fatal(1,"permutation domain");less_value=0;
                    for(j=i+1;j<dut.dimension;j=j+1)begin
                        if(dut.permutation[i]==dut.permutation[j])$fatal(1,"permutation collision");
                        if(dut.permutation[j]<dut.permutation[i])begin less_value=less_value+1;parity_value=parity_value^1;end
                    end
                    rank_value=rank_value+less_value*factorial(dut.dimension-i-1);
                end
                if(rank_value>=factorial(dut.dimension) || seen_permutations[rank_value])$fatal(1,"duplicate/missing determinant term");
                if(dut.odd_permutation!==parity_value[0])$fatal(1,"independent permutation parity");
                seen_permutations[rank_value]=1;permutation_count=permutation_count+1;
                if(main_active)main_terms=main_terms+1;
            end
            if(dut.state==4)begin
                if(dut.row>=dut.dimension || dut.read_index>D || dut.read_index>=dut.count)$fatal(1,"coefficient read ownership");
                read_checks=read_checks+1;if(main_active)main_factors=main_factors+1;
            end
            if(dut.state==6)begin
                if(dut.mul_step>=W)$fatal(1,"multiplier domain");
                multiply_checks=multiply_checks+1;if(main_active)main_mul_steps=main_mul_steps+1;
            end
            if(dut.state==10 && permutation_count!=factorial(dut.dimension))$fatal(1,"incomplete permutation population");
            if(m_valid && s_ready)$fatal(1,"overlapped frame ownership");
        end
        if(cycle>3000000)$fatal(1,"finite total watchdog");
    end
    task push;
        input signed [W-1:0] a_value,b_value;input [2:0] da,db;
        input integer last_value;input [TAG_W-1:0] tag_value;output integer edge_number;
        begin
            @(negedge clk);s_valid=1;s_a=a_value;s_b=b_value;s_degree_a=da;s_degree_b=db;
            s_last=last_value;s_tag=tag_value;#1;
            while(s_ready!==1'b1)begin @(negedge clk);#1;end
            @(posedge clk);#1;edge_number=cycle;
        end
    endtask
    task stop_source;
        begin @(negedge clk);s_valid=0;#1;end
    endtask
    task reset_now;
        begin
            rst=1;s_valid=0;m_ready=0;#1;
            if(s_ready!==0 || m_valid!==0)$fatal(1,"reset interface gates");
            @(posedge clk);#1;
            if(dut.state!==0 || dut.count!==0 || dut.started!==0 || m_resultant!==0 || m_status!==0 ||
               m_common_root!==0 || m_degree_a!==0 || m_degree_b!==0 || m_tag!==0)$fatal(1,"reset cancellation");
            @(negedge clk);rst=0;#1;
        end
    endtask
    task wait_output;
        integer guard;
        begin
            guard=0;
            while(!m_valid)begin @(negedge clk);#1;guard=guard+1;if(guard>BOUND)$fatal(1,"first-valid bound");end
        end
    endtask
    task retire;
        begin
            m_ready=1;@(posedge clk);#1;@(negedge clk);m_ready=0;s_valid=0;#1;
            if(m_valid)$fatal(1,"retirement left stale valid");
        end
    endtask
    task fresh;
        integer e;reg [OW-1:0] held;
        begin
            push(0,-1,1,1,0,{TAG_W{1'b1}},e);push(-1,-1,7,7,1,0,e);stop_source;wait_output;
            if(m_count!==2 || m_degree_a!==1 || m_degree_b!==1 || m_resultant!==1 || m_common_root!==0 ||
               m_status!==0 || m_tag!=={TAG_W{1'b1}})$fatal(1,"fresh analytic resultant");
            held=word;repeat(3)begin @(negedge clk);#1;if(!m_valid || word!==held)$fatal(1,"fresh hold");end
            retire;repeat(3)begin @(negedge clk);#1;if(m_valid)$fatal(1,"post-fresh stale valid");end
            fresh_checks=fresh_checks+1;
        end
    endtask
    function target_seen;
        input integer id;
        begin
            case(id)
                0:target_seen=dut.state==0 && !dut.started;
                1:target_seen=dut.state==0 && dut.started && dut.count==1;
                2:target_seen=dut.state==0 && dut.count==D+2;
                3:target_seen=dut.state==1;
                4:target_seen=dut.state==2;
                5:target_seen=dut.state==3;
                6:target_seen=dut.state==4 && dut.factor_present;
                7:target_seen=dut.state==5 && dut.present_q;
                8:target_seen=dut.state==6 && dut.mul_step==0;
                9:target_seen=dut.state==6 && dut.mul_step==W/2;
                10:target_seen=dut.state==6 && dut.mul_step==W-1;
                11:target_seen=dut.state==7;
                12:target_seen=dut.state==8;
                13:target_seen=dut.state==9 && dut.heap_i<dut.dimension && dut.heap_count[dut.heap_slot]<dut.heap_i;
                14:target_seen=dut.state==9 && dut.heap_i<dut.dimension && dut.heap_count[dut.heap_slot]>=dut.heap_i;
                15:target_seen=dut.state==9 && dut.heap_i>=dut.dimension;
                16:target_seen=dut.state==10;
                17:target_seen=dut.state==11 && m_status==0 && m_resultant!=0;
                18:target_seen=dut.state==11 && m_status==0 && m_common_root;
                19:target_seen=dut.state==11 && m_status==1;
                20:target_seen=dut.state==11 && m_status==2;
                21:target_seen=dut.state==11 && m_status==3;
                22:target_seen=D==1 ? dut.state==5 && dut.factor==0 : dut.state==4 && !dut.factor_present;
                23:target_seen=dut.state==5 && dut.factor<0;
                24:target_seen=dut.state==9 && dut.heap_i<dut.dimension && dut.heap_i[0];
                25:target_seen=D==1 ? dut.state==9 && dut.heap_i>=dut.dimension :
                    dut.state==9 && dut.heap_i<dut.dimension && !dut.heap_i[0];
                26:target_seen=dut.state==11 && m_status==2 && m_count==D+2;
                27:target_seen=dut.state==11 && m_status==0 && m_degree_a==0 && m_degree_b==0;
                28:target_seen=dut.state==11 && m_status==0 && m_degree_a==0 && m_degree_b==1;
                default:target_seen=0;
            endcase
        end
    endfunction
    task probe;
        input integer id;integer k,e,guard;reg [OW-1:0] held;
        begin
            case(id)
                0:begin end
                1:begin push(0,-1,1,1,0,1,e);stop_source;end
                2,26:begin
                    for(k=0;k<D+2;k=k+1)push(-1,-1,1,1,(id==26 && k==D+1),1,e);stop_source;
                end
                18:begin push(0,0,1,1,0,1,e);push(-1,-1,0,0,1,0,e);stop_source;end
                19:begin push(-1,-1,7,7,1,1,e);stop_source;end
                20:begin push(-1,-1,1,1,1,1,e);stop_source;end
                21:begin push(0,-1,0,0,1,1,e);stop_source;end
                22,25:begin
                    if(D>1)begin
                        push(0,-1,2,1,0,1,e);push(-1,-1,0,0,0,0,e);push(-1,0,0,0,1,0,e);
                    end else begin push(0,-1,1,1,0,1,e);push(-1,-1,0,0,1,0,e);end
                    stop_source;
                end
                27:begin push(-1,-1,0,0,1,1,e);stop_source;end
                28:begin push(-1,-1,0,1,0,1,e);push(0,-1,0,0,1,0,e);stop_source;end
                default:begin push(0,-1,1,1,0,1,e);push(-1,-1,0,0,1,0,e);stop_source;end
            endcase
            guard=0;
            while(!target_seen(id))begin
                @(negedge clk);#1;guard=guard+1;if(guard>BOUND)$fatal(1,"unreached reset target %0d",id);
            end
            if(id>=17 && id<=21 || id>=26)begin
                held=word;s_valid=1;s_a=-1;s_b=-1;s_degree_a=0;s_degree_b=0;s_last=1;s_tag=0;
                repeat(3)begin @(negedge clk);#1;if(!m_valid || word!==held || s_ready)$fatal(1,"held reset target");end
            end
            reset_probes=reset_probes+1;reset_now;fresh;
        end
    endtask
    task queued;
        integer e;reg [OW-1:0] held;
        begin
            push(0,-1,1,1,0,{TAG_W{1'b1}},e);push(-1,-1,0,0,1,0,e);stop_source;wait_output;
            if(m_resultant!==1 || m_status!==0)$fatal(1,"queued setup");held=word;
            s_valid=1;s_a=-1;s_b=-1;s_degree_a=0;s_degree_b=0;s_last=1;s_tag=0;
            repeat(4)begin @(negedge clk);#1;if(!m_valid || word!==held || s_ready)$fatal(1,"queued source blocked");end
            m_ready=1;@(posedge clk);#1;@(negedge clk);m_ready=0;#1;if(!s_ready)$fatal(1,"next frame admission");
            @(posedge clk);#1;stop_source;wait_output;
            if(m_resultant!==1 || m_status!==0 || m_common_root!==0 || m_count!==1 || m_degree_a!==0 ||
               m_degree_b!==0 || m_tag!==0)$fatal(1,"queued source acceptance lost");
            retire;queued_checks=queued_checks+1;
        end
    endtask
    integer input_fd,trace_fd,rc,fi,bi,last_value,e,previous_edge,tail_edge,delay_observed;
    reg [W-1:0] a_value,b_value;reg [2:0] da_value,db_value;reg [TAG_W-1:0] tag_value;reg [OW-1:0] held;
    reg [2047:0] input_path,expected_path,bounds_path,trace_path;
    initial begin
        if(!$value$plusargs("INPUTS=%s",input_path) || !$value$plusargs("EXPECTED=%s",expected_path) ||
           !$value$plusargs("BOUNDS=%s",bounds_path) || !$value$plusargs("TRACE=%s",trace_path))$fatal(1,"missing local fixtures");
        input_fd=$fopen(input_path,"r");trace_fd=$fopen(trace_path,"w");if(!input_fd || !trace_fd)$fatal(1,"fixture open");
        $readmemh(expected_path,expected);$readmemh(bounds_path,bounds);
        @(negedge clk);#1;reset_now;
        for(fi=0;fi<FRAMES;fi=fi+1)begin
            last_value=0;previous_edge=0;
            while(!last_value)begin
                rc=$fscanf(input_fd,"%h %h %h %h %d %h\n",a_value,b_value,da_value,db_value,last_value,tag_value);
                if(rc!=6)$fatal(1,"input fixture truncation");
                push(a_value,b_value,da_value,db_value,last_value,tag_value,e);accepted=accepted+1;
                if(previous_edge)begin if(e!=previous_edge+1)$fatal(1,"collection II1");ii1_checks=ii1_checks+1;end
                previous_edge=e;if(last_value)tail_edge=e;
            end
            stop_source;wait_output;delay_observed=cycle-tail_edge;
            if(delay_observed<1 || delay_observed>bounds[fi] || bounds[fi]==1 && delay_observed!=1)$fatal(1,"tail bound");
            if(word!==expected[fi])$fatal(1,"full result frame%0d got%h expected%h",fi,word,expected[fi]);
            $fdisplay(trace_fd,"%h %0d",word,delay_observed);if(delay_observed>maximum_latency)maximum_latency=delay_observed;
            held=word;repeat(5)begin @(negedge clk);#1;if(!m_valid || word!==held || s_ready)$fatal(1,"main output hold");end
            retire;outputs=outputs+1;
        end
        main_active=0;
        if(accepted!=BEATS || outputs!=FRAMES || main_terms!=TERMS || main_factors!=FACTORS || main_mul_steps!=MUL_STEPS)
            $fatal(1,"finite main totals terms%0d factors%0d steps%0d",main_terms,main_factors,main_mul_steps);
        for(bi=0;bi<29;bi=bi+1)probe(bi);
        queued;
        $fclose(input_fd);$fclose(trace_fd);
        $display("PASS frames=%0d beats=%0d outputs=%0d bounds=%0d max_latency=%0d terms=%0d factors=%0d mul_steps=%0d read_checks=%0d multiply_checks=%0d held_cycles=%0d source_stalls=%0d ii1_checks=%0d reset_probes=%0d fresh_checks=%0d queued_checks=%0d",FRAMES,BEATS,outputs,FRAMES,maximum_latency,main_terms,main_factors,main_mul_steps,read_checks,multiply_checks,held_cycles,source_stalls,ii1_checks,reset_probes,fresh_checks,queued_checks);
        $finish;
    end
endmodule
`default_nettype wire
