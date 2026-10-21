"""Independent byte-order oracle: exhaustive 16-bit values, framing and stalls."""
import hashlib
import random
import tempfile
from pathlib import Path
from tooling import PACKAGE, evidence_dir, execute, write_json

TB = r'''
`timescale 1ns/1ps
module tb;
localparam MODE=@MODE@,BE=@BE@,NI=@NI@,NO=@NO@;
localparam IW=MODE?8:16,OW=MODE?16:8;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,sv=0,mr=0;wire sr,mv,ms,me,pe,ev;
wire[OW-1:0]md;wire[7:0]ec;wire[31:0]cnt;
reg[17:0]stim[0:NI-1],expected[0:NO-1];
integer i=0,o=0,cycles=0,holds=0;reg held=0;reg[OW+1:0]saved;
wire[IW-1:0]sd=i<NI?stim[i][IW-1:0]:0;
wire ss=i<NI?stim[i][17]:0,se=i<NI?stim[i][16]:0;
generate if(MODE==0)begin
raw16_pack #(.BIG_ENDIAN(BE)) d(clk,rst_n,ce,sd,sv,ss,se,sr,md,mv,ms,me,mr,pe,ev,1'b0,ec,cnt);
end else begin
raw16_unpack #(.BIG_ENDIAN(BE)) d(clk,rst_n,ce,sd,sv,ss,se,sr,md,mv,ms,me,mr,pe,ev,1'b0,ec,cnt);
end endgenerate
always @(negedge clk)if(rst_n)begin
cycles=cycles+1;ce=cycles%13>2;mr=cycles%17>4;sv=i<NI&&cycles%7!=0;
end
always @(posedge clk)if(rst_n)begin
if(held&&(!mv||{ms,me,md}!==saved))$fatal(1,"held payload changed");
held<=mv&&!(ce&&mr);saved<={ms,me,md};
if(mv&&!(ce&&mr))holds<=holds+1;
if(sv&&sr&&ce)i<=i+1;
if(mv&&mr&&ce)begin
 if(o>=NO||md!==expected[o][OW-1:0]||{ms,me}!==expected[o][17:16])
  $fatal(1,"RAW16 mode%0d BE%0d token%0d data%h expected%h markers%0b/%0b",MODE,BE,o,md,expected[o],ms,me);
 o<=o+1;
end
if(pe||ev||cnt)$fatal(1,"unexpected protocol error");
if(o==NO)begin
 if(i!=NI||holds==0)$fatal(1,"total/coverage mismatch");
 $display("PASS RAW16_INDEPENDENT mode=%0d BE=%0d input=%0d output=%0d holds=%0d",MODE,BE,i,o,holds);$finish;
end
end
initial begin $readmemh("stim.hex",stim);$readmemh("expected.hex",expected);repeat(3)@(posedge clk);#1;rst_n=1;end
initial begin #50000000;$fatal(1,"watchdog");end
endmodule
'''


def main():
    base = PACKAGE/'image/raw16_codec'
    sources = [base/'raw16_pack.sv', base/'raw16_unpack.sv']
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    frozen = {p.name: sha(p) for p in sources}
    rng = random.Random(0x16c0dec)
    # Explicit distinguishing fixture, all possible words, then variable-width frames.
    frames = [([[0x1234, 0xabcd, 0x00ff]], 3),
              ([list(range(i, i+64)) for i in range(0, 65536, 64)], 64)]
    for width in (1, 3, 17, 255):
        frames.append(([[rng.randrange(65536) for _ in range(width)] for _ in range(3)], width))
    folder = evidence_dir('raw16_independent')
    for be in (0, 1):
        pixels, payload = [], []
        assert (0x1234).to_bytes(2, 'big' if be else 'little') == (b'\x12\x34' if be else b'\x34\x12')
        for lines, width in frames:
            for y, line in enumerate(lines):
                for x, value in enumerate(line):
                    sof = y == 0 and x == 0
                    eol = x == width-1
                    pixels.append(value | (int(sof)<<17) | (int(eol)<<16))
                    for j, byte in enumerate(value.to_bytes(2, 'big' if be else 'little')):
                        payload.append(byte | (int(sof and j == 0)<<17) | (int(eol and j == 1)<<16))
        for mode, (given, wanted) in enumerate(((pixels, payload), (payload, pixels))):
            with tempfile.TemporaryDirectory(prefix='raw16_root_peer_') as tmp:
                p = Path(tmp)
                tb = TB
                for k, v in dict(MODE=mode, BE=be, NI=len(given), NO=len(wanted)).items():
                    tb = tb.replace('@'+k+'@', str(v))
                (p/'tb.sv').write_text(tb, encoding='utf-8')
                for name, values in (('stim', given), ('expected', wanted)):
                    (p/(name+'.hex')).write_text('\n'.join(f'{v:05x}' for v in values), encoding='utf-8')
                label = f'{mode}_{be}'
                execute(['iverilog', '-g2012', '-s', 'tb', '-o', p/'sim', *sources, p/'tb.sv'], p, folder/('compile_'+label+'.log'))
                out = execute(['vvp', p/'sim'], p, folder/('simulation_'+label+'.log'))
                assert 'PASS RAW16_INDEPENDENT' in out
    assert frozen == {p.name: sha(p) for p in sources}, 'sources changed during peer test'
    write_json(folder/'results.json', dict(status='PASS', sources=frozen, profiles=4,
        exhaustive_values=65536, pixels_per_profile=len(pixels), bytes_per_profile=len(payload),
        frame_widths=[3, 64, 1, 3, 17, 255], reviewer_script_sha256=sha(Path(__file__)),
        scope='Independent int.to_bytes oracle for each direction/endian; complete frame markers and CE/stall stability; no PHY/board claim'))
    print(folder)


if __name__ == '__main__':
    main()
