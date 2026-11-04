// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_word_writeback_cache;
    parameter integer LINES=16, LINE_WORDS=4, TAG_W=8;
    parameter integer CASES=1, EVENTS=1, LOW_WORDS=128;
    localparam integer TOTAL_WORDS=LOW_WORDS+128;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1, c_valid=0, r_ready=0;
    wire c_ready,r_valid,r_hit;
    reg [1:0] c_op=0;
    reg [31:0] c_address=0,c_data=0;
    reg [3:0] c_strobe=0;
    reg [TAG_W-1:0] c_tag=0;
    wire [31:0] r_data;
    wire [1:0] r_status;
    wire [TAG_W-1:0] r_tag;
    wire q_valid,q_ready,q_write,p_ready;
    wire [31:0] q_address,q_data;
    wire [3:0] q_strobe;
    reg p_valid=0,p_error=0;
    reg [31:0] p_data=0;
    word_writeback_cache #(.LINES(LINES),.LINE_WORDS(LINE_WORDS),.TAG_W(TAG_W)) dut(
        .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),
        .c_op(c_op),.c_address(c_address),.c_data(c_data),.c_strobe(c_strobe),.c_tag(c_tag),
        .r_valid(r_valid),.r_ready(r_ready),.r_data(r_data),.r_status(r_status),.r_hit(r_hit),.r_tag(r_tag),
        .mem_req_valid(q_valid),.mem_req_ready(q_ready),.mem_req_write(q_write),
        .mem_req_address(q_address),.mem_req_data(q_data),.mem_req_strobe(q_strobe),
        .mem_resp_valid(p_valid),.mem_resp_ready(p_ready),.mem_resp_data(p_data),.mem_resp_error(p_error)
    );

    reg [31:0] memory [0:TOTAL_WORDS-1];
    reg [31:0] expected [0:TOTAL_WORDS-1];
    integer cycle=0,event_number=0;
    reg pending=0, trace_mode=1, block_request=0;
    integer delay_count=0;
    reg [31:0] pending_data=0;
    reg pending_error=0;
    integer events_file,commands_file,fields;
    integer event_write,event_error;
    reg [31:0] event_address,event_data,event_response;
    integer memory_index;
    reg actual_error;
    assign q_ready=!rst && !block_request && !pending && !p_valid && (cycle%5!=1) && (cycle%5!=2);

    function automatic [31:0] initial_word(input [31:0] address);
        initial_word=(address*32'h9e3779b1)^(address>>7)^32'h53a6c19d;
    endfunction
    function automatic integer index_of(input [31:0] address);
        if (address[1:0]!=0) index_of=-1;
        else if (address<LOW_WORDS*4) index_of=address>>2;
        else if (address>=32'hfffffe00) index_of=LOW_WORDS+((address-32'hfffffe00)>>2);
        else index_of=-1;
    endfunction

    // The responder has a deterministic variable request stall and response
    // delay. It commits only successful requests; reset cancels pending replies.
    always @(posedge clk) begin
        cycle<=cycle+1;
        if (cycle>3000000) $fatal(1,"bounded cycle timeout");
        if (rst) begin
            pending<=0; p_valid<=0; p_error<=0; p_data<=0;
            delay_count<=0;
        end else begin
            if (p_valid && p_ready) p_valid<=0;
            if (pending) begin
                if (delay_count==0) begin
                    p_valid<=1; p_error<=pending_error; p_data<=pending_data;
                    pending<=0;
                end else delay_count<=delay_count-1;
            end
            if (q_valid && q_ready) begin
                if (pending || p_valid) $fatal(1,"more than one outstanding request");
                memory_index=index_of(q_address);
                actual_error=(memory_index<0);
                event_response=0;
                if (trace_mode) begin
                    fields=$fscanf(events_file,"%d %h %h %d %h\n",event_write,event_address,event_data,event_error,event_response);
                    if (fields!=5) $fatal(1,"missing expected backend event %0d",event_number);
                    if ({q_write,q_address,q_data,q_strobe} !==
                        {event_write[0],event_address,event_data,(event_write[0]?4'hf:4'h0)})
                        $fatal(1,"backend event %0d expected w=%d a=%h d=%h got w=%d a=%h d=%h strobe=%h",
                            event_number,event_write,event_address,event_data,q_write,q_address,q_data,q_strobe);
                    actual_error=event_error!=0;
                    event_number=event_number+1;
                end
                if (q_write) begin
                    if (!actual_error) memory[memory_index]<=q_data;
                    pending_data<=0;
                end else if (actual_error) pending_data<=0;
                else begin
                    pending_data<=memory[memory_index];
                    if (trace_mode && memory[memory_index]!==event_response)
                        $fatal(1,"backend oracle memory mismatch event=%0d",event_number-1);
                end
                pending_error<=actual_error;
                pending<=1;
                delay_count<=cycle%4;
            end
        end
    end

    reg stalled_request=0,stalled_response=0;
    reg [68:0] held_request;
    reg [TAG_W+34:0] held_response;
    always @(posedge clk) begin
        if (rst) begin stalled_request<=0;stalled_response<=0;end
        else begin
            if (stalled_request && (!q_valid || {q_write,q_address,q_data,q_strobe}!==held_request))
                $fatal(1,"backend request changed under backpressure");
            if (stalled_response && (!r_valid || {r_tag,r_hit,r_status,r_data}!==held_response))
                $fatal(1,"response changed under backpressure");
            stalled_request<=q_valid&&!q_ready;
            held_request<={q_write,q_address,q_data,q_strobe};
            stalled_response<=r_valid&&!r_ready;
            held_response<={r_tag,r_hit,r_status,r_data};
        end
    end

    integer case_number,op,expected_status,expected_hit,expected_events,before_events;
    task automatic reset_now;
        begin
            rst=1;c_valid=0;r_ready=0;block_request=0;
            @(negedge clk);rst=0;
            if (r_valid || q_valid) $fatal(1,"stale valid immediately after reset");
        end
    endtask
    task automatic reset_all;
        begin
            @(negedge clk);
            reset_now();
        end
    endtask
    task automatic launch(input [1:0] op,input [31:0] address,input [31:0] value,input [3:0] strobe,input [TAG_W-1:0] tag);
        begin
            @(negedge clk);
            c_op=op;c_address=address;c_data=value;c_strobe=strobe;c_tag=tag;c_valid=1;r_ready=0;
            @(posedge clk);
            while (!c_ready) @(posedge clk);
            @(negedge clk);c_valid=0;
        end
    endtask
    task automatic finish_response(input [31:0] data_value,input [1:0] status_value,input hit_value,input [TAG_W-1:0] tag_value);
        begin
            while (!r_valid) @(negedge clk);
            if ({r_data,r_status,r_hit,r_tag} !== {data_value,status_value,hit_value,tag_value})
                $fatal(1,"response mismatch case=%0d got data=%h status=%d hit=%d tag=%h expected data=%h status=%d hit=%d tag=%h",
                    case_number,r_data,r_status,r_hit,r_tag,data_value,status_value,hit_value,tag_value);
            repeat (3) @(negedge clk);
            r_ready=1;
            @(negedge clk);r_ready=0;
        end
    endtask
    task automatic probe_write;
        begin
            launch(1,0,32'hcade3210,15,0);
            finish_response(0,0,0,0);
        end
    endtask

    reg [31:0] address,value,tag_value,expected_data;
    reg [3:0] strobe;
    integer i,probe,waited;
    reg [31:0] backing_value;
    string commands_path,events_path,expected_path;
    initial begin
        if (!$value$plusargs("COMMANDS=%s",commands_path) ||
            !$value$plusargs("EVENTS=%s",events_path) ||
            !$value$plusargs("EXPECTED=%s",expected_path)) $fatal(1,"missing vectors");
        commands_file=$fopen(commands_path,"r");
        events_file=$fopen(events_path,"r");
        if (!commands_file || !events_file) $fatal(1,"cannot open vector files");
        $readmemh(expected_path,expected);
        for (i=0;i<LOW_WORDS;i=i+1) memory[i]=initial_word(4*i);
        for (i=0;i<128;i=i+1) memory[LOW_WORDS+i]=initial_word(32'hfffffe00+4*i);
        reset_all();
        for (case_number=0;case_number<CASES;case_number=case_number+1) begin
            fields=$fscanf(commands_file,"%d %h %h %h %h %h %d %d %d\n",
                op,address,value,strobe,tag_value,expected_data,expected_status,expected_hit,expected_events);
            if (fields!=9) $fatal(1,"bad command vector case=%0d",case_number);
            before_events=event_number;
            if (op==4) reset_all();
            else begin
                launch(op[1:0],address,value,strobe,tag_value[TAG_W-1:0]);
                finish_response(expected_data,expected_status[1:0],expected_hit[0],tag_value[TAG_W-1:0]);
            end
            if (event_number-before_events!=expected_events)
                $fatal(1,"backend event count mismatch case=%0d",case_number);
        end
        if (event_number!=EVENTS) $fatal(1,"backend trace incomplete");
        for (i=0;i<TOTAL_WORDS;i=i+1)
            if (memory[i]!==expected[i]) $fatal(1,"final backing memory mismatch index=%0d",i);
        $fclose(commands_file);$fclose(events_file);
        trace_mode=0;

        // Seven bounded coordinated reset probes, including request/response
        // stalls, partial fill, dirty eviction and pending output. Singleton
        // lines substitute a waiting fill response for the partial-fill phase.
        for (probe=0;probe<7;probe=probe+1) begin
            reset_all();
            if (probe==4 || probe==5) probe_write();
            if (probe==1) block_request=1;
            launch(0,(probe==4 || probe==5)?4*LINES*LINE_WORDS:0,0,0,1);
            waited=0;
            begin : await_phase
                while (1) begin
                    if ((probe==0 && dut.state==1) ||
                        (probe==1 && q_valid&&!q_ready) ||
                        (probe==2 && dut.state==8 && p_valid) ||
                        (probe==3 && ((LINE_WORDS>1 && dut.state==7 && dut.word_index!=0) ||
                                            (LINE_WORDS==1 && dut.state==8 && !p_valid))) ||
                        (probe==4 && dut.state==5) ||
                        (probe==5 && dut.state==6 && p_valid) ||
                        (probe==6 && r_valid)) disable await_phase;
                    @(negedge clk);waited=waited+1;
                    if (waited>10000) $fatal(1,"reset phase probe not reached probe=%0d",probe);
                end
            end
            reset_now();
            backing_value=memory[0];
            launch(0,0,0,0,1);
            finish_response(backing_value,0,0,1);
            launch(0,0,0,0,0);
            finish_response(backing_value,0,1,0);
        end
        $display("PASS cases=%0d backend_events=%0d reset_probes=7 final_memory_words=%0d",CASES,EVENTS,TOTAL_WORDS);
        $finish;
    end
endmodule
