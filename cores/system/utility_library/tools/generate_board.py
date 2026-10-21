"""Eight-core hardware groups, each with 128 independently modeled vectors/core."""
import json
from catalog import CORES
from generate import ROOT, write
from golden import step, vectors


def rot(v, n):
    return ((v << n) | (v >> (32-n))) & 0xffffffff


HARNESS = '''// Generated wiring/ROM; expected data is from tools/golden.py.
module prod_board_group_{group} #(parameter INJECT_ERROR=0)(
    input wire clk, rst_n,
    output reg done, output reg [7:0] pass_mask,
    output reg [31:0] errors, count, digest, max_latency,
    output reg [31:0] stalled_beats
);
reg [160:0] rom[0:1023];
initial $readmemh("board/group_{group}.mem",rom);
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
{instances}
wire [31:0] result=results[unit*32+:32];
wire [31:0] aux=auxs[unit*32+:32];
wire fault=err[unit];
wire bad=({{result,aux,fault}}!=word[64:0]) || (INJECT_ERROR && addr==0);
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
            if(watch==32'd1000000) begin
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
                        if(addr==1023) begin done<=1; state<=4; end
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

TOP = '''module prod_top #(parameter GROUP=0, parameter REPORT_DELAY=25000000)(
    input wire clk, output wire uart_tx, output wire [1:0] led
);
reg [15:0] por=0;
always @(posedge clk) if(!(&por)) por<=por+1'b1;
wire rst_n=&por;
wire done;
wire [7:0] pass_mask;
wire [31:0] errors,count,digest,max_latency,stalled_beats;
generate
{groups}
endgenerate
assign led={{(done && errors!=0), (done && pass_mask==255 && errors==0)}};
reg [25:0] pace;
reg [6:0] char_index;
reg reporting;
wire tx_ready;
reg [7:0] tx_byte;
prod_uart_tx uart(.clk(clk),.rst_n(rst_n),.data(tx_byte),
    .valid(reporting),.ready(tx_ready),.tx(uart_tx));
function [7:0] hex;
input [3:0] nibble;
begin hex=(nibble<10)?8'd48+{{4'd0,nibble}}:8'd55+{{4'd0,nibble}}; end
endfunction
always @* begin
    tx_byte=10;
    case(char_index)
{chars}
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
            if(char_index=={last}) begin reporting<=0; pace<=0; end
            else char_index<=char_index+1'b1;
        end
    end
end
endmodule
'''

UART = '''// 50 MHz / 115200 baud, 8N1. Separate reusable board support, not counted IP.
module prod_uart_tx #(parameter BIT_CYCLES=434)(
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


