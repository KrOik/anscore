`timescale 1ns/1ps
`default_nettype none
module tb_soupbintcp_session_rx;
    parameter integer D=128, T=8;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, s_valid=0, m_ready=0, r_ready=0;
    reg [7:0] s_data=0;
    reg [T-1:0] s_tag=0;
    wire s_ready,m_valid,m_last,r_valid;
    wire [7:0] m_data,r_type,r_reason;
    wire [2:0] r_status;
    wire [15:0] r_length,r_payload_bytes;
    wire [63:0] m_sequence,r_sequence,r_next;
    wire [79:0] m_session,r_session;
    wire [T-1:0] m_tag,r_tag;
    wire r_logged,r_closed,r_faulted,r_exhausted;
    soupbintcp_session_rx #(.FIFO_DEPTH(D),.TAG_W(T)) dut(
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_tag(s_tag),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_last(m_last),
        .m_sequence(m_sequence),.m_session(m_session),.m_tag(m_tag),
        .r_valid(r_valid),.r_ready(r_ready),.r_status(r_status),.r_type(r_type),.r_reason(r_reason),
        .r_length(r_length),.r_payload_bytes(r_payload_bytes),.r_sequence(r_sequence),
        .r_next(r_next),.r_session(r_session),.r_tag(r_tag),.r_logged(r_logged),
        .r_closed(r_closed),.r_faulted(r_faulted),.r_exhausted(r_exhausted)
    );
    reg [7:0] bytes_in[0:65536], golden[0:65535];
    integer reset_first,nwire,estatus,etype,elen,elogged,eclosed,efault,eexhausted;
    integer ereason,nout,future,fd,scan,i,j,k,waited;
    reg [63:0] eseq,enext;
    reg [79:0] esession;
    reg [T-1:0] etag;
    integer cases=0,wire_bytes=0,payload_bytes=0,futures=0,vector_resets=0;
    integer resets=0,cancelled=0,recoveries=0,checks=0,holds=0;
    reg [4095:0] vector_path;
    reg [383:0] held;
    reg [T-1:0] future_tag;

    task reset_connection;
        begin
            @(negedge clk); rst=1; s_valid=0; m_ready=0; r_ready=0;
            #1; if (s_ready || m_valid || r_valid) $fatal(1,"reset visibility");
            repeat(3) @(posedge clk);
            @(negedge clk); rst=0;
            resets=resets+1;
        end
    endtask

    task send_vector;
        integer n,w;
        begin
            n=0;w=0;
            @(negedge clk);s_valid=1;s_data=bytes_in[0];s_tag=etag;
            while(n<nwire) begin
                @(posedge clk);
                if(m_valid) $fatal(1,"payload before final input transfer");
                w=w+1;if(w>100) $fatal(1,"vector input timeout");
                if(s_ready) begin
                    n=n+1;w=0;wire_bytes=wire_bytes+1;
                    @(negedge clk);
                    if(n==nwire) s_valid=0;
                    else begin
                        if(cases%3!=0 && n%5==2) begin
                            s_valid=0;repeat(2) @(posedge clk);@(negedge clk);
                        end
                        s_valid=1;s_data=bytes_in[n];s_tag=~etag;
                    end
                end
            end
        end
    endtask

    task send_byte(input [7:0] value,input [T-1:0] tag_value,input integer precommit);
        integer w;
        begin
            @(negedge clk); s_valid=1; s_data=value; s_tag=tag_value;
            w=0;
            begin : admission
                forever begin
                    @(posedge clk);
                    if (precommit && m_valid) $fatal(1,"payload before complete frame");
                    w=w+1; if(w>100) $fatal(1,"input admission timeout");
                    if(s_ready) disable admission;
                end
            end
            wire_bytes=wire_bytes+1;
            @(negedge clk); s_valid=0;
        end
    endtask

    task check_response;
        integer w,h;
        reg [383:0] observed;
        begin
            w=0;
            while(!r_valid) begin
                @(negedge clk);
                if(m_valid) $fatal(1,"extra payload");
                w=w+1; if(w>D+100) $fatal(1,"completion timeout");
            end
            if(r_status!==estatus[2:0] || r_type!==etype[7:0] || r_reason!==ereason[7:0] ||
               r_length!==elen[15:0] || r_payload_bytes!==(elen==0?16'd0:elen-1) ||
               r_sequence!==eseq || r_next!==enext || r_session!==esession || r_tag!==etag ||
               r_logged!==elogged[0] || r_closed!==eclosed[0] || r_faulted!==efault[0] ||
               r_exhausted!==eexhausted[0])
                $fatal(1,"response case=%0d type=%h status=%0d next=%h session=%h",cases,r_type,r_status,r_next,r_session);
            held={r_status,r_type,r_reason,r_length,r_payload_bytes,r_sequence,r_next,r_session,r_tag,
                  r_logged,r_closed,r_faulted,r_exhausted};
            for(h=0;h<6;h=h+1) begin
                @(posedge clk);
                observed={r_status,r_type,r_reason,r_length,r_payload_bytes,r_sequence,r_next,r_session,r_tag,
                          r_logged,r_closed,r_faulted,r_exhausted};
                if(!r_valid || s_ready || m_valid || observed!==held) $fatal(1,"held completion");
                holds=holds+1;
            end
            @(negedge clk); r_ready=1;
            @(posedge clk); if(!r_valid || s_ready) $fatal(1,"owner retirement fence");
            @(negedge clk); r_ready=0;
            checks=checks+1;
        end
    endtask

    task drain_payload;
        integer p,h,w;
        reg [7:0] held_byte;
        begin
            for(p=0;p<nout;p=p+1) begin
                w=0;
                while(!m_valid) begin
                    @(negedge clk);
                    if(r_valid) $fatal(1,"completion before payload");
                    w=w+1;if(w>100) $fatal(1,"payload timeout");
                end
                held_byte=m_data;
                for(h=0;h<3;h=h+1) begin
                    @(posedge clk);
                    if(!m_valid || m_data!==held_byte || m_data!==golden[p] ||
                       m_sequence!==eseq || m_session!==esession || m_tag!==etag ||
                       m_last!==(p==nout-1) || r_valid || s_ready) $fatal(1,"held payload");
                    holds=holds+1;
                end
                @(negedge clk); m_ready=1;
                @(posedge clk);
                if(!m_valid || m_data!==golden[p] || m_last!==(p==nout-1)) $fatal(1,"payload transfer");
                payload_bytes=payload_bytes+1;
                @(negedge clk); m_ready=0;
            end
        end
    endtask

    task login_one;
        integer b;
        reg [79:0] session;
        begin
            session=80'h202053455353494f4e31;
            send_byte(0,1,1);send_byte(31,7,1);send_byte(8'h41,3,1);
            for(b=0;b<10;b=b+1) send_byte(session[79-b*8 -: 8],5,1);
            for(b=0;b<19;b=b+1) send_byte(8'h20,6,1);
            send_byte(8'h31,7,1);
            estatus=0;etype=65;ereason=0;elen=31;eseq=0;enext=1;esession=session;
            elogged=1;eclosed=0;efault=0;eexhausted=0;etag=1;
            check_response();
        end
    endtask

    initial begin
        if(!$value$plusargs("vectors=%s",vector_path)) $fatal(1,"missing vectors");
        fd=$fopen(vector_path,"r"); if(!fd) $fatal(1,"vector open");
        reset_connection();
        while(!$feof(fd)) begin
            scan=$fscanf(fd,"%d %d %d %h %d %h %h %h %d %d %d %d %h %h %d %d\n",
                reset_first,nwire,estatus,etype,elen,eseq,enext,esession,elogged,eclosed,
                efault,eexhausted,etag,ereason,nout,future);
            if(scan==-1) begin end
            else begin
                if(scan!=16 || nwire<2 || nwire>65537 || nout>D-1) $fatal(1,"vector header");
                for(i=0;i<nwire;i=i+1) begin
                    scan=$fscanf(fd,"%h\n",bytes_in[i]);if(scan!=1) $fatal(1,"wire vector");
                end
                for(i=0;i<nout;i=i+1) begin
                    scan=$fscanf(fd,"%h\n",golden[i]);if(scan!=1) $fatal(1,"golden vector");
                end
                if(reset_first) begin reset_connection();vector_resets=vector_resets+1;end
                send_vector();
                if(future) begin
                    future_tag=etag+1'b1;
                    @(negedge clk);s_valid=1;s_data=0;s_tag=future_tag;
                end
                drain_payload();
                check_response();
                if(future) begin
                    // Keep the live future offer asserted through actual admission.
                    waited=0;
                    begin : future_admission
                        forever begin
                            @(posedge clk); waited=waited+1;
                            if(waited>20) $fatal(1,"future admission timeout");
                            if(s_ready) disable future_admission;
                        end
                    end
                    futures=futures+1;wire_bytes=wire_bytes+1;
                    @(negedge clk);s_valid=0;
                    send_byte(1,~future_tag,1);send_byte(8'h48,~future_tag,1);
                    estatus=0;etype=72;ereason=0;elen=1;eseq=0;etag=future_tag;
                    check_response();
                end
                cases=cases+1;
            end
        end
        $fclose(fd);
        // Four live cancellation phases each followed by a fresh real login.
        for(k=0;k<4;k=k+1) begin
            reset_connection();
            if(k==0) send_byte(0,1,1);
            else if(k==1) begin send_byte(0,1,1);send_byte(31,1,1);send_byte(65,1,1);send_byte(32,1,1);end
            else begin
                login_one();
                if(k==2) begin
                    send_byte(0,1,1);send_byte(3,1,1);send_byte(83,1,1);
                    send_byte(8'hab,1,1);send_byte(8'hcd,1,1);
                    waited=0;
                    while(!m_valid) begin @(negedge clk);waited=waited+1;if(waited>30)$fatal(1,"reset payload setup");end
                end else begin
                    send_byte(0,1,1);send_byte(1,1,1);send_byte(72,1,1);
                    waited=0;
                    while(!r_valid) begin @(negedge clk);waited=waited+1;if(waited>50)$fatal(1,"reset response setup");end
                end
            end
            cancelled=cancelled+1;
            reset_connection();
            repeat(8) begin @(posedge clk);if(m_valid||r_valid)$fatal(1,"reset leaked owner");end
            login_one();recoveries=recoveries+1;
        end
        $display("B45_A_SOUP_PASS D=%0d T=%0d cases=%0d checks=%0d bytes=%0d payload=%0d future=%0d vector_resets=%0d resets=%0d cancelled=%0d recoveries=%0d holds=%0d",
            D,T,cases,checks,wire_bytes,payload_bytes,futures,vector_resets,resets,cancelled,recoveries,holds);
        $finish;
    end
    initial begin #200000000; $fatal(1,"global watchdog"); end
endmodule
`default_nettype wire
