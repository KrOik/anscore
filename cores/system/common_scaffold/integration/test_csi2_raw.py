"""Actual CSI-2 packet receiver -> existing RAW10/12 unpacker RTL chains.

No D-PHY is modeled. All payload pixels are provisional until packet CRC
reports; the healthy streams tested here require every packet report to pass.
"""
import hashlib
import random
import tempfile
from pathlib import Path
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json


PARITY = (
    (0, 1, 2, 4, 5, 7, 10, 11, 13, 16, 20, 21, 22, 23),
    (0, 1, 3, 4, 6, 8, 10, 12, 14, 17, 20, 21, 22, 23),
    (0, 2, 3, 5, 6, 9, 11, 12, 15, 18, 20, 21, 22),
    (1, 2, 3, 7, 8, 9, 13, 14, 15, 19, 20, 21, 23),
    (4, 5, 6, 7, 8, 9, 16, 17, 18, 19, 20, 22, 23),
    (10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 21, 22, 23),
)


def header(dt, value, vc=2):
    data = (value << 8) | (vc << 6) | dt
    check = sum((sum((data >> bit) & 1 for bit in bits) % 2) << i
                for i, bits in enumerate(PARITY))
    return data.to_bytes(3, 'little') + bytes([check])


def packet(dt, payload):
    crc = 0xffff
    for byte in payload:
        for bit in range(8):
            mix = (crc ^ (byte >> bit)) & 1
            crc >>= 1
            if mix:
                crc ^= 0x8408
    return header(dt, len(payload)) + bytes(payload) + crc.to_bytes(2, 'little')


TB = r'''module tb;
localparam BITS=@BITS@,W=8,H=3,F=3,NP=W*H*F,NB=@BYTES@;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_last=0;
reg[7:0]s_data;reg done_ready=0,pixel_ready=0;
wire start_ready,s_ready,h_valid,h_short,h_corrected;
wire[1:0]h_vc;wire[5:0]h_dt;wire[15:0]h_word_count;
wire[7:0]payload;wire payload_valid,payload_ready,payload_first,payload_last;
wire[1:0]payload_vc;wire[5:0]payload_dt;
wire p_valid,p_error,p_last,done_valid,done_error;wire[7:0]p_error_code,error_code;
wire[31:0]packet_count,corrected_count,crc_error_count;
wire[3:0]frame_active,line_active;
csi2_packet_rx #(.MAX_WORD_COUNT(64)) rx(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start_valid),.start_ready(start_ready),
.cfg_check_sequence(1'b1),.abort(abort),.s_data(s_data),.s_valid(s_valid),.s_ready(s_ready),.s_last(s_last),
.h_valid(h_valid),.h_ready(1'b1),.h_vc(h_vc),.h_dt(h_dt),.h_word_count(h_word_count),.h_short(h_short),.h_corrected(h_corrected),
.m_data(payload),.m_valid(payload_valid),.m_ready(payload_ready),.m_first(payload_first),.m_last(payload_last),.m_vc(payload_vc),.m_dt(payload_dt),
.p_valid(p_valid),.p_ready(1'b1),.p_error(p_error),.p_error_code(p_error_code),.p_last(p_last),
.done_valid(done_valid),.done_ready(done_ready),.done_error(done_error),.error_code(error_code),
.packet_count(packet_count),.corrected_count(corrected_count),.crc_error_count(crc_error_count),.frame_active(frame_active),.line_active(line_active));
wire[BITS-1:0]pixel;wire pixel_valid,pixel_sof,pixel_eol,protocol_error;
wire[1:0]unpack_error;reg pending_sof=0;
img_csi2_raw_unpack #(.RAW_BITS(BITS)) unpack(
.clk(clk),.rst_n(rst_n),.clk_en(ce),.s_data(payload),.s_valid(payload_valid),.s_ready(payload_ready),
.s_sof(pending_sof&&payload_first),.s_eol(payload_last),
.m_data(pixel),.m_valid(pixel_valid),.m_ready(pixel_ready),.m_sof(pixel_sof),.m_eol(pixel_eol),
.protocol_error(protocol_error),.error_code(unpack_error));
reg[7:0]bytes_[0:NB-1];reg[BITS-1:0]expected[0:NP-1];
integer cycles=0,got=0,reports=0,i;reg take,held=0;reg[BITS+1:0]token;
always @(posedge clk)begin
cycles=cycles+1;if(cycles>200000)$fatal(1,"timeout");
if(rst_n)begin
if(held&&(!pixel_valid||{pixel,pixel_sof,pixel_eol}!==token))$fatal(1,"pixel hold");
held=pixel_valid&&!(ce&&pixel_ready);token={pixel,pixel_sof,pixel_eol};
if(protocol_error)$fatal(1,"unpack protocol %h",unpack_error);
if(ce&&h_valid)begin
if(h_vc!=2||h_corrected)$fatal(1,"header metadata");
if(h_dt==0)pending_sof<=1;
if(!h_short&&(h_dt!=((BITS==10)?6'h2b:6'h2c)||h_word_count!=(BITS*W/8)))$fatal(1,"RAW header");
end
if(ce&&payload_valid&&payload_ready)begin
if(payload_vc!=2||payload_dt!=((BITS==10)?6'h2b:6'h2c))$fatal(1,"payload metadata");
if(payload_first)pending_sof<=0;
end
if(ce&&p_valid)begin if(p_error)$fatal(1,"packet CRC/error %h",p_error_code);reports=reports+1;end
if(ce&&pixel_valid&&pixel_ready)begin
if(got>=NP||pixel!==expected[got]||pixel_sof!==(got%(W*H)==0)||pixel_eol!==(got%W==W-1))$fatal(1,"RAW pixel %d got%h",got,pixel);
got=got+1;
end
end end
task tick;begin @(negedge clk);#1;ce=cycles%11>1;pixel_ready=cycles%7>1;end endtask
initial begin
$readmemh("bytes.mem",bytes_);$readmemh("pixels.mem",expected);
repeat(3)@(negedge clk);#1;rst_n=1;start_valid=1;@(negedge clk);#1;start_valid=0;
for(i=0;i<NB;i=i+1)begin
s_data=bytes_[i];s_valid=1;s_last=i==NB-1;take=0;
while(!take)begin @(posedge clk);take=ce&&s_ready;tick;end
s_valid=0;if(i%5==1)tick;
end
while(!done_valid||got!=NP)tick;
if(done_error||error_code||packet_count!=33||reports!=33||corrected_count||crc_error_count||frame_active||line_active)$fatal(1,"stream result packets%0d reports%0d",packet_count,reports);
ce=0;done_ready=1;repeat(3)@(negedge clk);#1;if(!done_valid)$fatal(1,"DONE hold");
ce=1;@(negedge clk);#1;done_ready=0;if(!start_ready)$fatal(1,"DONE ack");
$display("PASS CSI2_RAW bits=%0d frames=%0d pixels=%0d reports=%0d",BITS,F,got,reports);$finish;
end endmodule'''


