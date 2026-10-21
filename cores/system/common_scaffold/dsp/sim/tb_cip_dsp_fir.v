module tb_cip_dsp_fir;
reg clk=0; always #5 clk=~clk;
reg rst_n=0, ce=1, cv=0, sv=0, sl=0, mr=0;
reg [31:0] ca=0;
reg signed [7:0] cd=0, sd=0;
wire cr,sr,mv,ml; wire signed [7:0] md;
cip_dsp_fir #(.DATA_W(8),.COEFF_W(8),.TAPS(3),.SHIFT(1)) dut
 (clk,rst_n,ce,cv,cr,ca,cd,sd,sv,sl,sr,md,mv,ml,mr);
integer i,j,x,sum,want,checks=0;
integer h0=0,h1=0,h2=0;
task tick; begin @(posedge clk); #1; @(negedge clk); end endtask
initial begin
    repeat(2) tick; rst_n=1;
    // h=[3,-2,1], including negative products and both saturation limits.
    cv=1; ca=0; cd=3; tick; ca=1; cd=-2; tick; ca=2; cd=1; tick; cv=0;
    for(i=0;i<200;i=i+1) begin
        x=((i*73+19)%256)-128;
        h2=h1; h1=h0; h0=x; sum=(3*h0-2*h1+h2)>>>1;
        want=sum>127 ? 127 : sum< -128 ? -128 : sum;
        sd=x; sl=(i%17==16); sv=1; #1;
        if(!sr) $fatal(1,"input not ready");
        tick; sv=0;
        // Paused compute must not advance.
        ce=0; repeat(2) tick; ce=1;
        j=0;
        while(!mv && j<10) begin tick; j=j+1; end
        if(!mv || md!==want[7:0] || ml!==sl) $fatal(1,"FIR mismatch i=%0d got=%0d expected=%0d",i,md,want);
        repeat(3) begin tick; if(!mv || md!==want[7:0] || ml!==sl) $fatal(1,"backpressure"); end
        ce=0; mr=1; tick; if(!mv) $fatal(1,"CE consumed output");
        ce=1; tick; mr=0;
        if(sl) begin h0=0; h1=0; h2=0; end
        checks=checks+1;
    end
    // Reset cancels in-flight work and clears history/coefficients.
    sd=100; sv=1; tick; sv=0; rst_n=0; tick; rst_n=1;
    repeat(5) tick; if(mv) $fatal(1,"reset cancellation");
    sd=100; sv=1; tick; sv=0; repeat(4) tick;
    if(!mv || md!==0) $fatal(1,"reset coefficients");
    $display("PASS FIR checks=%0d",checks); $finish;
end
initial begin #100000; $fatal(1,"timeout"); end
endmodule
