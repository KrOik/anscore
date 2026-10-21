"""Generate release files from authored kernels and independent models.

Run from any directory. Generation never imports or reads build evidence.
"""
import hashlib
import json
from pathlib import Path
from catalog import CORES
from golden import step, vectors

ROOT = Path(__file__).resolve().parents[1]


def write(rel, value):
    path = ROOT / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding='utf-8', newline='\n')


RTL = '''// Authored kernel. See ip/{name}/SPEC.md for exact semantics.
// Transfer on clk_en && valid && ready. Output and state freeze when !clk_en.
module prod_{name} (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire in_valid, output wire in_ready,
    input wire [31:0] a, b, c,
    output reg out_valid, input wire out_ready,
    output reg [31:0] result, aux, output reg fault
);
reg [95:0] state_r, state_n;
reg [31:0] r, x, temp, mask;
reg [32:0] ext;
reg [63:0] wide;
reg f;
integer i, j, idx;
assign in_ready = clk_en && (!out_valid || out_ready);
always @* begin
    r=0; x=0; f=0; temp=0; mask=0; ext=0; wide=0;
    i=0; j=0; idx=0; state_n=state_r;
    {body}
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
'''

BCD_PIPELINED = '''// Eight-digit BCD converter with two elastic pipeline stages.
// Latency=2 enabled edges, II=1. Registered 16-step double-dabble boundary.
module prod_bcd8_encode (
    input wire clk, rst_n, clk_en, in_valid, output wire in_ready,
    input wire [31:0] a,b,c, output reg out_valid, input wire out_ready,
    output reg [31:0] result, aux, output reg fault
);
reg stage_valid, stage_fault;
reg [63:0] stage_data;
reg [63:0] first, second;
integer i,j;
wire output_ready=(!out_valid || out_ready);
assign in_ready=clk_en && (!stage_valid || output_ready);
always @* begin
    first={32'd0,a};
    second=stage_data;
    for(i=0;i<16;i=i+1) begin
        for(j=0;j<8;j=j+1) begin
            if(first[32+j*4+:4]>=5) first[32+j*4+:4]=first[32+j*4+:4]+4'd3;
            if(second[32+j*4+:4]>=5) second[32+j*4+:4]=second[32+j*4+:4]+4'd3;
        end
        first=first<<1; second=second<<1;
    end
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        stage_valid<=0; stage_fault<=0; stage_data<=0;
        out_valid<=0; result<=0; aux<=0; fault<=0;
    end else if(clk_en) begin
        if(output_ready) begin
            out_valid<=stage_valid;
            if(stage_valid) begin
                result<=stage_fault?32'd0:second[63:32]; aux<=0; fault<=stage_fault;
            end
        end
        if(in_ready) begin
            stage_valid<=in_valid;
            if(in_valid) begin stage_data<=first; stage_fault<=(a>99999999); end
        end
    end
end
endmodule
'''

TB = '''`timescale 1ns/1ps
module tb_{name};
reg clk=0; always #5 clk=~clk;
reg rst_n=0, clk_en=0, in_valid=0, out_ready=0;
reg [31:0] a=0,b=0,c=0;
wire in_ready,out_valid,fault;
wire [31:0] result,aux;
prod_{name} dut(.*);
localparam N={count};
localparam LATENCY={latency};
reg [160:0] vec[0:N-1];
reg [31:0] rng=32'h18252056;
reg held=0; reg [64:0] held_word;
integer sent,received,cycles,phase;
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
        rng={{rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]}};
        clk_en=!randomized || (rng[1:0]!=0);
        out_ready=!randomized || (rng[4:2]!=0);
        in_valid=(sent<N) && (!randomized || in_valid || rng[6]);
        if(sent<N) {{a,b,c}}=vec[sent][160:65];
        @(posedge clk);
        if(held && ({{result,aux,fault}}!==held_word || out_valid!==1))
            $fatal(1,"{name} changed pending output at cycle %0d",cycles);
        if(clk_en && out_valid && out_ready) begin
            if({{result,aux,fault}} !== vec[received][64:0])
                $fatal(1,"{name} row %0d got %h expected %h",received,{{result,aux,fault}},vec[received][64:0]);
            received=received+1;
        end
        held=out_valid && (!clk_en || !out_ready);
        held_word={{result,aux,fault}};
        if(clk_en && in_valid && in_ready) begin
            sent=sent+1;
            if(prior_accept) consecutive=consecutive+1;
            prior_accept=1;
        end else prior_accept=0;
        if(out_valid && !out_ready && clk_en) stalls=stalls+1;
        if(!clk_en) pauses=pauses+1;
        cycles=cycles+1;
        if(cycles>N*25) $fatal(1,"{name} timeout");
    end
    @(negedge clk); in_valid=0; clk_en=1; out_ready=1;
    repeat(2) @(posedge clk);
    #1; if(out_valid!==0) $fatal(1,"{name} unexpected duplicate output");
end
endtask
initial begin
    $readmemh("vectors/{name}.mem",vec);
    reset_dut; run_vectors(0);
    reset_dut; run_vectors(1);
    // Drop a pending response with asynchronous reset while CE is disabled.
    @(negedge clk); clk_en=1; in_valid=1; out_ready=0; {{a,b,c}}=vec[0][160:65];
    repeat(LATENCY) @(posedge clk); #1;
    if(out_valid!==1) $fatal(1,"{name} pending setup failed");
    @(negedge clk); clk_en=0; rst_n=0;
    #1; if(out_valid!==0 || {{result,aux,fault}}!==65'd0) $fatal(1,"{name} reset failed");
    reset_dut; run_vectors(1);
    if(stalls==0 || pauses==0 || consecutive<N-1) $fatal(1,"{name} vacuous protocol coverage");
    $display("PASS {name} vectors=%0d phases=3 stalls=%0d pauses=%0d",N,stalls,pauses);
    $finish;
end
endmodule
'''


