module tb_cip_cordic_stream;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,cv=0,rr=0,sv=0,sl=0,mr=0;
reg [7:0] tag=0,opcode=0;
reg [15:0] sd=0;
reg [31:0] p0=0,p1=0;
wire cr,rv,sr,mv,ml;wire [7:0] rt;wire [15:0] md;wire [1:0] err;
cip_cordic_stream dut(clk,rst_n,ce,cv,cr,tag,rv,rr,rt,err,opcode,p0,p1,sl,ml,sd,sv,sr,md,mv,mr);
reg [1023:0] folder;
integer fi,fo,code,mode,angle,x,y,last,i,cycles=0,outputs=0,packets=0,responses=0;
integer mon_code,ex,el;
reg held=0;reg [15:0] held_data;reg held_last;
reg packet_open=0,last_seen=0;
reg [5:0] stalled_words=0;
task tick;begin @(posedge clk);#1;@(negedge clk);#1;end endtask
always @(negedge clk) begin
    cycles=cycles+1;ce=(cycles%7!=2 && cycles%11!=3);mr=(cycles%9>2);
end
always @(posedge clk) begin
    if(rst_n) begin
        if(held && (!mv || md!==held_data || ml!==held_last)) $fatal(1,"serialized output unstable");
        if(mv && (!ce || !mr)) stalled_words[outputs%6]=1;
        if(ce && mv && mr) begin
            mon_code=$fscanf(fo,"%d %d\n",ex,el);
            if(mon_code!=2 || md!==ex[15:0] || ml!==el[0]) $fatal(1,"CORDIC adapter word %0d got=%h expected=%h",outputs,md,ex[15:0]);
            outputs=outputs+1;if(ml) last_seen=1;
        end
        held=mv && !(ce && mr);held_data=md;held_last=ml;
    end else held=0;
end
task command(input [7:0] op,input [31:0] a,input [31:0] b,input [7:0] t);
begin cv=1;opcode=op;p0=a;p1=b;tag=t;#1;while(!ce || !cr) tick;tick;cv=0;end endtask
task response(input [7:0] t,input [1:0] e);
begin
    while(!rv) tick;
    repeat(5) begin if(rt!==t || err!==e || !rv || cr || sr) $fatal(1,"CORDIC response");tick;end
    rr=1;while(!ce) tick;tick;rr=0;if(rv) $fatal(1,"duplicate response");responses=responses+1;
end endtask
task sample(input [15:0] value,input final_word);
begin sv=1;sd=value;sl=final_word;#1;while(!sr || !ce) tick;tick;sv=0;end endtask
initial begin
    if(!$value$plusargs("folder=%s",folder)) $fatal(1,"fixtures required");
    fi=$fopen($sformatf("%0s/input.txt",folder),"r");fo=$fopen($sformatf("%0s/expected.txt",folder),"r");
    if(!fi || !fo) $fatal(1,"fixtures missing");
    repeat(2) tick;rst_n=1;#1;if(sr || mv) $fatal(1,"uncommanded data");
    command(255,0,0,8'hf0);response(8'hf0,1);
    command(0,131072,0,8'hf1);response(8'hf1,2);
    command(1,0,1,8'hf2);response(8'hf2,2);
    command(0,262143,0,8'hf3);response(8'hf3,2);
    while(!$feof(fi)) begin
        code=$fscanf(fi,"%d %d %d %d %d\n",mode,angle,x,y,last);if(code!=5) $fatal(1,"bad fixture");
        if(!packet_open) begin
            // Odd-word packet abort must not affect the next valid packet.
            command(0,0,0,8'h40+packets);sample(123,1);response(8'h40+packets,2);
            command(mode,angle,0,8'h80+packets);packet_open=1;last_seen=0;
            cv=1;opcode=255;p0=123;p1=456;tag=255;
        end
        sample(x,0);sample(y,last);
        if(last) begin
            while(!rv) tick;
            if(!last_seen || sr || cr) $fatal(1,"response before serialized final word");
            cv=0;response(8'h80+packets,0);packet_open=0;packets=packets+1;
        end
    end
    code=$fscanf(fo,"%d %d\n",ex,el);if(code==2 || mv || stalled_words!==6'b111111) $fatal(1,"missing outputs/stall coverage");
    command(0,0,0,8'hfe);sample(123,0);rst_n=0;tick;rst_n=1;
    repeat(20) tick;if(rv || mv || sr || !cr) $fatal(1,"partial pair reset");
    command(1,0,0,8'hff);sample(123,0);sample(456,1);
    repeat(3) tick;rst_n=0;tick;rst_n=1;
    repeat(20) tick;if(rv || mv || sr || !cr) $fatal(1,"compute reset");
    $display("CORDIC_ADAPTER PASS words=%0d packets=%0d responses=%0d stalls=%b",outputs,packets,responses,stalled_words);
    $fclose(fi);$fclose(fo);$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
