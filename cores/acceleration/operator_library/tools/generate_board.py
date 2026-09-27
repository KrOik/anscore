"""Board harness, top, ROM and expectations for the accelerator groups.

Everything in board/expected.json is computed by the independent Python
model, including the timing-accounting fields:

  count        = 128 rows per unit
  max_latency  = max(4, longest core latency)      [hold_beats reaches 3]
  stalled      = sum over rows of max(0, hold - latency + 1)

The harness retires one row at a time, so a row issued at enabled beat B with
hold h on a core of latency L retires at B + max(h + 1, L) and burns
max(0, h - L + 1) stalled beats. That is arithmetic, not measurement.
"""
import json

from catalog import CORES
from generate_lib import ROOT, write
from golden import step, vectors
from groups import plan, ROWS_PER_CORE

HARNESS = '''// Generated wiring/ROM; expected data comes from the family models.
module acc_board_group_@GROUP@ #(parameter INJECT_ERROR=0)(
    input wire clk, rst_n,
    output reg done, output reg [7:0] pass_mask,
    output reg [31:0] errors, count, digest, max_latency,
    output reg [31:0] stalled_beats
);
reg [160:0] rom[0:@ROWS_MINUS_ONE@];
initial $readmemh("board/group_@GROUP@.mem",rom);
reg [160:0] word;
reg [9:0] addr;
reg [2:0] state;
reg [3:0] divider;
reg [31:0] beat, issue_beat, watch;
reg [1:0] hold_beats;
wire ce=(divider==15);
wire [2:0] unit=addr[9:7];
wire [31:0] a=word[160:129], b=word[128:97], c=word[96:65];
wire [7:0] ready,valid,err;
wire [255:0] results,auxs;
wire request=(state==2);
wire consume=(state==3 && hold_beats==0);
@INSTANCES@
wire [31:0] result=results[unit*32+:32];
wire [31:0] aux=auxs[unit*32+:32];
wire fault=err[unit];
wire bad=({result,aux,fault}!=word[64:0]) || (INJECT_ERROR && addr==0);
wire [31:0] latency=beat-issue_beat;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        addr<=0; state<=0; divider<=0; done<=0; pass_mask<=255;
        errors<=0; count<=0; digest<=0; max_latency<=0;
        stalled_beats<=0; beat<=0; issue_beat<=0; hold_beats<=0;
        word<=0; watch<=0;
    end else begin
        divider<=divider+1'b1;
        if(!done) begin
            watch<=watch+1;
            if(watch==32'd2000000) begin
                done<=1; errors<=errors+1; pass_mask<=0; state<=4;
            end else case(state)
                0: begin word<=rom[addr]; state<=1; end
                1: if(ce) state<=2;
                2: if(ce && ready[unit]) begin
                    issue_beat<=beat; hold_beats<=addr[1:0]; state<=3;
                end
                3: if(ce) begin
                    if(hold_beats!=0) begin
                        hold_beats<=hold_beats-1'b1;
                        if(valid[unit]) stalled_beats<=stalled_beats+1;
                    end else if(valid[unit]) begin
                        count<=count+1;
                        digest<={{digest[30:0],digest[31]}}^result^{{aux[24:0],aux[31:25]}}^{{31'd0,fault}};
                        if(latency>max_latency) max_latency<=latency;
                        if(bad) begin errors<=errors+1; pass_mask[unit]<=0; end
                        if(addr==@ROWS_MINUS_ONE@) begin done<=1; state<=4; end
                        else begin addr<=addr+1'b1; state<=0; end
                    end
                end
                default: state<=4;
            endcase
        end
        if(ce) beat<=beat+1;
    end
end
endmodule
'''

TOP = '''module acc_top #(parameter GROUP=0, parameter REPORT_DELAY=25000000)(
    input wire clk, output wire uart_tx, output wire [1:0] led
);
reg [15:0] por=0;
always @(posedge clk) if(!(&por)) por<=por+1'b1;
wire rst_n=&por;
wire done;
wire [7:0] pass_mask;
wire [31:0] errors,count,digest,max_latency,stalled_beats;
generate
@GROUPS@
endgenerate
assign led={(done && errors!=0), (done && pass_mask==8'hff && errors==0)};
reg [25:0] pace;
reg [6:0] char_index;
reg reporting;
wire tx_ready;
reg [7:0] tx_byte;
acc_uart_tx uart(.clk(clk),.rst_n(rst_n),.data(tx_byte),
    .valid(reporting),.ready(tx_ready),.tx(uart_tx));
function [7:0] hex;
input [3:0] nibble;
begin hex=(nibble<10)?8'd48+{4'd0,nibble}:8'd55+{4'd0,nibble}; end
endfunction
// Group label stays one byte wide for up to 36 groups: 0-9 then A-Z.
function [7:0] gchar;
input [15:0] g;
begin gchar=(g<10)?(8'd48+g[7:0]):(8'd55+g[7:0]); end
endfunction
always @* begin
    tx_byte=10;
    case(char_index)
@CHARS@
        default: tx_byte=10;
    endcase
end
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin pace<=0; char_index<=0; reporting<=0; end
    else if(done) begin
        if(!reporting) begin
            if(pace==REPORT_DELAY) begin pace<=0; char_index<=0; reporting<=1; end
            else pace<=pace+1'b1;
        end else if(tx_ready) begin
            if(char_index==@LAST@) begin reporting<=0; pace<=0; end
            else char_index<=char_index+1'b1;
        end
    end
end
endmodule
'''

