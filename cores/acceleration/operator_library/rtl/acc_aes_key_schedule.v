// Authored kernel. See ip/aes_key_schedule/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_aes_key_schedule (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire in_valid, output wire in_ready,
    input wire [31:0] a, b, c,
    output reg out_valid, input wire out_ready,
    output reg [31:0] result, aux, output reg fault
);
reg [255:0] state_r, state_n;
reg [31:0] r, x, temp, mask, pa, pb, pc, ph, pl;
reg [32:0] ext;
reg [63:0] wide, wide2;
reg signed [63:0] swide, swide2;
reg signed [31:0] sa, sb, sc;
reg [95:0] data;
reg f;
integer i, j, idx, lane, sh;

assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    if(c[30] || c[29:8] != 0) begin
    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;
end else if(c[31]) begin
    case(c[1:0])
        2'd0: begin wide = {state_r[63:32], a}; wide2 = state_r[127:64]; end
        2'd1: begin wide = {a, state_r[31:0]}; wide2 = state_r[127:64]; end
        2'd2: begin wide = state_r[63:0]; wide2 = {state_r[127:96], a}; end
        default: begin wide = state_r[63:0]; wide2 = {a, state_r[95:64]}; end
    endcase
    state_n = {128'd0, wide2, wide};
    r = a; x = 32'h8000_0000 | c[1:0];
end else if(c[7:0] < 8'd4 || c[7:0] > 8'h2b) begin
    f = 1'b1; r = 32'd0; x = 32'd0; state_n = state_r;
end else begin
    x = 32'd0;
    pa = state_r[31:0];
    pb = state_r[127:96];
    if(c[1:0] == 2'd0) begin
        temp = (pa >> 8) | (pa << 24);
        for(lane = 0; lane < 4; lane = lane + 1) begin
            case(lane)
                0: mask = {24'd0, temp[7:0]};
                1: mask = {24'd0, temp[15:8]};
                2: mask = {24'd0, temp[23:16]};
                default: mask = {24'd0, temp[31:24]};
            endcase
            x[lane] = (mask == 32'd0);
        case(mask[7:0])
            8'h00: pa = 8'h63;
            8'h01: pa = 8'h7c;
            8'h02: pa = 8'h77;
            8'h03: pa = 8'h7b;
            8'h04: pa = 8'hf2;
            8'h05: pa = 8'h6b;
            8'h06: pa = 8'h6f;
            8'h07: pa = 8'hc5;
            8'h08: pa = 8'h30;
            8'h09: pa = 8'h01;
            8'h0a: pa = 8'h67;
            8'h0b: pa = 8'h2b;
            8'h0c: pa = 8'hfe;
            8'h0d: pa = 8'hd7;
            8'h0e: pa = 8'hab;
            8'h0f: pa = 8'h76;
            8'h10: pa = 8'hca;
            8'h11: pa = 8'h82;
            8'h12: pa = 8'hc9;
            8'h13: pa = 8'h7d;
            8'h14: pa = 8'hfa;
            8'h15: pa = 8'h59;
            8'h16: pa = 8'h47;
            8'h17: pa = 8'hf0;
            8'h18: pa = 8'had;
            8'h19: pa = 8'hd4;
            8'h1a: pa = 8'ha2;
            8'h1b: pa = 8'haf;
            8'h1c: pa = 8'h9c;
            8'h1d: pa = 8'ha4;
            8'h1e: pa = 8'h72;
            8'h1f: pa = 8'hc0;
            8'h20: pa = 8'hb7;
            8'h21: pa = 8'hfd;
            8'h22: pa = 8'h93;
            8'h23: pa = 8'h26;
            8'h24: pa = 8'h36;
            8'h25: pa = 8'h3f;
            8'h26: pa = 8'hf7;
            8'h27: pa = 8'hcc;
            8'h28: pa = 8'h34;
            8'h29: pa = 8'ha5;
            8'h2a: pa = 8'he5;
            8'h2b: pa = 8'hf1;
            8'h2c: pa = 8'h71;
            8'h2d: pa = 8'hd8;
            8'h2e: pa = 8'h31;
            8'h2f: pa = 8'h15;
            8'h30: pa = 8'h04;
            8'h31: pa = 8'hc7;
            8'h32: pa = 8'h23;
            8'h33: pa = 8'hc3;
            8'h34: pa = 8'h18;
            8'h35: pa = 8'h96;
            8'h36: pa = 8'h05;
            8'h37: pa = 8'h9a;
            8'h38: pa = 8'h07;
            8'h39: pa = 8'h12;
            8'h3a: pa = 8'h80;
            8'h3b: pa = 8'he2;
            8'h3c: pa = 8'heb;
            8'h3d: pa = 8'h27;
            8'h3e: pa = 8'hb2;
            8'h3f: pa = 8'h75;
            8'h40: pa = 8'h09;
            8'h41: pa = 8'h83;
            8'h42: pa = 8'h2c;
            8'h43: pa = 8'h1a;
            8'h44: pa = 8'h1b;
            8'h45: pa = 8'h6e;
            8'h46: pa = 8'h5a;
            8'h47: pa = 8'ha0;
            8'h48: pa = 8'h52;
            8'h49: pa = 8'h3b;
            8'h4a: pa = 8'hd6;
            8'h4b: pa = 8'hb3;
            8'h4c: pa = 8'h29;
            8'h4d: pa = 8'he3;
            8'h4e: pa = 8'h2f;
            8'h4f: pa = 8'h84;
            8'h50: pa = 8'h53;
            8'h51: pa = 8'hd1;
            8'h52: pa = 8'h00;
            8'h53: pa = 8'hed;
            8'h54: pa = 8'h20;
            8'h55: pa = 8'hfc;
            8'h56: pa = 8'hb1;
            8'h57: pa = 8'h5b;
            8'h58: pa = 8'h6a;
            8'h59: pa = 8'hcb;
            8'h5a: pa = 8'hbe;
            8'h5b: pa = 8'h39;
            8'h5c: pa = 8'h4a;
            8'h5d: pa = 8'h4c;
            8'h5e: pa = 8'h58;
            8'h5f: pa = 8'hcf;
            8'h60: pa = 8'hd0;
            8'h61: pa = 8'hef;
            8'h62: pa = 8'haa;
            8'h63: pa = 8'hfb;
            8'h64: pa = 8'h43;
            8'h65: pa = 8'h4d;
            8'h66: pa = 8'h33;
            8'h67: pa = 8'h85;
            8'h68: pa = 8'h45;
            8'h69: pa = 8'hf9;
            8'h6a: pa = 8'h02;
            8'h6b: pa = 8'h7f;
            8'h6c: pa = 8'h50;
            8'h6d: pa = 8'h3c;
            8'h6e: pa = 8'h9f;
            8'h6f: pa = 8'ha8;
            8'h70: pa = 8'h51;
            8'h71: pa = 8'ha3;
            8'h72: pa = 8'h40;
            8'h73: pa = 8'h8f;
            8'h74: pa = 8'h92;
            8'h75: pa = 8'h9d;
            8'h76: pa = 8'h38;
            8'h77: pa = 8'hf5;
            8'h78: pa = 8'hbc;
            8'h79: pa = 8'hb6;
            8'h7a: pa = 8'hda;
            8'h7b: pa = 8'h21;
            8'h7c: pa = 8'h10;
            8'h7d: pa = 8'hff;
            8'h7e: pa = 8'hf3;
            8'h7f: pa = 8'hd2;
            8'h80: pa = 8'hcd;
            8'h81: pa = 8'h0c;
            8'h82: pa = 8'h13;
            8'h83: pa = 8'hec;
            8'h84: pa = 8'h5f;
            8'h85: pa = 8'h97;
            8'h86: pa = 8'h44;
            8'h87: pa = 8'h17;
            8'h88: pa = 8'hc4;
            8'h89: pa = 8'ha7;
            8'h8a: pa = 8'h7e;
            8'h8b: pa = 8'h3d;
            8'h8c: pa = 8'h64;
            8'h8d: pa = 8'h5d;
            8'h8e: pa = 8'h19;
            8'h8f: pa = 8'h73;
            8'h90: pa = 8'h60;
            8'h91: pa = 8'h81;
            8'h92: pa = 8'h4f;
            8'h93: pa = 8'hdc;
            8'h94: pa = 8'h22;
            8'h95: pa = 8'h2a;
            8'h96: pa = 8'h90;
            8'h97: pa = 8'h88;
            8'h98: pa = 8'h46;
            8'h99: pa = 8'hee;
            8'h9a: pa = 8'hb8;
            8'h9b: pa = 8'h14;
            8'h9c: pa = 8'hde;
            8'h9d: pa = 8'h5e;
            8'h9e: pa = 8'h0b;
            8'h9f: pa = 8'hdb;
            8'ha0: pa = 8'he0;
            8'ha1: pa = 8'h32;
            8'ha2: pa = 8'h3a;
            8'ha3: pa = 8'h0a;
            8'ha4: pa = 8'h49;
            8'ha5: pa = 8'h06;
            8'ha6: pa = 8'h24;
            8'ha7: pa = 8'h5c;
            8'ha8: pa = 8'hc2;
            8'ha9: pa = 8'hd3;
            8'haa: pa = 8'hac;
            8'hab: pa = 8'h62;
            8'hac: pa = 8'h91;
            8'had: pa = 8'h95;
            8'hae: pa = 8'he4;
            8'haf: pa = 8'h79;
            8'hb0: pa = 8'he7;
            8'hb1: pa = 8'hc8;
            8'hb2: pa = 8'h37;
            8'hb3: pa = 8'h6d;
            8'hb4: pa = 8'h8d;
            8'hb5: pa = 8'hd5;
            8'hb6: pa = 8'h4e;
            8'hb7: pa = 8'ha9;
            8'hb8: pa = 8'h6c;
            8'hb9: pa = 8'h56;
            8'hba: pa = 8'hf4;
            8'hbb: pa = 8'hea;
            8'hbc: pa = 8'h65;
            8'hbd: pa = 8'h7a;
            8'hbe: pa = 8'hae;
            8'hbf: pa = 8'h08;
            8'hc0: pa = 8'hba;
            8'hc1: pa = 8'h78;
            8'hc2: pa = 8'h25;
            8'hc3: pa = 8'h2e;
            8'hc4: pa = 8'h1c;
            8'hc5: pa = 8'ha6;
            8'hc6: pa = 8'hb4;
            8'hc7: pa = 8'hc6;
            8'hc8: pa = 8'he8;
            8'hc9: pa = 8'hdd;
            8'hca: pa = 8'h74;
            8'hcb: pa = 8'h1f;
            8'hcc: pa = 8'h4b;
            8'hcd: pa = 8'hbd;
            8'hce: pa = 8'h8b;
            8'hcf: pa = 8'h8a;
            8'hd0: pa = 8'h70;
            8'hd1: pa = 8'h3e;
            8'hd2: pa = 8'hb5;
            8'hd3: pa = 8'h66;
            8'hd4: pa = 8'h48;
            8'hd5: pa = 8'h03;
            8'hd6: pa = 8'hf6;
            8'hd7: pa = 8'h0e;
            8'hd8: pa = 8'h61;
            8'hd9: pa = 8'h35;
            8'hda: pa = 8'h57;
            8'hdb: pa = 8'hb9;
            8'hdc: pa = 8'h86;
            8'hdd: pa = 8'hc1;
            8'hde: pa = 8'h1d;
            8'hdf: pa = 8'h9e;
            8'he0: pa = 8'he1;
            8'he1: pa = 8'hf8;
            8'he2: pa = 8'h98;
            8'he3: pa = 8'h11;
            8'he4: pa = 8'h69;
            8'he5: pa = 8'hd9;
            8'he6: pa = 8'h8e;
            8'he7: pa = 8'h94;
            8'he8: pa = 8'h9b;
            8'he9: pa = 8'h1e;
            8'hea: pa = 8'h87;
            8'heb: pa = 8'he9;
            8'hec: pa = 8'hce;
            8'hed: pa = 8'h55;
            8'hee: pa = 8'h28;
            8'hef: pa = 8'hdf;
            8'hf0: pa = 8'h8c;
            8'hf1: pa = 8'ha1;
            8'hf2: pa = 8'h89;
            8'hf3: pa = 8'h0d;
            8'hf4: pa = 8'hbf;
            8'hf5: pa = 8'he6;
            8'hf6: pa = 8'h42;
            8'hf7: pa = 8'h68;
            8'hf8: pa = 8'h41;
            8'hf9: pa = 8'h99;
            8'hfa: pa = 8'h2d;
            8'hfb: pa = 8'h0f;
            8'hfc: pa = 8'hb0;
            8'hfd: pa = 8'h54;
            8'hfe: pa = 8'hbb;
            8'hff: pa = 8'h16;
            default: pa = 8'h00;
        endcase
            case(lane)
                0: pc[7:0] = pa[7:0];
                1: pc[15:8] = pa[7:0];
                2: pc[23:16] = pa[7:0];
                default: pc[31:24] = pa[7:0];
            endcase
        end
        case(c[7:0])
            8'd4: pl = 32'h00000001;
            8'd8: pl = 32'h00000002;
            8'd12: pl = 32'h00000004;
            8'd16: pl = 32'h00000008;
            8'd20: pl = 32'h00000010;
            8'd24: pl = 32'h00000020;
            8'd28: pl = 32'h00000040;
            8'd32: pl = 32'h00000080;
            8'd36: pl = 32'h0000001b;
            8'd40: pl = 32'h00000036;
            default: pl = 32'd0;
        endcase
        pc = pc ^ pl;
        pa = pc;
        x[16] = 1'b1;
    end
    r = pa ^ pb;
    state_n = {128'd0, state_r[95:0], r};
    x = x | (c[7:0] << 8);
end
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        out_valid<=0; result<=0; aux<=0; fault<=0; state_r<=0;
    end else if(clk_en) begin
        if(in_ready) begin
            out_valid<=in_valid;
            if(in_valid) begin
                result<=r; aux<=x; fault<=f; state_r<=state_n;
            end
        end
    end
end
endmodule
