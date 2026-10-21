"""Generate hashlib SHA-256 cases spanning padding and multi-block boundaries."""
import argparse
import hashlib
import json
import random
from pathlib import Path
from sha256_board_model import expected_records

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output-dir',type=Path,required=True)
args=parser.parse_args()
args.output_dir.mkdir(parents=True,exist_ok=True)
rng=random.Random(0x5A256)
lengths=[1,2,3,7,15,16,31,32,55,56,57,63,64,65,119,120,121,127,128,129,255,256,257,511,512,513,1023,1024,1025,2048,4096]
lengths += [rng.randrange(1,2049) for _ in range(64-len(lengths))]
data=bytearray(); descriptors=[]
for length in lengths:
    message=bytes(rng.randrange(256) for _ in range(length))
    descriptors.append(f'{len(data):08x}{length:08x}{hashlib.sha256(message).hexdigest()}')
    data.extend(message)
(args.output_dir/'sha_cases.mem').write_text('\n'.join(descriptors)+'\n',encoding='ascii')
(args.output_dir/'sha_bytes.mem').write_text('\n'.join(f'{b:02x}' for b in data)+'\n',encoding='ascii')
(args.output_dir/'sha_cases.json').write_text(json.dumps(dict(lengths=lengths,total_bytes=len(data)),indent=2)+'\n')
print(f'Generated 64 hashlib cases, {len(data)} bytes; empty-message API remains unsupported')
(args.output_dir/'sha_board_expected.mem').write_text('\n'.join(expected_records())+'\n',encoding='ascii')
