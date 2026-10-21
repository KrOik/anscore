module tb_cip_cic_decimator;
parameter RATE=8,STAGES=3,SHIFT=9;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,cv=0,rr=0,sv=0,sl=0,mr=0;
reg [7:0] tag=0,opcode=0,sd=0;
reg [31:0] p0=0,p1=0;
wire cr,rv,sr,mv,ml;wire [7:0] rt,md;wire [1:0] err;
cip_cic_decimator #(.DATA_W(8),.RATE(RATE),.STAGES(STAGES),.SHIFT(SHIFT)) dut
 (clk,rst_n,ce,cv,cr,tag,rv,rr,rt,err,opcode,p0,p1,sl,ml,sd,sv,sr,md,mv,mr);
reg [1023:0] folder;
integer fi,fo,code,a,b,i,cycles=0,outputs=0,packets=0,responses=0;
integer mon_code,ex,el;
reg held=0;reg [7:0] held_data;reg held_last;
reg packet_open=0,last_seen=0,checking=1;
task tick;begin @(posedge clk);#1;@(negedge clk);#1;end endtask
always @(negedge clk) begin
    cycles=cycles+1;ce=(cycles%7!=2 && cycles%11!=3);mr=(cycles%9>2);
end
always @(posedge clk) begin
    if(rst_n) begin
        if(held && (!mv || md!==held_data || ml!==held_last)) $fatal(1,"stalled output unstable");
        if(checking && ce && mv && mr) begin
            mon_code=$fscanf(fo,"%d %d\n",ex,el);
            if(mon_code!=2 || md!==ex[7:0] || ml!==el[0]) $fatal(1,"CIC adapter numeric %0d",outputs);
            outputs=outputs+1;
            if(ml) last_seen=1;
        end
        held=mv && !(ce && mr);held_data=md;held_last=ml;
    end else held=0;
end
task command(input [7:0] op,input [31:0] a,input [31:0] b,input [7:0] t);
begin
    cv=1;opcode=op;p0=a;p1=b;tag=t;#1;
    while(!ce || !cr) tick;
    tick;cv=0;
end endtask
task response(input [7:0] t,input [1:0] e);
begin
    while(!rv) tick;
    repeat(5) begin
        if(rt!==t || err!==e || !rv || cr || sr) $fatal(1,"response retention");tick;
    end
    rr=1;while(!ce) tick;tick;rr=0;
    if(rv) $fatal(1,"duplicate response");responses=responses+1;
end endtask
initial begin
    if(!$value$plusargs("folder=%s",folder)) $fatal(1,"fixtures required");
    fi=$fopen($sformatf("%0s/input.txt",folder),"r");
    fo=$fopen($sformatf("%0s/expected.txt",folder),"r");
    if(!fi || !fo) $fatal(1,"fixtures missing");
    repeat(2) tick;rst_n=1;#1;if(sr || mv) $fatal(1,"uncommanded data");
    command(0,1,0,8'hf0);response(8'hf0,2);
    command(0,0,1,8'hf1);response(8'hf1,2);
    command(1,0,0,8'hf2);response(8'hf2,1);
    while(!$feof(fi)) begin
        if(!packet_open) begin
            command(0,0,0,8'h80+packets);packet_open=1;last_seen=0;
            // Attempted coefficient command must remain blocked throughout RUN.
            cv=1;opcode=1;p0=0;p1=99;tag=255;
        end
        code=$fscanf(fi,"%d %d\n",a,b);if(code!=2) $fatal(1,"input fixture");
        sv=1;sd=a;sl=b;#1;
        while(!sr || !ce) begin if(cr || rv) $fatal(1,"early run response");tick;end
        tick;sv=0;
        if(b) begin
            while(!rv) tick;
            if(!last_seen || sr || cr) $fatal(1,"response before final output");
            cv=0;response(8'h80+packets,0);packet_open=0;packets=packets+1;
        end
    end
    code=$fscanf(fo,"%d %d\n",a,b);if(code==2 || mv) $fatal(1,"missing outputs");
    checking=0;command(0,0,0,8'hfe);sv=1;sd=123;sl=0;#1;
    while(!ce || !sr) tick;tick;sv=0;rst_n=0;tick;rst_n=1;
    repeat(10) tick;if(rv || mv || sr || !cr) $fatal(1,"reset cancellation");
    $display("CIC_ADAPTER PASS rate=%0d stages=%0d shift=%0d outputs=%0d packets=%0d responses=%0d",RATE,STAGES,SHIFT,outputs,packets,responses);
    $fclose(fi);$fclose(fo);$finish;
end
initial begin #5000000;$fatal(1,"timeout");end
endmodule
