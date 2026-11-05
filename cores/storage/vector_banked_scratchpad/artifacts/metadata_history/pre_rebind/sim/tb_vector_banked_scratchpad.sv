// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_vector_banked_scratchpad;
    parameter integer LANES=4, BANKS=4, WORDS=64, DATA_W=32, TAG_W=8;
    localparam integer COUNT_W=(LANES<2)?1:$clog2(LANES+1);
    localparam integer ROW_W=(WORDS<2)?1:$clog2(WORDS);
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg s_valid=0, m_ready=0;
    wire s_ready, m_valid;
    reg [LANES-1:0] s_mask=0,s_write=0;
    reg [LANES*32-1:0] s_address=0;
    reg [LANES*DATA_W-1:0] s_data=0;
    reg [TAG_W-1:0] s_tag=0;
    wire [1:0] m_status;
    wire [LANES-1:0] m_mask,m_error_mask;
    wire [LANES*DATA_W-1:0] m_data;
    wire [TAG_W-1:0] m_tag;
    wire [COUNT_W-1:0] m_accesses,m_rounds;
    vector_banked_scratchpad #(.LANES(LANES),.BANKS(BANKS),.WORDS(WORDS),
        .DATA_W(DATA_W),.TAG_W(TAG_W)) dut(.*);

    integer cycle=0,total_requests=0,total_responses=0,total_vectors=0;
    integer cancellations=0,held_cycles=0,watchdog=0;
    integer id,kind,want_status,want_accesses,want_rounds,hold_count,gap_count;
    reg [LANES-1:0] in_mask,in_write,want_error,want_known;
    reg [LANES*32-1:0] in_addresses;
    reg [LANES*DATA_W-1:0] in_data,want_data;
    reg [TAG_W-1:0] in_tag;
    reg [LANES-1:0] score_mask,score_write,issued_mask;
    reg [LANES*32-1:0] score_address;
    reg [LANES*DATA_W-1:0] score_data;
    reg active=0;
    integer accepted_cycle=0,request_base=0;
    integer b,l,winner,parallel_requests;
    reg [LANES*DATA_W+2*LANES+TAG_W+2*COUNT_W+2-1:0] held_payload;
    wire [LANES*DATA_W+2*LANES+TAG_W+2*COUNT_W+2-1:0] output_payload=
        {m_status,m_mask,m_error_mask,m_data,m_tag,m_accesses,m_rounds};
    reg was_held=0;
    integer vector_count,fd,scan,row;
    reg [2047:0] input_path;

    task check_answer;
        integer i;
        begin
            if(m_status!==want_status[1:0] || m_mask!==in_mask ||
               m_error_mask!==want_error || m_tag!==in_tag ||
               m_accesses!==want_accesses[COUNT_W-1:0] ||
               m_rounds!==want_rounds[COUNT_W-1:0])
                $fatal(1,"answer fields id=%0d status=%0d mask=%h error=%h tag=%h accesses=%0d rounds=%0d",
                    id,m_status,m_mask,m_error_mask,m_tag,m_accesses,m_rounds);
            for(i=0;i<LANES;i=i+1)
                if(want_known[i] &&
                   m_data[i*DATA_W+:DATA_W]!==want_data[i*DATA_W+:DATA_W])
                    $fatal(1,"data mismatch id=%0d lane=%0d got=%h expected=%h",id,i,
                        m_data[i*DATA_W+:DATA_W],want_data[i*DATA_W+:DATA_W]);
            if(total_requests-request_base!=want_accesses)
                $fatal(1,"physical request count id=%0d got=%0d expected=%0d",id,
                    total_requests-request_base,want_accesses);
            if(cycle-accepted_cycle != (want_rounds==0?1:2*want_rounds+1))
                $fatal(1,"first-valid latency id=%0d got=%0d expected=%0d",id,
                    cycle-accepted_cycle,(want_rounds==0?1:2*want_rounds+1));
        end
    endtask

    // Physical request monitor: expected winners come from captured PUBLIC
    // inputs and the specified ascending lane order, never DUT owner registers.
    // No hierarchical RAM contents are read or initialized by this testbench.
    always @(posedge clk) begin
        cycle=cycle+1; watchdog=watchdog+1;
        if(watchdog>200000) $fatal(1,"bounded testbench watchdog");
        if(!rst_n) begin active=0;was_held=0;issued_mask=0; end
        else begin
            if(was_held && (!m_valid || output_payload!==held_payload))
                $fatal(1,"held response changed id=%0d",id);
            was_held=m_valid && !m_ready;
            if(was_held) begin held_payload=output_payload;held_cycles=held_cycles+1;end
            if(s_valid && s_ready) begin
                if(active) $fatal(1,"accepted another vector before retirement");
                score_mask=s_mask;score_write=s_write;
                score_address=s_address;score_data=s_data;issued_mask=0;
                active=1;accepted_cycle=cycle;request_base=total_requests;
                total_vectors=total_vectors+1;
                $display("ACCEPT %0d %0d %0d",id,kind,cycle);
            end
            parallel_requests=0;
            for(b=0;b<BANKS;b=b+1) begin
                if(dut.implementation.bank_req_valid[b] && dut.implementation.bank_req_ready[b]) begin
                    if(!active) $fatal(1,"orphan bank request");
                    if(want_status!=0 && kind==0) $fatal(1,"rejected vector accessed RAM");
                    winner=-1;
                    for(l=0;l<LANES;l=l+1)
                        if(winner<0 && score_mask[l] && !issued_mask[l] &&
                           score_address[l*32+:32]%BANKS==b) winner=l;
                    if(winner<0) $fatal(1,"unexpected bank request id=%0d bank=%0d",id,b);
                    if(score_address[winner*32+:32]>=BANKS*WORDS)
                        $fatal(1,"out of range physical request");
                    if(dut.implementation.bank_req_address[b*ROW_W+:ROW_W]!==
                       (score_address[winner*32+:32]/BANKS) ||
                       dut.implementation.bank_req_write[b]!==score_write[winner] ||
                       dut.implementation.bank_req_data[b*DATA_W+:DATA_W]!==score_data[winner*DATA_W+:DATA_W])
                        $fatal(1,"physical request payload/order id=%0d bank=%0d lane=%0d",id,b,winner);
                    issued_mask[winner]=1'b1;
                    total_requests=total_requests+1;parallel_requests=parallel_requests+1;
                    $display("BANK %0d %0d %0d %0d %0d %0d %h",id,cycle,b,winner,
                        dut.implementation.bank_req_address[b*ROW_W+:ROW_W],dut.implementation.bank_req_write[b],
                        dut.implementation.bank_req_data[b*DATA_W+:DATA_W]);
                end
            end
            if(m_valid && !active) $fatal(1,"orphan completion");
            if(m_valid && m_ready) begin
                active=0;total_responses=total_responses+1;
                $display("RESP %0d %0d %h %h %h %h %0d %0d",id,m_status,m_mask,
                    m_error_mask,m_data,m_tag,m_accesses,m_rounds);
            end
        end
    end

    task pulse_reset;
        begin
            // Asynchronous assertion between edges must immediately suppress
            // public handshakes, every bank request and every held completion.
            rst_n=0;s_valid=0;m_ready=0;
            #1;
            if(s_ready!==0 || m_valid!==0 || dut.implementation.bank_req_valid!==0)
                $fatal(1,"asynchronous reset gating");
            repeat(2) @(negedge clk);
            rst_n=1;
            repeat(2) begin @(negedge clk);if(m_valid) $fatal(1,"post-reset orphan response");end
        end
    endtask

    initial begin
        if(!$value$plusargs("INPUT=%s",input_path)) $fatal(1,"missing INPUT");
        fd=$fopen(input_path,"r");if(!fd) $fatal(1,"cannot open INPUT");
        scan=$fscanf(fd,"%d\n",vector_count);if(scan!=1) $fatal(1,"bad vector header");
        repeat(3) @(negedge clk);rst_n=1;
        for(row=0;row<vector_count;row=row+1) begin
            scan=$fscanf(fd,"%d %d %h %h %h %h %h %d %h %h %h %d %d %d %d\n",
                id,kind,in_mask,in_write,in_addresses,in_data,in_tag,want_status,
                want_error,want_data,want_known,want_accesses,want_rounds,hold_count,gap_count);
            if(scan!=15 || id!=row) $fatal(1,"malformed vector row=%0d scan=%0d",row,scan);
            repeat(gap_count) @(negedge clk);
            if(kind==4) begin
                @(negedge clk);pulse_reset();
                $display("IDLE_RESET %0d",id);
            end else begin
                @(negedge clk);
                s_mask=in_mask;s_write=in_write;s_address=in_addresses;
                s_data=in_data;s_tag=in_tag;s_valid=1;m_ready=0;
                @(posedge clk);
                while(!s_ready) @(posedge clk);
                @(negedge clk);
                s_valid=0;
                // Changes after acceptance must not affect the owned vector.
                s_mask=~in_mask;s_write=~in_write;s_address=~in_addresses;
                s_data=~in_data;s_tag=~in_tag;
                if(kind==1) begin
                    if(total_requests!=request_base) $fatal(1,"preflight cancel already accessed RAM");
                    pulse_reset();cancellations=cancellations+1;
                    $display("CANCEL %0d %0d 0",id,kind);
                end else if(kind==2) begin
                    while(total_requests==request_base) @(negedge clk);
                    if(total_requests-request_base!=1) $fatal(1,"directed first-issue reset must commit one write");
                    pulse_reset();cancellations=cancellations+1;
                    $display("CANCEL %0d %0d 1",id,kind);
                end else begin
                    while(!m_valid) @(negedge clk);
                    check_answer();
                    if(kind==3) begin
                        $display("HELD %0d %0d %h %h %h %h %0d %0d",id,m_status,m_mask,
                            m_error_mask,m_data,m_tag,m_accesses,m_rounds);
                        repeat(hold_count) @(negedge clk);
                        pulse_reset();cancellations=cancellations+1;
                        $display("CANCEL %0d %0d %0d",id,kind,want_accesses);
                    end else begin
                        repeat(hold_count) @(negedge clk);
                        m_ready=1;@(posedge clk);#1;
                        @(negedge clk);m_ready=0;
                    end
                end
            end
        end
        scan=$fgetc(fd);
        if(scan!=-1) $fatal(1,"unexpected trailing vector bytes");
        $fclose(fd);
        repeat(3) @(negedge clk);
        $display("PASS vectors=%0d responses=%0d cancellations=%0d requests=%0d held=%0d cycles=%0d",
            total_vectors,total_responses,cancellations,total_requests,held_cycles,cycle);
        $finish;
    end
endmodule
