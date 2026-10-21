"""Independent RAW14 bit-basis, byte fixture and elastic stream oracle."""
import hashlib
import random
import tempfile
from pathlib import Path
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

TB = r'''
`timescale 1ns/1ps
module tb;
parameter MODE=@MODE@,NI=@NI@,NO=@NO@;
localparam IW=MODE?8:14,OW=MODE?14:8,IG=MODE?7:4,OG=MODE?4:7;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,sv=0,ss=0,se=0,mr=0;reg[IW-1:0]sd=0;
wire sr,mv,ms,me,pe,ev;wire[OW-1:0]md;wire[7:0]ec;wire[31:0]cnt;
generate if(MODE==0)begin
raw14_pack d(clk,rst_n,ce,sd,sv,ss,se,sr,md,mv,ms,me,mr,pe,ev,1'b0,ec,cnt);
end else begin
raw14_unpack d(clk,rst_n,ce,sd,sv,ss,se,sr,md,mv,ms,me,mr,pe,ev,1'b0,ec,cnt);
end endgenerate
reg[IW-1:0]input_values[0:NI-1];reg[OW-1:0]expected[0:NO-1];
integer i=0,o=0,cycles=0,held_cycles=0;reg held=0;reg[OW+1:0]held_value;
always @(negedge clk)if(rst_n)begin
 cycles=cycles+1;ce=cycles%9!=0&&cycles%9!=1;mr=cycles%11>2;
 sv=i<NI&&cycles%7!=0;sd=i<NI?input_values[i]:0;ss=i==0;se=i%IG==IG-1;
end
always @(posedge clk)if(rst_n)begin
 if(held&&(!mv||{ms,me,md}!==held_value))$fatal(1,"held stream changed");
 held<=mv&&!(ce&&mr);held_value<={ms,me,md};
 if(mv&&!(ce&&mr))held_cycles<=held_cycles+1;
 if(sv&&sr&&ce)i<=i+1;
 if(mv&&mr&&ce)begin
  if(o>=NO||md!==expected[o]||ms!==(o==0)||me!==(o%OG==OG-1))
   $fatal(1,"RAW14 oracle mode%0d token%0d got%h expected%h",MODE,o,md,expected[o]);
  o<=o+1;
 end
 if(pe||ev||cnt)$fatal(1,"unexpected protocol fault");
 if(o==NO)begin
  if(i!=NI||held_cycles==0)$fatal(1,"totals");
  $display("PASS RAW14_BIT_BASIS mode=%0d input=%0d output=%0d held=%0d",MODE,i,o,held_cycles);$finish;
 end
end
initial begin $readmemh("input.hex",input_values);$readmemh("expected.hex",expected);repeat(3)@(posedge clk);#1;rst_n=1;end
initial begin #1000000;$fatal(1,"watchdog");end
endmodule
'''


def pack(values):
    # Treat the four LSB sextets as one integer, independent of RTL slices.
    low = sum((v % 64) * 64**i for i, v in enumerate(values))
    return [v // 64 for v in values] + list(low.to_bytes(3, 'little'))


def main():
    group = PACKAGE/'image/raw14_codec'
    sources = [group/'raw14_pack.sv', group/'raw14_unpack.sv']
    frozen = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    fixture = [0x1234, 0x2abc, 0x3f01, 0xff]
    assert pack(fixture) == [0x48, 0xaa, 0xfc, 3, 0x34, 0x1f, 0xfc]
    groups = [fixture, [0]*4, [16383]*4]
    for bit in range(56):
        basis = [0]*4
        basis[bit//14] = 1 << (bit%14)
        groups += [basis, [16383 ^ v for v in basis]]
    rng = random.Random(0x14ba515)
    groups += [[rng.randrange(16384) for _ in range(4)] for _ in range(257)]
    pixels = [v for row in groups for v in row]
    payload = [v for row in groups for v in pack(row)]
    folder = evidence_dir('raw14_bit_basis')
    for mode, (given, expected) in enumerate(((pixels, payload), (payload, pixels))):
        with tempfile.TemporaryDirectory(prefix='raw14_root_peer_') as tmp:
            p = Path(tmp)
            tb = TB.replace('@MODE@', str(mode)).replace('@NI@', str(len(given))).replace('@NO@', str(len(expected)))
            (p/'tb.sv').write_text(tb, encoding='utf-8')
            (p/'input.hex').write_text('\n'.join(f'{v:x}' for v in given), encoding='utf-8')
            (p/'expected.hex').write_text('\n'.join(f'{v:x}' for v in expected), encoding='utf-8')
            execute(['iverilog', '-g2012', '-s', 'tb', '-o', p/'sim', *sources, p/'tb.sv'], p, folder/f'compile_{mode}.log')
            out = execute(['vvp', p/'sim'], p, folder/f'simulation_{mode}.log')
            assert 'PASS RAW14_BIT_BASIS' in out
    assert frozen == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    write_json(folder/'results.json', dict(status='PASS', sources=frozen, groups=len(groups),
               basis_bits=56, complemented_basis_bits=56, pixels=len(pixels), payload_bytes=len(payload),
               reviewer_script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               scope='Independent byte fixture and algebraic bit-basis oracle for both directions, CE/stalls/markers; no PHY or board claim'))
    print(folder)


if __name__ == '__main__':
    main()
