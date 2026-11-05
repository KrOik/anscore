// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module tb_gif_lzw_decoder;
    parameter integer COUNT_W=32,TAG_W=8;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg s_valid=0,s_last=0,s_bad=0,m_ready=0,done_ready=0;
    reg [7:0] s_data=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,done_valid;
    wire [7:0] m_index,done_min_code_size;
    wire [TAG_W-1:0] m_tag,done_tag;
    wire [4:0] done_errors;
    wire [COUNT_W-1:0] done_count;
    gif_lzw_decoder #(.COUNT_W(COUNT_W),.TAG_W(TAG_W)) dut(.*);

    integer input_byte[0:19999],input_last[0:19999],input_bad[0:19999];
    reg [31:0] input_tag[0:19999];
    integer expected_index[0:19999];
    integer generation[0:4095];
    integer case_id,n_input,n_output,exp_errors,exp_min,exp_latency;
    integer exp_dict_reads,exp_dict_writes,exp_width,exp_next,exp_codes,exp_kw,exp_refills;
    reg [TAG_W-1:0] exp_tag;
    integer cycle_count=0,start_cycle,seen_outputs,seen_inputs,done_hold_cycles;
    integer dict_reads,dict_writes,stack_reads,stack_writes,max_width,max_next;
    integer codes,kw,refills,epoch=1,prior_state=-1;
    integer source_pointer,packet_cycles,pass_packets=0,pass_resets=0;
    reg active=0,started=0,completion_seen=0,completion_valid_seen=0,aborting=0;
    reg held_source=0,held_index=0,held_summary=0;
    reg [7:0] held_s_data,held_m_index;
    reg held_s_last,held_s_bad;
    reg [TAG_W-1:0] held_s_tag,held_m_tag,held_done_tag;
    reg [4:0] held_errors;
    reg [COUNT_W-1:0] held_count;
    reg [7:0] held_min;
    string profile,mode,vector_path,list_path;
    integer stall_mode=0;
    integer list_fd,scan,count_cases,k,cid;
    integer rid,owner,prefix,next_offer;
    integer ps,pneed,pbits,perrors,pwidth,pnext,pcode,pwalk,pstack,pcount;
    reg [TAG_W-1:0] fresh_tag;

    task automatic load_case(input integer id);
        integer fd,i,rc,t_id,t_nin,t_nout,t_errors,t_min,t_latency;
        integer t_dr,t_dw,t_width,t_next,t_codes,t_kw,t_refills;
        integer byte_value,last_value,bad_value,index_value;
        reg [31:0] tag_value,header_tag;
        begin
            vector_path=$sformatf("fixtures/case_%02d.vec",id);
            fd=$fopen(vector_path,"r");
            if(!fd)$fatal(1,"missing vector %s",vector_path);
            rc=$fscanf(fd,"%d %d %d %d %d %h %d %d %d %d %d %d %d %d\n",
                t_id,t_nin,t_nout,t_errors,t_min,header_tag,t_latency,t_dr,t_dw,t_width,t_next,t_codes,t_kw,t_refills);
            if(rc!=14 || t_id!=id || t_nin<1 || t_nin>20000 || t_nout<0 || t_nout>20000)
                $fatal(1,"vector header id=%0d rc=%0d",id,rc);
            case_id=t_id;n_input=t_nin;n_output=t_nout;exp_errors=t_errors;exp_min=t_min;
            exp_tag=header_tag;exp_latency=t_latency;exp_dict_reads=t_dr;exp_dict_writes=t_dw;
            exp_width=t_width;exp_next=t_next;exp_codes=t_codes;exp_kw=t_kw;exp_refills=t_refills;
            for(i=0;i<n_input;i=i+1)begin
                rc=$fscanf(fd,"%d %d %d %h\n",byte_value,last_value,bad_value,tag_value);
                if(rc!=4)$fatal(1,"input vector id=%0d row=%0d",id,i);
                input_byte[i]=byte_value;input_last[i]=last_value;input_bad[i]=bad_value;input_tag[i]=tag_value;
            end
            for(i=0;i<n_output;i=i+1)begin
                rc=$fscanf(fd,"%d\n",index_value);
                if(rc!=1)$fatal(1,"output vector id=%0d row=%0d",id,i);
                expected_index[i]=index_value;
            end
            if(!$feof(fd))begin
                rc=$fscanf(fd,"%d",index_value);
                if(rc==1)$fatal(1,"trailing vector id=%0d",id);
            end
            $fclose(fd);
            active=1;started=0;completion_seen=0;completion_valid_seen=0;
            seen_outputs=0;seen_inputs=0;source_pointer=0;packet_cycles=0;done_hold_cycles=0;
            dict_reads=0;dict_writes=0;stack_reads=0;stack_writes=0;max_width=0;max_next=0;
            codes=0;kw=0;refills=0;
        end
    endtask

    task automatic tick;
        reg accepted_source;
        begin
            @(posedge clk);
            cycle_count=cycle_count+1;
            accepted_source=!rst && s_valid && s_ready;
            if(rst)begin
                if(s_ready!==0 || m_valid!==0 || done_valid!==0)$fatal(1,"reset mask");
                held_source=0;held_index=0;held_summary=0;prior_state=-1;
                epoch=epoch+1;
            end else begin
                if(held_source && (!s_valid || {s_data,s_last,s_bad,s_tag}!=={held_s_data,held_s_last,held_s_bad,held_s_tag}))
                    $fatal(1,"source changed while stalled");
                if(held_index && (!m_valid || {m_index,m_tag}!=={held_m_index,held_m_tag}))
                    $fatal(1,"index hold");
                if(held_summary && (!done_valid || {done_errors,done_count,done_min_code_size,done_tag}!=={held_errors,held_count,held_min,held_done_tag}))
                    $fatal(1,"summary hold");
                if(m_valid && (s_ready || done_valid))$fatal(1,"index ownership");
                if(done_valid && s_ready)$fatal(1,"completion ownership");
                if(s_ready !== (dut.state==0 || dut.state==1 || dut.state==13 || dut.state==14))
                    $fatal(1,"unexpected ready state");
                if(active)begin
                    if(s_valid && s_ready)begin
                        if(completion_valid_seen)$fatal(1,"input after completion before retirement");
                        if(seen_inputs>=n_input)$fatal(1,"extra accepted input");
                        if({s_data,s_last,s_bad,s_tag}!=={8'(input_byte[seen_inputs]),1'(input_last[seen_inputs]),1'(input_bad[seen_inputs]),TAG_W'(input_tag[seen_inputs])})
                            $fatal(1,"input mismatch case=%0d byte=%0d",case_id,seen_inputs);
                        seen_inputs=seen_inputs+1;
                        source_pointer=source_pointer+1;
                        if(!started)begin started=1;start_cycle=cycle_count;end
                    end
                    if(m_valid)begin
                        if(m_tag!==exp_tag)$fatal(1,"index tag case=%0d",case_id);
                        if(seen_outputs>=n_output || m_index!==8'(expected_index[seen_outputs]))
                            $fatal(1,"index case=%0d pos=%0d got=%0d",case_id,seen_outputs,m_index);
                    end
                    if(m_valid && m_ready)seen_outputs=seen_outputs+1;
                    if(done_valid)begin
                        if(done_errors!==5'(exp_errors) || done_count!==COUNT_W'(n_output) ||
                           done_min_code_size!==8'(exp_min) || done_tag!==exp_tag ||
                           seen_outputs!=n_output || seen_inputs!=n_input)
                            $fatal(1,"summary case=%0d got err=%0d count=%0d seen=%0d/%0d",case_id,done_errors,done_count,seen_outputs,seen_inputs);
                        if(done_ready)completion_seen=1;
                    end
                    if(dut.state==0 && s_valid && s_ready)epoch=epoch+1;
                    if(started)begin
                        if(dut.state!=0 && dut.code_width>max_width)max_width=dut.code_width;
                        if(dut.state!=0 && dut.next_code>max_next)max_next=dut.next_code;
                        if(dut.state==3)begin
                            codes=codes+1;
                            if(dut.current_code==dut.clear_code)epoch=epoch+1;
                        end
                        if(dut.state==4)kw=kw+1;
                        if(dut.state==2 && dut.bit_count<dut.code_width)refills=refills+1;
                        if(dut.state==6)begin
                            if(dut.walk<=dut.end_code || dut.walk>=dut.next_code || generation[dut.walk]!=epoch)
                                $fatal(1,"unowned dictionary read case=%0d addr=%0d epoch=%0d",case_id,dut.walk,epoch);
                            dict_reads=dict_reads+1;
                        end
                        if(dut.state==7)begin
                            if(prior_state!=6 || dut.dictionary_q[19:8]>=dut.walk || dut.dictionary_q[7:0]>=dut.clear_code)
                                $fatal(1,"dictionary synchronous read / decreasing prefix");
                        end
                        if(dut.state==9 && dut.previous_valid && dut.next_code<4096)begin
                            if(dut.previous_code>=dut.next_code)$fatal(1,"dictionary prefix ownership");
                            generation[dut.next_code]=epoch;
                            dict_writes=dict_writes+1;
                        end
                        if(dut.state==4 || dut.state==7 || dut.state==8)begin
                            if(dut.stack_count>=4096)$fatal(1,"stack write bound");
                            stack_writes=stack_writes+1;
                        end
                        if(dut.state==10 && !(&dut.output_count))begin
                            if(dut.stack_count<1 || dut.stack_count>4096)$fatal(1,"stack read bound");
                            stack_reads=stack_reads+1;
                        end
                        if(dut.state==11 && prior_state!=10)$fatal(1,"stack synchronous read");
                        if(dut.state>=2 && dut.state<=12 && (dut.code_width<3 || dut.code_width>12 || dut.next_code>4096 || dut.bit_count>19))
                            $fatal(1,"scalar bounds");
                    end
                end else if(m_valid || done_valid)$fatal(1,"unowned output");
                held_source=s_valid && !s_ready;
                held_s_data=s_data;held_s_last=s_last;held_s_bad=s_bad;held_s_tag=s_tag;
                held_index=m_valid && !m_ready;held_m_index=m_index;held_m_tag=m_tag;
                held_summary=done_valid && !done_ready;
                held_errors=done_errors;held_count=done_count;held_min=done_min_code_size;held_done_tag=done_tag;
                prior_state=dut.state;
            end
            #1;
            if(accepted_source)s_valid=0;
            if(!rst && active && done_valid && !completion_valid_seen)begin
                completion_valid_seen=1;
                if(!aborting && exp_errors==0)begin
                    if(dict_reads!=exp_dict_reads || dict_writes!=exp_dict_writes || stack_reads!=n_output || stack_writes!=n_output ||
                       max_width!=exp_width || max_next!=exp_next || codes!=exp_codes || kw!=exp_kw || refills!=exp_refills)
                        $fatal(1,"work case=%0d dr=%0d/%0d dw=%0d/%0d sw=%0d sr=%0d codes=%0d kw=%0d refill=%0d width=%0d next=%0d",case_id,dict_reads,exp_dict_reads,dict_writes,exp_dict_writes,stack_writes,stack_reads,codes,kw,refills,max_width,max_next);
                    if(stall_mode==0 && cycle_count-start_cycle!=exp_latency)
                        $fatal(1,"latency case=%0d got=%0d expected=%0d",case_id,cycle_count-start_cycle,exp_latency);
                end
            end
        end
    endtask

    task automatic drive_packet;
        begin
            if(!s_valid)begin
                if(source_pointer<n_input && (!stall_mode || packet_cycles%7!=2))begin
                    s_valid=1;s_data=8'(input_byte[source_pointer]);s_last=1'(input_last[source_pointer]);
                    s_bad=1'(input_bad[source_pointer]);s_tag=TAG_W'(input_tag[source_pointer]);
                end else s_valid=0;
            end
            m_ready=!stall_mode || (packet_cycles%9>=3 && packet_cycles%13!=8);
            done_ready=!aborting && completion_valid_seen && done_hold_cycles>=3;
            if(completion_valid_seen)done_hold_cycles=done_hold_cycles+1;
            packet_cycles=packet_cycles+1;
            if(packet_cycles>400000)$fatal(1,"fixed packet cycle budget case=%0d",case_id);
        end
    endtask

    task automatic finish_packet;
        begin
            while(!completion_seen)begin drive_packet();tick();end
            s_valid=0;done_ready=0;m_ready=0;active=0;
            pass_packets=pass_packets+1;
        end
    endtask

    function automatic integer predicate_match();
        begin
            predicate_match=(ps<0 || dut.state==ps) && (pneed<0 || dut.need_length==pneed) &&
                (pbits<0 || dut.bit_count==pbits) && (perrors<0 || dut.errors==perrors) &&
                (pwidth<0 || dut.code_width==pwidth) && (pnext<0 || dut.next_code==pnext) &&
                (pcode<0 || dut.current_code==pcode) && (pwalk<0 || dut.walk==pwalk) &&
                (pstack<0 || dut.stack_count==pstack) && (pcount<0 || dut.output_count==pcount);
        end
    endfunction

    task automatic reset_probe;
        integer j;
        begin
            aborting=1;stall_mode=0;load_case(owner);
            while(!predicate_match())begin drive_packet();tick();end
            if(seen_outputs!=prefix)$fatal(1,"reset prefix id=%0d got=%0d expected=%0d",rid,seen_outputs,prefix);
            fresh_tag=~exp_tag;
            m_ready=0;done_ready=0;
            if(next_offer)begin
                if(!done_valid || s_ready)$fatal(1,"DONE pending next offer setup");
                s_valid=1;s_data=2;s_last=0;s_bad=0;s_tag=fresh_tag;
                repeat(2)tick();
                if(seen_outputs!=prefix || !done_valid || s_ready)$fatal(1,"DONE pending next offer accepted");
            end
            // Reset can cancel a held source and both held sink channels.
            rst=1;s_valid=1;s_data=8'ha5;s_last=1;s_bad=1;s_tag=fresh_tag;
            #1;
            if(s_ready!==0 || m_valid!==0 || done_valid!==0)$fatal(1,"immediate reset mask");
            for(j=0;j<3;j=j+1)tick();
            active=0;s_valid=0;rst=0;aborting=0;
            #1;
            if(!s_ready || m_valid || done_valid)$fatal(1,"reset ownership clear");
            load_case(99);exp_tag=fresh_tag;input_tag[0]=fresh_tag;
            finish_packet();
            pass_resets=pass_resets+1;
        end
    endtask

    initial begin
        for(k=0;k<4096;k=k+1)generation[k]=0;
        if(!$value$plusargs("PROFILE=%s",profile))$fatal(1,"missing PROFILE");
        if(!$value$plusargs("MODE=%s",mode))$fatal(1,"missing MODE");
        if(!$value$plusargs("STALL=%d",stall_mode))stall_mode=0;
        repeat(3)begin s_valid=1;s_data=8'hfe;s_last=1;s_bad=1;tick();end
        s_valid=0;rst=0;
        #1;
        if(!s_ready || m_valid || done_valid)$fatal(1,"initial reset recovery");
        if(mode=="main")begin
            list_path=$sformatf("fixtures/%s.main",profile);
            list_fd=$fopen(list_path,"r");if(!list_fd)$fatal(1,"missing main list");
            scan=$fscanf(list_fd,"%d\n",count_cases);if(scan!=1)$fatal(1,"main list count");
            for(k=0;k<count_cases;k=k+1)begin
                scan=$fscanf(list_fd,"%d\n",cid);if(scan!=1)$fatal(1,"main list row");
                load_case(cid);finish_packet();
            end
            $fclose(list_fd);
            repeat(2)tick();
            $display("PASS MAIN profile=%s stall=%0d packets=%0d",profile,stall_mode,pass_packets);
        end else if(mode=="reset")begin
            list_path=$sformatf("fixtures/%s.reset",profile);
            list_fd=$fopen(list_path,"r");if(!list_fd)$fatal(1,"missing reset list");
            scan=$fscanf(list_fd,"%d\n",count_cases);if(scan!=1)$fatal(1,"reset list count");
            for(k=0;k<count_cases;k=k+1)begin
                scan=$fscanf(list_fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",rid,owner,prefix,next_offer,ps,pneed,pbits,perrors,pwidth,pnext,pcode,pwalk,pstack,pcount);
                if(scan!=14)$fatal(1,"reset list row");
                reset_probe();
            end
            $fclose(list_fd);
            repeat(2)tick();
            $display("PASS RESET profile=%s probes=%0d recoveries=%0d",profile,pass_resets,pass_packets);
        end else $fatal(1,"unknown mode");
        $finish;
    end
endmodule
`default_nettype wire
