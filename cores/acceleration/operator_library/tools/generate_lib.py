"""Shared templates and emission helpers for accelerator core generation."""
import re
from pathlib import Path

from golden import tables

ROOT = Path(__file__).resolve().parents[1]
STATE_BITS = 256

# Tokens are replaced literally: Verilog is full of braces that str.format eats.
RTL = '''// Authored kernel. See ip/@@NAME@@/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module acc_@@NAME@@ (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire in_valid, output wire in_ready,
    input wire [31:0] a, b, c,
    output reg out_valid, input wire out_ready,
    output reg [31:0] result, aux, output reg fault
);
reg [@@STATE_MSB@@:0] state_r, state_n;
reg [31:0] r, x, temp, mask, pa, pb, pc, ph, pl;
reg [32:0] ext;
reg [63:0] wide, wide2;
reg signed [63:0] swide, swide2;
reg signed [31:0] sa, sb, sc;
reg [95:0] data;
reg f;
integer i, j, idx, lane, sh;
@@DECL@@
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; pa=0; pb=0; pc=0; ph=0; pl=0;
    ext=0; wide=0; wide2=0; swide=0; swide2=0; data={a,b,c};
    sa=$signed(a); sb=$signed(b); sc=$signed(c);
    i=0; j=0; idx=0; lane=0; sh=0; state_n=state_r;
    @@BODY@@
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        out_valid<=0; result<=0; aux<=0; fault<=0; state_r<=0;
    end else if(clk_en) begin
        if(in_ready) begin
            out_valid<=in_valid;
            if(in_valid) begin
                result<=r; aux<=x; fault<=f;@@STATE_UPDATE@@
            end
        end
    end
end
endmodule
'''

TB = '''`timescale 1ns/1ps
module tb_@@NAME@@;
reg clk=0; always #5 clk=~clk;
reg rst_n=0, clk_en=0, in_valid=0, out_ready=0;
reg [31:0] a=0,b=0,c=0;
wire in_ready,out_valid,fault;
wire [31:0] result,aux;
acc_@@NAME@@ dut(.*);
localparam N=@@COUNT@@;
localparam LATENCY=@@LATENCY@@;
reg [160:0] vec[0:N-1];
reg [31:0] rng=32'h250ACCE5;
reg held=0; reg [64:0] held_word;
integer sent,received,cycles;
integer stalls=0, pauses=0, consecutive=0;
reg prior_accept=0;
task reset_dut;
begin
    @(negedge clk); rst_n=0; in_valid=0; clk_en=0; out_ready=0;
    repeat(3) @(posedge clk);
    @(negedge clk); rst_n=1;
    sent=0; received=0; cycles=0; held=0; prior_accept=0;
end
endtask
task run_vectors;
input integer randomized;
begin
    while(received<N) begin
        @(negedge clk);
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        clk_en=!randomized || (rng[1:0]!=0);
        out_ready=!randomized || (rng[4:2]!=0);
        in_valid=(sent<N) && (!randomized || in_valid || rng[6]);
        if(sent<N) {a,b,c}=vec[sent][160:65];
        @(posedge clk);
        if(held && ({result,aux,fault}!==held_word || out_valid!==1))
            $fatal(1,"@@NAME@@ changed pending output at cycle %0d",cycles);
        if(clk_en && out_valid && out_ready) begin
            if({result,aux,fault} !== vec[received][64:0])
                $fatal(1,"@@NAME@@ row %0d got %h expected %h",
                       received,{result,aux,fault},vec[received][64:0]);
            received=received+1;
        end
        held=out_valid && (!clk_en || !out_ready);
        held_word={result,aux,fault};
        if(clk_en && in_valid && in_ready) begin
            sent=sent+1;
            if(prior_accept) consecutive=consecutive+1;
            prior_accept=1;
        end else prior_accept=0;
        if(out_valid && !out_ready && clk_en) stalls=stalls+1;
        if(!clk_en) pauses=pauses+1;
        cycles=cycles+1;
        if(cycles>N*40) $fatal(1,"@@NAME@@ timeout");
    end
    @(negedge clk); in_valid=0; clk_en=1; out_ready=1;
    repeat(LATENCY+2) @(posedge clk);
    #1; if(out_valid!==0) $fatal(1,"@@NAME@@ unexpected duplicate output");
end
endtask
initial begin
    $readmemh("vectors/@@NAME@@.mem",vec);
    reset_dut; run_vectors(0);
    reset_dut; run_vectors(1);
    // Drop a pending response with asynchronous reset while CE is disabled.
    @(negedge clk); clk_en=1; in_valid=1; out_ready=0; {a,b,c}=vec[0][160:65];
    repeat(LATENCY) @(posedge clk); #1;
    if(out_valid!==1) $fatal(1,"@@NAME@@ pending setup failed");
    @(negedge clk); clk_en=0; rst_n=0;
    #1; if(out_valid!==0 || {result,aux,fault}!==65'd0) $fatal(1,"@@NAME@@ reset failed");
    reset_dut; run_vectors(1);
    if(stalls==0 || pauses==0 || consecutive<N-1) $fatal(1,"@@NAME@@ vacuous protocol coverage");
    $display("PASS @@NAME@@ vectors=%0d phases=3 stalls=%0d pauses=%0d",N,stalls,pauses);
    $finish;
end
endmodule
'''


def write(rel, value):
    path = ROOT / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_text(encoding='utf-8') != value:
        path.write_text(value, encoding='utf-8', newline='\n')
    return path


def emit_rom(entry):
    image = entry.get('rom')
    if not image:
        return ''
    words = tables(entry['name'])[image['suffix']]
    width = image['width']
    assert all(0 <= v < (1 << width) for v in words), f'{entry["name"]}: {image["suffix"]} overflows {width} bits'
    digits = (width + 3) // 4
    write(f'tables/{entry["name"]}_{image["suffix"]}.mem',
          '\n'.join(f'{v:0{digits}x}' for v in words) + '\n')
    return (f'// Image generated from the family model; read combinationally here.\n'
            f'reg [{width-1}:0] {image["name"]} [0:{len(words)-1}];\n'
            f'initial $readmemh("tables/{entry["name"]}_{image["suffix"]}.mem", {image["name"]});\n')


def kernel_of(entry):
    name = entry['name']
    if entry.get('module'):
        assert f'module acc_{name}' in entry['module'], f'{name}: custom module header missing'
        assert entry['module'].rstrip().endswith('endmodule'), f'{name}: custom module trailer'
        return entry['module'].rstrip() + '\n'
    decl = (emit_rom(entry) + entry['decl'].rstrip('\n')).strip('\n')
    body = re.sub(r'\n\s*\n', '\n', entry['body'].strip())
    assert 'posedge' not in body and 'negedge' not in body, \
        f'{name}: template kernels are combinational; use module= for clocked logic'
    rtl = (RTL.replace('@@NAME@@', name)
              .replace('@@STATE_MSB@@', str(STATE_BITS - 1))
              .replace('@@STATE_UPDATE@@', ' state_r<=state_n;' if entry['stateful'] else '')
              .replace('@@DECL@@', decl)
              .replace('@@BODY@@', body))
    assert '@@' not in rtl, f'{name}: unresolved template token'
    return rtl
