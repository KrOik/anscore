module tb_cip_dsp_resampler;
parameter UP=3,DOWN=2,TAPS=11;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,cv=0,sv=0,sl=0,mr=1;
reg [31:0] ca=0;
reg signed [7:0] cd=0,sd=0;
wire cr,sr,mv,ml;wire signed [7:0] md;
cip_dsp_resampler #(.DATA_W(8),.COEFF_W(8),.UP(UP),.DOWN(DOWN),.TAPS(TAPS),.SHIFT(6)) dut
 (clk,rst_n,ce,cv,cr,ca,cd,sd,sv,sl,sr,md,mv,ml,mr);
reg [1023:0] folder;
integer fi,fo,fc,code,a,b,i,cycles=0,outputs=0;
integer mon_code,ex,last_ex;
reg held=0;reg signed [7:0] held_data;reg held_last;
task tick;begin @(posedge clk);#1;@(negedge clk);#1;end endtask
always @(negedge clk) begin
    cycles=cycles+1;
    ce=(cycles%7!=2 && cycles%11!=3);
    mr=(cycles%9>2);
end
always @(posedge clk) begin
    if(rst_n) begin
        if(held && (!mv || md!==held_data || ml!==held_last)) $fatal(1,"unstable output");
        if(ce && mv && mr) begin
            mon_code=$fscanf(fo,"%d %d\n",ex,last_ex);
            if(mon_code!=2 || md!==ex[7:0] || ml!==last_ex[0])
                $fatal(1,"resampler output %0d got %0d/%b expected %0d/%0d",outputs,md,ml,ex,last_ex);
            outputs=outputs+1;
        end
        held=mv && !(ce && mr);held_data=md;held_last=ml;
    end else held=0;
end
initial begin
    if(!$value$plusargs("folder=%s",folder)) $fatal(1,"fixture required");
    fi=$fopen($sformatf("%0s/input.txt",folder),"r");
    fo=$fopen($sformatf("%0s/expected.txt",folder),"r");
    fc=$fopen($sformatf("%0s/coeff.txt",folder),"r");
    if(!fi || !fo || !fc) $fatal(1,"fixture missing");
    repeat(2) tick;rst_n=1;
    for(i=0;i<TAPS;i=i+1) begin
        code=$fscanf(fc,"%d\n",a);if(code!=1) $fatal(1,"coeff fixture");
        cv=1;ca=i;cd=a;
        while(!cr || !ce) tick;
        tick;
    end
    cv=0;
    while(!$feof(fi)) begin
        code=$fscanf(fi,"%d %d\n",a,b);if(code!=2) $fatal(1,"input fixture");
        sv=1;sd=a;sl=b;#1;
        while(!sr || !ce) tick;
        tick;sv=0;
        repeat((a&3)) tick;
    end
    while(!cr) tick;
    repeat(3) tick;
    code=$fscanf(fo,"%d %d\n",a,b);if(code==2 || mv) $fatal(1,"missing output");
    // A reset cancels a partial packet and reopens coefficient loading.
    sd=123;sl=0;sv=1;while(!sr || !ce) tick;tick;sv=0;
    rst_n=0;tick;rst_n=1;repeat(10) tick;
    if(mv || !cr || !sr) $fatal(1,"reset cancellation");
    $display("PASS RESAMPLER up=%0d down=%0d taps=%0d outputs=%0d",UP,DOWN,TAPS,outputs);
    $fclose(fi);$fclose(fo);$fclose(fc);$finish;
end
initial begin #5000000;$fatal(1,"timeout");end
endmodule
