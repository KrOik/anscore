`timescale 1ns/1ps
module tb_descriptor_drr;
    parameter integer F=4, N=8, C=12, D=32, T=8, Q=64;
    localparam integer CW=(N<=1 ? 1 : $clog2(N+1));
    reg clk=0; always #5 clk=~clk;
    reg rst=1, run_enable=0;
    reg cmd_valid=0; wire cmd_ready;
    reg [1:0] cmd_op=0; reg [31:0] cmd_flow=0;
    reg [C-1:0] cmd_cost=0; reg [D-1:0] cmd_data=0; reg [T-1:0] cmd_tag=0;
    wire rsp_valid; reg rsp_ready=0;
    wire [2:0] rsp_status; wire [31:0] rsp_flow; wire [T-1:0] rsp_tag;
    wire [CW-1:0] rsp_count; wire [C-1:0] rsp_quantum; wire [C:0] rsp_deficit;
    wire m_valid; reg m_ready=0;
    wire [31:0] m_flow; wire [C-1:0] m_cost; wire [D-1:0] m_data; wire [T-1:0] m_tag;
    descriptor_drr_scheduler #(.FLOWS(F),.DEPTH(N),.COST_W(C),.DATA_W(D),.TAG_W(T),
                               .DEFAULT_QUANTUM(Q)) dut (.*);
    integer cycles=0, bound=0, fd, got, commands=0, outputs=0, resets=0, selections=0;
    integer held_output=0, held_response=0, same_edge=0, h;
    reg [63:0] a [0:11];
    reg [4095:0] vector_path;
    reg past_m_stall=0, past_r_stall=0;
    reg [32+C+D+T-1:0] saved_m;
    reg [3+32+T+CW+C+C+1-1:0] saved_r;
    wire [32+C+D+T-1:0] packed_m={m_flow,m_cost,m_data,m_tag};
    wire [3+32+T+CW+C+C+1-1:0] packed_r={rsp_status,rsp_flow,rsp_tag,rsp_count,rsp_quantum,rsp_deficit};
    always @(posedge clk) begin
        cycles=cycles+1;
        if (bound > 0 && cycles > bound) $fatal(1,"fixed cycle bound exceeded");
        if (rst) begin past_m_stall=0; past_r_stall=0; end
        else begin
            if (past_m_stall && (!m_valid || packed_m !== saved_m)) $fatal(1,"output ownership changed under stall");
            if (past_r_stall && (!rsp_valid || packed_r !== saved_r)) $fatal(1,"response ownership changed under stall");
            past_m_stall=m_valid && !m_ready; saved_m=packed_m;
            past_r_stall=rsp_valid && !rsp_ready; saved_r=packed_r;
            if (m_valid && m_ready) begin
                outputs=outputs+1;
                $display("O %0h %0h %0h %0h",m_flow,m_cost,m_data,m_tag);
            end
        end
    end

    task automatic reset_unit;
        begin
            @(negedge clk); rst=1; cmd_valid=0; rsp_ready=0; m_ready=0; run_enable=0;
            repeat (2) @(negedge clk);
            if (m_valid || rsp_valid || cmd_ready) $fatal(1,"reset must suppress ownership");
            rst=0; resets=resets+1;
            @(negedge clk);
            if (m_valid || rsp_valid || !cmd_ready) $fatal(1,"reset recovery");
        end
    endtask

    task automatic command_unit;
        reg [3+32+T+CW+C+C+1-1:0] expected;
        begin
            @(negedge clk);
            if (!cmd_ready) $fatal(1,"unexpected command owner");
            cmd_op=a[1]; cmd_flow=a[2]; cmd_cost=a[3]; cmd_data=a[4]; cmd_tag=a[5]; cmd_valid=1;
            m_ready=a[10][0];
            if (m_ready && !m_valid) $fatal(1,"concurrent pop requires held output");
            if (m_ready) same_edge=same_edge+1;
            @(negedge clk); cmd_valid=0; m_ready=0;
            if (!rsp_valid) $fatal(1,"response missing after accepted command");
            expected={a[6][2:0],a[2][31:0],a[5][T-1:0],a[7][CW-1:0],a[8][C-1:0],a[9][C:0]};
            if (packed_r !== expected)
                $fatal(1,"response mismatch op=%0d flow=%0d got=%h expected=%h",cmd_op,cmd_flow,packed_r,expected);
            $display("C %0h %0h %0h %0h %0h %0h",rsp_flow,rsp_tag,rsp_status,rsp_count,rsp_quantum,rsp_deficit);
            commands=commands+1;
            repeat (3) begin
                @(negedge clk); held_response=held_response+1;
                if (!rsp_valid || packed_r !== expected || cmd_ready) $fatal(1,"held response changed");
            end
            if (!a[10][1]) begin
                rsp_ready=1; @(negedge clk); rsp_ready=0;
                if (rsp_valid || !cmd_ready) $fatal(1,"response ACK boundary");
            end
        end
    endtask

    task automatic expect_unit;
        reg [32+C+D+T-1:0] expected;
        begin
            while (!m_valid) @(negedge clk);
            expected={a[1][31:0],a[2][C-1:0],a[3][D-1:0],a[4][T-1:0]};
            if (packed_m !== expected) $fatal(1,"DRR/FIFO output mismatch got=%h expected=%h",packed_m,expected);
            selections=selections+1;
            repeat (3) begin
                @(negedge clk); held_output=held_output+1;
                if (!m_valid || packed_m !== expected) $fatal(1,"held output mismatch");
            end
        end
    endtask

    initial begin
        if (!$value$plusargs("VECTOR=%s",vector_path) || !$value$plusargs("BOUND=%d",bound))
            $fatal(1,"explicit fixture and finite bound required");
        fd=$fopen(vector_path,"r"); if (!fd) $fatal(1,"fixture open failed");
        while (!$feof(fd)) begin
            got=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h %h\n",
                        a[0],a[1],a[2],a[3],a[4],a[5],a[6],a[7],a[8],a[9],a[10],a[11]);
            if (got != 12) $fatal(1,"malformed fixed fixture");
            case (a[0])
                0: command_unit();
                1: begin run_enable=a[1][0]; end
                2: expect_unit();
                3: begin
                    @(negedge clk); if (!m_valid) $fatal(1,"pop without owner");
                    m_ready=1; @(negedge clk); m_ready=0;
                end
                4: reset_unit();
                5: begin
                    if (commands != a[1] || outputs != a[2] || resets != a[3] || selections != a[4])
                        $fatal(1,"fixture completion counts");
                    $display("PASS commands=%0d outputs=%0d resets=%0d selections=%0d cycles=%0d held_output=%0d held_response=%0d same_edge=%0d",
                             commands,outputs,resets,selections,cycles,held_output,held_response,same_edge);
                    $fclose(fd); $finish;
                end
                default: $fatal(1,"unknown fixture action");
            endcase
        end
        $fatal(1,"missing completion record");
    end
endmodule
