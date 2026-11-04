// SPDX-License-Identifier: Apache-2.0
module tb_smith_waterman_affine;
    parameter integer CHAR_W=8,MAX_LEN=32,MATCH_SCORE=2,MISMATCH_PENALTY=1,GAP_OPEN=3,GAP_EXTEND=1,TAG_W=8;
    localparam integer CW=(MAX_LEN<2)?1:$clog2(MAX_LEN+1);
    localparam integer SW=(MAX_LEN*MATCH_SCORE<2)?1:$clog2(MAX_LEN*MATCH_SCORE+1);
    reg clk=0;always #5 clk=~clk;
    reg rst=1,a_valid=0,b_valid=0,a_keep=0,b_keep=0,a_last=0,b_last=0,m_ready=0;
    reg [CHAR_W-1:0] a_char=0,b_char=0;reg [TAG_W-1:0] a_tag=0;
    wire a_ready,b_ready,m_valid;wire [SW-1:0] m_score;
    wire [CW-1:0] m_a_end,m_b_end,m_a_length,m_b_length;
    wire [1:0] m_error;wire [TAG_W-1:0] m_tag;
    smith_waterman_affine #(.CHAR_W(CHAR_W),.MAX_LEN(MAX_LEN),.MATCH_SCORE(MATCH_SCORE),
        .MISMATCH_PENALTY(MISMATCH_PENALTY),.GAP_OPEN(GAP_OPEN),.GAP_EXTEND(GAP_EXTEND),.TAG_W(TAG_W)) dut(.*);
    localparam integer OW=SW+4*CW+2+TAG_W;
    wire [OW-1:0] payload={m_score,m_a_end,m_b_end,m_a_length,m_b_length,m_error,m_tag};
    reg held=0;reg [OW-1:0] held_payload;
    integer cycles=0,stalls=0;
    always @(posedge clk) begin
        cycles<=cycles+1;if(cycles>3000000) $fatal(1,"global watchdog");
        if(rst) held<=0;
        else begin
            if(held && (!m_valid || payload!==held_payload)) $fatal(1,"held output changed");
            held<=m_valid && !m_ready;
            if(m_valid && !m_ready) begin held_payload<=payload;stalls<=stalls+1;end
            if(m_valid && (a_ready || b_ready)) $fatal(1,"input ownership");
        end
    end
    task reset_now;
        begin
            rst=1;a_valid=0;b_valid=0;m_ready=0;
            repeat(2) @(posedge clk);@(negedge clk);rst=0;
            repeat(3) begin @(posedge clk);if(m_valid || !a_ready || !b_ready) $fatal(1,"reset did not rearm");end
        end
    endtask
    task reset_core;begin @(negedge clk);reset_now();end endtask
    task send_a(input integer symbol,keep,last,input reg[31:0] tag);
        reg accepted;
        begin
            @(negedge clk);a_valid=1;a_char=CHAR_W'(symbol);a_keep=(keep!=0);a_last=(last!=0);a_tag=TAG_W'(tag);
            accepted=0;while(!accepted) begin @(posedge clk);accepted=a_ready;end
            @(negedge clk);a_valid=0;
        end
    endtask
    task send_b(input integer symbol,keep,last);
        reg accepted;
        begin
            @(negedge clk);b_valid=1;b_char=CHAR_W'(symbol);b_keep=(keep!=0);b_last=(last!=0);
            accepted=0;while(!accepted) begin @(posedge clk);accepted=b_ready;end
            @(negedge clk);b_valid=0;
        end
    endtask
    task cancel_at(input integer target);
        integer timer;
        begin
            reset_core();
            if(target==0) send_a(0,1,0,7);
            else if(target==6) send_b(0,1,0);
            else if(target==7) send_a(0,1,1,7);
            else begin
                fork send_a(0,1,1,7);send_b(0,1,1);join
                timer=0;
                while(dut.state!=target) begin @(negedge clk);timer=timer+1;if(timer>1000) $fatal(1,"reset phase not reached");end
            end
            reset_now();
        end
    endtask
    reg [CHAR_W-1:0] avec[0:MAX_LEN+15],bvec[0:MAX_LEN+15];
    integer akeeps[0:MAX_LEN+15],alasts[0:MAX_LEN+15],bkeeps[0:MAX_LEN+15],blasts[0:MAX_LEN+15];
    reg [31:0] atags[0:MAX_LEN+15];
    integer pairs=0,n_a,n_b,score,aend,bend,alen,blen,error,rc,i,k,fd;
    reg [31:0] tag;
    task drive_a;
        integer index;
        begin
            for(index=0;index<n_a;index=index+1) begin
                repeat((index+pairs)%3) @(negedge clk);
                send_a(avec[index],akeeps[index],alasts[index],atags[index]);
            end
        end
    endtask
    task drive_b;
        integer index;
        begin
            for(index=0;index<n_b;index=index+1) begin
                repeat((index+2*pairs)%4) @(negedge clk);
                send_b(bvec[index],bkeeps[index],blasts[index]);
            end
        end
    endtask
    string file_name;
    initial begin
        reset_core();
        cancel_at(0);cancel_at(6);cancel_at(7);
        cancel_at(1);cancel_at(2);cancel_at(3);cancel_at(4);cancel_at(5);
        if(!$value$plusargs("VECTORS=%s",file_name)) $fatal(1,"missing vectors");
        fd=$fopen(file_name,"r");if(!fd) $fatal(1,"cannot open vectors");
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %h\n",n_a,n_b,score,aend,bend,alen,blen,error,tag);
            if(rc!=9 || n_a>MAX_LEN+16 || n_b>MAX_LEN+16) $fatal(1,"vector header");
            for(i=0;i<n_a;i=i+1) begin
                rc=$fscanf(fd,"%h %d %d %h\n",avec[i],akeeps[i],alasts[i],atags[i]);if(rc!=4) $fatal(1,"A vector");
            end
            for(i=0;i<n_b;i=i+1) begin
                rc=$fscanf(fd,"%h %d %d\n",bvec[i],bkeeps[i],blasts[i]);if(rc!=3) $fatal(1,"B vector");
            end
            fork drive_a();drive_b();join
            k=0;while(!m_valid) begin @(negedge clk);k=k+1;if(k>2*MAX_LEN*MAX_LEN+4*MAX_LEN+10) $fatal(1,"result timeout");end
            repeat(5) begin
                if(payload!=={SW'(score),CW'(aend),CW'(bend),CW'(alen),CW'(blen),2'(error),TAG_W'(tag)})
                    $fatal(1,"pair=%0d got score=%0d ends=%0d/%0d lens=%0d/%0d error=%b tag=%h expected %0d %0d/%0d %0d/%0d %0d %h",pairs,
                        m_score,m_a_end,m_b_end,m_a_length,m_b_length,m_error,m_tag,score,aend,bend,alen,blen,error,tag);
                @(posedge clk);@(negedge clk);
            end
            m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;
            if(m_valid || !a_ready || !b_ready) $fatal(1,"result did not retire");
            pairs=pairs+1;
        end
        repeat(10) begin @(posedge clk);if(m_valid) $fatal(1,"extra output");end
        if(stalls<5*pairs) $fatal(1,"missing stall coverage");
        $display("PASS pairs=%0d reset_probes=8 stalls=%0d",pairs,stalls);$finish;
    end
endmodule
