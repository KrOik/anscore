module tb_img_filter_adaptive_mean3x3;
parameter PIXEL_W=8;
parameter GAUSSIAN=0;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,sv=0,sof=0,eol=0,mr=0,invert=0;
reg [9*PIXEL_W-1:0] taps=0;
reg signed [PIXEL_W:0] offset=0;
wire sr,mv,mo,me;wire [PIXEL_W-1:0] md;
generate if(GAUSSIAN) begin:gaussian
img_filter_adaptive_gaussian3x3 #(.PIXEL_W(PIXEL_W)) dut
 (clk,rst_n,ce,taps,offset,invert,sv,sof,eol,sr,md,mv,mo,me,mr);
end else begin:mean
img_filter_adaptive_mean3x3 #(.PIXEL_W(PIXEL_W)) dut
 (clk,rst_n,ce,taps,offset,invert,sv,sof,eol,sr,md,mv,mo,me,mr);
end endgenerate
reg [1023:0] fixture;
integer fd,code,value,a,b,c,d,expected,i,waits,checks=0;
task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
task compare;
begin
    if(!mv || md!==expected[PIXEL_W-1:0] || mo!==c[0] || me!==d[0])
        $fatal(1,"adaptive check %0d got %0d/%b/%b expected %0d/%0d/%0d",checks,md,mo,me,expected,c,d);
end endtask
initial begin
    if(!$value$plusargs("fixture=%s",fixture)) $fatal(1,"fixture required");
    fd=$fopen(fixture,"r");if(!fd) $fatal(1,"fixture missing");
    repeat(2) tick;rst_n=1;
    while(!$feof(fd)) begin
        for(i=0;i<9;i=i+1) begin
            code=$fscanf(fd,"%d ",value);if(code!=1) $fatal(1,"tap fixture");taps[i*PIXEL_W+:PIXEL_W]=value;
        end
        code=$fscanf(fd,"%d %d %d %d %d\n",a,b,c,d,expected);if(code!=5) $fatal(1,"metadata fixture");
        offset=a;invert=b;sof=c;eol=d;sv=1;ce=0;#1;
        repeat(2) begin tick;if(sr || mv) $fatal(1,"accepted while paused");end
        ce=1;#1;if(!sr) $fatal(1,"input blocked");tick;sv=0;
        // Configuration belongs to the accepted window, not the output edge.
        taps=~taps;offset=~offset;invert=~invert;sof=~sof;eol=~eol;
        waits=0;while(!mv && waits<6) begin tick;waits=waits+1;end
        compare;
        repeat(checks%4) begin tick;compare;end
        mr=1;ce=0;repeat(2) begin tick;compare;end
        ce=1;tick;mr=0;if(mv) $fatal(1,"duplicate output");checks=checks+1;
    end
    sv=1;ce=1;tick;sv=0;rst_n=0;tick;rst_n=1;
    repeat(5) tick;if(mv) $fatal(1,"reset did not cancel");
    if(GAUSSIAN) $display("ADAPTIVE_GAUSSIAN PASS width=%0d checks=%0d",PIXEL_W,checks);
    else $display("ADAPTIVE_MEAN PASS width=%0d checks=%0d",PIXEL_W,checks);
    $fclose(fd);$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
