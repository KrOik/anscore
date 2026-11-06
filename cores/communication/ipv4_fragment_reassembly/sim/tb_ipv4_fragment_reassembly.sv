`timescale 1ns/1ps
module tb_ipv4_fragment_reassembly;
    parameter integer N=37,T=8,EX=0;
    localparam CW=$clog2(N+1);
    reg clk=0; always #5 clk=~clk;
    reg rst=1,cv=0,sv=0,sl=0,dr=0,mr=0;
    reg [1:0] op;reg [31:0] src,dst;reg [15:0] ident,len;
    reg [7:0] protocol,sd;reg [12:0] off;reg more;
    reg [T-1:0] tag;reg [159:0] header;
    wire cr,sr,dv,dc,da,mv,ml;wire [3:0] ds;
    wire [CW-1:0] df,dt,mt;wire [T-1:0] dtag,mtag;
    wire [7:0] md,mp;wire [31:0] ms,mdst;wire [15:0] mi;
    generate if(EX==0) begin:g
        ipv4_fragment_reassembly #(.MAX_BYTES(N),.TAG_W(T)) dut(
            .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_op(op),.c_src(src),.c_dst(dst),
            .c_id(ident),.c_protocol(protocol),.c_offset8(off),.c_more(more),.c_length(len),.c_tag(tag),
            .s_valid(sv),.s_ready(sr),.s_data(sd),.s_last(sl),
            .d_valid(dv),.d_ready(dr),.d_status(ds),.d_complete(dc),.d_active(da),
            .d_filled(df),.d_total(dt),.d_tag(dtag),
            .m_valid(mv),.m_ready(mr),.m_data(md),.m_last(ml),.m_length(mt),
            .m_src(ms),.m_dst(mdst),.m_id(mi),.m_protocol(mp),.m_tag(mtag));
    end else begin:g
        ipv4_header_reassembly #(.MAX_BYTES(N),.TAG_W(T)) dut(
            .clk(clk),.rst(rst),.h_valid(cv),.h_ready(cr),.h_op(op),.h_header(header),.h_tag(tag),
            .s_valid(sv),.s_ready(sr),.s_data(sd),.s_last(sl),
            .d_valid(dv),.d_ready(dr),.d_status(ds),.d_complete(dc),.d_active(da),
            .d_filled(df),.d_total(dt),.d_tag(dtag),
            .m_valid(mv),.m_ready(mr),.m_data(md),.m_last(ml),.m_length(mt),
            .m_src(ms),.m_dst(mdst),.m_id(mi),.m_protocol(mp),.m_tag(mtag));
    end endgenerate
    integer cycles=0,holds=0,commands=0,inputs=0,replays=0,resets=0,future=0;
    always @(posedge clk) begin
        cycles<=cycles+1;
        if(cycles>180000)$fatal(1,"bounded TB deadline");
        if(rst && (cr || sr || dv || mv))$fatal(1,"reset gating");
    end
    task tick;begin @(posedge clk);#1;end endtask
    task reset_now;begin
        @(negedge clk);rst=1;tick();@(negedge clk);rst=0;cv=0;sv=0;dr=0;mr=0;
        resets=resets+1;tick();
    end endtask
    task submit;begin
        @(negedge clk);cv=1;
        begin:wait_c forever begin @(posedge clk);if(cr)disable wait_c;end end
        #1;commands=commands+1;@(negedge clk);cv=0;
    end endtask
    task byte_in(input integer value,input integer last);begin
        @(negedge clk);sd=value;sl=last;sv=1;
        begin:wait_s forever begin @(posedge clk);if(sr)disable wait_s;end end
        #1;inputs=inputs+1;@(negedge clk);sv=0;
    end endtask
    reg [3:0] saved_ds;reg saved_dc,saved_da;reg [CW-1:0] saved_df,saved_dt;reg[T-1:0] saved_tag;
    task check_response(input integer status,input integer complete,input integer active,
                        input integer filled,input integer total);integer k;begin
        while(!dv)tick();
        if(ds!==status || dc!==complete || da!==active || df!==filled || dt!==total || dtag!==tag)
            $fatal(1,"response cmd=%0d actual=%0d/%0d/%0d/%0d/%0d tag%0d expected=%0d/%0d/%0d/%0d/%0d tag%0d",
                commands,ds,dc,da,df,dt,dtag,status,complete,active,filled,total,tag);
        saved_ds=ds;saved_dc=dc;saved_da=da;saved_df=df;saved_dt=dt;saved_tag=dtag;
        for(k=0;k<3;k=k+1)begin tick();holds=holds+1;
            if(!dv || {ds,dc,da,df,dt,dtag}!={saved_ds,saved_dc,saved_da,saved_df,saved_dt,saved_tag})
                $fatal(1,"held response changed");
            if(cr || sr || mv)$fatal(1,"response ownership");
        end
        @(negedge clk);dr=1;tick();@(negedge clk);dr=0;
    end endtask
    reg [7:0] saved_md;reg saved_ml;reg [CW-1:0] saved_mt;
    task check_byte(input integer value,input integer last,input integer length);integer k;begin
        while(!mv)tick();
        if(md!==value || ml!==last || mt!==length || ms!==src || mdst!==dst || mi!==ident || mp!==protocol || mtag!==tag)
            $fatal(1,"replay cmd=%0d byte=%0d expected=%0d last=%0d/%0d",commands,md,value,ml,last);
        saved_md=md;saved_ml=ml;saved_mt=mt;
        for(k=0;k<3;k=k+1)begin tick();holds=holds+1;
            if(!mv || {md,ml,mt,ms,mdst,mi,mp,mtag}!=={saved_md,saved_ml,saved_mt,src,dst,ident,protocol,tag})
                $fatal(1,"held replay changed");
            if(cr || sr || dv)$fatal(1,"replay ownership");
        end
        @(negedge clk);mr=1;tick();replays=replays+1;@(negedge clk);mr=0;
    end endtask
    // Independent fixed20 header helper for directed protocol-reset tests.
    task fixed_header;reg [159:0] temp;reg[31:0] sum;reg[15:0] check;integer j;begin
        temp={8'h45,8'd0,(len+16'd20),ident,1'b0,1'b0,more,off,8'd64,protocol,16'd0,src,dst};
        sum=0;for(j=0;j<10;j=j+1)sum=sum+temp[j*16+:16];
        sum=(sum&65535)+(sum>>16);sum=(sum&65535)+(sum>>16);check=~sum[15:0];
        temp[79:64]=check;header=temp;
    end endtask
    task basic(input integer opcode,input integer size,input integer mf);begin
        op=opcode;src=32'hc0a80101;dst=32'hc0a80102;ident=16'h1234;protocol=17;
        off=0;more=mf;len=size;tag=7;fixed_header();submit();
    end endtask
    task recover;begin
        basic(2,1,0);check_response(0,0,0,0,0);
        basic(0,1,0);byte_in(90,1);check_response(0,1,1,1,1);check_byte(90,1,1);
    end endtask
    integer f,rc,kind,ns,nm,es,ec,ea,ef,et,i,k,bytevalue,lastvalue;
    integer vb[0:4095],vl[0:4095],expected[0:4095];reg[2047:0] vector_path;
    initial begin
        op=0;src=0;dst=0;ident=0;protocol=0;off=0;more=0;len=0;tag=0;header=0;sd=0;
        if(!$value$plusargs("vectors=%s",vector_path))$fatal(1,"missing vectors");
        f=$fopen(vector_path,"r");if(!f)$fatal(1,"open vectors");reset_now();
        while(!$feof(f))begin
            rc=$fscanf(f,"%d",kind);
            if(rc==1)begin
                if(kind==1)reset_now();
                else begin
                    rc=$fscanf(f,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %h",
                        op,src,dst,ident,protocol,off,more,len,tag,ns,es,ec,ea,ef,et,nm,header);
                    if(rc!=17)$fatal(1,"bad transaction %0d",rc);
                    for(i=0;i<ns;i=i+1)begin rc=$fscanf(f,"%d %d",vb[i],vl[i]);if(rc!=2)$fatal(1,"bad byte");end
                    for(i=0;i<nm;i=i+1)begin rc=$fscanf(f,"%d",expected[i]);if(rc!=1)$fatal(1,"bad expected");end
                    submit();for(i=0;i<ns;i=i+1)byte_in(vb[i],vl[i]);
                    check_response(es,ec,ea,ef,et);
                    for(i=0;i<nm;i=i+1)check_byte(expected[i],i==nm-1,nm);
                end
            end
        end
        $fclose(f);
        // Continuous valid beats exercise the one-byte-per-clock RAM path.
        if(N>=8)begin
            basic(0,8,0);while(!sr)tick();
            for(k=0;k<8;k=k+1)begin
                @(negedge clk);sv=1;sd=120+k;sl=k==7;
                @(posedge clk);if(!sr)$fatal(1,"payload II1 violated");#1;inputs=inputs+1;
            end
            @(negedge clk);sv=0;check_response(0,1,1,8,8);
            for(k=0;k<8;k=k+1)check_byte(120+k,k==7,8);
        end
        // A real future FLUSH is offered during held STATUS, then accepted.
        basic(2,1,0);while(!dv)tick();
        @(negedge clk);op=1;cv=1;
        for(k=0;k<4;k=k+1)begin tick();holds=holds+1;if(cr || !dv)$fatal(1,"future accepted while busy");end
        @(negedge clk);dr=1;tick();@(negedge clk);dr=0;
        begin:future_c forever begin @(posedge clk);if(cr)disable future_c;end end
        #1;commands=commands+1;future=future+1;@(negedge clk);cv=0;check_response(0,0,0,0,0);
        // Pending input and one committed byte are both cancelled by reset.
        basic(0,N>=8?8:1,N>=8);while(!sr)tick();reset_now();recover();
        if(N>=8)begin basic(0,8,1);byte_in(41,0);reset_now();recover();end
        // Held completion ACK, first replay, and final replay reset independently.
        basic(0,1,0);byte_in(77,1);while(!dv)tick();reset_now();recover();
        basic(0,1,0);byte_in(78,1);check_response(0,1,1,1,1);while(!mv)tick();reset_now();recover();
        if(N>=3)begin
            basic(0,3,0);byte_in(21,0);byte_in(22,0);byte_in(23,1);
            check_response(0,1,1,3,3);check_byte(21,0,3);check_byte(22,0,3);
            while(!mv)tick();reset_now();recover();
        end
        if(EX)begin basic(0,1,0);tick();reset_now();recover();end
        $display("PASS ipv4_fragment_reassembly N=%0d T=%0d EX=%0d commands=%0d inputs=%0d replays=%0d resets=%0d holds=%0d future=%0d cycles=%0d",
            N,T,EX,commands,inputs,replays,resets,holds,future,cycles);$finish;
    end
endmodule
