module tb_stream_window;
    parameter W=7,H=6,K=3,D=8,PAD=-1;
    localparam NI=W*H*3;
    localparam NO=(PAD>=0)?NI:((W>=K && H>=K)?(W-K+1)*(H-K+1)*3:0);
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, sv=0, su=0, sl=0, mr=0;
    reg [D-1:0] sd=0;
    wire sr,mv,mu,ml,err;
    wire [K*K*D-1:0] md;
    generate if(PAD<0) begin: valid_core
      stream_window #(.WIDTH(W),.HEIGHT(H),.K(K),.DATA_WIDTH(D)) dut
        (clk,rst_n,sd,sv,su,sl,sr,md,mv,mu,ml,mr,err);
    end else begin: padded_core
      stream_window_padded #(.WIDTH(W),.HEIGHT(H),.K(K),.DATA_WIDTH(D),.PAD_MODE(PAD)) dut
        (clk,rst_n,sd,sv,su,sl,sr,md,mv,mu,ml,mr,err);
    end endgenerate
    reg [D+1:0] input_mem[0:NI-1];
    reg [K*K*D+1:0] expected_mem[0:(NO>0?NO:1)-1];
    integer sent,received,cycles,epoch,i;
    reg [31:0] rng=32'hcafe1234;
    reg held;
    reg [K*K*D+1:0] held_word;
    reg [K*K*D+1:0] observed;
    reg mutation;
    reg mutate_order,mutate_count,mutate_sideband;
    integer accepted_at[0:NI-1];
    integer input_index,frame_index,ox,oy,prev_output_cycle;
    initial begin
        mutation=$test$plusargs("mutate");
        mutate_order=$test$plusargs("order");
        mutate_count=$test$plusargs("count");
        mutate_sideband=$test$plusargs("sideband");
        $readmemh("input.mem",input_mem);
        if(NO>0) $readmemh("expected.mem",expected_mem);
        for(epoch=0;epoch<3;epoch=epoch+1) begin
            @(negedge clk); rst_n=0;sv=0;mr=0;
            repeat(3) @(negedge clk);
            if(mv!==0 || err!==0) $fatal(1,"reset failed");
            rst_n=1; sent=0;received=0;cycles=0;held=0;prev_output_cycle=-1;
            while(sent<NI || received<NO || cycles<NI+10) begin
                rng=rng ^ (rng<<13);rng=rng ^ (rng>>17);rng=rng ^ (rng<<5);
                mr=(epoch==0)?1:((cycles%79<24)?0:rng[0]);
                if(!sv && sent<NI && (epoch==0 || rng[2])) begin
                    {su,sl,sd}=input_mem[sent]; sv=1;
                end
                @(posedge clk);
                if(held && {mu,ml,md}!==held_word) $fatal(1,"stalled payload changed");
                if(held && mv!==1) $fatal(1,"stalled valid dropped");
                held=mv&&!mr; held_word={mu,ml,md};
                if(mv&&mr) begin
                    observed={mu,ml,md};
                    if(mutation && received==0) observed=observed^1;
                    if(mutate_order && received==0 && NO>1) observed=expected_mem[1];
                    if(mutate_sideband && received==0) observed=observed^(1'b1<<(K*K*D+1));
                    if(received>=NO || observed!==expected_mem[received])
                        $fatal(1,"window mismatch output=%0d got=%h exp=%h",received,observed,expected_mem[received]);
                    if(epoch==0)begin
                        if(PAD<0)begin
                            frame_index=received/((W-K+1)*(H-K+1));
                            ox=received%(W-K+1);oy=(received/ (W-K+1))%(H-K+1);
                            input_index=frame_index*W*H+(oy+K-1)*W+ox+K-1;
                            if(cycles-accepted_at[input_index]!=2)$fatal(1,"VALID latency mismatch");
                        end else begin
                            ox=received%W;
                            if(received%(W*H)==0)begin
                              frame_index=received/(W*H);
                              if(cycles-accepted_at[frame_index*W*H] !=
                                 W*(1+((K/2<H-1)?K/2:H-1))+(K-1)*(W+K-1)+K-1+4)
                                $fatal(1,"PAD first latency mismatch got=%0d",cycles-accepted_at[frame_index*W*H]);
                            end
                        end
                        if(ox>0 && cycles-prev_output_cycle!=1)$fatal(1,"row II mismatch");
                        prev_output_cycle=cycles;
                    end
                    if(!(mutate_count && received==NO-1))received=received+1;
                end
                if(sv&&sr) begin
                    accepted_at[sent]=cycles;
                    if(epoch==0 && sent>0 && sent%(W*H)==0)begin
                        if(cycles-accepted_at[sent-W*H] !=
                           ((PAD<0)?W*H:(W*H+(W+K-1)*(H+K-1)+4)))
                            $fatal(1,"frame period mismatch");
                    end
                    sent=sent+1; @(negedge clk); sv=0;
                end
                else @(negedge clk);
                cycles=cycles+1;
                if(cycles>NI*100+1000) $fatal(1,"timeout");
            end
            sv=0;mr=1;
            repeat(8) begin
                @(posedge clk); if(mv) $fatal(1,"extra output");
                @(negedge clk);
            end
            if(err!==0) $fatal(1,"unexpected marker error");
            // Interrupt a held output, or a completed empty-region frame.
            // The next epoch resets controls but retains every RAM word.
            sent=0;cycles=0;mr=0;
            while(!mv && sent<NI)begin
                sv=1;{su,sl,sd}=input_mem[sent];
                @(posedge clk);if(sr)sent=sent+1;
                @(negedge clk);cycles=cycles+1;
                if(cycles>NI*100+1000)$fatal(1,"reset setup timeout");
            end
            sv=0;repeat(4)@(negedge clk);
        end
        // Explicit malformed SOF/EOL is sticky until synchronous reset.
        rst_n=0;sv=0; @(negedge clk);rst_n=1;sv=1;su=0;sl=0;mr=1;
        @(negedge clk);sv=0;
        if(err!==1) $fatal(1,"missing marker diagnostic");
        rst_n=0; @(negedge clk);
        if(err!==0 || mv!==0) $fatal(1,"diagnostic reset");
        $display("PASS window W=%0d H=%0d K=%0d D=%0d epochs=3 outputs/epoch=%0d",W,H,K,D,NO);
        $finish;
    end
endmodule
