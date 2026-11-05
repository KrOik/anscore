// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_canonical_huffman_encoder;
    parameter integer SYMBOLS=19, MAX_BITS=8, MAX_FRAME=31;
    reg clk=0; always #5 clk=~clk;
    reg rst=1,cfg_valid=0,cfg_r_ready=0,c_valid=0,s_valid=0,m_ready=0,d_ready=0;
    reg [1:0] cfg_op=0;
    reg [31:0] cfg_symbol=0,cfg_length=0,c_count=0,s_symbol=0;
    reg [7:0] cfg_tag=0,c_tag=0;
    wire cfg_ready,cfg_r_valid,c_ready,s_ready,m_valid,m_last,d_valid;
    wire [1:0] cfg_r_op;
    wire [2:0] cfg_r_status,d_status;
    wire [MAX_BITS-1:0] cfg_r_code;
    wire [31:0] cfg_r_length,d_error_index,d_bits;
    wire [7:0] cfg_r_tag,m_data,m_tag,d_tag;
    wire [3:0] m_valid_bits;
    canonical_huffman_encoder #(.SYMBOLS(SYMBOLS),.MAX_BITS(MAX_BITS),.MAX_FRAME(MAX_FRAME)) dut(.*);
    integer fd,rc,kind,a,b,c,d,e,f,g,h,k,j,cycles;
    integer frames=0,bytes_checked=0,stalls=0,configs=0;
    reg [1023:0] vector_file;
    reg [31:0] input_symbols[0:MAX_FRAME-1];
    integer expected_bytes[0:MAX_FRAME*MAX_BITS/8+1];
    integer expected_bits[0:MAX_FRAME*MAX_BITS/8+1];
    task config_op(input integer op,input [31:0] sym,len,input integer tag,status,code,bits);
        begin
            @(negedge clk); cfg_valid=1; cfg_op=op; cfg_symbol=sym; cfg_length=len; cfg_tag=tag;
            cycles=0;
            while(!cfg_ready) begin
                @(negedge clk); cycles=cycles+1;
                if(cycles>30000) $fatal(1,"cfg ready timeout");
            end
            if(c_ready) $fatal(1,"configuration did not have priority");
            @(posedge clk); @(negedge clk); cfg_valid=0;
            cycles=0;
            while(!cfg_r_valid) begin
                @(negedge clk); cycles=cycles+1;
                if(cycles>30000) $fatal(1,"cfg response timeout");
            end
            for(j=0;j<3;j=j+1) begin
                if(!cfg_r_valid || cfg_r_op!==op[1:0] || cfg_r_status!==status[2:0] ||
                   cfg_r_code!==code[MAX_BITS-1:0] || cfg_r_length!==bits || cfg_r_tag!==tag[7:0] || c_ready || s_ready)
                    $fatal(1,"cfg payload/stall mismatch op%0d status%0d",op,cfg_r_status);
                @(negedge clk); stalls=stalls+1;
            end
            cfg_r_ready=1; @(posedge clk); @(negedge clk); cfg_r_ready=0; configs=configs+1;
        end
    endtask
    task start_frame(input [31:0] count,input integer tag);
        begin
            @(negedge clk); c_valid=1; c_count=count; c_tag=tag; cycles=0;
            while(!c_ready) begin
                @(negedge clk); cycles=cycles+1;
                if(cycles>30000) $fatal(1,"frame ready timeout");
            end
            @(posedge clk); @(negedge clk); c_valid=0;
        end
    endtask
    task send_symbol(input [31:0] symbol);
        begin
            @(negedge clk); s_valid=1; s_symbol=symbol; cycles=0;
            while(!s_ready) begin
                @(negedge clk); cycles=cycles+1;
                if(cycles>30000) $fatal(1,"input ready timeout");
            end
            if(m_valid || d_valid) $fatal(1,"frame exposed output before full input validation");
            @(posedge clk); @(negedge clk); s_valid=0;
        end
    endtask
    task reset_service;
        begin
            @(negedge clk); rst=1; c_valid=0; cfg_valid=0; s_valid=0;
            m_ready=0; d_ready=0; cfg_r_ready=0;
            @(posedge clk); @(negedge clk); rst=0;
            repeat(SYMBOLS+2) @(negedge clk);
            if(m_valid || d_valid || cfg_r_valid || !c_ready) $fatal(1,"reset did not cancel ownership");
        end
    endtask
    task install_single;
        begin
            config_op(0,0,1,200,0,0,0);
            config_op(1,0,0,201,0,0,0);
        end
    endtask
    initial begin
        if(!$value$plusargs("vectors=%s",vector_file)) $fatal(1,"missing vectors");
        repeat(2) @(negedge clk); rst=0;
        fd=$fopen(vector_file,"r"); if(!fd) $fatal(1,"missing vector file");
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d\n",kind,a,b,c,d,e,f,g,h);
            if(rc!=9) $fatal(1,"malformed vector header");
            if(kind==0) config_op(a,b,c,d,e,f,g);
            else if(kind==1) begin
                for(k=0;k<f;k=k+1) begin
                    rc=$fscanf(fd,"%d\n",input_symbols[k]);
                    if(rc!=1) $fatal(1,"bad symbol vector");
                end
                for(k=0;k<g;k=k+1) begin
                    rc=$fscanf(fd,"%d %d\n",expected_bytes[k],expected_bits[k]);
                    if(rc!=2) $fatal(1,"bad byte vector");
                end
                start_frame(a,b);
                for(k=0;k<f;k=k+1) begin
                    repeat(k%3) @(negedge clk);
                    send_symbol(input_symbols[k]);
                end
                // Hold a conflicting configuration request through frame drain.
                cfg_valid=1; cfg_op=3; cfg_symbol=0; cfg_length=0;
                for(k=0;k<g;k=k+1) begin
                    cycles=0;
                    while(!m_valid) begin
                        if(d_valid) $fatal(1,"completion preceded expected bytes");
                        @(negedge clk); cycles=cycles+1;
                        if(cycles>30000) $fatal(1,"byte wait timeout");
                    end
                    for(j=0;j<2+(k%3);j=j+1) begin
                        if(!m_valid || m_data!==expected_bytes[k][7:0] || m_valid_bits!==expected_bits[k][3:0] ||
                           m_last!==(k==g-1) || m_tag!==b[7:0] || cfg_ready || c_ready || s_ready || d_valid)
                            $fatal(1,"frame%0d byte%0d got%0d/%0d expected%0d/%0d",frames,k,m_data,m_valid_bits,expected_bytes[k],expected_bits[k]);
                        @(negedge clk); stalls=stalls+1;
                    end
                    m_ready=1; @(posedge clk); @(negedge clk); m_ready=0; bytes_checked=bytes_checked+1;
                end
                cycles=0;
                while(!d_valid) begin
                    if(m_valid) $fatal(1,"unexpected error-frame or extra byte");
                    @(negedge clk); cycles=cycles+1;
                    if(cycles>30000) $fatal(1,"completion timeout");
                end
                for(j=0;j<3;j=j+1) begin
                    if(!d_valid || d_status!==c[2:0] || d_error_index!==d || d_bits!==e || d_tag!==b[7:0] ||
                       m_valid || cfg_ready || c_ready || s_ready)
                        $fatal(1,"completion mismatch frame%0d status%0d bits%0d index%0d expected%0d/%0d/%0d",frames,d_status,d_bits,d_error_index,c,e,d);
                    @(negedge clk); stalls=stalls+1;
                end
                cfg_valid=0; d_ready=1; @(posedge clk); @(negedge clk); d_ready=0; frames=frames+1;
            end else $fatal(1,"unknown vector kind");
        end
        $fclose(fd);
        // Four independently reset ownership phases; reset clears the table too.
        reset_service(); install_single(); start_frame(1,210); reset_service();
        config_op(2,0,0,211,4,0,0);
        install_single(); start_frame(1,212); send_symbol(0); reset_service();
        config_op(2,0,0,213,4,0,0);
        install_single(); start_frame(1,214); send_symbol(0);
        while(!m_valid) @(negedge clk);
        reset_service(); config_op(2,0,0,215,4,0,0);
        start_frame(0,216); if(!d_valid) $fatal(1,"empty frame must complete");
        reset_service(); config_op(2,0,0,217,4,0,0);
        $display("PASS canonical_huffman_encoder S=%0d B=%0d F=%0d frames=%0d bytes=%0d configs=%0d stalls=%0d reset_phases=4",SYMBOLS,MAX_BITS,MAX_FRAME,frames,bytes_checked,configs,stalls);
        $finish;
    end
    initial begin #200000000; $fatal(1,"global TB watchdog"); end
endmodule
