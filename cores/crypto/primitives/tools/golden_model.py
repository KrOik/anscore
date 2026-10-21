#!/usr/bin/env python3
# Independent golden model for the crypto_20k selftest (SOP trap T1: nothing
# here is derived from RTL output).
#
#   AES-128 : pycryptodome AES + hard-coded FIPS-197 published checks
#   SHA-256 : hashlib.sha256
#   CRC     : binascii.crc32 (mode 2) + from-spec bit models (modes 0/1),
#             cross-checked against the standard "123456789" check values.
#
# The FNV-1a fold below replicates crypto_selftest.v byte order exactly:
#   AESB : dout[127:120]..dout[7:0] for vectors 0..3
#   SHAB : digest[255:248]..digest[7:0] for messages 0..2
#   CRC* : crc_out[31:24],[23:16],[15:8],[7:0]
import binascii
import hashlib
import json
import os

from Crypto.Cipher import AES

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FNV_SEED = 0x811C9DC5
FNV_PRIME = 0x01000193


def fnv(h, b):
    return ((h ^ b) * FNV_PRIME) & 0xFFFFFFFF


def fnv_bytes(h, data):
    for b in data:
        h = fnv(h, b)
    return h


# ---------------------------------------------------------------------------
# Stimulus replication (must match crypto_selftest.v)
# ---------------------------------------------------------------------------
AES_KEYS = [
    "000102030405060708090a0b0c0d0e0f",
    "00" * 16,
    "2b7e151628aed2a6abf7158809cf4f3c",
    "d5f0e1d2c3b4a5968778695a4b3c2d1e",
]
AES_DINS = [
    "00112233445566778899aabbccddeeff",
    "00" * 16,
    "6bc1bee22e409f96e93d7e117393172a",
    "00102030405060708090a0b0c0d0e0f0",
]
# FIPS-197 published ciphertexts (App C.1, known answer, App B / SP800-38A F.1.1)
AES_PUBLISHED = [
    "69c4e0d86a7b0430d8cdb78070b4c55a",
    "66e94bd4ef8a2c3b884cfa59ca342b2e",
    "3ad77bb40d7a3660a89ecaf32466ef97",
    None,  # vector 3: model-generated only
]

SHA_MSGS = [
    b"abc",
    b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
    bytes(((i * 31 + (i >> 2) + 7) & 0xFF) for i in range(100)),
]

CRC_STREAM = bytes(
    (0x31 + j) if j < 9 else ((j * 37 + (j >> 1) + 0x11) & 0xFF)
    for j in range(64)
)


def aes128_ecb(key_hex, pt_hex):
    return AES.new(bytes.fromhex(key_hex), AES.MODE_ECB).encrypt(
        bytes.fromhex(pt_hex))


def crc8_smbus(data):
    c = 0x00
    for b in data:
        for i in range(7, -1, -1):
            fb = ((c >> 7) ^ ((b >> i) & 1)) & 1
            c = ((c << 1) & 0xFF) ^ (0x07 if fb else 0)
    return c


def crc16_ccitt_false(data):
    c = 0xFFFF
    for b in data:
        for i in range(7, -1, -1):
            fb = ((c >> 15) ^ ((b >> i) & 1)) & 1
            c = ((c << 1) & 0xFFFF) ^ (0x1021 if fb else 0)
    return c


def u32_bytes(v):
    return bytes(((v >> 24) & 0xFF, (v >> 16) & 0xFF,
                  (v >> 8) & 0xFF, v & 0xFF))


def compute():
    # --- sanity: model self-checks against published values ------------------
    for i in range(3):
        ct = aes128_ecb(AES_KEYS[i], AES_DINS[i]).hex()
        assert ct == AES_PUBLISHED[i], \
            "AES model mismatch v%d: %s != %s" % (i, ct, AES_PUBLISHED[i])
    assert crc8_smbus(b"123456789") == 0xF4
    assert crc16_ccitt_false(b"123456789") == 0x29B1
    assert binascii.crc32(b"123456789") & 0xFFFFFFFF == 0xCBF43926
    assert hashlib.sha256(b"abc").hexdigest() == \
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    # --- per-unit digests ----------------------------------------------------
    h = FNV_SEED
    cts = []
    for k, d in zip(AES_KEYS, AES_DINS):
        ct = aes128_ecb(k, d)
        cts.append(ct.hex())
        h = fnv_bytes(h, ct)
    dg_aes = h

    h = FNV_SEED
    shas = []
    for m in SHA_MSGS:
        dg = hashlib.sha256(m).digest()
        shas.append(dg.hex())
        h = fnv_bytes(h, dg)
    dg_sha = h

    v8 = crc8_smbus(CRC_STREAM)
    v16 = crc16_ccitt_false(CRC_STREAM)
    v32 = binascii.crc32(CRC_STREAM) & 0xFFFFFFFF
    dg_crc8 = fnv_bytes(FNV_SEED, u32_bytes(v8))
    dg_crc16 = fnv_bytes(FNV_SEED, u32_bytes(v16))
    dg_crc32 = fnv_bytes(FNV_SEED, u32_bytes(v32))

    return {
        "digests": {
            "AESB": dg_aes, "SHAB": dg_sha,
            "CRC8": dg_crc8, "CR16": dg_crc16, "CR32": dg_crc32,
        },
        "aes_ciphertexts": cts,
        "sha256_hexdigests": shas,
        "crc_values": {"crc8": v8, "crc16": v16, "crc32": v32},
    }


if __name__ == "__main__":
    r = compute()
    for name, v in r["digests"].items():
        print("%-4s EXP = 32'h%08x" % (name, v))
    print()
    for i, ct in enumerate(r["aes_ciphertexts"]):
        print("aes ct[%d] = %s" % (i, ct))
    for i, d in enumerate(r["sha256_hexdigests"]):
        print("sha dg[%d] = %s" % (i, d))
    print("crc8=%02x crc16=%04x crc32=%08x" % (
        r["crc_values"]["crc8"], r["crc_values"]["crc16"],
        r["crc_values"]["crc32"]))
    out = os.path.join(ROOT, "sim", "golden_digests.json")
    with open(out, "w") as f:
        json.dump(r, f, indent=2)
    print("wrote", out)
