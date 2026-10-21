module tb_img_adaptive_threshold_frame;
parameter PIXEL_W=8,GAUSSIAN=0;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,cv=0,sv=0,sof=0,eol=0,mr=0,rr=0,invert=0;
reg [15:0] width=0,height=0,tag=0;
reg signed [PIXEL_W:0] offset=0;
reg [PIXEL_W-1:0] pixel=0;
wire cr,sr,mv,mo,me,ml,rv;wire [PIXEL_W-1:0] md;wire [15:0] mt,rt,ow,oh;
wire [3:0] error;wire [31:0] pixels;
img_adaptive_threshold_frame #(.PIXEL_W(PIXEL_W),.MAX_WIDTH(32),.GAUSSIAN(GAUSSIAN)) dut
 (clk,rst_n,ce,cv,cr,width,height,tag,offset,invert,pixel,sv,sof,eol,sr,md,mv,mo,me,ml,mt,mr,rv,rr,error,rt,pixels,ow,oh);
reg [1023:0] folder;
integer fi,fo,code,a,b,c,w,h,off,inv,t,expected_error,expected_pixels,i,cycles=0,outputs=0,commands=0;
integer mc,ed,eso,eeo,ela,et;
reg held=0,last_seen=0;
reg [PIXEL_W-1:0] held_data;
reg held_sof,held_eol,held_last;reg [15:0] held_tag;
task tick;begin @(posedge clk);#1;@(negedge clk);#1;end endtask
always @(negedge clk) begin cycles=cycles+1;ce=cycles%11!=3;mr=cycles%9>2;end
always @(posedge clk) begin
    if(rst_n) begin
        if(held && (!mv || md!==held_data || mo!==held_sof || me!==held_eol || ml!==held_last || mt!==held_tag))
            $fatal(1,"adaptive frame stalled output changed");
        if(ce && mv && mr) begin
            mc=$fscanf(fo,"%d %d %d %d %d\n",ed,eso,eeo,ela,et);
            if(mc!=5 || md!==ed[PIXEL_W-1:0] || mo!==eso[0] || me!==eeo[0] || ml!==ela[0] || mt!==et[15:0])
                $fatal(1,"adaptive frame output %0d got=%0d expected=%0d",outputs,md,ed);
            outputs=outputs+1;if(ml) last_seen=1;
        end
        held=mv && !(ce && mr);held_data=md;held_sof=mo;held_eol=me;held_last=ml;held_tag=mt;
    end else held=0;
end
task command;
begin
    cv=1;width=w;height=h;offset=off;invert=inv;tag=t;#1;
    while(!cr || !ce) tick;tick;
    // Keep an attempted command pending while active, but change all payload.
    width=2;height=1;offset=~offset;invert=~invert;tag=~tag;
end endtask
task sample(input [PIXEL_W-1:0] value,input first,input row_end);
begin pixel=value;sof=first;eol=row_end;sv=1;#1;while(!sr || !ce) tick;tick;sv=0;end endtask
task response;
integer waits;
begin
    waits=0;while(!rv && waits<100000) begin tick;waits=waits+1;end
    cv=0;
    repeat(7) begin
        if(!rv || error!==expected_error[3:0] || rt!==t[15:0] || pixels!==expected_pixels || cr || sr || mv)
            $fatal(1,"adaptive frame response cmd=%0d code=%0d expected=%0d pixels=%0d expected=%0d",commands,error,expected_error,pixels,expected_pixels);
        if(expected_error!=1 && (!last_seen || ow!==w-2 || oh!==h-2)) $fatal(1,"early done/dimensions");
        if(expected_error==1 && (ow || oh)) $fatal(1,"invalid dimensions published");
        tick;
    end
    rr=1;while(!ce) tick;tick;rr=0;if(rv || !cr) $fatal(1,"response did not retire");commands=commands+1;
end endtask
initial begin
    if(!$value$plusargs("folder=%s",folder)) $fatal(1,"fixtures required");
    fi=$fopen($sformatf("%0s/input.txt",folder),"r");fo=$fopen($sformatf("%0s/expected.txt",folder),"r");
    if(!fi || !fo) $fatal(1,"fixtures missing");
    repeat(2) tick;rst_n=1;#1;if(sr || mv || rv || !cr) $fatal(1,"idle state");
    while(!$feof(fi)) begin
        code=$fscanf(fi,"%d %d %d %d %d %d\n",w,h,off,inv,t,expected_error);if(code!=6) $fatal(1,"command fixture");
        command;last_seen=0;expected_pixels=expected_error==1?0:(w-2)*(h-2);
        if(expected_error!=1) for(i=0;i<w*h;i=i+1) begin
            code=$fscanf(fi,"%d %d %d\n",a,b,c);if(code!=3) $fatal(1,"pixel fixture");sample(a,b,c);
            if(i%3==0) tick;
        end
        response;
    end
    w=6;h=4;off=0;inv=0;t=77;command;cv=0;
    for(i=0;i<8;i=i+1) sample(i,i==0,i%6==5);
    rst_n=0;tick;rst_n=1;repeat(10) tick;if(mv || rv || sr || !cr) $fatal(1,"capture reset");
    w=3;h=3;off=0;inv=0;t=1365;expected_error=0;expected_pixels=1;last_seen=0;command;
    for(i=0;i<9;i=i+1) sample(0,i==0,i%3==2);
    response;
    code=$fscanf(fo,"%d %d %d %d %d\n",ed,eso,eeo,ela,et);if(code==5 || mv) $fatal(1,"missing outputs");
    $display("ADAPTIVE_FRAME PASS outputs=%0d commands=%0d",outputs,commands);
    $fclose(fi);$fclose(fo);$finish;
end
initial begin #10000000;$fatal(1,"timeout");end
endmodule
