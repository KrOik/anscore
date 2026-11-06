`timescale 1ns/1ps
module tb_codebook;
    parameter MC=3, MD=5, TW=8, WRAPPER=0;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg cfg_valid=0, cfg_first=0, cfg_rsp_ready=0;
    reg [6:0] cfg_code=0; reg [8:0] cfg_dim=0;
    reg signed [7:0] cfg_value=0;
    wire cfg_ready, cfg_rsp_valid; wire [1:0] cfg_status;
    wire [6:0] cfg_rsp_code; wire [8:0] cfg_rsp_dim;
    reg c_valid=0; wire c_ready;
    reg [6:0] c_codes=0; reg [8:0] c_dims=0;
    reg [TW-1:0] c_tag=0; reg [3:0] c_shift=0;
    reg s_valid=0; wire s_ready; reg signed [7:0] s_value=0;
    wire m_valid; reg m_ready=0; wire [1:0] m_error;
    wire [5:0] m_code; wire [23:0] m_distance,m_margin;
    wire m_second_valid; wire [TW-1:0] m_tag;
    wire out_valid; reg out_ready=0;
    wire signed [7:0] out_value,out_original;
    wire signed [8:0] out_residual;
    wire [7:0] out_dim; wire out_last,out_clip,out_inexact;
    wire [TW-1:0] out_tag;
    generate if(WRAPPER) begin: encoded
        codebook_residual_encode #(.MAX_CODES(MC),.MAX_DIMS(MD),.TAG_W(TW)) dut(
            .clk(clk),.rst(rst),.cfg_valid(cfg_valid),.cfg_ready(cfg_ready),
            .cfg_code(cfg_code),.cfg_dim(cfg_dim),.cfg_first(cfg_first),.cfg_value(cfg_value),
            .cfg_rsp_valid(cfg_rsp_valid),.cfg_rsp_ready(cfg_rsp_ready),.cfg_status(cfg_status),
            .cfg_rsp_code(cfg_rsp_code),.cfg_rsp_dim(cfg_rsp_dim),
            .c_valid(c_valid),.c_ready(c_ready),.c_codes(c_codes),.c_dims(c_dims),
            .c_tag(c_tag),.c_residual_shift(c_shift),.s_valid(s_valid),.s_ready(s_ready),.s_value(s_value),
            .m_valid(m_valid),.m_ready(m_ready),.m_error(m_error),.m_code(m_code),
            .m_distance(m_distance),.m_margin(m_margin),.m_second_valid(m_second_valid),.m_tag(m_tag),
            .e_valid(out_valid),.e_ready(out_ready),.e_value(out_value),.e_clip(out_clip),
            .e_inexact(out_inexact),.e_dim(out_dim),.e_last(out_last),.e_tag(out_tag)
        );
        assign out_original=0; assign out_residual=0;
    end else begin: exact
        signed8_codebook_search #(.MAX_CODES(MC),.MAX_DIMS(MD),.TAG_W(TW)) dut(
            .clk(clk),.rst(rst),.cfg_valid(cfg_valid),.cfg_ready(cfg_ready),
            .cfg_code(cfg_code),.cfg_dim(cfg_dim),.cfg_first(cfg_first),.cfg_value(cfg_value),
            .cfg_rsp_valid(cfg_rsp_valid),.cfg_rsp_ready(cfg_rsp_ready),.cfg_status(cfg_status),
            .cfg_rsp_code(cfg_rsp_code),.cfg_rsp_dim(cfg_rsp_dim),
            .c_valid(c_valid),.c_ready(c_ready),.c_codes(c_codes),.c_dims(c_dims),.c_tag(c_tag),
            .s_valid(s_valid),.s_ready(s_ready),.s_value(s_value),
            .m_valid(m_valid),.m_ready(m_ready),.m_error(m_error),.m_code(m_code),
            .m_distance(m_distance),.m_margin(m_margin),.m_second_valid(m_second_valid),.m_tag(m_tag),
            .r_valid(out_valid),.r_ready(out_ready),.r_dim(out_dim),.r_value(out_value),
            .r_original(out_original),.r_residual(out_residual),.r_last(out_last),.r_tag(out_tag)
        );
        assign out_clip=0; assign out_inexact=0;
    end endgenerate

    integer cycle_count=0,queries=0,configs=0,replays=0,held_cycles=0,resets=0;
    always @(posedge clk) begin
        cycle_count=cycle_count+1;
        if(cycle_count>1500000) $fatal(1,"Bounded HDL watchdog");
    end
    integer original[0:MD-1],centroid[0:MD-1],residual[0:MD-1];
    integer encoded_value[0:MD-1],clip[0:MD-1],inexact[0:MD-1];
    reg [TW+56:0] held_summary;
    reg [TW+35:0] held_output;
    reg [17:0] held_cfg;

    task reset_now;
        begin
            @(negedge clk); rst=1;
            cfg_valid=0; c_valid=0; s_valid=0;
            cfg_rsp_ready=0; m_ready=0; out_ready=0;
            repeat(2) @(posedge clk);
            @(negedge clk);
            if(cfg_ready || cfg_rsp_valid || c_ready || s_ready || m_valid || out_valid)
                $fatal(1,"Public reset qualification");
            rst=0; resets=resets+1;
            @(negedge clk);
            if(cfg_rsp_valid || s_ready || m_valid || out_valid) $fatal(1,"Stale output after reset");
        end
    endtask

    task configure;
        input integer code,dim,first,value,status;
        begin
            @(negedge clk);
            cfg_valid=1; cfg_code=code; cfg_dim=dim; cfg_first=first; cfg_value=value;
            do @(posedge clk); while(!cfg_ready);
            @(negedge clk); cfg_valid=0; cfg_code=127; cfg_dim=511; cfg_first=0; cfg_value=17;
            while(!cfg_rsp_valid) @(negedge clk);
            if(cfg_status!==status || cfg_rsp_code!==code || cfg_rsp_dim!==dim)
                $fatal(1,"Config reply code=%0d dim=%0d got=%0d expected=%0d",code,dim,cfg_status,status);
            held_cfg={cfg_status,cfg_rsp_code,cfg_rsp_dim};
            repeat(2) begin
                @(negedge clk); held_cycles=held_cycles+1;
                if(!cfg_rsp_valid || {cfg_status,cfg_rsp_code,cfg_rsp_dim}!==held_cfg || c_ready || cfg_ready)
                    $fatal(1,"Held configuration reply");
            end
            cfg_rsp_ready=1; @(posedge clk); @(negedge clk); cfg_rsp_ready=0;
            configs=configs+1;
        end
    endtask

    task command;
        input integer count,size,tag,shift;
        begin
            @(negedge clk); c_valid=1; c_codes=count; c_dims=size; c_tag=tag; c_shift=shift;
            do @(posedge clk); while(!c_ready);
            @(negedge clk); c_valid=0; c_codes=0; c_dims=0; c_tag=~tag; c_shift=15;
        end
    endtask

    task sample;
        input integer value;
        begin
            @(negedge clk); s_valid=1; s_value=value;
            do @(posedge clk); while(!s_ready);
            @(negedge clk); s_valid=0; s_value=42;
        end
    endtask

    task run_query;
        input integer count,size,tag,shift,error,winner,distance,margin,second;
        integer j;
        begin
            command(count,size,tag,shift);
            if(error==0) begin
                for(j=0;j<size;j=j+1) begin
                    repeat(j%3) @(negedge clk);
                    sample(original[j]);
                end
            end
            while(!m_valid) @(negedge clk);
            if(m_error!==error || m_code!==winner || m_distance!==distance ||
               m_margin!==margin || m_second_valid!==second || m_tag!==tag[TW-1:0])
                $fatal(1,"Summary query=%0d got=%0d/%0d/%0d/%0d/%0d expected=%0d/%0d/%0d/%0d/%0d",
                    queries,m_error,m_code,m_distance,m_margin,m_second_valid,error,winner,distance,margin,second);
            held_summary={m_error,m_code,m_distance,m_margin,m_second_valid,m_tag};
            repeat(5) begin
                @(negedge clk); held_cycles=held_cycles+1;
                if(!m_valid || {m_error,m_code,m_distance,m_margin,m_second_valid,m_tag}!==held_summary ||
                    s_ready || c_ready || cfg_ready || out_valid) $fatal(1,"Held summary or premature replay");
            end
            m_ready=1; @(posedge clk); @(negedge clk); m_ready=0;
            if(error==0) begin
                for(j=0;j<size;j=j+1) begin
                    while(!out_valid) @(negedge clk);
                    if(out_dim!==j || out_last!==(j==size-1) || out_tag!==tag[TW-1:0])
                        $fatal(1,"Replay metadata dimension=%0d",j);
                    if(WRAPPER) begin
                        if($signed(out_value)!==encoded_value[j] || out_clip!==clip[j] || out_inexact!==inexact[j])
                            $fatal(1,"Encoded residual dimension=%0d",j);
                    end else if($signed(out_value)!==centroid[j] || $signed(out_original)!==original[j] ||
                                $signed(out_residual)!==residual[j]) $fatal(1,"Exact replay dimension=%0d",j);
                    held_output={out_value,out_original,out_residual,out_dim,out_last,out_clip,out_inexact,out_tag};
                    repeat(2+j%3) begin
                        @(negedge clk); held_cycles=held_cycles+1;
                        if(!out_valid || {out_value,out_original,out_residual,out_dim,out_last,out_clip,out_inexact,out_tag}!==held_output)
                            $fatal(1,"Held replay changed");
                    end
                    out_ready=1; @(posedge clk); @(negedge clk); out_ready=0;
                    replays=replays+1;
                end
            end else if(out_valid) $fatal(1,"Error emitted payload");
            queries=queries+1;
        end
    endtask

    task reset_trial;
        input integer phase;
        begin
            reset_now(); configure(0,0,1,0,0);
            if(phase==0) begin
                // Keep the unaccepted command valid until reset cancels it.
                @(negedge clk); cfg_valid=1; cfg_code=0; cfg_dim=0; cfg_first=1; cfg_value=1;
                c_valid=1; c_codes=1; c_dims=1; c_tag=8'hA5;
                @(posedge clk);
                if(!cfg_ready || c_ready) $fatal(1,"Configuration priority");
                @(negedge clk); cfg_valid=0;
                while(!cfg_rsp_valid) @(negedge clk);
                if(c_ready || m_valid) $fatal(1,"Command accepted during config reply");
            end else begin
                command(1,1,8'hA5,0);
                if(phase==1) begin
                    while(!s_ready) @(negedge clk);
                    repeat(3) @(negedge clk);
                end else begin
                    sample(7);
                    if(phase==2) repeat(2) @(negedge clk);
                    else begin
                        while(!m_valid) @(negedge clk);
                        if(phase==4) begin
                            m_ready=1; @(posedge clk); @(negedge clk); m_ready=0;
                            while(!out_valid) @(negedge clk);
                        end
                    end
                end
            end
            reset_now();
            run_query(1,1,8'hB6,0,2,0,0,0,0);
            configure(0,0,1,3,0);
            original[0]=7; centroid[0]=3; residual[0]=4;
            encoded_value[0]=4; clip[0]=0; inexact[0]=0;
            run_query(1,1,8'hC7,0,0,0,16,0,0);
        end
    endtask

    task encoded_overlap;
        begin
            reset_now(); configure(0,0,1,0,0);
            command(1,1,8'h11,1); sample(127);
            while(!m_valid) @(negedge clk);
            if(m_error!==0 || m_code!==0 || m_distance!==16129 || m_margin!==0 ||
               m_second_valid!==0 || m_tag!==8'h11) $fatal(1,"First overlap summary");
            m_ready=1; @(posedge clk); @(negedge clk); m_ready=0;
            while(!out_valid) @(negedge clk);
            if(!c_ready) $fatal(1,"Wrapper did not free completed core query");
            held_output={out_value,out_original,out_residual,out_dim,out_last,out_clip,out_inexact,out_tag};
            command(1,1,8'h22,0); sample(1);
            while(!m_valid) @(negedge clk);
            if(m_error!==0 || m_code!==0 || m_distance!==1 || m_margin!==0 ||
               m_second_valid!==0 || m_tag!==8'h22) $fatal(1,"Second overlap summary");
            if(!out_valid || {out_value,out_original,out_residual,out_dim,out_last,out_clip,out_inexact,out_tag}!==held_output)
                $fatal(1,"Old encoded payload changed while new query computed");
            m_ready=1; @(posedge clk); @(negedge clk); m_ready=0;
            if($signed(out_value)!==64 || out_tag!==8'h11 || out_dim!==0 ||
               !out_last || out_clip || !out_inexact) $fatal(1,"Old shift/tag in overlap");
            out_ready=1; @(posedge clk); @(negedge clk); out_ready=0;
            while(!out_valid) @(negedge clk);
            if($signed(out_value)!==1 || out_tag!==8'h22 || out_dim!==0 ||
               !out_last || out_clip || out_inexact) $fatal(1,"New shift/tag in overlap");
            out_ready=1; @(posedge clk); @(negedge clk); out_ready=0;
            queries=queries+2; replays=replays+2;
        end
    endtask

    integer fd,rc,finished=0,j;
    integer a,b,c,d,e,f,g,h,k;
    integer v0,v1,v2,v3,v4,v5;
    reg [31:0] token;
    reg [2047:0] vector_path;
    initial begin
        if(!$value$plusargs("VECTORS=%s",vector_path)) $fatal(1,"Missing exact vector path");
        fd=$fopen(vector_path,"r"); if(fd==0) $fatal(1,"Vector open");
        while(!finished) begin
            rc=$fscanf(fd,"%s",token); if(rc!=1) $fatal(1,"Missing vector terminator");
            case(token)
                "R": reset_now();
                "C": begin
                    rc=$fscanf(fd,"%d %d %d %d %d",a,b,c,d,e);
                    if(rc!=5) $fatal(1,"Config vector parse");
                    configure(a,b,c,d,e);
                end
                "Q": begin
                    rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d",a,b,c,d,e,f,g,h,k);
                    if(rc!=9) $fatal(1,"Query vector parse");
                    if(e==0) begin
                        if(b<1 || b>MD) $fatal(1,"Golden dimension bound");
                        for(j=0;j<b;j=j+1) begin
                            rc=$fscanf(fd,"%s %d %d %d %d %d %d",token,v0,v1,v2,v3,v4,v5);
                            if(rc!=7 || token!="D") $fatal(1,"Replay vector parse");
                            original[j]=v0; centroid[j]=v1; residual[j]=v2;
                            encoded_value[j]=v3; clip[j]=v4; inexact[j]=v5;
                        end
                    end
                    run_query(a,b,c,d,e,f,g,h,k);
                end
                "E": finished=1;
                default: $fatal(1,"Unknown vector token");
            endcase
        end
        rc=$fscanf(fd,"%s",token);
        if(rc==1 || !$feof(fd)) $fatal(1,"Trailing vector token");
        $fclose(fd);
        for(j=0;j<5;j=j+1) reset_trial(j);
        if(WRAPPER) encoded_overlap();
        $display("CODEBOOK_PASS codes=%0d dims=%0d wrapper=%0d queries=%0d configs=%0d replays=%0d holds=%0d resets=%0d cycles=%0d",
            MC,MD,WRAPPER,queries,configs,replays,held_cycles,resets,cycle_count);
        $finish;
    end
endmodule
