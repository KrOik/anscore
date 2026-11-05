// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none
module tb_transport #(
    parameter integer B=16,X=16,C=16,TAG=8
);
    localparam integer L=(B>1)?$clog2(B):0,TW=C+L,CW=TW+X,IW=(L>0)?L:1;
    localparam integer FW=(B>1)?$clog2(2*B):1;
    localparam integer OW=2+2*IW+2*X+C+CW+2*TW+FW+2+TAG;
    reg clk=0; always #5 clk=~clk;
    reg rst=1,s_valid=0,m_ready=0;
    wire s_ready,m_valid,m_summary,m_last;
    reg signed [X-1:0] s_key=0;
    reg [C-1:0] s_source=0,s_target=0;
    reg [TAG-1:0] s_tag=0;
    wire [IW-1:0] m_source_index,m_target_index;
    wire signed [X-1:0] m_source_key,m_target_key;
    wire [C-1:0] m_quantity;
    wire [CW-1:0] m_cost;
    wire [TW-1:0] m_source_total,m_target_total;
    wire [FW-1:0] m_flow_count;
    wire [1:0] m_error;
    wire [TAG-1:0] m_tag;
    exact_1d_transport #(.NUM_BINS(B),.KEY_W(X),.MASS_W(C),.TAG_W(TAG)) dut (
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),.s_key(s_key),
        .s_source(s_source),.s_target(s_target),.s_tag(s_tag),.m_valid(m_valid),.m_ready(m_ready),
        .m_summary(m_summary),.m_last(m_last),.m_source_index(m_source_index),
        .m_target_index(m_target_index),.m_source_key(m_source_key),.m_target_key(m_target_key),
        .m_quantity(m_quantity),.m_cost(m_cost),.m_source_total(m_source_total),
        .m_target_total(m_target_total),.m_flow_count(m_flow_count),.m_error(m_error),.m_tag(m_tag)
    );
    longint signed ix[0:15][0:63],ia[0:15][0:63],ib[0:15][0:63];
    longint signed expected[0:15][0:127][0:12],frame_tag[0:15];
    integer ids[0:5],nout[0:15],nframes;
    integer in_count=0,out_count=0,hold_count=0,offer_count=0,probe_count=0,reset_count=0;
    integer begin_count=0,end_count=0,gap_count=0,cycles=0;
    reg allow_input=0,allow_output=0,was_input_stall=0,was_output_stall=0;
    reg [X+2*C+TAG-1:0] saved_input;
    reg [OW-1:0] saved_output;
    longint unsigned saved_source_ptr,saved_target_ptr,saved_source_residual,saved_target_residual;
    wire [OW-1:0] packed_output={m_summary,m_last,m_source_index,m_target_index,
        m_source_key,m_target_key,m_quantity,m_cost,m_source_total,m_target_total,m_flow_count,m_error,m_tag};
    always @(posedge clk) begin
        cycles=cycles+1;
        if (cycles>100000) $fatal(1,"fixed watchdog");
        if (rst) begin
            if (s_ready!==0 || m_valid!==0) $fatal(1,"reset masks");
            was_input_stall=0; was_output_stall=0;
        end else begin
            if (was_input_stall && (!s_valid || {s_key,s_source,s_target,s_tag}!==saved_input))
                $fatal(1,"input changed under backpressure");
            if (was_output_stall && (!m_valid || packed_output!==saved_output))
                $fatal(1,"output changed under backpressure");
            if (was_output_stall && (dut.source_ptr!=saved_source_ptr || dut.target_ptr!=saved_target_ptr
                || dut.source_residual!=saved_source_residual || dut.target_residual!=saved_target_residual))
                $fatal(1,"pointer/residual advanced before retirement");
            if (m_valid && dut.capture_count!=B) $fatal(1,"output before full capture");
            if (s_valid && s_ready && !allow_input) $fatal(1,"unplanned input acceptance");
            if (m_valid && m_ready && !allow_output) $fatal(1,"unplanned output retirement");
            was_input_stall=s_valid && !s_ready;
            was_output_stall=m_valid && !m_ready;
            saved_input={s_key,s_source,s_target,s_tag}; saved_output=packed_output;
            saved_source_ptr=dut.source_ptr;saved_target_ptr=dut.target_ptr;
            saved_source_residual=dut.source_residual;saved_target_residual=dut.target_residual;
        end
    end

    task automatic load_fixture(input string filename);
        integer fd,r,hb,hx,hc,ht,k,j,f,id,ch;
        longint signed fixture_key,fixture_source,fixture_target,fixture_expected;
        begin
            fd=$fopen(filename,"r"); if (!fd) $fatal(1,"fixture open");
            r=$fscanf(fd,"%d %d %d %d %d",hb,hx,hc,ht,nframes);
            if (r!=5 || hb!=B || hx!=X || hc!=C || ht!=TAG || nframes<1 || nframes>6)
                $fatal(1,"fixture header");
            for (f=0;f<nframes;f=f+1) begin
                r=$fscanf(fd,"%d",id); if (r!=1 || id<0 || id>15) $fatal(1,"fixture id");
                ids[f]=id;
                r=$fscanf(fd,"%d %d",frame_tag[id],nout[id]);
                if (r!=2 || nout[id]<1 || nout[id]>128) $fatal(1,"fixture frame");
                for (k=0;k<B;k=k+1) begin
                    r=$fscanf(fd,"%d %d %d",fixture_key,fixture_source,fixture_target);
                    if (r!=3) $fatal(1,"fixture input");
                    ix[id][k]=fixture_key;ia[id][k]=fixture_source;ib[id][k]=fixture_target;
                end
                for (j=0;j<nout[id];j=j+1)
                    for (k=0;k<13;k=k+1) begin
                        r=$fscanf(fd,"%d",fixture_expected); if (r!=1) $fatal(1,"fixture token");
                        expected[id][j][k]=fixture_expected;
                    end
            end
            // Signed integer is essential: EOF is -1, never an 8-bit 255.
            ch=$fgetc(fd);
            while (ch!=-1) begin
                if (ch!=9 && ch!=10 && ch!=13 && ch!=32) $fatal(1,"fixture trailing byte");
                ch=$fgetc(fd);
            end
            $fclose(fd);
        end
    endtask

    task automatic input_record(input integer phase,id,row,input longint signed tag_value);
        begin
            if (!s_valid || !s_ready || rst) $fatal(1,"missing input handshake");
            if ($signed(s_key)!==ix[id][row] || s_source!=ia[id][row] || s_target!=ib[id][row]
                || s_tag!=tag_value) $fatal(1,"input tuple");
            $display("IN %0d %0d %0d %0d %0d %0d %0d",phase,id,row,$signed(s_key),s_source,s_target,s_tag);
            in_count=in_count+1;
        end
    endtask

    task automatic send_beat(input integer phase,id,row,input longint signed first_tag,input integer stalled);
        longint signed offered_tag;
        begin
            offered_tag=(first_tag+row)&((64'd1<<TAG)-1);
            if (stalled && row%3==1) begin
                repeat (2) begin @(posedge clk); gap_count=gap_count+1; end
            end
            @(negedge clk);
            s_key=ix[id][row];s_source=ia[id][row];s_target=ib[id][row];s_tag=offered_tag;
            s_valid=1;allow_input=1;
            @(posedge clk); while (!s_ready) @(posedge clk);
            input_record(phase,id,row,offered_tag);
            @(negedge clk);s_valid=0;allow_input=0;
        end
    endtask

    task automatic record_output(input string kind,input integer phase,id,row,input longint signed active_tag);
        longint signed actual[0:12];integer k;
        begin
            if (!m_valid || rst) $fatal(1,"missing valid token");
            actual[0]=m_summary;actual[1]=m_last;actual[2]=m_source_index;actual[3]=m_target_index;
            actual[4]=$signed(m_source_key);actual[5]=$signed(m_target_key);actual[6]=m_quantity;
            actual[7]=m_cost;actual[8]=m_flow_count;actual[9]=m_error;actual[10]=m_source_total;
            actual[11]=m_target_total;actual[12]=m_tag;
            for (k=0;k<12;k=k+1)
                if (actual[k]!==expected[id][row][k]) $fatal(1,"token mismatch id=%0d row=%0d field=%0d",id,row,k);
            if (actual[12]!==active_tag) $fatal(1,"captured tag mismatch");
            $display("%s %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                kind,phase,id,row,actual[0],actual[1],actual[2],actual[3],actual[4],actual[5],actual[6],
                actual[7],actual[8],actual[9],actual[10],actual[11],actual[12]);
        end
    endtask

    task automatic await_output;
        begin
            while (!m_valid) begin @(posedge clk); @(negedge clk); end
        end
    endtask

    task automatic retire_output(input integer phase,id,row,input longint signed active_tag,input integer holds);
        integer h;
        begin
            await_output();
            for (h=0;h<holds;h=h+1) begin
                @(posedge clk);record_output("HOLD",phase,id,row,active_tag);hold_count=hold_count+1;
                @(negedge clk);
            end
            m_ready=1;allow_output=1;
            @(posedge clk);record_output("OUT",phase,id,row,active_tag);out_count=out_count+1;
            if (m_summary && s_ready) $fatal(1,"same-final-edge input ready");
            @(negedge clk);m_ready=0;allow_output=0;
        end
    endtask

    task automatic run_frame(input integer phase,id,input longint signed active_tag,
        input integer stalled,preoffered,next_id);
        integer row,holds,start_cycle;
        begin
            $display("BEGIN %0d %0d %0d",phase,id,active_tag);begin_count=begin_count+1;start_cycle=cycles;
            row=0;
            if (preoffered) begin
                allow_input=1;
                @(posedge clk);input_record(phase,id,0,active_tag);
                @(negedge clk);s_valid=0;allow_input=0;row=1;
            end
            while (row<B) begin send_beat(phase,id,row,active_tag,stalled);row=row+1;end
            if (next_id>=0) begin
                // A real next frame, held through final retirement; never replay the current row.
                s_key=ix[next_id][0];s_source=ia[next_id][0];s_target=ib[next_id][0];
                s_tag=frame_tag[next_id];s_valid=1;
                $display("OFFER %0d %0d %0d %0d %0d",next_id,$signed(s_key),s_source,s_target,s_tag);
                offer_count=offer_count+1;
            end
            for (row=0;row<nout[id];row=row+1) begin
                holds=0;
                if (stalled && (row==0 || row==nout[id]-1)) holds=3;
                retire_output(phase,id,row,active_tag,holds);
            end
            if (cycles-start_cycle>8*B+(2*B-1)*(C+12)+16+2*B+8)
                $fatal(1,"frozen active budget plus scripted stalls");
            $display("END %0d %0d",phase,id);end_count=end_count+1;
        end
    endtask

    task automatic reset_episode(input integer point,abort_id,fresh_id,input longint signed fresh_tag);
        integer row,start_in,start_out,expected_state,expected_bit,edge_no,h;
        begin
            $display("BEGIN 1 %0d %0d",abort_id,frame_tag[abort_id]);begin_count=begin_count+1;
            start_in=in_count;start_out=out_count;
            if (point==0) send_beat(1,abort_id,0,frame_tag[abort_id],0);
            else begin
                for (row=0;row<B;row=row+1) send_beat(1,abort_id,row,frame_tag[abort_id],0);
                if (point==1) begin
                    while (!(dut.state==10 && dut.multiply_index==C/2)) @(negedge clk);
                end else if (point==2) begin
                    await_output();
                    if (m_summary) $fatal(1,"flow cancellation was not reachable");
                    for (h=0;h<3;h=h+1) begin
                        @(posedge clk);record_output("HOLD",1,abort_id,0,frame_tag[abort_id]);hold_count=hold_count+1;
                        @(negedge clk);
                    end
                end else begin
                    for (row=0;row<nout[abort_id]-1;row=row+1)
                        retire_output(1,abort_id,row,frame_tag[abort_id],0);
                    await_output();
                    if (!m_summary) $fatal(1,"summary cancellation was not reachable");
                    for (h=0;h<3;h=h+1) begin
                        @(posedge clk);record_output("HOLD",1,abort_id,nout[abort_id]-1,frame_tag[abort_id]);hold_count=hold_count+1;
                        @(negedge clk);
                    end
                end
            end
            expected_state=(point==0)?1:((point==1)?10:((point==2)?12:16));
            expected_bit=(point==0)?0:((point==1)?C/2:C-1);
            if (dut.state!=expected_state || dut.multiply_index!=expected_bit
                || in_count-start_in!=((point==0)?1:B)
                || out_count-start_out!=((point==3)?nout[abort_id]-1:0)) $fatal(1,"reset probe vacuous");
            $display("PROBE %0d %0d %0d %0d %0d %0d",point,abort_id,in_count-start_in,out_count-start_out,dut.state,dut.multiply_index);
            probe_count=probe_count+1;
            rst=1;s_valid=0;m_ready=0;allow_input=0;allow_output=0;
            for (edge_no=0;edge_no<3;edge_no=edge_no+1) begin
                @(posedge clk);
                if (s_ready!==0 || m_valid!==0) $fatal(1,"reset edge mask");
                $display("RESET %0d %0d",point,edge_no);reset_count=reset_count+1;
                @(negedge clk);
            end
            rst=0;
            run_frame(2,fresh_id,fresh_tag,0,0,-1);
        end
    endtask

    string fixture,profile,mode;
    integer f,next_id,stalled,abort_id,fresh_id;
    longint signed fresh_base;
    initial begin
        if (!$value$plusargs("FIXTURE=%s",fixture) || !$value$plusargs("PROFILE=%s",profile)
            || !$value$plusargs("MODE=%s",mode)) $fatal(1,"fixed arguments required");
        load_fixture(fixture);
        repeat (3) @(posedge clk);
        @(negedge clk);rst=0;
        $display("START %s %s",profile,mode);
        if (mode=="base" || mode=="stall") begin
            stalled=(mode=="stall");
            for (f=0;f<nframes;f=f+1) begin
                next_id=(stalled && f<nframes-1)?ids[f+1]:-1;
                run_frame(0,ids[f],frame_tag[ids[f]],stalled,stalled && f>0,next_id);
            end
        end else if (mode=="reset") begin
            if (profile=="p2" && B==16 && C==16) begin abort_id=9;fresh_id=11;fresh_base=160;end
            else if (profile=="p3" && B==64 && C==24) begin abort_id=14;fresh_id=12;fresh_base=2768240640;end
            else $fatal(1,"fixed reset profile");
            for (f=0;f<4;f=f+1) reset_episode(f,abort_id,fresh_id,fresh_base+f);
        end else $fatal(1,"unplanned mode");
        $display("COUNTS %0d %0d %0d %0d %0d %0d %0d %0d %0d",in_count,out_count,hold_count,offer_count,probe_count,reset_count,begin_count,end_count,gap_count);
        $display("PASS TRANSPORT %s %s",profile,mode);
        $display("FINISH TRANSPORT");
        $finish;
    end
endmodule
`default_nettype wire
