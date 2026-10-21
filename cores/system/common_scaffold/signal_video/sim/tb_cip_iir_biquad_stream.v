module tb_cip_iir_biquad_stream;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,cv=0,rr=0,sv=0,sl=0,mr=0;
reg [7:0] tag=0,opcode=0,sd=0;
reg [31:0] p0=0,p1=0;
wire cr,rv,sr,mv,ml;wire [7:0] rt,md;wire [1:0] err;
cip_iir_biquad_stream #(.DATA_W(8),.COEFF_W(8),.SHIFT(6)) dut
 (clk,rst_n,ce,cv,cr,tag,rv,rr,rt,err,opcode,p0,p1,sl,ml,sd,sv,sr,md,mv,mr);
integer i,j,packet,x,h0=0,h1=0,h2=0,y1=0,y2=0,want,outputs=0,responses=0;
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task command(input [7:0] op,input [31:0] a,input [31:0] b,input [7:0] t);
begin
    cv=1;opcode=op;p0=a;p1=b;tag=t;#1;
    if(!cr) $fatal(1,"command readiness");tick;cv=0;
end endtask
task response(input [7:0] t,input [1:0] e);
begin
    if(!rv || rt!==t || err!==e) $fatal(1,"response tag/error");
    repeat(3) begin tick;if(!rv || rt!==t || err!==e || cr || sr) $fatal(1,"response stall");end
    ce=0;rr=1;repeat(2) tick;if(!rv) $fatal(1,"CE consumed response");
    ce=1;tick;rr=0;if(rv) $fatal(1,"response duplicated");responses=responses+1;
end endtask
initial begin
    repeat(2) tick;rst_n=1;#1;if(sr || mv) $fatal(1,"uncommanded data");
    command(1,0,32,8'h10);response(8'h10,0);
    command(1,1,16,8'h11);response(8'h11,0);
    command(1,2,32'hfffffff8,8'h12);response(8'h12,0);
    command(1,3,32'hffffffe0,8'h17);response(8'h17,0);
    command(1,4,12,8'h18);response(8'h18,0);
    command(1,5,5,8'h13);response(8'h13,2);
    command(1,0,32'h000000ff,8'h14);response(8'h14,2);
    command(8'hfe,0,0,8'h15);response(8'h15,1);
    command(0,1,0,8'h16);response(8'h16,2);
    for(packet=0;packet<3;packet=packet+1) begin
        command(0,0,0,8'h80+packet);
        cv=1;tag=8'hff;opcode=1;p0=0;p1=99;
        for(i=0;i<23;i=i+1) begin
            x=((i*73+packet*31)%256)-128;
            h2=h1;h1=h0;h0=x;want=(32*h0+16*h1-8*h2+32*y1-12*y2)>>>6;
            if(want>127) want=127;if(want< -128) want=-128;
            y2=y1;y1=want;
            sd=x;sl=i==22;sv=1;#1;
            if(!sr || cr || rv) $fatal(1,"run state");tick;sv=0;
            ce=0;repeat(2) tick;ce=1;
            j=0;while(!mv && j<8) begin tick;j=j+1;end
            if(!mv || md!==want[7:0] || ml!==sl) $fatal(1,"numeric output %0d",outputs);
            repeat(3) begin tick;if(!mv || md!==want[7:0] || ml!==sl || rv || cr) $fatal(1,"data stall");end
            if(sl) begin sv=1;#1;if(sr) $fatal(1,"accepted sample after last");end
            ce=0;mr=1;tick;if(!mv) $fatal(1,"CE consumed data");ce=1;tick;mr=0;sv=0;
            outputs=outputs+1;
        end
        cv=0;response(8'h80+packet,0);h0=0;h1=0;h2=0;y1=0;y2=0;
    end
    command(0,0,0,8'ha0);sv=1;sd=120;sl=0;tick;sv=0;
    rst_n=0;#1;if(rv || mv || sr || cr) $fatal(1,"reset activity");tick;rst_n=1;
    repeat(6) tick;if(rv || mv || sr || !cr) $fatal(1,"reset cancellation");
    command(0,0,0,8'ha1);sv=1;sd=127;sl=1;#1;tick;sv=0;
    repeat(6) tick;if(!mv || md!==0 || !ml) $fatal(1,"reset coefficient clear");
    mr=1;tick;mr=0;response(8'ha1,0);
    $display("IIR_ADAPTER PASS outputs=%0d responses=%0d",outputs,responses);$finish;
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