def run(bits):
    folder = evidence_dir('csi2_raw')
    rng = random.Random(bits)
    pixels = []
    stream = bytearray()
    group = 4 if bits == 10 else 2
    for frame in range(3):
        stream.extend(header(0, frame + 7))
        for line in range(3):
            stream.extend(header(2, line + 1))
            row = [rng.randrange(1 << bits) for _ in range(8)]
            if line == 0:
                row[:4] = [0, (1 << bits) - 1, 1, (1 << bits) // 2]
            pixels.extend(row)
            packed = []
            lowbits = bits - 8
            for i in range(0, 8, group):
                values = row[i:i + group]
                packed.extend(v >> lowbits for v in values)
                packed.append(sum((v & ((1 << lowbits) - 1)) << (j * lowbits)
                                  for j, v in enumerate(values)))
            stream.extend(packet(0x2b if bits == 10 else 0x2c, packed))
            stream.extend(header(3, line + 1))
        stream.extend(header(1, frame + 7))
    sources = [PACKAGE/'image/csi2_packet_rx/csi2_packet_rx.sv',
               PACKAGE/'image/raw_unpack/img_csi2_raw_unpack.v']
    hashes = {str(s.relative_to(ROOT)): hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}
    with tempfile.TemporaryDirectory(prefix='csi2_raw_') as tmp:
        path = Path(tmp)
        (path/'bytes.mem').write_text('\n'.join(f'{v:x}' for v in stream))
        (path/'pixels.mem').write_text('\n'.join(f'{v:x}' for v in pixels))
        (path/'tb.sv').write_text(TB.replace('@BITS@', str(bits)).replace('@BYTES@', str(len(stream))))
        execute(['iverilog', '-g2012', '-s', 'tb', '-o', path/'sim', *sources, path/'tb.sv'], ROOT, folder/'compile.log')
        execute(['vvp', path/'sim'], path, folder/'simulation.log')
    assert hashes == {str(s.relative_to(ROOT)): hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}
    write_json(folder/'results.json', dict(status='PASS', raw_bits=bits, frames=3,
        pixels=len(pixels), packet_reports=33, input_bytes=len(stream), sources=hashes,
        board_tested=False, scope='healthy packet-to-RAW RTL chain; no D-PHY or routed timing claim'))
    print(folder, flush=True)


if __name__ == '__main__':
    for bits in (10, 12):
        run(bits)