def main():
    expected = []
    for group in range(7):
        instances, memory = [], []
        digest = 0
        for idx, entry in enumerate(CORES[group*8:group*8+8]):
            name = entry['name']
            state = 0
            for a, b, c in vectors(name)[:128]:
                r, x, f, state = step(name, a, b, c, state)
                memory.append(f'{(a << 129)|(b << 97)|(c << 65)|(r << 33)|(x << 1)|f:041x}')
                digest = rot(digest, 1)^r^rot(x, 7)^f
            instances.append(f'prod_{name} u{idx}(.clk(clk),.rst_n(rst_n),.clk_en(ce),'
                             f'.in_valid(request && unit=={idx}),.in_ready(ready[{idx}]),'
                             f'.a(a),.b(b),.c(c),.out_valid(valid[{idx}]),.out_ready(consume),'
                             f'.result(results[{idx*32}+:32]),.aux(auxs[{idx*32}+:32]),.fault(err[{idx}]));')
        assert len(memory) == 1024
        write(f'board/group_{group}.mem', '\n'.join(memory)+'\n')
        write(f'board/prod_board_group_{group}.v', HARNESS.format(group=group, instances='\n'.join(instances)))
        expected.append(dict(group=group, cores=[e['name'] for e in CORES[group*8:group*8+8]],
                             vectors_per_core=128, mask='FF', errors=0, count=1024,
                             digest=f'{digest:08X}', max_latency=4,
                             stalled_beats=1440 if group==2 else 1536))
        bench = f'''`timescale 1ns/1ps
module tb_board_{group};
reg clk=0; always #10 clk=~clk;
reg rst_n=0;
wire done; wire [7:0] pass_mask;
wire [31:0] errors,count,digest,max_latency,stalled_beats;
wire neg_done; wire [7:0] neg_mask;
wire [31:0] neg_errors,neg_count,neg_digest,neg_latency,neg_stalls;
prod_board_group_{group} dut(.*);
prod_board_group_{group} #(.INJECT_ERROR(1)) negative(.clk(clk),.rst_n(rst_n),
 .done(neg_done),.pass_mask(neg_mask),.errors(neg_errors),.count(neg_count),
 .digest(neg_digest),.max_latency(neg_latency),.stalled_beats(neg_stalls));
initial begin
 repeat(4) @(negedge clk); rst_n=1;
 wait(done && neg_done); #1;
 if(pass_mask!==8'hff || errors!==0 || count!==1024 || digest!==32'h{digest:08x}
    || max_latency!==4 || stalled_beats!=={1440 if group==2 else 1536}) $fatal(1,"board group {group} failed");
 if(neg_mask!==8'hfe || neg_errors!==1 || neg_count!==1024) $fatal(1,"negative detector failed");
 $display("PASS board group={group} mask=%h count=%d digest=%h latency=%d stalls=%d negative=PASS",pass_mask,count,digest,max_latency,stalled_beats);
 $finish;
end
initial begin #25000000; $fatal(1,"board timeout"); end
endmodule
'''
        write(f'sim/tb_board_{group}.sv', bench)
    # UART report layout is specified by literal fields + dynamic numeric slots.
    fields = [('P25 G=', None), ('0', 'group'), (' M=', None), ('FF', 'pass_mask'),
              (' E=', None), ('00000000', 'errors'), (' N=', None), ('00000400', 'count'),
              (' D=', None), ('00000000', 'digest'), (' L=', None), ('00000004', 'max_latency'),
              (' S=', None), ('00000600', 'stalled_beats'), ('\r\n', None)]
    chars = []
    pos = 0
    for literal, dynamic in fields:
        for k, char in enumerate(literal):
            if dynamic == 'group':
                expression = '8\'d48+GROUP'
            elif dynamic:
                expression = f'hex({dynamic}[{(len(literal)-k-1)*4}+:4])'
            else:
                expression = f"8'd{ord(char)}"
            chars.append(f"        {pos}: tx_byte={expression};")
            pos += 1
    groups = '\n'.join(f'if(GROUP=={g}) begin:g{g}\nprod_board_group_{g} st('
                        '.clk(clk),.rst_n(rst_n),.done(done),.pass_mask(pass_mask),'
                        '.errors(errors),.count(count),.digest(digest),'
                        '.max_latency(max_latency),.stalled_beats(stalled_beats));\nend' for g in range(7))
    write('board/prod_top.v', TOP.format(groups=groups, chars='\n'.join(chars), last=pos-1))
    write('board/prod_uart_tx.v', UART)
    write('board/tang25k.cst', '''IO_LOC "clk" E2;
IO_PORT "clk" PULL_MODE=NONE DRIVE=OFF BANK_VCCIO=3.3;
IO_LOC "uart_tx" C3;
IO_PORT "uart_tx" PULL_MODE=UP DRIVE=8 BANK_VCCIO=3.3;
IO_LOC "led[0]" E8;
IO_PORT "led[0]" PULL_MODE=UP DRIVE=8 BANK_VCCIO=3.3;
IO_LOC "led[1]" L6;
IO_PORT "led[1]" PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
''')
    write('board/expected.json', json.dumps(expected, indent=2)+'\n')
    for group, expected_group in enumerate(expected):
        report = (f'P25 G={group} M=FF E=00000000 N=00000400 '
                  f'D={expected_group["digest"]} L=00000004 S={expected_group["stalled_beats"]:08X}\r\n')
        encoded = ''.join(f'{byte:02x}' for byte in report.encode('ascii'))
        write(f'sim/tb_uart_{group}.sv', f'''`timescale 1ns/1ps
module tb_uart_{group};
reg clk=0; always #10 clk=~clk;
wire uart_tx; wire [1:0] led;
prod_top #(.GROUP({group}),.REPORT_DELAY(16)) dut(.*);
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
initial begin #25000000; $fatal(1,"UART timeout"); end
endmodule
''')
    print('Generated seven board groups; 7168 checked responses; CE=1/16')


if __name__ == '__main__':
    main()
