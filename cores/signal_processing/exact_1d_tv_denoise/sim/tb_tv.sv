// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module tb_tv;
    parameter integer N=16, DATA_W=16, TAG_W=8;
    localparam integer C=$clog2(N+1), I=(N<=1)?1:$clog2(N);
    localparam integer P=DATA_W+$clog2(N+4);
    localparam integer PACK_W=P+C+I+1+TAG_W;
    localparam integer EDGE_BOUND=(8*C+10)*N*(N+1)/2+6*N+64;
    reg clk=0, rst=1, s_valid=0, m_ready=0;
    reg signed [DATA_W-1:0] s_data=0;
    reg [DATA_W-1:0] s_lambda=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready, m_valid, m_last;
    wire signed [P-1:0] m_numerator;
    wire [C-1:0] m_denominator;
    wire [I-1:0] m_index;
    wire [TAG_W-1:0] m_tag;
    wire [PACK_W-1:0] packet={m_numerator,m_denominator,m_index,m_last,m_tag};
    wire [2*DATA_W+TAG_W-1:0] input_packet={s_data,s_lambda,s_tag};
    exact_1d_tv_denoise #(.N(N),.DATA_W(DATA_W),.TAG_W(TAG_W)) dut (
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),
        .s_data(s_data),.s_lambda(s_lambda),.s_tag(s_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_numerator(m_numerator),
        .m_denominator(m_denominator),.m_index(m_index),.m_last(m_last),.m_tag(m_tag)
    );
    always #5 clk=~clk;

    integer samples[0:N-1], target_num[0:N-1], target_den[0:N-1];
    integer stall_index[0:1], stall_duration[0:1], stall_seen[0:1];
    integer penalty, gap_after, gap_cycles, stall_count, offer_future;
    reg [31:0] case_tag;
    string fixture_path, profile_name, only_case, reset_job, case_name, word;
    integer input_sent=0, output_received=0, frame_edges=0;
    integer total_rows=0, total_frames=0, total_offers=0, reset_edges=0;
    reg monitor_active=0, allow_retire=0, hold_active=0, offer_logged=0;
    reg reset_logging=0;
    reg future_pending=0, next_input_phase=0, future_accepted=0, input_held=0;
    reg [PACK_W-1:0] held_packet;
    reg [2*DATA_W+TAG_W-1:0] held_input_packet;
    longint signed observed_n, observed_d, expected_n, expected_d;
    integer j;

    // Sample handshakes in the active region, before DUT nonblocking updates.
    // Drivers change only on falling edges. All fscanf destinations below are
    // direct scalar handles; arrays are assigned only after return checks.
    always @(posedge clk) begin
        if (rst) begin
            if (s_ready !== 1'b0 || m_valid !== 1'b0) $fatal(1,"RESET_HANDSHAKE_MASK");
            hold_active=0;
            input_held=0;
            if (reset_logging) begin
                reset_edges=reset_edges+1;
                $display("RESETEDGE %s %s %0d",case_name,reset_job,reset_edges);
            end
        end else begin
            if (input_held && (s_valid!==1'b1 || input_packet!==held_input_packet))
                $fatal(1,"HELD_INPUT_CHANGED");
            input_held=s_valid && !s_ready;
            held_input_packet=input_packet;
            if (monitor_active) begin
            frame_edges=frame_edges+1;
            if (frame_edges>EDGE_BOUND) $fatal(1,"FRAME_EDGE_BOUND");
            if (hold_active && (m_valid!==1'b1 || packet!==held_packet))
                $fatal(1,"HELD_OUTPUT_CHANGED");
            if (m_valid && (^packet===1'bx)) $fatal(1,"UNKNOWN_VALID_OUTPUT");
            if (s_valid && s_ready) begin
                if (next_input_phase) begin
                    if (!future_pending || future_accepted || input_sent!=N || output_received!=N ||
                        input_packet!=={(2*DATA_W+TAG_W){1'b0}})
                        $fatal(1,"PARTIAL_NEXT_OWNER_HANDSHAKE");
                    future_accepted=1;
                    $display("NEXTIN %s 0 %0d %0d %08h",case_name,$signed(s_data),s_lambda,s_tag);
                end else begin
                    if (input_sent>=N) $fatal(1,"UNEXPECTED_FUTURE_HANDSHAKE");
                    if ($signed(s_data)!==samples[input_sent]) $fatal(1,"DRIVER_SAMPLE");
                    $display("IN %s %0d %0d %0d %08h",case_name,input_sent,$signed(s_data),s_lambda,s_tag);
                    input_sent=input_sent+1;
                end
            end
            if (s_valid && !s_ready && input_sent==N && m_valid && m_last && !offer_logged) begin
                if (s_ready!==1'b0) $fatal(1,"FUTURE_OFFER_READY");
                offer_logged=1;
                total_offers=total_offers+1;
                $display("OFFER %s %s",case_name,reset_job);
            end
            if (m_valid && !m_ready) begin
                held_packet=packet;
                hold_active=1;
                $display("HOLD %s %0d %0d %0d %08h %0d",case_name,m_index,
                    $signed(m_numerator),m_denominator,m_tag,m_last);
                if (allow_retire) begin
                    for (j=0;j<stall_count;j=j+1)
                        if (m_index==stall_index[j]) stall_seen[j]=stall_seen[j]+1;
                end
            end else hold_active=0;
            if (m_valid && m_ready) begin
                if (!allow_retire) $fatal(1,"ABORTED_FRAME_RETIRED");
                if (input_sent!=N || output_received>=N) $fatal(1,"OUTPUT_OWNERSHIP");
                if (m_index!=output_received || m_last!==(output_received==N-1))
                    $fatal(1,"OUTPUT_INDEX_LAST");
                if (m_tag!==case_tag[TAG_W-1:0]) $fatal(1,"FIRST_BEAT_TAG");
                observed_n=$signed(m_numerator);
                observed_d=m_denominator;
                expected_n=target_num[output_received];
                expected_d=target_den[output_received];
                if (observed_d<1 || observed_d>N) $fatal(1,"OUTPUT_DENOMINATOR");
                if (observed_n*expected_d != expected_n*observed_d) $fatal(1,"EXACT_RATIONAL_TARGET");
                if ((penalty==0 || N==1) && observed_d!=1) $fatal(1,"DENOMINATOR_ONE_CONTRACT");
                $display("REC %s %0d %0d %0d %08h %0d",case_name,output_received,
                    observed_n,observed_d,m_tag,m_last);
                output_received=output_received+1;
                total_rows=total_rows+1;
            end
            end
        end
    end

    task automatic offer_input;
        begin
            s_valid=1;
            s_data=samples[input_sent];
            if (input_sent==0) begin
                s_lambda=penalty;
                s_tag=allow_retire ? case_tag[TAG_W-1:0] : ~case_tag[TAG_W-1:0];
            end else begin
                // Later values differ deliberately; the first beat owns them.
                s_lambda=~penalty;
                s_tag=allow_retire ? ~case_tag[TAG_W-1:0] : case_tag[TAG_W-1:0];
            end
        end
    endtask

    task automatic run_fresh;
        integer gap_left, slot, remaining[0:1];
        reg gap_started;
        begin
            input_sent=0;output_received=0;frame_edges=0;
            monitor_active=1;allow_retire=1;hold_active=0;offer_logged=0;
            future_pending=0;next_input_phase=0;future_accepted=0;
            gap_left=0;gap_started=0;
            for (slot=0;slot<2;slot=slot+1) begin
                remaining[slot]=(slot<stall_count)?stall_duration[slot]:0;
                stall_seen[slot]=0;
            end
            while (output_received<N) begin
                @(negedge clk);
                s_valid=0;m_ready=1;
                if (!gap_started && gap_after>=0 && input_sent==gap_after) begin
                    gap_started=1;gap_left=gap_cycles;
                end
                if (gap_left>0) gap_left=gap_left-1;
                else if (input_sent<N) offer_input();
                for (slot=0;slot<stall_count;slot=slot+1) begin
                    if (m_valid && m_index==stall_index[slot] && remaining[slot]>0) begin
                        m_ready=0;remaining[slot]=remaining[slot]-1;
                    end
                end
                if (offer_future!=0 && input_sent==N && m_valid && m_last && !m_ready)
                    future_pending=1;
                if (future_pending) begin
                    s_valid=1;s_data=0;s_lambda=0;s_tag=0;
                end
                @(posedge clk);#1;
            end
            @(negedge clk);
            if (input_sent!=N || output_received!=N) $fatal(1,"FRESH_COUNTS");
            if (gap_after>=0 && !gap_started) $fatal(1,"UNREACHED_INPUT_GAP");
            for (slot=0;slot<stall_count;slot=slot+1)
                if (stall_seen[slot]!=stall_duration[slot]) $fatal(1,"UNREACHED_OR_EXTRA_STALL");
            if (offer_future!=0 && !offer_logged) $fatal(1,"UNREACHED_FUTURE_OFFER");
            total_frames=total_frames+1;
            $display("FRAME %s %0d %0d %0d",case_name,input_sent,output_received,frame_edges);
            if (future_pending) begin
                // Keep the sampled offer stable through the old retirement and
                // the next owner's real first handshake. This is one partial
                // next frame, with no complete numerical case or output added.
                if (N==1 || s_valid!==1'b1 || s_ready!==1'b1)
                    $fatal(1,"PARTIAL_NEXT_OWNER_ADMISSION");
                next_input_phase=1;m_ready=1;
                @(posedge clk);#1;
                @(negedge clk);
                if (!future_accepted) $fatal(1,"PARTIAL_NEXT_OWNER_NOT_ACCEPTED");
                next_input_phase=0;future_pending=0;
            end
            s_valid=0;m_ready=1;monitor_active=0;
        end
    endtask

    task automatic reset_named_work;
        reg reached;
        integer held_probe_cycles;
        begin
            input_sent=0;output_received=0;frame_edges=0;
            monitor_active=1;allow_retire=0;hold_active=0;offer_logged=0;
            reached=0;held_probe_cycles=0;
            while (!reached) begin
                @(negedge clk);
                s_valid=0;m_ready=(reset_job!="HELD_FINAL");
                if (reset_job=="PARTIAL") reached=(input_sent==3);
                else if (reset_job=="ENVELOPE")
                    reached=(dut.state==dut.ST_COMPARE_INIT && dut.compare_stage==3 && dut.scan_index==1);
                else if (reset_job=="JUMP")
                    reached=(dut.state==dut.ST_WRITE_BLOCK && dut.emit_right_sign==1 && dut.emit_end==1);
                else if (reset_job=="HELD_FINAL" && m_valid && m_last) begin
                    held_probe_cycles=held_probe_cycles+1;
                    reached=(held_probe_cycles==3);
                    if (!reached) begin
                        s_valid=1;s_data=0;s_lambda=0;s_tag=0;
                    end
                end
                if (!reached) begin
                    if (input_sent<N) offer_input();
                    @(posedge clk);
                end
            end
            if (output_received!=0) $fatal(1,"RESET_ABORT_OUTPUT_COUNT");
            if (reset_job=="PARTIAL" && input_sent!=3) $fatal(1,"RESET_PARTIAL_COUNT");
            if (reset_job!="PARTIAL" && input_sent!=N) $fatal(1,"RESET_COMPLETE_INPUT_COUNT");
            if (reset_job=="HELD_FINAL" && (!hold_active || !offer_logged || s_ready!==1'b0))
                $fatal(1,"RESET_HELD_OFFER_PREDICATE");
            $display("PROBE %s %s %0d %0d %0d",case_name,reset_job,input_sent,output_received,dut.state);
            $display("RESETAT %s %s",case_name,reset_job);
            s_valid=0;m_ready=0;rst=1;reset_logging=1;
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst=0;reset_logging=0;monitor_active=0;hold_active=0;
            if (reset_edges!=3) $fatal(1,"RESET_EDGE_COUNT");
        end
    endtask

    integer fd, scanned, header_n, header_w, header_tag, header_cases;
    integer row, case_number, selected_cases;
    integer scan_sample, scan_num, scan_den, scan_stall_index, scan_stall_cycles;
    initial begin
        fixture_path="";profile_name="";only_case="";reset_job="NONE";
        if (!$value$plusargs("FIXTURE=%s",fixture_path)) $fatal(1,"FIXTURE_REQUIRED");
        if (!$value$plusargs("PROFILE=%s",profile_name)) $fatal(1,"PROFILE_REQUIRED");
        scanned=$value$plusargs("CASE=%s",only_case);
        scanned=$value$plusargs("RESET_JOB=%s",reset_job);
        if (!(reset_job=="NONE" || reset_job=="PARTIAL" || reset_job=="ENVELOPE" ||
              reset_job=="JUMP" || reset_job=="HELD_FINAL")) $fatal(1,"UNKNOWN_RESET_JOB");
        if (reset_job!="NONE" && only_case=="") $fatal(1,"RESET_CASE_REQUIRED");
        repeat (3) @(posedge clk);
        @(negedge clk);rst=0;
        fd=$fopen(fixture_path,"r");
        if (fd==0) $fatal(1,"FIXTURE_OPEN");
        scanned=$fscanf(fd,"%s %d %d %d %d",word,header_n,header_w,header_tag,header_cases);
        if (scanned!=5 || word!="TVFIX1" || header_n!=N || header_w!=DATA_W || header_tag!=TAG_W)
            $fatal(1,"FIXTURE_HEADER");
        if (header_cases<1 || header_cases>3) $fatal(1,"FIXED_CASE_COUNT");
        selected_cases=0;
        for (case_number=0;case_number<header_cases;case_number=case_number+1) begin
            scanned=$fscanf(fd,"%s %s %d %h %d %d %d %d",word,case_name,penalty,case_tag,
                gap_after,gap_cycles,stall_count,offer_future);
            if (scanned!=8 || word!="CASE" || stall_count<0 || stall_count>2) $fatal(1,"FIXTURE_CASE");
            for (row=0;row<stall_count;row=row+1) begin
                scanned=$fscanf(fd,"%s %d %d",word,scan_stall_index,scan_stall_cycles);
                if (scanned!=3 || word!="STALL") $fatal(1,"FIXTURE_STALL");
                stall_index[row]=scan_stall_index;stall_duration[row]=scan_stall_cycles;
            end
            for (row=0;row<N;row=row+1) begin
                scanned=$fscanf(fd,"%s %d",word,scan_sample);
                if (scanned!=2 || word!="X") $fatal(1,"FIXTURE_INPUT");
                samples[row]=scan_sample;
            end
            for (row=0;row<N;row=row+1) begin
                scanned=$fscanf(fd,"%s %d %d",word,scan_num,scan_den);
                if (scanned!=3 || word!="Y") $fatal(1,"FIXTURE_TARGET");
                target_num[row]=scan_num;target_den[row]=scan_den;
            end
            scanned=$fscanf(fd,"%s",word);
            if (scanned!=1 || word!="END") $fatal(1,"FIXTURE_END");
            if (only_case=="" || only_case==case_name) begin
                selected_cases=selected_cases+1;
                if (offer_future!=0 && case_number!=header_cases-1)
                    $fatal(1,"PARTIAL_NEXT_OWNER_MUST_END_SELECTED_PROGRAM");
                if (reset_job!="NONE") reset_named_work();
                run_fresh();
            end
        end
        scanned=$fgetc(fd);
        while (scanned!=-1) begin
            if (scanned!=9 && scanned!=10 && scanned!=13 && scanned!=32)
                $fatal(1,"FIXTURE_TRAILING_DATA");
            scanned=$fgetc(fd);
        end
        $fclose(fd);
        if (selected_cases<1 || (reset_job!="NONE" && selected_cases!=1)) $fatal(1,"SELECTED_CASE_COUNT");
        if (only_case=="" && selected_cases!=header_cases) $fatal(1,"NORMAL_CASE_COUNT");
        if (total_rows!=N*selected_cases || total_frames!=selected_cases) $fatal(1,"TOTAL_COUNTS");
        $display("PASS TV profile=%s frames=%0d rows=%0d reset=%s",profile_name,total_frames,total_rows,reset_job);
        $display("FINISH TV");
        $finish;
    end
endmodule
`default_nettype wire
