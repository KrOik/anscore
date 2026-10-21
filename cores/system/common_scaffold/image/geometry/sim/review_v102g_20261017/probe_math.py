from pathlib import Path
import random,hashlib,json
root=Path('cores/system/common_scaffold/board/tang25k/build/image_resample_frame_selftest_25k_20261017_v102g')
rng=random.Random(0x1026)
count=0
for maxdim in [1,2,3,4,8,64,255,256,1023,32768,65535,65536]:
    xw=max(1,maxdim.bit_length())
    ew=xw+16
    for pixelw in [1,8,16]:
        divw=max(pixelw+xw+xw,ew)
        for _ in range(2000):
            sw=rng.randint(1,min(maxdim,65535))
            dw=rng.choice([1,2,3,65534,65535,rng.randint(1,65535)])
            ox=rng.choice([0,dw-1,rng.randrange(dw)])
            mask=(1<<divw)-1
            edge_mask=(1<<ew)-1
            left=ox*sw & edge_mask
            right=(ox+1)*sw & edge_mask
            assert left==ox*sw and right==(ox+1)*sw
            old_first=ox*sw & mask
            old_last=((ox+1)*sw-1) & mask
            new_first=left & mask
            new_last=((right-1)&edge_mask)&mask
            assert (old_first,old_last)==(new_first,new_last)
            assert right>=1
            count+=1
p=root/'img_geo_area_resample_serial.v'
print(json.dumps({'read_only_review':'PASS','f_g_edge_operand_sample_checks':count,'seed':'0x1026','max_source_parameters':[1,2,3,4,8,64,255,256,1023,32768,65535,65536],'destination_cases':'1,2,3,65534,65535,uniform seeded; ox=first,last,uniform seeded','engine_sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'note':'Mathematical operand-width check plus static CE/reset review; not a substitute for RTL simulation or physical timing.'},indent=2))
