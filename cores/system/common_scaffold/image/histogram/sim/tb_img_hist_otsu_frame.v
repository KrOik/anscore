module tb_img_hist_otsu_frame;
parameter WIDTH=5,HEIGHT=3,COUNT_W=8,INVALID=0;
localparam N=WIDTH*HEIGHT;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,cv=0,sv=0,sof=0,eol=0,mr=0,dr=0,invert=0;
reg [15:0] tag=0;
reg [7:0] gray=0;
wire cr,sr,mv,mo,me,ml,dv,de,busy;
wire [7:0] mg,ec,threshold;
wire [COUNT_W-1:0] dc;
wire [15:0] mt,dt;
img_hist_otsu_frame #(.FRAME_WIDTH(WIDTH),.FRAME_HEIGHT(HEIGHT),.COUNT_WIDTH(COUNT_W)) dut
 (clk,rst_n,ce,cv,cr,tag,invert,sv,sr,gray,sof,eol,mv,mr,mg,mo,me,ml,mt,dv,dr,de,ec,threshold,dc,dt,busy);
reg [1023:0] folder;
integer fi,fo,code,a,b,c,d,i,cycles=0,outputs=0,commands=0;
integer mc,eg,eso,eeo,ela,et,eth,expected_tag,expected_threshold,expected_error;
reg held=0,last_seen=0;
reg [7:0] held_gray,held_threshold;
reg held_sof,held_eol,held_last;
reg [15:0] held_tag;
task tick;begin @(posedge clk);#1;@(negedge clk);#1;end endtask
always @(negedge clk) begin cycles=cycles+1;ce=cycles%11!=3;mr=cycles%9>2;end
always @(posedge clk) begin
    if(rst_n) begin
        if(held && (!mv || mg!==held_gray || mo!==held_sof || me!==held_eol || ml!==held_last || mt!==held_tag || threshold!==held_threshold))
            $fatal(1,"Otsu frame stalled output changed");
        if(ce && mv && mr) begin
            if(INVALID) $fatal(1,"output on invalid parameters");
            mc=$fscanf(fo,"%d %d %d %d %d %d\n",eg,eso,eeo,ela,et,eth);
            if(mc!=6 || mg!==eg[7:0] || mo!==eso[0] || me!==eeo[0] || ml!==ela[0] || mt!==et[15:0] || threshold!==eth[7:0])
                $fatal(1,"Otsu frame output %0d gray=%0d expected=%0d threshold=%0d expected=%0d",outputs,mg,eg,threshold,eth);
            outputs=outputs+1;if(ml) last_seen=1;
        end
        held=mv && !(ce && mr);held_gray=mg;held_sof=mo;held_eol=me;held_last=ml;held_tag=mt;held_threshold=threshold;
    end else held=0;
end
task command(input [15:0] t,input inv);
begin cv=1;tag=t;invert=inv;#1;while(!cr || !ce) tick;tick;cv=0;invert=~invert;tag=~tag;end endtask
task sample(input [7:0] pixel,input first,input line_end);
begin sv=1;gray=pixel;sof=first;eol=line_end;#1;while(!sr || !ce) tick;tick;sv=0;end endtask
task response;
integer waits;
begin
    waits=0;while(!dv && waits<300000) begin tick;waits=waits+1;end
    repeat(7) begin
        if(!dv || de!==(expected_error!=0) || ec!==expected_error[7:0] || dt!==expected_tag[15:0] || cr || sr)
            $fatal(1,"Otsu frame response cmd=%0d code=%0d expected=%0d",commands,ec,expected_error);
        if(dc!==(INVALID?0:N)) $fatal(1,"Otsu frame count");
        if(!expected_error && (threshold!==expected_threshold[7:0] || !last_seen)) $fatal(1,"early/incorrect done");
        tick;
    end
    dr=1;while(!ce) tick;tick;dr=0;if(dv || !cr) $fatal(1,"done did not retire");commands=commands+1;
end endtask
initial begin
    repeat(2) tick;rst_n=1;#1;if(sr || mv || dv || !cr) $fatal(1,"idle state");
    if(INVALID) begin
        expected_tag=31;expected_error=1;command(31,1);response;
        $display("OTSU_FRAME INVALID PASS");$finish;
    end
    if(!$value$plusargs("folder=%s",folder)) $fatal(1,"fixtures required");
    fi=$fopen($sformatf("%0s/input.txt",folder),"r");fo=$fopen($sformatf("%0s/expected.txt",folder),"r");
    if(!fi || !fo) $fatal(1,"fixtures missing");
    while(!$feof(fi)) begin
        code=$fscanf(fi,"%d %d %d %d\n",a,expected_tag,expected_threshold,expected_error);if(code!=4) $fatal(1,"command fixture");
        command(expected_tag,a);last_seen=0;
        for(i=0;i<N;i=i+1) begin
            code=$fscanf(fi,"%d %d %d\n",a,b,c);if(code!=3) $fatal(1,"pixel fixture");sample(a,b,c);
            if(i%3==0) tick;
        end
        response;
    end
    if(mv) $fatal(1,"unexpected pending output");
    command(77,0);
    while(!sr) tick;
    // Reset before capture to check cancellation without relying on RAM clearing.
    rst_n=0;tick;rst_n=1;repeat(10) tick;if(mv || dv || sr || !cr) $fatal(1,"capture reset");
    command(78,0);for(i=0;i<N;i=i+1) sample(i,i==0,i%WIDTH==WIDTH-1);
    repeat(50) tick;rst_n=0;tick;rst_n=1;
    repeat(100) tick;if(mv || dv || sr || !cr) $fatal(1,"processing reset");
    expected_tag=1365;expected_threshold=0;expected_error=0;last_seen=0;
    command(1365,0);for(i=0;i<N;i=i+1) sample(0,i==0,i%WIDTH==WIDTH-1);
    response;
    code=$fscanf(fo,"%d %d %d %d %d %d\n",eg,eso,eeo,ela,et,eth);if(code==6 || mv) $fatal(1,"missing recovery outputs");
    $display("OTSU_FRAME PASS outputs=%0d commands=%0d",outputs,commands);
    $fclose(fi);$fclose(fo);$finish;
end
initial begin #100000000;$fatal(1,"timeout");end
endmodule
