// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_recovering_itch_rx;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,cv=0,tv=0,sv=0,keep=1,last=0,mr=0,qr=0,rr=0;
    reg [79:0] session_id=80'h53455353494f4e303031;
    reg [63:0] cfg_next=100;reg [7:0] cfg_tag=1,retry_tag=2,stag=3,data=0;
    wire cr,tr,sr,mv,qv,ql,rv,busy,ml;
    wire [7:0] qdata,qtag,mt,mtag,rtag;
    wire [63:0] ms,mo,mnew,mstock,mmatch,rsession_seq,rnext,rn,rt,ru;
    wire [15:0] locate,tracking,messages,events;
    wire [47:0] timestamp;wire [31:0] qty,price,attr;
    wire sell,printable,pv,stockv,av,matchv;
    wire [1:0] kind;wire [3:0] status,recovery_status;
    wire [79:0] rsession;wire rend,outstanding,closed,requested;
    wire [518:0] event_value={mt,ms,locate,tracking,timestamp,mo,mnew,qty,price,mstock,attr,mmatch,
        sell,printable,pv,stockv,av,matchv,ml,mtag};
    wire [453:0] completion={kind,status,recovery_status,rsession,rsession_seq,messages,events,rnext,
        rend,rtag,rn,rt,ru,outstanding,closed,requested};
    reg [518:0] held_event;reg [453:0] held_completion;
    reg [159:0] frame,expected_frame;
    integer configs=0,packets=0,retries=0,requests=0,request_bytes=0,event_count=0,
        completions=0,holds=0,blocked=0,resets=0,i,j,watchdog=0;
    reg [287:0] add_body;
    recovering_itch_rx #(.REQUEST_MAX(3),.TAG_W(8)) dut(
        .clk(clk),.rst(rst),.cfg_valid(cv),.cfg_ready(cr),.cfg_session(session_id),.cfg_next(cfg_next),.cfg_tag(cfg_tag),
        .retry_valid(tv),.retry_ready(tr),.retry_tag(retry_tag),.s_valid(sv),.s_ready(sr),.s_data(data),.s_keep(keep),.s_last(last),.s_tag(stag),
        .m_valid(mv),.m_ready(mr),.m_type(mt),.m_sequence(ms),.m_locate(locate),.m_tracking(tracking),.m_timestamp(timestamp),
        .m_order(mo),.m_new_order(mnew),.m_quantity(qty),.m_price(price),.m_stock(mstock),.m_attribution(attr),.m_match(mmatch),
        .m_sell(sell),.m_printable(printable),.m_price_valid(pv),.m_stock_valid(stockv),.m_attribution_valid(av),.m_match_valid(matchv),.m_last(ml),.m_tag(mtag),
        .request_valid(qv),.request_ready(qr),.request_data(qdata),.request_last(ql),.request_tag(qtag),
        .rsp_valid(rv),.rsp_ready(rr),.rsp_kind(kind),.rsp_status(status),.rsp_recovery_status(recovery_status),
        .rsp_session(rsession),.rsp_sequence(rsession_seq),.rsp_messages(messages),.rsp_events(events),.rsp_next(rnext),.rsp_end(rend),.rsp_tag(rtag),
        .recovery_next(rn),.recovery_target(rt),.recovery_until(ru),.recovery_outstanding(outstanding),.recovery_closed(closed),.rsp_requested(requested),.busy(busy));
    task tick;begin @(posedge clk);#1;end endtask
    task reset;
        begin @(negedge clk);rst=1;cv=0;tv=0;sv=0;mr=0;qr=0;rr=0;tick();
            if(cr||tr||sr||mv||qv||rv||busy)$fatal(1,"reset gate");
            @(negedge clk);rst=0;tick();resets=resets+1;
            if(!cr||!tr||!sr||busy)$fatal(1,"reset idle");end
    endtask
    task finish_response(input [1:0] ek,input [3:0] es,ers,input [63:0] en,et,eu,input eo,ec,er);
        begin
            while(!rv)tick();
            if(kind!==ek||status!==es||recovery_status!==ers||rn!==en||rt!==et||ru!==eu||outstanding!==eo||closed!==ec||requested!==er)
                $fatal(1,"completion #%0d kind/status/rec=%0d/%0d/%0d next/target/until=%0d/%0d/%0d out/closed/req=%b%b%b",completions,kind,status,recovery_status,rn,rt,ru,outstanding,closed,requested);
            held_completion=completion;
            @(negedge clk);cv=1;tv=1;sv=1;
            repeat(4)begin
                if(cr||tr||sr||mv||qv)$fatal(1,"held completion admitted future");
                tick();holds=holds+1;blocked=blocked+1;
                if(!rv||completion!==held_completion)$fatal(1,"completion stability");
            end
            @(negedge clk);rr=1;tick();completions=completions+1;
            @(negedge clk);rr=0;cv=0;tv=0;sv=0;
        end
    endtask
    task configure(input [63:0] n);
        begin
            @(negedge clk);cfg_next=n;cv=1;
            if(!cr)$fatal(1,"config admission");tick();configs=configs+1;
            @(negedge clk);cv=0;
            finish_response(0,0,0,n,n,0,0,0,0);
        end
    endtask
    task send_byte(input [7:0] b,input final_byte);
        begin @(negedge clk);data=b;last=final_byte;sv=1;
            while(!sr)tick();tick();end
    endtask
    task packet(input [63:0] seq,input [15:0] number,input add_event);
        reg [159:0] header;integer k,total;
        begin
            header={session_id,seq,number};total=20+((number==0||number==65535)?0:(add_event?38:number*2));
            for(k=0;k<20;k=k+1)send_byte(header[159-k*8-:8],k==total-1);
            if(number!=0&&number!=65535)begin
                if(add_event)begin
                    send_byte(0,0);send_byte(36,0);
                    for(k=0;k<36;k=k+1)send_byte(add_body[287-k*8-:8],k==35);
                end else for(k=0;k<number*2;k=k+1)send_byte(0,k==number*2-1);
            end
            @(negedge clk);sv=0;last=0;packets=packets+1;
        end
    endtask
    task request_frame(input [63:0] seq,input [15:0] number);
        reg [7:0] held_byte;
        begin
            expected_frame={session_id,seq,number};frame=0;
            while(!qv)tick();
            for(j=0;j<20;j=j+1)begin
                if(!qv||qdata!==expected_frame[159-j*8-:8]||ql!==(j==19)||qtag!==rtag)$fatal(1,"request byte %0d",j);
                if(j==19)begin
                    held_byte=qdata;@(negedge clk);cv=1;tv=1;sv=1;qr=0;
                    repeat(5)begin tick();holds=holds+1;blocked=blocked+1;
                        if(!qv||qdata!==held_byte||!ql||rv||cr||tr||sr)$fatal(1,"request final ownership");end
                end
                @(negedge clk);qr=1;tick();request_bytes=request_bytes+1;
                @(negedge clk);qr=0;
            end
            cv=0;tv=0;sv=0;requests=requests+1;
        end
    endtask
    task retry_begin;
        begin @(negedge clk);tv=1;if(!tr)$fatal(1,"retry admission");tick();retries=retries+1;
            @(negedge clk);tv=0;end
    endtask
    task retire_event;
        begin
            while(!mv)tick();held_event=event_value;
            if(mt!=="A"||ms!==100||locate!==16'h1234||tracking!==16'h5678||timestamp!==48'h010203040506||
                mo!==64'h1122334455667788||qty!==100||price!==12345||mstock!==64'h4142434445464748||
                sell||!pv||!stockv||av||matchv||!ml||mtag!==stag)$fatal(1,"real receiver event");
            @(negedge clk);cv=1;tv=1;sv=1;
            repeat(5)begin tick();holds=holds+1;blocked=blocked+1;
                if(!mv||event_value!==held_event||qv||rv||cr||tr||sr)$fatal(1,"event owner");end
            @(negedge clk);mr=1;tick();event_count=event_count+1;
            @(negedge clk);mr=0;cv=0;tv=0;sv=0;
        end
    endtask
    initial begin
        add_body={8'h41,16'h1234,16'h5678,48'h010203040506,64'h1122334455667788,8'h42,32'd100,64'h4142434445464748,32'd12345};
        reset();configure(100);
        retry_begin();finish_response(2,0,7,100,100,0,0,0,0);
        packet(105,2,0);request_frame(100,3);finish_response(1,7,0,100,107,103,1,0,1);
        packet(105,2,0);finish_response(1,7,6,100,107,103,1,0,0);
        retry_begin();request_frame(100,3);finish_response(2,0,0,100,107,103,1,0,1);
        packet(100,1,1);retire_event();request_frame(101,3);finish_response(1,0,0,101,107,104,1,0,1);
        packet(101,2,0);request_frame(103,3);finish_response(1,0,0,103,107,106,1,0,1);
        packet(102,4,0);finish_response(1,6,6,103,107,106,1,0,0);
        packet(110,0,0);finish_response(1,7,6,103,110,106,1,0,0);
        packet(103,3,0);request_frame(106,3);finish_response(1,0,0,106,110,109,1,0,1);
        packet(106,3,0);request_frame(109,1);finish_response(1,0,0,109,110,110,1,0,1);
        packet(109,1,0);finish_response(1,0,5,110,110,0,0,0,0);
        packet(110,65535,0);finish_response(1,0,0,110,110,0,0,1,0);
        retry_begin();finish_response(2,0,8,110,110,0,0,1,0);
        packet(111,1,0);finish_response(1,7,8,110,110,0,0,1,0);
        configure(64'hfffffffffffffffe);
        packet(64'hfffffffffffffffe,2,0);finish_response(1,9,0,64'hfffffffffffffffe,64'hfffffffffffffffe,0,0,0,0);
        packet(64'hffffffffffffffff,1,0);finish_response(1,7,3,64'hfffffffffffffffe,64'hfffffffffffffffe,0,0,0,0);
        // Actual reset during receiver capture, manager configuration, held response,
        // held normalized event, and the final request byte; fresh epochs prove recovery.
        @(negedge clk);data=8'h53;sv=1;last=0;tick();reset();configure(100);
        @(negedge clk);cv=1;tick();configs=configs+1;@(negedge clk);cv=0;tick();reset();configure(100);
        retry_begin();while(!rv)tick();reset();configure(100);
        packet(100,1,1);while(!mv)tick();reset();configure(100);
        packet(105,1,0);while(!qv)tick();
        for(i=0;i<19;i=i+1)begin @(negedge clk);qr=1;tick();request_bytes=request_bytes+1;end
        @(negedge clk);qr=0;if(!qv||!ql)$fatal(1,"reset final request phase");reset();configure(100);
        retry_begin();finish_response(2,0,7,100,100,0,0,0,0);
        $display("PASS recovering_itch_rx configs=%0d packets=%0d retries=%0d requests=%0d request_bytes=%0d events=%0d completions=%0d holds=%0d blocked=%0d resets=%0d",configs,packets,retries,requests,request_bytes,event_count,completions,holds,blocked,resets);$finish;
    end
    always @(posedge clk)begin watchdog=watchdog+1;if(watchdog>50000)$fatal(1,"watchdog");end
endmodule