def main():
    rows = []
    for number, entry in enumerate(CORES):
        name = entry['name']
        latency = entry.get('latency', 1)
        rtl = BCD_PIPELINED if name == 'bcd8_encode' else RTL.format(**entry)
        write(f'rtl/prod_{name}.v', rtl)
        state = 0
        vv = []
        for a, b, c in vectors(name):
            r, x, f, state = step(name, a, b, c, state)
            packed = (a << 129) | (b << 97) | (c << 65) | (r << 33) | (x << 1) | f
            vv.append(f'{packed:041x}')
        write(f'vectors/{name}.mem', '\n'.join(vv)+'\n')
        write(f'sim/tb_{name}.sv', TB.format(name=name, count=len(vv), latency=latency))
        manifest = dict(schema='production-ip-v1', ip_name=name,
                        core_module='prod_'+name, family=entry['family'],
                        version='1.0.0', interface='enabled-ready-valid-32x3-v1',
                        source=f'rtl/prod_{name}.v', dependencies=[],
                        stateful=entry['stateful'], description=entry['spec'],
                        clock_domain='single', latency_enabled_cycles=latency,
                        initiation_interval_enabled_cycles=1,
                        reference_model='tools/golden.py:step',
                        testbench=f'sim/tb_{name}.sv', vector_count=len(vv),
                        vector_sha256=hashlib.sha256(('\n'.join(vv)+'\n').encode()).hexdigest(),
                        rtl_sha256=hashlib.sha256(rtl.encode()).hexdigest(),
                        board_group=number//8, validation=dict(simulation='run-required', synthesis='run-required', board='run-required'),
                        provenance='original source authored in this workspace; no third-party RTL imported',
                        qualification='engineering candidate; not certified production or side-channel protection')
        write(f'ip/{name}/manifest.json', json.dumps(manifest, indent=2)+'\n')
        write(f'ip/{name}/files.f', f'../../rtl/prod_{name}.v\n')
        write(f'ip/{name}/SPEC.md', f'# {name}\n\n{entry["spec"]}\n\n'
              'See [common interface](../../doc/INTERFACE.md). '
              f'Latency: {latency} enabled edge(s); II=1 when output ready. '
              'Only accepted transactions update state. '\
              'Reset clears pending output and state, even while CE is zero.\n\n'
              f'Independent model: `step("{name}", a, b, c, state)`. '
              f'Test vectors: {len(vv)}. No additional RTL dependencies.\n')
        rows.append(manifest)
    write('catalog.json', json.dumps(dict(count=56, device='GW5A-LV25MG121NES',
                                        budget=dict(lut_class=15000, dsp_class=4), cores=rows), indent=2)+'\n')
    write('doc/CATALOG.md', '# IP catalog\n\n| ID | Family | Core | Exact function |\n|---|---|---|---|\n'+
          '\n'.join(f'| {i+1:02d} | {e["family"]} | [{e["name"]}](../ip/{e["name"]}/SPEC.md) | {e["spec"]} |'
                    for i, e in enumerate(CORES))+'\n')
    print(f'Generated {len(rows)} independent RTL cores, manifests, models and benches')


if __name__ == '__main__':
    main()
