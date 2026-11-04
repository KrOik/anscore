// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_word_memmove;
    parameter COUNT_W=16,TAG_W=8,CASES=1;
    localparam MEMORY_WORDS=128;
    reg clk=0,rst=1,s_valid=0,done_ready=0;
    always #5 clk=~clk;
    reg [31:0] s_source=0,s_destination=0;
    reg [COUNT_W-1:0] s_words=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,done_valid,done_backward;
    wire [1:0] done_status;
    wire [COUNT_W-1:0] done_words;
    wire [TAG_W-1:0] done_tag;
    wire mem_req_valid,mem_req_write,mem_resp_ready;
    wire [31:0] mem_req_address,mem_req_data;
    wire [3:0] mem_req_strobe;
    reg mem_resp_valid=0,mem_resp_error=0;
    reg [31:0] mem_resp_data=0;
    wire mem_req_ready;
    word_memmove #(.COUNT_W(COUNT_W),.TAG_W(TAG_W)) dut(.*);
    reg [31:0] memory[0:MEMORY_WORDS-1];
    reg [31:0] initial_words[0:CASES*MEMORY_WORDS-1],expected_words[0:CASES*MEMORY_WORDS-1];
    reg [31:0] base=0;
    integer fail_read=-1,fail_write=-1,reads=0,writes=0,requests=0;
    integer cycles=0,delay_left=0,req_index;
    reg pending=0,pending_error=0,new_case=0,was_stalled=0;
    reg [31:0] pending_data;
    reg [68:0] held_request;
    wire address_ok=mem_req_address[1:0]==0 && mem_req_address>=base &&
        {1'b0,mem_req_address} < ({1'b0,base}+33'(MEMORY_WORDS*4));
    assign mem_req_ready=!rst && !new_case && !pending && !mem_resp_valid && cycles%4!=1;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>200000) $fatal(1,"watchdog");
        if(rst || new_case) begin
            pending<=0;mem_resp_valid<=0;reads<=0;writes<=0;requests<=0;was_stalled<=0;
        end else begin
            if(was_stalled && (!mem_req_valid || {mem_req_write,mem_req_address,mem_req_data,mem_req_strobe}!==held_request))
                $fatal(1,"memory request changed while stalled");
            was_stalled<=mem_req_valid&&!mem_req_ready;
            held_request<={mem_req_write,mem_req_address,mem_req_data,mem_req_strobe};
            if(mem_resp_valid&&mem_resp_ready) mem_resp_valid<=0;
            if(pending) begin
                if(delay_left==0) begin
                    pending<=0;mem_resp_valid<=1;mem_resp_data<=pending_data;mem_resp_error<=pending_error;
                end else delay_left<=delay_left-1;
            end
            if(mem_req_valid&&mem_req_ready) begin
                if(pending || mem_resp_valid) $fatal(1,"multiple outstanding requests");
                requests<=requests+1;pending<=1;delay_left<=cycles%3;
                pending_error<=!address_ok || (mem_req_write ? writes==fail_write : reads==fail_read);
                pending_data<=0;
                req_index=(mem_req_address-base)>>2;
                if(mem_req_write) begin
                    if(mem_req_strobe!==4'b1111) $fatal(1,"partial write");
                    writes<=writes+1;
                    if(address_ok && writes!=fail_write) memory[req_index]<=mem_req_data;
                end else begin
                    reads<=reads+1;
                    if(address_ok) pending_data<=memory[req_index];
                end
            end
        end
    end
    task reset_core;
        begin
            @(negedge clk);rst=1;s_valid=0;done_ready=0;
            repeat(2) @(negedge clk);rst=0;
            repeat(2) @(negedge clk);
            if(done_valid || !s_ready) $fatal(1,"reset cancellation");
        end
    endtask
    task start(input [31:0] src,dst,input [COUNT_W-1:0] count,input [TAG_W-1:0] tag);
        begin
            @(negedge clk);s_valid=1;s_source=src;s_destination=dst;s_words=count;s_tag=tag;
            do @(posedge clk);while(!s_ready);
            @(negedge clk);s_valid=0;s_source=~src;s_destination=~dst;s_words=~count;s_tag=~tag;
        end
    endtask
    integer fd,rc,n=0,k,status,moved,backward,expected_requests,words;
    integer phase,offset;
    reg [31:0] src,dst,case_base;
    reg [TAG_W-1:0] tag;
    reg [1023:0] path;
    initial begin
        if(!$value$plusargs("VECTORS=%s",path)) $fatal(1,"vectors missing");
        fd=$fopen(path,"r");if(!fd) $fatal(1,"cannot open vectors");
        if(!$value$plusargs("INITIAL=%s",path)) $fatal(1,"initial missing");
        $readmemh(path,initial_words);
        if(!$value$plusargs("EXPECTED=%s",path)) $fatal(1,"expected missing");
        $readmemh(path,expected_words);
        reset_core();
        // Reset both the request/response peer and engine at elapsed transfer
        // points and with a held completion. Memory writes need not roll back.
        for(phase=0;phase<5;phase=phase+1) begin
            for(k=0;k<MEMORY_WORDS;k=k+1) memory[k]=k+5;
            base=0;fail_read=-1;fail_write=-1;
            start(0,64,COUNT_W'((COUNT_W<4)?1:8),0);
            if(phase==4) begin wait(done_valid);repeat(3) @(negedge clk);end
            else repeat(phase*5) @(negedge clk);
            reset_core();
        end
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%h %h %d %h %d %d %d %d %d %d %h\n",
                       src,dst,words,tag,fail_read,fail_write,status,moved,backward,expected_requests,case_base);
            if(rc!=11 || n>=CASES) $fatal(1,"bad descriptor file");
            @(negedge clk);new_case=1;base=case_base;
            for(k=0;k<MEMORY_WORDS;k=k+1) memory[k]=initial_words[n*MEMORY_WORDS+k];
            @(negedge clk);new_case=0;
            start(src,dst,COUNT_W'(words),tag);
            while(!done_valid) @(negedge clk);
            repeat(6) begin
                if(!done_valid || {done_status,done_words,done_backward,done_tag}!==
                    {2'(status),COUNT_W'(moved),1'(backward),tag})
                    $fatal(1,"case%0d completion got %0d/%0d/%b/%h want %0d/%0d/%0d/%h",
                        n,done_status,done_words,done_backward,done_tag,status,moved,backward,tag);
                if(s_ready || mem_req_valid || mem_resp_ready) $fatal(1,"work after completion");
                @(negedge clk);
            end
            if(requests!=expected_requests) $fatal(1,"case%0d request count %0d want%0d",n,requests,expected_requests);
            for(k=0;k<MEMORY_WORDS;k=k+1)
                if(memory[k]!==expected_words[n*MEMORY_WORDS+k])
                    $fatal(1,"case%0d memory[%0d] got%h expected%h",n,k,memory[k],expected_words[n*MEMORY_WORDS+k]);
            done_ready=1;@(posedge clk);@(negedge clk);done_ready=0;
            if(done_valid) $fatal(1,"duplicate completion");
            n=n+1;
        end
        if(n!=CASES) $fatal(1,"missing cases");
        $fclose(fd);$display("PASS cases=%0d reset_cases=5 memory_words_checked=%0d",n,n*MEMORY_WORDS);$finish;
    end
endmodule
