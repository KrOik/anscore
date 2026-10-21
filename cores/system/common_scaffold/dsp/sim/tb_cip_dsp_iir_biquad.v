module tb_cip_dsp_iir_biquad;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,ce=1,cv=0,sv=0,sl=0,mr=0;
reg [2:0] ca=0;
reg signed [7:0] cd=0,sd=0;
wire cr,sr,mv,ml; wire signed [7:0] md;
cip_dsp_iir_biquad #(.DATA_W(8),.COEFF_W(8),.SHIFT(6)) dut
 (clk,rst_n,ce,cv,cr,ca,cd,sd,sv,sl,sr,md,mv,ml,mr);
reg [1023:0] fixture;
integer fd,code,a,b,c,d,e,f,g,i,checks=0;
reg signed [7:0] expected;
task tick; begin @(posedge clk); #1; @(negedge clk); end endtask
initial begin
    if(!$value$plusargs("fixture=%s",fixture)) $fatal(1,"fixture required");
    fd=$fopen(fixture,"r"); if(!fd) $fatal(1,"fixture missing");
    repeat(2) tick; rst_n=1;
    while(!$feof(fd)) begin
        code=$fscanf(fd,"%d %d %d %d %d %d %d\n",a,b,c,d,e,f,g);
        if(code!=7) $fatal(1,"malformed fixture");
        if(a==0) begin
            cv=1; ca=b; cd=c; #1;
            if(!cr) $fatal(1,"coefficient readiness"); tick; cv=0;
        end else if(a==1) begin
            sd=b; sl=c; sv=1; expected=d; #1;
            if(!sr) $fatal(1,"sample readiness"); tick; sv=0;
            ce=0; repeat(e) tick; ce=1;
            i=0; while(!mv && i<32) begin tick; i=i+1; end
            if(!mv || md!==expected || ml!==sl) $fatal(1,"numeric check %0d got %0d expected %0d",checks,md,expected);
            repeat(f) begin tick; if(!mv || md!==expected || ml!==sl) $fatal(1,"backpressure"); end
            ce=0; mr=1; repeat(g) tick;
            if(!mv || md!==expected) $fatal(1,"CE pause");
            ce=1; tick; mr=0; checks=checks+1;
        end else begin
            // Abort a real in-flight transaction, clear coefficient and delay state.
            sd=123; sv=1; tick; sv=0; rst_n=0; tick; rst_n=1;
            repeat(7) tick; if(mv) $fatal(1,"reset cancellation");
        end
    end
    $display("PASS IIR checks=%0d",checks); $fclose(fd); $finish;
end
initial begin #1000000; $fatal(1,"timeout"); end
endmodule
