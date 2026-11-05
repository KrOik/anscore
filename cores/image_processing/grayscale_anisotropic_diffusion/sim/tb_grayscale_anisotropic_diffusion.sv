`timescale 1ns/1ps
module tb_grayscale_anisotropic_diffusion;
    parameter WIDTH=16,HEIGHT=16,TAG_W=8;
    localparam N=WIDTH*HEIGHT,XW=(WIDTH<2)?1:$clog2(WIDTH),YW=(HEIGHT<2)?1:$clog2(HEIGHT);
    localparam RESPONSE_W=XW+YW+8+16+4+5+TAG_W;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0;
    reg [7:0] s_pixel=0,s_k=0;
    reg [4:0] s_iterations=0;
    reg [TAG_W-1:0] s_tag=0;
    wire s_ready,m_valid,m_sof,m_eol,m_last,m_keep;
    wire [7:0] m_pixel;
    wire [15:0] m_value_q8;
    wire [XW-1:0] m_x;wire [YW-1:0] m_y;
    wire [4:0] m_errors;wire [TAG_W-1:0] m_tag;
    grayscale_anisotropic_diffusion #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.TAG_W(TAG_W)) dut(
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),.s_pixel(s_pixel),.s_k(s_k),
        .s_iterations(s_iterations),.s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),.s_tag(s_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_pixel(m_pixel),.m_value_q8(m_value_q8),
        .m_x(m_x),.m_y(m_y),.m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),.m_keep(m_keep),
        .m_errors(m_errors),.m_tag(m_tag));

    integer pixels[0:N-1],markers[0:N-1][0:2];
    integer expected_records[0:N-1][0:9],expected_states[0:16*N-1],expected_coefficients[0:255];
    integer frame_id,fk,fiters,ftag,nout,ferrors,nstates,ntable,expected_tail;
    integer received=0,sent=0,write_seen=0,table_seen=0,iter_seen=0;
    integer log_id=0,cycle=0,last_input_cycle=0,stall_mode=0;
    integer table_sum=0,iteration_sum=0,iteration_min=65535,iteration_max=0;
    integer total_records=0,total_writes=0,total_iterations=0,total_tables=0;
    integer aborted_records=0,old_writes=0,reset_edges=0,frames=0;
    reg monitor_active=0,old_owner=0,force_hold=0,tail_seen=0,held=0;
    reg [RESPONSE_W-1:0] held_response;
    wire [RESPONSE_W-1:0] response={m_x,m_y,m_pixel,m_value_q8,m_sof,m_eol,m_last,m_keep,m_errors,m_tag};
    string profile,mode;
    function automatic string prefix;
        begin if(old_owner) prefix="ABORT";else prefix="";end
    endfunction
    always @(negedge clk) begin
        m_ready<=!force_hold && (!stall_mode || (cycle%7!=1 && cycle%7!=2));
        #1;
        if(!rst && monitor_active && m_valid && !tail_seen) begin
            if(cycle-last_input_cycle!=expected_tail) $fatal(1,"exact tail mismatch actual=%0d expected=%0d",cycle-last_input_cycle,expected_tail);
            $display("%sTAIL %s %0d %0d",prefix(),profile,log_id,cycle-last_input_cycle);
            tail_seen=1;
        end
    end
    always @(posedge clk) begin
        cycle=cycle+1;
        if(rst) held=0;
        else begin
            if(held && (!m_valid || response!==held_response)) $fatal(1,"held response changed");
            held=m_valid && !m_ready;held_response=response;
            if(s_valid && s_ready && dut.capture_index==N-1) last_input_cycle=cycle;
            if(m_valid && s_ready) $fatal(1,"owner accepted future frame");
            if(monitor_active) begin
                if(dut.state==dut.DIV_WAIT && dut.divider_valid && dut.divider_zero) $fatal(1,"unexpected zero divisor");
                if(dut.state==dut.LUT_WRITE) begin
                    if(ntable!=256 || dut.table_index!=table_seen || dut.table_value!==expected_coefficients[table_seen])
                        $fatal(1,"coefficient mismatch index=%0d",table_seen);
                    table_sum=table_sum+dut.table_value;table_seen=table_seen+1;
                    if(table_seen==256) begin
                        $display("%sTABLE %s %0d 256 %0d",prefix(),profile,log_id,table_sum);
                        if(!old_owner) total_tables=total_tables+1;
                    end
                end
                if(dut.state==dut.WRITE_PIXEL) begin
                    if(write_seen>=nstates || dut.iteration!=write_seen/N || dut.pixel_index!=write_seen%N ||
                       dut.updated!==expected_states[write_seen] || dut.new_value<0 || dut.new_value>65280)
                        $fatal(1,"snapshot mismatch iteration=%0d pixel=%0d",dut.iteration,dut.pixel_index);
                    iteration_sum=iteration_sum+dut.updated;
                    if(dut.updated<iteration_min) iteration_min=dut.updated;
                    if(dut.updated>iteration_max) iteration_max=dut.updated;
                    write_seen=write_seen+1;
                    if(old_owner) old_writes=old_writes+1;else total_writes=total_writes+1;
                end
                if(dut.state==dut.ITER_SWAP) begin
                    if(write_seen!=(iter_seen+1)*N || dut.iteration!=iter_seen) $fatal(1,"incomplete bank swap");
                    $display("%sITER %s %0d %0d %0d %0d %0d %0d",prefix(),profile,log_id,iter_seen,N,iteration_min,iteration_max,iteration_sum);
                    iter_seen=iter_seen+1;iteration_min=65535;iteration_max=0;iteration_sum=0;
                    if(!old_owner) total_iterations=total_iterations+1;
                end
                if(m_valid && m_ready) begin
                    if(received>=nout) $fatal(1,"extra output");
                    if($unsigned(m_x)!=expected_records[received][0] || $unsigned(m_y)!=expected_records[received][1] ||
                       $unsigned(m_pixel)!=expected_records[received][2] || $unsigned(m_value_q8)!=expected_records[received][3] ||
                       m_sof!=expected_records[received][4] || m_eol!=expected_records[received][5] ||
                       m_last!=expected_records[received][6] || m_keep!=expected_records[received][7] ||
                       $unsigned(m_errors)!=expected_records[received][8] || $unsigned(m_tag)!=expected_records[received][9])
                        $fatal(1,"public tuple mismatch at%0d",received);
                    $display("%sREC %s %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",prefix(),profile,log_id,
                        $unsigned(m_x),$unsigned(m_y),$unsigned(m_pixel),$unsigned(m_value_q8),m_sof,m_eol,m_last,m_keep,$unsigned(m_errors),$unsigned(m_tag));
                    received=received+1;
                    if(old_owner) aborted_records=aborted_records+1;else total_records=total_records+1;
                end
            end
        end
    end
    task read_case(input integer fd);
        integer result,i,j,value_tmp,marker0_tmp,marker1_tmp,marker2_tmp;
        begin
            result=$fscanf(fd,"%d %d %d %d %d %d %d %d %d",frame_id,fk,fiters,ftag,nout,ferrors,nstates,ntable,expected_tail);
            if(result!=9 || nout<1 || nout>N || nstates<0 || nstates>16*N || (ntable!=0 && ntable!=256)) $fatal(1,"fixture header");
            for(i=0;i<N;i=i+1) begin
                result=$fscanf(fd,"%d %d %d %d",pixels[i],marker0_tmp,marker1_tmp,marker2_tmp);
                if(result!=4) $fatal(1,"fixture input");
                markers[i][0]=marker0_tmp;markers[i][1]=marker1_tmp;markers[i][2]=marker2_tmp;
            end
            for(i=0;i<ntable;i=i+1) begin
                result=$fscanf(fd,"%d",value_tmp);if(result!=1) $fatal(1,"fixture coefficient");
                expected_coefficients[i]=value_tmp;
            end
            for(i=0;i<nstates;i=i+1) begin
                result=$fscanf(fd,"%d",value_tmp);if(result!=1) $fatal(1,"fixture snapshot");
                expected_states[i]=value_tmp;
            end
            for(i=0;i<nout;i=i+1) for(j=0;j<10;j=j+1) begin
                result=$fscanf(fd,"%d",value_tmp);if(result!=1) $fatal(1,"fixture tuple");
                expected_records[i][j]=value_tmp;
            end
            received=0;sent=0;write_seen=0;table_seen=0;iter_seen=0;table_sum=0;
            iteration_sum=0;iteration_min=65535;iteration_max=0;tail_seen=0;monitor_active=1;log_id=frame_id;
        end
    endtask
    task load_single(input string name);
        integer fd,count,result;
        begin
            fd=$fopen($sformatf("fixtures/%s/%s.txt",profile,name),"r");
            if(fd==0) $fatal(1,"missing fixed single fixture");
            result=$fscanf(fd,"%d",count);if(result!=1 || count!=1) $fatal(1,"single count");
            read_case(fd);$fclose(fd);
        end
    endtask
    task send_range(input integer first,input integer limit);
        integer i,done;
        begin
            for(i=first;i<limit;i=i+1) begin
                @(negedge clk);
                if(stall_mode && i%5==2) begin s_valid=0;repeat(2) @(negedge clk);end
                s_pixel=pixels[i];s_sof=markers[i][0];s_eol=markers[i][1];s_last=markers[i][2];
                s_k=(i==0)?fk:(fk^8'had);s_iterations=(i==0)?fiters:5'd31;
                s_tag=(i==0)?TAG_W'(ftag):~TAG_W'(ftag);s_valid=1;done=0;
                while(!done) begin @(posedge clk);if(s_ready) begin done=1;sent=sent+1;end #1;end
                @(negedge clk);s_valid=0;
            end
        end
    endtask
    task finish_frame;
        integer guard;
        begin
            guard=0;
            while(received<nout) begin @(negedge clk);guard=guard+1;if(guard>2000000) $fatal(1,"fixed frame watchdog");end
            if(write_seen!=nstates || table_seen!=ntable || iter_seen!=(ferrors?0:fiters) || !tail_seen) $fatal(1,"incomplete computation");
            $display("FRAME %s %0d %0d %0d %0d %0d",profile,log_id,received,ferrors,ftag,write_seen);
            monitor_active=0;
            repeat(3) begin @(negedge clk);if(m_valid) $fatal(1,"extra frame result");end
        end
    endtask
    function automatic integer predicate(input string name);
        begin
            if(name=="capture_prefix") predicate=(dut.state==dut.CAPTURE && dut.capture_index==1);
            else if(name=="table_divide") predicate=(dut.state==dut.DIV_WAIT && dut.table_index==1 && dut.u_divider.busy && dut.u_divider.step==7);
            else if(name=="flux_product") predicate=(dut.state==dut.FLUX_TAKE && dut.pixel_index==0 && dut.iteration==0 && dut.direction==3 && dut.product!=0);
            else if(name=="output_held") predicate=(m_valid && !m_ready && received==0 && m_keep);
            else predicate=0;
        end
    endfunction
    task reset_probe(input integer ordinal,input string name);
        integer guard,edge_number;
        begin
            old_owner=1;force_hold=1;load_single("reset_old");log_id=ordinal;
            if(name=="capture_prefix") send_range(0,1);else send_range(0,N);
            guard=0;
            while(!predicate(name)) begin @(negedge clk);guard=guard+1;if(guard>20000) $fatal(1,"fixed reset predicate absent");end
            $display("PROBE %s %0d %s %0d %0d %0d %0d %0d %0d %0d %0d %0d",profile,ordinal,name,
                sent,received,dut.state,dut.u_divider.busy,dut.u_divider.step,dut.pixel_index,dut.iteration,dut.direction,dut.source_bank);
            if(!predicate(name)) $fatal(1,"reset moved from predicate");
            rst=1;s_valid=1;s_pixel=211;s_k=0;s_iterations=31;s_sof=0;s_eol=0;s_last=0;s_tag=0;monitor_active=0;
            for(edge_number=0;edge_number<3;edge_number=edge_number+1) begin
                @(posedge clk);if(s_ready || m_valid || !s_valid) $fatal(1,"reset offer transferred");
                $display("RESETEDGE %s %0d %0d",profile,ordinal,edge_number);reset_edges=reset_edges+1;#1;
            end
            load_single("reset_fresh");log_id=ordinal;old_owner=0;
            @(negedge clk);rst=0;s_valid=0;force_hold=0;
            send_range(0,N);finish_frame;
        end
    endtask
    integer fd,count,result,i;
    initial begin
        if(!$value$plusargs("PROFILE=%s",profile) || !$value$plusargs("MODE=%s",mode)) $fatal(1,"fixed profile/mode required");
        result=$value$plusargs("STALL=%d",stall_mode);
        repeat(3) @(posedge clk);@(negedge clk);rst=0;
        if(mode=="main") begin
            fd=$fopen($sformatf("fixtures/%s/vectors.txt",profile),"r");if(fd==0) $fatal(1,"missing vectors");
            result=$fscanf(fd,"%d",count);if(result!=1 || count<1) $fatal(1,"main count");
            for(i=0;i<count;i=i+1) begin
                read_case(fd);old_owner=0;force_hold=0;send_range(0,N);finish_frame;frames=frames+1;
            end
            $fclose(fd);
            $display("PASS MAIN profile=%s stall=%0d frames=%0d records=%0d writes=%0d iterations=%0d tables=%0d",profile,stall_mode,frames,total_records,total_writes,total_iterations,total_tables);
        end else if(mode=="reset" && profile=="p3") begin
            reset_probe(0,"capture_prefix");reset_probe(1,"table_divide");reset_probe(2,"flux_product");reset_probe(3,"output_held");
            $display("PASS RESET profile=%s probes=4 fresh_records=%0d fresh_writes=%0d old_writes=%0d aborted_records=%0d reset_edges=%0d",profile,total_records,total_writes,old_writes,aborted_records,reset_edges);
        end else $fatal(1,"unknown fixed mode/profile");
        $finish;
    end
endmodule
