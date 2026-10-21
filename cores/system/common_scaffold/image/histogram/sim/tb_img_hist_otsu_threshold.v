module tb_img_hist_otsu_threshold;
parameter COUNT_W=16;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,cv=0,sv=0,rr=0,pause=0;
reg [COUNT_W-1:0] count=0;
wire cr,sr,rv;wire [7:0] threshold;wire [1:0] error;
img_hist_otsu_threshold #(.COUNT_W(COUNT_W)) dut
 (clk,rst_n,ce,cv,cr,count,sv,sr,rv,rr,threshold,error);
reg [1023:0] fixture;
integer fd,code,value,expected,expected_error,i,waits,cycles=0,checks=0;
task tick;begin @(posedge clk);#1;@(negedge clk);#1;end endtask
always @(negedge clk) begin cycles=cycles+1;ce=!pause && cycles%11!=3;end
task command;
begin cv=1;#1;while(!cr || !ce) tick;tick;cv=0;end endtask
task sample(input [COUNT_W-1:0] data);
begin count=data;sv=1;#1;while(!sr || !ce) tick;tick;sv=0;end endtask
task compare;
begin
    if(!rv || threshold!==expected[7:0] || error!==expected_error[1:0] || sr || cr)
        $fatal(1,"Otsu histogram %0d got=%0d/%0d expected=%0d/%0d",checks,threshold,error,expected,expected_error);
end endtask
initial begin
    if(!$value$plusargs("fixture=%s",fixture)) $fatal(1,"fixture required");
    fd=$fopen(fixture,"r");if(!fd) $fatal(1,"fixture missing");
    repeat(2) tick;rst_n=1;#1;if(sr || rv || !cr) $fatal(1,"idle state");
    while(!$feof(fd)) begin
        code=$fscanf(fd,"%d %d\n",expected,expected_error);if(code!=2) $fatal(1,"answer fixture");
        command;
        for(i=0;i<256;i=i+1) begin
            code=$fscanf(fd,"%d\n",value);if(code!=1) $fatal(1,"count fixture");sample(value);
            if(i%5==0) tick;
        end
        waits=0;
        while(!rv && waits<300000) begin tick;waits=waits+1;end
        compare;
        repeat(7) begin tick;compare;end
        pause=1;tick;rr=1;repeat(4) begin tick;compare;end
        pause=0;while(!ce) tick;tick;rr=0;
        if(rv || !cr) $fatal(1,"response did not retire");checks=checks+1;
    end
    command;sample(1);rst_n=0;tick;rst_n=1;
    repeat(10) tick;if(rv || sr || !cr) $fatal(1,"partial load reset");
    command;for(i=0;i<256;i=i+1) sample(1);
    repeat(20) tick;rst_n=0;tick;rst_n=1;
    repeat(100) tick;if(rv || sr || !cr) $fatal(1,"multiply reset");
    $display("OTSU PASS count_width=%0d checks=%0d cycles=%0d",COUNT_W,checks,cycles);$fclose(fd);$finish;
end
initial begin #100000000;$fatal(1,"timeout");end
endmodule
