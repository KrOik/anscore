`timescale 1ns/1ps
// One bounded end-to-end group regression; independent integer image references.
module tb_img_mf_frame_group;
    localparam W=6,H=5,N=W*H,CW=W+2,CH=H+2;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,clk_en=1,select_auto=0;
    integer cycle=0;
    reg cmd_valid=0;reg [3:0] cmd_opcode=0;reg [15:0] cmd_frameid=0;
    reg s_valid=0,aux_valid=0;reg [23:0] s_data=0,aux_data=0;
    reg s_sof=0,s_eol=0,aux_sof=0,aux_eol=0;reg [15:0] s_tag=0,aux_tag=0,s_frameid=0,aux_frameid=0;
    reg [8:0] weight=128;reg key_enable=0;reg [23:0] key=0;
    reg [7:0] threshold=50;reg [3:0] bg_shift=1;reg bg_freeze=0;
    reg m_ready=1,rsp_ready=1;
    wire a_cmd_ready,b_cmd_ready,a_s_ready,b_s_ready,a_aux_ready,b_aux_ready;
    wire a_rsp_valid,b_rsp_valid,a_rsp_done,b_rsp_done;wire [7:0] a_rsp_error,b_rsp_error,a_error,b_error;
    wire [3:0] a_rsp_opcode,b_rsp_opcode;wire [15:0] a_rsp_frameid,b_rsp_frameid;
    wire a_m_valid,b_m_valid,a_m_sof,b_m_sof,a_m_eol,b_m_eol,a_foreground;
    wire [23:0] a_m_data,b_m_data;wire [15:0] a_m_tag,b_m_tag,a_m_frameid,b_m_frameid;
    wire [7:0] a_m_error,b_m_error;wire [1:0] a_frames,b_frames;
    wire signed [15:0] dx,dy;wire [47:0] cost,confidence;wire [31:0] cw,ch;
    wire cmd_ready=select_auto?b_cmd_ready:a_cmd_ready;
    wire s_ready=select_auto?b_s_ready:a_s_ready;
    wire aux_ready=select_auto?b_aux_ready:a_aux_ready;
    wire rsp_valid=select_auto?b_rsp_valid:a_rsp_valid;
    wire [7:0] rsp_error=select_auto?b_rsp_error:a_rsp_error;
    wire m_valid=select_auto?b_m_valid:a_m_valid;
    wire [23:0] m_data=select_auto?b_m_data:a_m_data;
    wire m_sof=select_auto?b_m_sof:a_m_sof,m_eol=select_auto?b_m_eol:a_m_eol;
    wire [15:0] m_tag=select_auto?b_m_tag:a_m_tag,m_frameid=select_auto?b_m_frameid:a_m_frameid;
    wire [7:0] m_error=select_auto?b_m_error:a_m_error;
    img_mf_frame_application #(.WIDTH(W),.HEIGHT(H),.CAPTURE_TIMEOUT(40)) app (
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(cmd_valid && !select_auto),.cmd_ready(a_cmd_ready),.cmd_opcode(cmd_opcode),.cmd_frameid(cmd_frameid),
        .cfg_weight(weight),.cfg_key_enable(key_enable),.cfg_key(key),.cfg_threshold(threshold),.cfg_bg_shift(bg_shift),.cfg_bg_freeze(bg_freeze),
        .rsp_valid(a_rsp_valid),.rsp_ready(rsp_ready),.rsp_done(a_rsp_done),.rsp_opcode(a_rsp_opcode),.rsp_frameid(a_rsp_frameid),.rsp_error(a_rsp_error),.error_code(a_error),
        .s_valid(s_valid && !select_auto),.s_ready(a_s_ready),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),.s_tag(s_tag),.s_frameid(s_frameid),
        .aux_valid(aux_valid && !select_auto),.aux_ready(a_aux_ready),.aux_data(aux_data),.aux_sof(aux_sof),.aux_eol(aux_eol),.aux_tag(aux_tag),.aux_frameid(aux_frameid),
        .m_valid(a_m_valid),.m_ready(m_ready),.m_data(a_m_data),.m_foreground(a_foreground),.m_sof(a_m_sof),.m_eol(a_m_eol),.m_tag(a_m_tag),.m_frameid(a_m_frameid),.m_error(a_m_error),.frames_valid(a_frames)
    );
    img_mf_auto_stitch #(.WIDTH(W),.HEIGHT(H),.MAX_SHIFT(1),.CAPTURE_TIMEOUT(40)) stitch (
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(cmd_valid && select_auto),.cmd_ready(b_cmd_ready),.cmd_opcode(cmd_opcode),.cmd_frameid(cmd_frameid),
        .cfg_aux_weight(weight),.cfg_background(24'h030303),
        .cfg_h00(32'sd1),.cfg_h01(32'sd0),.cfg_h02(32'sd1),.cfg_h10(32'sd0),.cfg_h11(32'sd1),.cfg_h12(32'sd0),.cfg_h20(32'sd0),.cfg_h21(32'sd0),.cfg_h22(32'sd1),
        .rsp_valid(b_rsp_valid),.rsp_ready(rsp_ready),.rsp_done(b_rsp_done),.rsp_opcode(b_rsp_opcode),.rsp_frameid(b_rsp_frameid),.rsp_error(b_rsp_error),.error_code(b_error),
        .s_valid(s_valid && select_auto),.s_ready(b_s_ready),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),.s_tag(s_tag),.s_frameid(s_frameid),
        .aux_valid(aux_valid && select_auto),.aux_ready(b_aux_ready),.aux_data(aux_data),.aux_sof(aux_sof),.aux_eol(aux_eol),.aux_tag(aux_tag),.aux_frameid(aux_frameid),
        .m_valid(b_m_valid),.m_ready(m_ready),.m_data(b_m_data),.m_sof(b_m_sof),.m_eol(b_m_eol),.m_tag(b_m_tag),.m_frameid(b_m_frameid),.m_error(b_m_error),
        .frames_valid(b_frames),.registration_dx(dx),.registration_dy(dy),.registration_cost(cost),.registration_confidence(confidence),.canvas_width(cw),.canvas_height(ch)
    );
    integer pixels0[0:N-1],pixels1[0:N-1],bg[0:N-1];
    integer seen=0,expect_mode=0,expect_frame=0;
    integer i,x,y,a,b,e,delta,px,py,ax,ay;
    reg [23:0] expected_rgb;
    reg expected_foreground;
    reg held=0;reg [65:0] held_payload;
    wire [65:0] payload={m_data,m_sof,m_eol,m_tag,m_frameid,m_error};
    always @(negedge clk) if (rst_n) begin
        cycle=cycle+1;clk_en=(cycle%7!=0 && cycle%7!=1);m_ready=(cycle%4!=0);
    end
    always @(posedge clk) if (rst_n) begin
        if (held && (!m_valid || payload!==held_payload)) $fatal(1,"output changed under stall");
        held=m_valid && (!clk_en || !m_ready);held_payload=payload;
        if (clk_en && m_valid && m_ready) begin
            if (expect_mode==0) $fatal(1,"unexpected output outside process");
            expected_foreground=0;
            if (expect_mode==10) begin
                px=seen%CW-1;py=seen/CW-1;ax=px+1;ay=py;
                a=-1;b=-1;
                if (px>=0 && px<W && py>=0 && py<H) a=pixels0[py*W+px];
                if (ax>=0 && ax<W && ay>=0 && ay<H) b=pixels1[ay*W+ax];
                if (a>=0 && b>=0) e=(a*(256-weight)+b*weight+128)/256;
                else if (a>=0) e=a;else if (b>=0) e=b;else e=3;
            end else begin
                a=pixels0[seen];b=pixels1[seen];
                case (expect_mode)
                    3: e=(key_enable && b==key[7:0])?a:(a*(256-weight)+b*weight+128)/256;
                    4: begin e=a>=b?a-b:b-a;expected_foreground=e>threshold;end
                    5: begin
                        e=a;delta=a-bg[seen]/256;if (delta<0) delta=-delta;
                        expected_foreground=delta>threshold;
                    end
                    6: e=(a*(256-weight)+b*weight+128)/256;
                    default: e=0;
                endcase
            end
            expected_rgb={e[7:0],e[7:0],e[7:0]};
            if (m_data!==expected_rgb || m_error!==0 || m_tag!==seen || m_frameid!==expect_frame ||
                m_sof!==(seen==0) || m_eol!==((seen%((expect_mode==10)?CW:W))==((expect_mode==10)?CW-1:W-1)))
                $fatal(1,"pixel mode=%0d index=%0d got=%h expected=%h tag=%d frame=%d error=%h",expect_mode,seen,m_data,expected_rgb,m_tag,m_frameid,m_error);
            if (!select_auto && a_foreground!==expected_foreground) $fatal(1,"foreground mismatch");
            seen=seen+1;
        end
    end
    task issue;
        input [3:0] opcode;input [15:0] frame;
        begin
            @(negedge clk);cmd_opcode=opcode;cmd_frameid=frame;cmd_valid=1;
            begin: wait_cmd
                forever begin @(posedge clk);if (clk_en && cmd_ready) disable wait_cmd;end
            end
            @(negedge clk);cmd_valid=0;
        end
    endtask
    task response;
        input [7:0] expected_error;
        begin
            begin: wait_rsp
                forever begin
                    @(posedge clk);
                    if (clk_en && rsp_valid && rsp_ready) begin
                        if (rsp_error!==expected_error) $fatal(1,"response got %h expected %h",rsp_error,expected_error);
                        disable wait_rsp;
                    end
                end
            end
            @(negedge clk);
        end
    endtask
    task capture;
        input integer kind;input [15:0] frame;input integer background_capture;
        integer index,base,extra;
        begin
            issue(kind,frame);
            for (index=0;index<N;index=index+1) begin
                @(negedge clk);
                base=pixels0[index];extra=background_capture?20:pixels1[index];
                s_data={base[7:0],base[7:0],base[7:0]};
                aux_data=background_capture?{8'd0,extra[7:0],8'd0}:{extra[7:0],extra[7:0],extra[7:0]};
                s_tag=index;aux_tag=index;s_frameid=frame;aux_frameid=frame;
                s_sof=index==0;aux_sof=index==0;s_eol=index%W==W-1;aux_eol=index%W==W-1;
                s_valid=kind!=1;aux_valid=kind!=0;
                begin: wait_pixel
                    forever begin
                        @(posedge clk);
                        if (clk_en && ((kind==1)||(s_valid && s_ready)) && ((kind==0)||(aux_valid && aux_ready))) disable wait_pixel;
                    end
                end
            end
            @(negedge clk);s_valid=0;aux_valid=0;response(0);
        end
    endtask
    task process_frame;
        input integer opcode;input integer expected_mode;input integer frame;
        begin
            seen=0;expect_mode=expected_mode;expect_frame=frame;
            issue(opcode,frame);response(0);
            if (seen!=((expected_mode==10)?CW*CH:N)) $fatal(1,"incomplete frame count=%0d",seen);
            expect_mode=0;
        end
    endtask
    initial begin
        for (i=0;i<N;i=i+1) begin
            x=i%W;y=i/W;pixels0[i]=30+(x*71+y*43+x*y*19)%180;
        end
        for (i=0;i<N;i=i+1) begin
            x=i%W;pixels1[i]=x==0?17:pixels0[i-1];bg[i]=20*256;
        end
        repeat (4) @(negedge clk);rst_n=1;
        issue(6,1);response(8'h04); // uninitialized frames fail explicitly
        capture(2,11,0);
        process_frame(6,6,12);
        key_enable=1;key={3{8'd17}};weight=192;
        process_frame(3,3,13);
        process_frame(4,4,14);
        issue(8,15);response(0); // initialize Q8.8 background from main, no caller-provided history
        for (i=0;i<N;i=i+1) begin
            bg[i]=pixels0[i]*256;
            if (app.store_i.mem1[i]!==bg[i]) $fatal(1,"background initialization mismatch");
        end
        process_frame(5,5,15);
        for (i=0;i<N;i=i+1) bg[i]=20*256;
        capture(1,15,1);
        process_frame(5,5,16);
        for (i=0;i<N;i=i+1) begin
            delta=pixels0[i]*256-bg[i];bg[i]=bg[i]+(delta>>>1);
            if (app.store_i.mem1[i]!==bg[i]) $fatal(1,"background writeback mismatch index %d",i);
        end
        process_frame(5,5,17); // reads the first update, not the captured background
        weight=300;issue(6,18);response(8'h08);weight=128;
        select_auto=1;
        capture(2,21,0);
        process_frame(3,10,22);
        if (dx!==16'sd1 || dy!==16'sd0 || cost!==0 || confidence==0 || cw!=CW || ch!=CH)
            $fatal(1,"registration result dx=%0d dy=%0d cost=%0d confidence=%0d",dx,dy,cost,confidence);
        process_frame(4,10,23); // explicitly supplied inverse homography path
        rsp_ready=0;issue(15,24);
        repeat (12) begin
            @(negedge clk);
            if (!b_rsp_valid || b_rsp_error!==8'h80 || b_rsp_opcode!==15 || b_rsp_frameid!==24)
                $fatal(1,"response changed under backpressure");
        end
        rsp_ready=1;response(8'h80);
        for (i=0;i<N;i=i+1) begin pixels0[i]=42;pixels1[i]=42;end
        capture(2,24,0);
        issue(3,24);response(8'h20); // ambiguous flat image must not claim registration
        issue(0,25);response(8'h02); // finite capture starvation response
        // Reset discards frame validity; stale frame RAM must never be replayed.
        @(negedge clk);rst_n=0;held=0;
        repeat (3) @(negedge clk);rst_n=1;
        issue(3,26);response(8'h04);
        $display("MF GROUP PASS: capture, OSD, diff, EWMA writeback/reuse, fusion, SAD+warp, homography, CE/backpressure, errors/reset");
        $finish;
    end
    initial begin #1000000;$fatal(1,"group watchdog");end
endmodule