UART = '''// 50 MHz / 115200 baud, 8N1. Board support, not a catalog IP.
module acc_uart_tx #(parameter BIT_CYCLES=434)(
 input wire clk,rst_n, input wire [7:0] data, input wire valid,
 output wire ready, output wire tx
);
reg [9:0] shift;
reg [8:0] timer;
reg [3:0] bits;
assign ready=(bits==0);
assign tx=(bits==0)?1'b1:shift[0];
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin shift<=1023; timer<=0; bits<=0; end
 else if(bits==0) begin
   if(valid) begin shift<={1'b1,data,1'b0}; timer<=BIT_CYCLES-1; bits<=10; end
 end else if(timer==0) begin
   timer<=BIT_CYCLES-1; shift<={1'b1,shift[9:1]}; bits<=bits-1'b1;
 end else timer<=timer-1'b1;
end
endmodule
'''

CST = '''IO_LOC "clk" E2;
IO_PORT "clk" PULL_MODE=NONE DRIVE=OFF BANK_VCCIO=3.3;
IO_LOC "uart_tx" C3;
IO_PORT "uart_tx" PULL_MODE=UP DRIVE=8 BANK_VCCIO=3.3;
IO_LOC "led[0]" E8;
IO_PORT "led[0]" PULL_MODE=UP DRIVE=8 BANK_VCCIO=3.3;
IO_LOC "led[1]" L6;
IO_PORT "led[1]" PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
'''


def rot(value, n):
    return ((value << n) | (value >> (32 - n))) & 0xffffffff


