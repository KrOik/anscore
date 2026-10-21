`timescale 1ns/1ps
module tb_geo_inverse_map_bounds;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,clk_en=1,s_valid=0,m_ready=0;
    wire s_ready,m_valid;
    reg [15:0] s_x=0,s_y=0,s_src_width=1,s_src_height=1;
    reg s_sof=0,s_eol=0,s_eof=0;
    reg [3:0] s_mode=0;
    reg [15:0] s_dst_width=1,s_dst_height=1;
    reg signed [31:0] s_h00=0,s_h01=0,s_h02=0;
    reg signed [31:0] s_h10=0,s_h11=0,s_h12=0;
    reg signed [31:0] s_h20=0,s_h21=0,s_h22=0;
    wire [23:0] m_x_q8,m_y_q8;
    wire m_border;
    wire [3:0] m_error;
    wire m_sof,m_eol,m_eof;

    img_geo_inverse_map dut (.*);

    task automatic check(input [23:0] want_x,input [23:0] want_y,
                        input want_border,input [3:0] want_error);
        reg [55:0] held;
        reg [3:0] checked_mode;
        reg checked_sof, checked_eol, checked_eof;
        reg [15:0] saved_x, saved_y, saved_sw, saved_sh, saved_dw, saved_dh;
        reg expect_division;
        integer wait_cycles;
        begin
            checked_mode=s_mode;
            checked_sof=s_sof; checked_eol=s_eol; checked_eof=s_eof;
            saved_x=s_x; saved_y=s_y;
            saved_sw=s_src_width; saved_sh=s_src_height;
            saved_dw=s_dst_width; saved_dh=s_dst_height;
            expect_division=(want_error==0) &&
                            ((checked_mode==1) || (checked_mode==8));
            @(negedge clk); s_valid=1; m_ready=0;
            do @(posedge clk); while (!(clk_en && s_ready));
            @(negedge clk); s_valid=0;
            if (expect_division) begin
                // The divider must use its accepted operands and markers even
                // when upstream changes every input while it is busy.
                if (s_ready) $fatal(1,"divider accepted a second input while busy");
                s_mode=4'd15; s_x=0; s_y=0;
                s_src_width=0; s_src_height=0; s_dst_width=0; s_dst_height=0;
                s_sof=~checked_sof; s_eol=~checked_eol; s_eof=~checked_eof;
                // The global CE freezes the iterative divider and retains the
                // busy/ready contract until enabled clocks resume.
                clk_en=0;
                repeat(3) begin
                    @(posedge clk); #1;
                    if (s_ready || m_valid)
                        $fatal(1,"CE pause changed busy divider handshake state");
                end
                @(negedge clk); clk_en=1;
                wait_cycles=0;
                while (!m_valid) begin
                    if (s_ready) $fatal(1,"divider ready asserted while busy");
                    @(posedge clk); #1; wait_cycles=wait_cycles+1;
                    if (wait_cycles>116) $fatal(1,"divider response exceeded 116 clocks");
                end
                if (wait_cycles!=116)
                    $fatal(1,"divider latency=%0d expected=116 mode=%0d",wait_cycles,checked_mode);
            end else if (!m_valid) begin
                $fatal(1,"non-dividing response was not registered on acceptance mode=%0d",checked_mode);
            end
            if ({m_x_q8,m_y_q8,m_border,m_error,m_sof,m_eol,m_eof} !==
                {want_x,want_y,want_border,want_error,checked_sof,checked_eol,checked_eof})
                $fatal(1,"mapping mismatch mode=%0d got=%h/%h/%b/%h expected=%h/%h/%b/%h",
                    checked_mode,m_x_q8,m_y_q8,m_border,m_error,
                    want_x,want_y,want_border,want_error);
            held={m_x_q8,m_y_q8,m_border,m_error,m_sof,m_eol,m_eof};
            repeat(3) begin
                @(posedge clk);
                if (!m_valid || {m_x_q8,m_y_q8,m_border,m_error,m_sof,m_eol,m_eof} !== held)
                    $fatal(1,"mapping output did not hold under backpressure");
            end
            @(negedge clk); m_ready=1;
            do @(posedge clk); while (!(m_valid && m_ready));
            @(negedge clk); m_ready=0;
            if (expect_division) begin
                s_mode=checked_mode; s_x=saved_x; s_y=saved_y;
                s_src_width=saved_sw; s_src_height=saved_sh;
                s_dst_width=saved_dw; s_dst_height=saved_dh;
                s_sof=checked_sof; s_eol=checked_eol; s_eof=checked_eof;
            end
        end
    endtask

    reg [63:0] reference_x,reference_y;
    initial begin
        repeat(3) @(negedge clk); rst_n=1;

        // Maximum legal coordinates and dimensions exercise the narrowed
        // 40-bit Q8 scale numerator without overflow.
        s_mode=1; s_x=16'd65534; s_y=16'd65533;
        s_src_width=16'd65535; s_src_height=16'd65535;
        s_dst_width=16'd65535; s_dst_height=16'd65535;
        s_sof=1; s_eol=0; s_eof=0;
        check(24'hFFFE00,24'hFFFD00,0,0);

        // Non-integer scale uses the exact quotient, including the low Q8 bits.
        s_x=16'd32767; s_y=16'd16383;
        s_src_width=16'd65535; s_src_height=16'd50003;
        s_dst_width=16'd32768; s_dst_height=16'd16384;
        reference_x=((64'd32767*65535)<<8)/32768;
        reference_y=((64'd16383*50003)<<8)/16384;
        s_sof=0; s_eol=1; s_eof=0;
        check(reference_x[23:0],reference_y[23:0],0,0);

        // Maximum-size identity homography validates signed product sums and
        // the narrowed 50-bit projective numerator/denominator.
        s_mode=8; s_x=16'd65534; s_y=16'd65533;
        s_src_width=16'd65535; s_src_height=16'd65535;
        s_dst_width=16'd65535; s_dst_height=16'd65535;
        s_h00=32'sd65536; s_h01=0; s_h02=0;
        s_h10=0; s_h11=32'sd65536; s_h12=0;
        s_h20=0; s_h21=0; s_h22=32'sd65536;
        check(24'hFFFE00,24'hFFFD00,0,0);

        // Signed numerator and denominator with matching negative signs must
        // preserve the positive identity coordinate.
        s_h00=-32'sd65536; s_h11=-32'sd65536; s_h22=-32'sd65536;
        check(24'hFFFE00,24'hFFFD00,0,0);

        // Opposite numerator/denominator signs must produce negative source
        // coordinates and the documented border result.
        s_h00=32'sd65536; s_h02=0;
        s_h11=32'sd65536; s_h12=0; s_h22=-32'sd65536;
        check(0,0,1,0);

        // Just outside the image remains the documented border result.
        s_h00=32'sd65536; s_h02=32'sd65536;
        s_h11=32'sd65536; s_h12=32'sd65536; s_h22=32'sd65536;
        check(0,0,1,0);

        // Preserve explicit divide-by-zero and unsupported-operation errors.
        s_h00=32'sd65536; s_h01=0; s_h02=0;
        s_h10=0; s_h11=32'sd65536; s_h12=0;
        s_h20=0; s_h21=0; s_h22=0;
        check(0,0,1,4);
        s_mode=15;
        check(0,0,1,3);

        // CE contract: ready may remain high while clk_en is low, but the
        // transfer is frozen. Holding valid/payload through the pause causes
        // exactly one acceptance when enabled clocks resume.
        @(negedge clk);
        s_mode=0; s_x=0; s_y=0;
        s_src_width=1; s_src_height=1; s_dst_width=1; s_dst_height=1;
        s_sof=1; s_eol=1; s_eof=1;
        s_valid=1; m_ready=0; clk_en=0;
        repeat(3) begin
            @(posedge clk); #1;
            if (!s_ready || m_valid)
                $fatal(1,"CE pause did not keep ready high while freezing acceptance");
        end
        @(negedge clk); clk_en=1;
        @(posedge clk); #1;
        if (!m_valid || m_error!=0 || m_border!=0 || m_x_q8!=0 || m_y_q8!=0 ||
            {m_sof,m_eol,m_eof}!==3'b111)
            $fatal(1,"held CE-paused input was not accepted exactly on resume");
        @(negedge clk); s_valid=0; m_ready=1;
        @(posedge clk); #1;
        if (m_valid) $fatal(1,"CE test output did not retire");
        @(negedge clk); m_ready=0;

        $display("PASS tb_geo_inverse_map_bounds");
        $finish;
    end
endmodule
