module tb_cip_dsp_cordic;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,ce=1,sv=0,mode=0,sl=0,mr=0;
reg signed [15:0] sx=0,sy=0;
reg signed [17:0] sz=0;
wire sr,mv,ml; wire signed [19:0] mx,my; wire signed [17:0] mz;
cip_dsp_cordic dut(clk,rst_n,ce,sv,sr,mode,sl,sx,sy,sz,mv,mr,ml,mx,my,mz);
reg [1023:0] fixture;
integer fd,code,a,b,c,d,e,ex,ey,ez,pause,stall,i,checks=0;
task tick; begin @(posedge clk); #1; @(negedge clk); end endtask
task compare;
begin
    if(!mv || mx!==ex[19:0] || my!==ey[19:0] || mz!==ez[17:0] || ml!==sl)
        $fatal(1,"CORDIC %0d got %0d,%0d,%0d expected %0d,%0d,%0d",checks,mx,my,mz,ex,ey,ez);
end endtask
initial begin
    if(!$value$plusargs("fixture=%s",fixture)) $fatal(1,"fixture required");
    fd=$fopen(fixture,"r");if(!fd) $fatal(1,"fixture missing");
    repeat(2) tick;rst_n=1;
    while(!$feof(fd)) begin
        code=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d\n",a,b,c,d,e,ex,ey,ez,pause,stall);
        if(code!=10) $fatal(1,"malformed fixture");
        mode=a;sx=b;sy=c;sz=d;sl=e;sv=1;#1;
        if(!sr) $fatal(1,"input blocked");tick;sv=0;
        repeat(5) tick;ce=0;repeat(pause) tick;ce=1;
        i=0;while(!mv && i<20) begin tick;i=i+1;end
        compare;
        repeat(stall) begin tick;compare;end
        ce=0;mr=1;repeat(2) begin tick;compare;end
        ce=1;tick;mr=0;checks=checks+1;
    end
    // Reset while work is pending, then check idle state.
    sv=1;tick;sv=0;repeat(3) tick;rst_n=0;tick;rst_n=1;
    repeat(20) tick;if(mv || !sr) $fatal(1,"reset did not cancel");
    $display("PASS CORDIC checks=%0d",checks);$fclose(fd);$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