def stalled_for(latency):
    """Stalled beats contributed by one core over its 128 board rows."""
    return sum(ROWS_PER_CORE // 4 * max(0, hold - latency + 1) for hold in range(4))


def group_label(group):
    """One-byte UART group field: '0'-'9' then 'A'-'Z'."""
    assert 0 <= group < 36
    return str(group) if group < 10 else chr(ord('A') + group - 10)


def main():
    by_name = {entry['name']: entry for entry in CORES}
    expected = []
    for row in plan():
        group, units = row['group'], row['units']
        memory, digest, stalls = [], 0, 0
        instances = []
        for unit, entry in enumerate(row['entries']):
            name = entry['name']
            state = 0
            for a, b, c in vectors(name)[:ROWS_PER_CORE]:
                r, x, f, state = step(name, a, b, c, state)
                memory.append(f'{(a << 129)|(b << 97)|(c << 65)|(r << 33)|(x << 1)|f:041x}')
                digest = rot(digest, 1) ^ r ^ rot(x, 7) ^ f
            stalls += stalled_for(entry['latency'])
            instances.append(
                f'acc_{name} u{unit}(.clk(clk),.rst_n(rst_n),.clk_en(ce),'
                f'.in_valid(request && unit=={unit}),.in_ready(ready[{unit}]),'
                f'.a(a),.b(b),.c(c),.out_valid(valid[{unit}]),.out_ready(consume),'
                f'.result(results[{unit*32}+:32]),.aux(auxs[{unit*32}+:32]),'
                f'.fault(err[{unit}]));')
        assert len(memory) == row['rows']
        max_latency = max(4, max(by_name[n]['latency'] for n in row['names']))
        write(f'board/group_{group}.mem', '\n'.join(memory) + '\n')
        write(f'board/acc_board_group_{group}.v',
              HARNESS.replace('@GROUP@', str(group))
                     .replace('@ROWS_MINUS_ONE@', str(row['rows'] - 1))
                     .replace('@INSTANCES@', '\n'.join(instances)).replace('{{', '{').replace('}}', '}'))
        expected.append(dict(group=group, cores=row['names'], units=units,
                             vectors_per_core=ROWS_PER_CORE, mask='FF', errors=0,
                             count=row['rows'], digest=f'{digest:08X}',
                             max_latency=max_latency, stalled_beats=stalls))
        write(f'sim/tb_board_{group}.sv', f'''`timescale 1ns/1ps
module tb_board_{group};
reg clk=0; always #10 clk=~clk;
reg rst_n=0;
wire done; wire [7:0] pass_mask;
wire [31:0] errors,count,digest,max_latency,stalled_beats;
wire neg_done; wire [7:0] neg_mask;
wire [31:0] neg_errors,neg_count,neg_digest,neg_latency,neg_stalls;
acc_board_group_{group} dut(.*);
acc_board_group_{group} #(.INJECT_ERROR(1)) negative(.clk(clk),.rst_n(rst_n),
 .done(neg_done),.pass_mask(neg_mask),.errors(neg_errors),.count(neg_count),
 .digest(neg_digest),.max_latency(neg_latency),.stalled_beats(neg_stalls));
initial begin
 repeat(4) @(negedge clk); rst_n=1;
 wait(done && neg_done); #1;
 if(pass_mask!==8'hff || errors!==0 || count!=={row['rows']} || digest!==32'h{digest:08x}
    || max_latency!=={max_latency} || stalled_beats!=={stalls}) $fatal(1,"board group {group} failed");
 if(neg_mask!==8'hfe || neg_errors!==1 || neg_count!=={row['rows']}) $fatal(1,"negative detector failed");
 $display("PASS board group={group} units={units} mask=%h count=%d digest=%h latency=%d stalls=%d negative=PASS",pass_mask,count,digest,max_latency,stalled_beats);
 $finish;
end
initial begin #60000000; $fatal(1,"board timeout"); end
endmodule
''')
    fields = [('A25 G=', None), ('0', 'group'), (' M=', None), ('FF', 'pass_mask'),
              (' E=', None), ('00000000', 'errors'), (' N=', None), ('00000400', 'count'),
              (' D=', None), ('00000000', 'digest'), (' L=', None), ('00000004', 'max_latency'),
              (' S=', None), ('00000600', 'stalled_beats'), ('\r\n', None)]
    chars, pos = [], 0
    for literal, dynamic in fields:
        for k, char in enumerate(literal):
            if dynamic == 'group':
                expression = 'gchar(GROUP)'
            elif dynamic:
                expression = f'hex({dynamic}[{(len(literal)-k-1)*4}+:4])'
            else:
                expression = f"8'd{ord(char)}"
            chars.append(f'        {pos}: tx_byte={expression};')
            pos += 1
    groups = '\n'.join(
        f'if(GROUP=={row["group"]}) begin:g{row["group"]}\nacc_board_group_{row["group"]} st('
        '.clk(clk),.rst_n(rst_n),.done(done),.pass_mask(pass_mask),'
        '.errors(errors),.count(count),.digest(digest),'
        '.max_latency(max_latency),.stalled_beats(stalled_beats));\nend' for row in plan())
    write('board/acc_top.v', TOP.replace('@GROUPS@', groups).replace('@CHARS@', '\n'.join(chars))
                                 .replace('@LAST@', str(pos - 1)))
    write('board/acc_uart_tx.v', UART)
    write('board/tang25k.cst', CST)
    write('board/expected.json', json.dumps(expected, indent=2) + '\n')
    for expected_row in expected:
        group = expected_row['group']
        report = (f"A25 G={group_label(group)} M={expected_row['mask']} E=00000000 "
                  f"N={expected_row['count']:08X} D={expected_row['digest']} "
                  f"L={expected_row['max_latency']:08X} S={expected_row['stalled_beats']:08X}\r\n")
        encoded = ''.join(f'{byte:02x}' for byte in report.encode('ascii'))
        write(f'sim/tb_uart_{group}.sv', f'''`timescale 1ns/1ps
module tb_uart_{group};
reg clk=0; always #10 clk=~clk;
wire uart_tx; wire [1:0] led;
acc_top #(.GROUP({group}),.REPORT_DELAY(16)) dut(.*);
localparam [551:0] EXPECTED=552'h{encoded};
reg [7:0] value;
integer k,bit_index;
initial begin
    for(k=0;k<69;k=k+1) begin
        @(negedge uart_tx);
        repeat(651) @(posedge clk);
        #1; value[0]=uart_tx;
        for(bit_index=1;bit_index<8;bit_index=bit_index+1) begin
            repeat(434) @(posedge clk); #1; value[bit_index]=uart_tx;
        end
        repeat(434) @(posedge clk); #1;
        if(uart_tx!==1) $fatal(1,"UART stop bit failed");
        if(value!==EXPECTED[(68-k)*8+:8]) $fatal(1,"UART group{group} byte%0d got%h expected%h",k,value,EXPECTED[(68-k)*8+:8]);
    end
    if(led!==2'b01) $fatal(1,"UART LED verdict mismatch");
    $display("PASS UART group={group} bytes=69 115200 8N1"); $finish;
end
initial begin #90000000; $fatal(1,"UART timeout"); end
endmodule
''')
    total = sum(row['rows'] for row in plan())
    print(f'Generated {len(expected)} board groups covering {len(CORES)} cores; '
          f'{total} model-checked responses; CE=1/16')


if __name__ == '__main__':
    main()
