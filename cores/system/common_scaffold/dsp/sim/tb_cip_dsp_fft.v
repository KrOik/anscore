module tb_cip_dsp_fft;
parameter LOG_N=6,DATA_W=16;
localparam OUT_W=DATA_W+LOG_N+2;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,sv=0,inv=0,sl=0,mr=0;
reg signed [DATA_W-1:0] sre=0,simag=0;
wire sr,mv,ml,me;wire signed [OUT_W-1:0] mre,mim;
cip_dsp_fft #(.DATA_W(DATA_W),.LOG_N(LOG_N)) dut
 (clk,rst_n,ce,sv,sr,inv,sl,sre,simag,mv,mr,ml,me,mre,mim);
reg [1023:0] folder;
integer fi,fo,code,a,b,c,d,cycles=0,outputs=0;
integer mon_code,er,ei,el,ee;
reg recovery=0;
integer recovered=0,j;
reg held=0;reg signed [OUT_W-1:0] held_re,held_im;reg held_last,held_error;
task tick;begin @(posedge clk);#1;@(negedge clk);#1;end endtask
always @(negedge clk) begin
    cycles=cycles+1;
    ce=(cycles%5!=2 && cycles%13!=4);
    mr=(cycles%11>3);
end
always @(posedge clk) begin
    if(rst_n) begin
        if(held && (!mv || mre!==held_re || mim!==held_im || ml!==held_last || me!==held_error))
            $fatal(1,"FFT output unstable under stall/CE");
        if(ce && mv && mr) begin
            if(recovery) begin
                if(mre!==0 || mim!==0 || me!==0 || ml!==(recovered==((1<<LOG_N)-1)))
                    $fatal(1,"FFT reset recovery mismatch");
                recovered=recovered+1;
            end else begin
            mon_code=$fscanf(fo,"%d %d %d %d\n",er,ei,el,ee);
            if(mon_code!=4 || mre!==er[OUT_W-1:0] || mim!==ei[OUT_W-1:0] || ml!==el[0] || me!==ee[0])
                $fatal(1,"FFT %0d got %0d,%0d last=%b err=%b expected %0d,%0d last=%0d err=%0d",outputs,mre,mim,ml,me,er,ei,el,ee);
            outputs=outputs+1;
            end
        end
        held=mv && !(ce && mr);held_re=mre;held_im=mim;held_last=ml;held_error=me;
    end else held=0;
end
initial begin
    if(!$value$plusargs("folder=%s",folder)) $fatal(1,"fixture required");
    fi=$fopen($sformatf("%0s/input.txt",folder),"r");
    fo=$fopen($sformatf("%0s/expected.txt",folder),"r");
    if(!fi || !fo) $fatal(1,"fixture missing");
    repeat(2) tick;rst_n=1;
    while(!$feof(fi)) begin
        code=$fscanf(fi,"%d %d %d %d\n",a,b,c,d);if(code!=4) $fatal(1,"bad fixture");
        sre=a;simag=b;inv=c;sl=d;sv=1;#1;
        while(!sr || !ce) tick;
        tick;sv=0;repeat(a&1) tick;
    end
    while(!sr) tick;
    repeat(4) tick;
    code=$fscanf(fo,"%d %d %d %d\n",a,b,c,d);
    if(code==4 || mv) $fatal(1,"missing FFT outputs");
    // Reset aborts a partial load. RAM contents need not reset.
    sv=1;sl=0;while(!ce) tick;tick;sv=0;rst_n=0;tick;rst_n=1;
    repeat(10) tick;if(!sr || mv) $fatal(1,"reset cancellation");
    recovery=1;
    // Load a complete frame, abort during butterflies, then overwrite RAM
    // with a new complete zero frame and verify exact recovery.
    for(j=0;j<(1<<LOG_N);j=j+1) begin
        sre=77;simag=-51;sl=j==((1<<LOG_N)-1);sv=1;
        #1;while(!sr || !ce) tick;tick;sv=0;
    end
    repeat(8) tick;rst_n=0;tick;rst_n=1;repeat(2) tick;
    if(mv || !sr || recovered!=0) $fatal(1,"compute reset did not cancel");
    for(j=0;j<(1<<LOG_N);j=j+1) begin
        sre=0;simag=0;sl=j==((1<<LOG_N)-1);sv=1;
        #1;while(!sr || !ce) tick;tick;sv=0;
    end
    while(!sr) tick;
    if(recovered!=(1<<LOG_N)) $fatal(1,"missing recovery frame");
    $display("PASS FFT N=%0d outputs=%0d recovery=%0d",1<<LOG_N,outputs,recovered);
    $fclose(fi);$fclose(fo);$finish;
end
initial begin #20000000;$fatal(1,"timeout");end
endmodule
