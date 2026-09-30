"""Independent hashlib results and protocol cycle counts for SHA board tests."""
import hashlib

LENGTHS=(3,55,56,63,64,65,119,120,127,128,129,255)


def message(index):
    if index==0:
        return b'abc'
    return bytes((i*31+(i>>2)+7+index*17)&255 for i in range(LENGTHS[index]))


def expected_records():
    rows=[]
    for index,length in enumerate(LENGTHS):
        # Padded blocks take 64 byte-load + 64 compression beats, then one
        # final digest-valid beat. Starts at the cycle after init acceptance.
        cycles=((length+9+63)//64)*128+1
        rows.append(f'{cycles:04X}'+hashlib.sha256(message(index)).hexdigest().upper())
    return rows
