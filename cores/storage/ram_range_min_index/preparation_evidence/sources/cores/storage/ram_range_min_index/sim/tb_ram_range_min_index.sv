`timescale 1ns/1ps
module tb_ram_range_min_index;
    parameter integer BUCKETS=64, VALUE_W=16, TAG_W=8;
    localparam integer H=$clog2(BUCKETS), P=1<<H;
    localparam integer IW=H>0?H:1;
    localparam integer BOUND=256*(H+1);
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, c_valid=0;
    wire c_ready, r_valid;
    reg [1:0] c_op=0;
    reg [31:0] c_lo=0,c_hi=0;
    reg [VALUE_W-1:0] c_value=0;
    reg [TAG_W-1:0] c_tag=0;
    wire [1:0] r_op,r_status;
    wire [31:0] r_index;
    wire [VALUE_W-1:0] r_value;
    wire [TAG_W-1:0] r_tag;
    integer cycle=0, stall_mode=0;
    reg hold_sink=0;
    wire r_ready=rst_n && !hold_sink && (stall_mode==0 || cycle%11>=4);
    ram_range_min_index #(.BUCKETS(BUCKETS),.VALUE_W(VALUE_W),.TAG_W(TAG_W)) dut (
        .clk(clk),.rst_n(rst_n),.c_valid(c_valid),.c_ready(c_ready),
        .c_op(c_op),.c_lo(c_lo),.c_hi(c_hi),.c_value(c_value),.c_tag(c_tag),
        .r_valid(r_valid),.r_ready(r_ready),.r_op(r_op),.r_status(r_status),
        .r_index(r_index),.r_value(r_value),.r_tag(r_tag)
    );
    reg input_stalled=0,output_stalled=0,owner=0;
    reg [2+64+VALUE_W+TAG_W-1:0] input_snapshot;
    reg [4+32+VALUE_W+TAG_W-1:0] output_snapshot;
    always @(posedge clk) begin
        cycle<=cycle+1;
        if (cycle>(BUCKETS+24+11*16+64)*(BOUND+32)) $fatal(1,"GLOBAL_WATCHDOG");
        if (!rst_n) begin
            if (c_ready!==0 || r_valid!==0) $fatal(1,"RESET_PUBLIC_HANDSHAKE");
            input_stalled<=0;output_stalled<=0;owner<=0;
        end else begin
            if (input_stalled && (c_valid!==1 ||
                {c_op,c_lo,c_hi,c_value,c_tag}!==input_snapshot)) $fatal(1,"SOURCE_STABILITY");
            if (output_stalled && (r_valid!==1 ||
                {r_op,r_status,r_index,r_value,r_tag}!==output_snapshot)) $fatal(1,"RESPONSE_STABILITY");
            input_stalled<=c_valid && !c_ready;
            output_stalled<=r_valid && !r_ready;
            input_snapshot<={c_op,c_lo,c_hi,c_value,c_tag};
            output_snapshot<={r_op,r_status,r_index,r_value,r_tag};
            if (c_ready && r_valid) $fatal(1,"OWNER_FALLTHROUGH");
            if (c_valid && c_ready) begin
                if (owner) $fatal(1,"DOUBLE_OWNER");
                owner<=1;
            end
            if (r_valid && r_ready) begin
                if (!owner) $fatal(1,"ORPHAN_RESULT");
                owner<=0;
            end
            if (dut.g_legal.state==6 && (dut.g_legal.span<=1 || dut.g_legal.sp>=H))
                $fatal(1,"STACK_BOUND");
            if (dut.g_legal.state==12 && dut.g_legal.req_ready) begin
                if (dut.g_legal.bus_addr<1 || dut.g_legal.bus_addr>=2*P) $fatal(1,"RAM_ADDRESS");
            end
            if (dut.g_legal.rsp_valid && dut.g_legal.rsp_error) $fatal(1,"RAM_ERROR");
        end
    end
    string profile,mode,path,label;
    integer f,count,i,got,j,k,age,first_seen,accepted,total_commands=0,total_records=0,probes=0;
    reg [31:0] a_op[0:299],a_lo[0:299],a_hi[0:299],a_value[0:299],a_tag[0:299];
    reg [31:0] a_rop[0:299],a_status[0:299],a_index[0:299],a_result[0:299],a_rtag[0:299];
    reg [31:0] cancel_op,cancel_lo,cancel_hi,cancel_value,cancel_tag;
    task automatic offer_row(input integer n);
        begin
            c_valid=1;c_op=a_op[n][1:0];c_lo=a_lo[n];c_hi=a_hi[n];
            c_value=a_value[n][VALUE_W-1:0];c_tag=a_tag[n][TAG_W-1:0];
        end
    endtask
    task automatic program_run(input string which,input integer already_offered);
        integer fd,rows,idx,rc,waits,done,seen;
        string filename;
        begin
            filename=$sformatf("prepared/fixtures/%s/%s.txt",profile,which);
            fd=$fopen(filename,"r");if (!fd) $fatal(1,"MISSING_FIXTURE %s",filename);
            rc=$fscanf(fd,"%d",rows);if(rc!=1 || rows<0 || rows>300) $fatal(1,"FIXTURE_COUNT");
            for(idx=0;idx<rows;idx=idx+1) begin
                rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d",
                    a_op[idx],a_lo[idx],a_hi[idx],a_value[idx],a_tag[idx],
                    a_rop[idx],a_status[idx],a_index[idx],a_result[idx],a_rtag[idx]);
                if(rc!=10) $fatal(1,"FIXTURE_ROW");
            end
            $fclose(fd);
            if(rows>0 && already_offered) begin
                if(c_valid!==1 || {c_op,c_lo,c_hi,c_value,c_tag}!==
                    {a_op[0][1:0],a_lo[0],a_hi[0],a_value[0][VALUE_W-1:0],a_tag[0][TAG_W-1:0]})
                    $fatal(1,"NEXT_OFFER_NOT_RETAINED");
            end
            if(rows>0 && !already_offered) begin @(negedge clk);offer_row(0);end
            for(idx=0;idx<rows;idx=idx+1) begin
                done=0;waits=0;
                while(!done) begin
                    @(posedge clk);waits=waits+1;
                    if(c_valid && c_ready) done=1;
                    if(waits>8) $fatal(1,"ADMISSION_OR_BOOT_BOUND");
                end
                $display("CMD %s %s %0d %0d %0d %0d %0d %0d",profile,which,idx,
                    c_op,c_lo,c_hi,c_value,c_tag);
                total_commands=total_commands+1;
                @(negedge clk);
                if(idx+1<rows) offer_row(idx+1);else c_valid=0;
                done=0;seen=0;waits=0;
                while(!done) begin
                    @(posedge clk);waits=waits+1;
                    if(!seen && r_valid) begin
                        seen=1;
                        if(waits>BOUND || (a_op[idx]==2 && waits>8)) $fatal(1,"FIRST_VALID_BOUND");
                    end
                    if(!seen && waits>BOUND) $fatal(1,"MISSING_FIRST_VALID");
                    if(r_valid && r_ready) begin
                        if({r_op,r_status,r_index,r_value,r_tag}!==
                            {a_rop[idx][1:0],a_status[idx][1:0],a_index[idx],a_result[idx][VALUE_W-1:0],a_rtag[idx][TAG_W-1:0]})
                            $fatal(1,"RESULT_MISMATCH profile=%s program=%s index=%0d",profile,which,idx);
                        $display("REC %s %s %0d %0d %0d %0d %0d %0d",profile,which,idx,
                            r_op,r_status,r_index,r_value,r_tag);
                        total_records=total_records+1;done=1;
                    end
                    if(waits>BOUND+16) $fatal(1,"FINITE_STALL_BOUND");
                end
            end
        end
    endtask
    function automatic trigger(input integer which);
        begin
            trigger=0;
            case(which)
            1: trigger=dut.g_legal.state==3 && dut.g_legal.op==0;
            2: trigger=dut.g_legal.state==13 && !dut.g_legal.bus_write && dut.g_legal.bus_return==4;
            3: trigger=dut.g_legal.state==13 && dut.g_legal.bus_write && dut.g_legal.bus_return==5;
            4: trigger=dut.g_legal.state==13 && dut.g_legal.bus_write && dut.g_legal.bus_return==6;
            5: trigger=dut.g_legal.state==13 && dut.g_legal.bus_write && dut.g_legal.bus_return==7 &&
                dut.g_legal.span==1 && dut.g_legal.node==P+cancel_lo && dut.g_legal.bus_data[VALUE_W+IW];
            6: trigger=dut.g_legal.state==13 && dut.g_legal.bus_write && dut.g_legal.bus_return==7 &&
                dut.g_legal.span==2 && dut.g_legal.node==(P+cancel_lo)/2 && !dut.g_legal.bus_data[VALUE_W+IW];
            7: trigger=dut.g_legal.state==13 && !dut.g_legal.bus_write && dut.g_legal.bus_return==4 && dut.g_legal.op==1;
            8: trigger=r_valid && r_status==0 && dut.g_legal.op==1;
            9: trigger=r_valid && r_status==1 && dut.g_legal.op==1;
            10: trigger=r_valid && r_status==0 && dut.g_legal.op==2;
            11: trigger=r_valid && r_status==0 && dut.g_legal.op==1 && c_valid && !c_ready;
            endcase
        end
    endfunction
    task automatic reset_job(input integer which);
        integer fd,rc,waits,hit,edge_number;
        string job;
        begin
            job=$sformatf("R%02d",which);
            @(negedge clk);c_valid=0;rst_n=0;hold_sink=0;
            repeat(3) @(posedge clk);
            @(negedge clk);rst_n=1;
            program_run({"pre_",job},0);
            fd=$fopen($sformatf("prepared/fixtures/%s/cancel_%s.txt",profile,job),"r");
            if(!fd) $fatal(1,"CANCEL_FIXTURE_MISSING");
            rc=$fscanf(fd,"%d %d %d %d %d",cancel_op,cancel_lo,cancel_hi,cancel_value,cancel_tag);
            if(rc!=5) $fatal(1,"CANCEL_FIXTURE_ROW");$fclose(fd);
            @(negedge clk);hold_sink=1;c_valid=1;c_op=cancel_op[1:0];c_lo=cancel_lo;c_hi=cancel_hi;
            c_value=cancel_value[VALUE_W-1:0];c_tag=cancel_tag[TAG_W-1:0];
            waits=0;hit=0;
            while(!hit) begin
                @(posedge clk);waits=waits+1;
                if(c_ready) hit=1;
                if(waits>8) $fatal(1,"CANCEL_ADMISSION_BOUND");
            end
            $display("CANCEL %s %s %0d %0d %0d %0d %0d",profile,job,c_op,c_lo,c_hi,c_value,c_tag);
            @(negedge clk);c_valid=(which==11);c_op=0;c_lo=BUCKETS-1;c_hi=BUCKETS-1;c_value=1;c_tag=1;
            waits=0;
            while(!trigger(which)) begin
                @(negedge clk);waits=waits+1;
                if(c_ready || waits>BOUND) $fatal(1,"RESET_TARGET_NOT_REACHED");
            end
            if(which==11) begin
                repeat(3) begin
                    @(negedge clk);
                    if(c_ready || !r_valid) $fatal(1,"NEXT_OFFER_OWNER_HOLD");
                end
            end
            if(c_ready || r_ready) $fatal(1,"RESET_PROBE_OWNERSHIP");
            $display("PROBE %s %s %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",profile,job,
                dut.g_legal.state,dut.g_legal.op,dut.g_legal.node,dut.g_legal.span,
                r_valid,r_status,c_ready,c_valid,dut.g_legal.bus_write,dut.g_legal.bus_return,
                dut.g_legal.bus_data[VALUE_W+IW]);
            c_valid=1;
            $display("OFFER %s %s %0d %0d %0d %0d %0d",profile,job,c_op,c_lo,c_hi,c_value,c_tag);
            rst_n=0;#1;
            if(c_ready!==0 || r_valid!==0) $fatal(1,"ASYNC_RESET_MASK");
            for(edge_number=0;edge_number<3;edge_number=edge_number+1) begin
                @(posedge clk);
                if(c_valid!==1 || c_ready!==0 || r_valid!==0) $fatal(1,"RESET_OFFER_HANDSHAKE");
                $display("RESETEDGE %s %s %0d 1 0 0",profile,job,edge_number);
            end
            @(negedge clk);rst_n=1;hold_sink=0;
            program_run({"fresh_",job},1);
            $display("RESETDONE %s %s",profile,job);probes=probes+1;
        end
    endtask
    initial begin
        if(!$value$plusargs("PROFILE=%s",profile) || !$value$plusargs("MODE=%s",mode)) $fatal(1,"PLUSARGS");
        if(mode=="main") begin
            if(!$value$plusargs("STALL=%d",stall_mode) || (stall_mode!=0 && stall_mode!=1)) $fatal(1,"STALL_MODE");
            repeat(3) @(posedge clk);
            @(negedge clk);rst_n=1;
            program_run("main",0);
            repeat(2) @(posedge clk);
            $display("PASS MAIN profile=%s stall=%0d commands=%0d records=%0d",profile,stall_mode,total_commands,total_records);
        end else if(mode=="reset") begin
            for(j=1;j<=11;j=j+1)
                if(BUCKETS!=1 || j==1 || j>=8) reset_job(j);
            repeat(2) @(posedge clk);
            $display("PASS RESET profile=%s probes=%0d commands=%0d records=%0d",profile,probes,total_commands,total_records);
        end else $fatal(1,"BAD_MODE");
        $finish;
    end
endmodule
