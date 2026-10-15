#!/usr/bin/env python3
"""Pure-python SM2 reference (GM/T 0003) for generating FPGA test vectors.
Uses gmssl only for SM3 hash. Curve: sm2p256v1.
"""
from gmssl import sm3, func

P_HEX  = "FFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFF"
A_HEX  = "FFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFC"
B_HEX  = "28E9FA9E9D9F5E344D5A9E4BCF6509A7F39789F515AB8F92DDBCBD414D940E93"
N_HEX  = "FFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFF7203DF6B21C6052B53BBF40939D54123"
GX_HEX = "32C4AE2C1F1981195F9904466A39C9948FE30BBFF2660BE1715A4589334C74C7"
GY_HEX = "BC3736A2F4F6779C59BDCEE36B692153D0A9877CC62A474002DF32E52139F0A0"

p = int(P_HEX, 16); a = int(A_HEX, 16); b = int(B_HEX, 16)
n = int(N_HEX, 16); Gx = int(GX_HEX, 16); Gy = int(GY_HEX, 16)

def inv(x, m): return pow(x % m, m - 2, m) if m == p else pow(x % m, -1, m)

def sm3_hash(data: bytes) -> int:
    return int(sm3.sm3_hash(func.bytes_to_list(list(data))), 16)

def jac_double(X, Y, Z):
    if Z == 0 or Y == 0: return (0, 1, 0)
    A = Y * Y % p; B = 4 * X * A % p; C = 8 * A * A % p
    D = (3 * X * X + a * Z * Z * Z * Z) % p
    X3 = (D * D - 2 * B) % p; Y3 = (D * (B - X3) - C) % p; Z3 = 2 * Y * Z % p
    return X3, Y3, Z3

def jac_add(X1, Y1, Z1, X2, Y2, Z2):
    if Z1 == 0: return (X2, Y2, Z2)
    if Z2 == 0: return (X1, Y1, Z1)
    U1 = X1 * Z2 * Z2 % p; U2 = X2 * Z1 * Z1 % p
    S1 = Y1 * Z2 * Z2 * Z2 % p; S2 = Y2 * Z1 * Z1 * Z1 % p
    if U1 == U2:
        return jac_double(X1, Y1, Z1) if S1 == S2 else (0, 1, 0)
    H = (U2 - U1) % p; R = (S2 - S1) % p
    X3 = (R * R - H * H * H - 2 * U1 * H * H) % p
    Y3 = (R * (U1 * H * H - X3) - S1 * H * H * H) % p
    Z3 = H * Z1 * Z2 % p
    return X3, Y3, Z3

def jac_aff(X, Y, Z):
    if Z == 0: return None
    zi = inv(Z, p); z2 = zi * zi % p
    return (X * z2 % p, Y * z2 * zi % p)

def pmul(k, X, Y):
    R = (0, 1, 0); B = (X % p, Y % p, 1)
    for i in range(255, -1, -1):
        R = jac_double(*R)
        if (k >> i) & 1: R = jac_add(*R, *B)
    return jac_aff(*R)

def za_calc(Px, Py, uid=b"ALICE123@YAHOO.COM"):
    entl = (len(uid) * 8).to_bytes(2, "big")
    data = entl + uid + bytes.fromhex(A_HEX + B_HEX + GX_HEX + GY_HEX) + \
           Px.to_bytes(32, "big") + Py.to_bytes(32, "big")
    return sm3_hash(data)

def sm2_sign(d, msg: bytes, k, uid=b"ALICE123@YAHOO.COM"):
    Px, Py = pmul(d, Gx, Gy)
    e = sm3_hash(za_calc(Px, Py).to_bytes(32, "big") + msg)
    x1, _ = pmul(k, Gx, Gy)
    r = (e + x1) % n
    s = inv(1 + d, n) * (k - r * d) % n
    return r, s, e

def sm2_verify(Px, Py, msg: bytes, r, s, uid=b"ALICE123@YAHOO.COM"):
    if not (1 <= r < n and 1 <= s < n): return False
    e = sm3_hash(za_calc(Px, Py).to_bytes(32, "big") + msg)
    t = (r + s) % n
    sG = pmul(s, Gx, Gy); tP = pmul(t, Px, Py)
    if sG is None or tP is None: return False
    pt = jac_aff(*jac_add(sG[0], sG[1], 1, tP[0], tP[1], 1))
    return (e + pt[0]) % n == r

def kdf(z: bytes, klen: int) -> bytes:
    out = b""; ct = 1
    while len(out) < klen:
        out += sm3.sm3_hash(func.bytes_to_list(list(z + ct.to_bytes(4, "big")))).encode() \
               .decode().encode("latin1") if False else bytes.fromhex(
               sm3.sm3_hash(func.bytes_to_list(list(z + ct.to_bytes(4, "big")))))
        ct += 1
    return out[:klen]

def sm2_encrypt(Px, Py, msg: bytes, k):
    C1x, C1y = pmul(k, Gx, Gy)
    x2, y2 = pmul(k, Px, Py)
    t = kdf(x2.to_bytes(32, "big") + y2.to_bytes(32, "big"), len(msg))
    C2 = bytes(m ^ tt for m, tt in zip(msg, t))
    C3 = sm3_hash(x2.to_bytes(32, "big") + msg + y2.to_bytes(32, "big"))
    return C1x, C1y, C2, C3

def sm2_decrypt(d, C1x, C1y, C2: bytes, C3):
    x2, y2 = pmul(d, C1x, C1y)
    t = kdf(x2.to_bytes(32, "big") + y2.to_bytes(32, "big"), len(C2))
    M = bytes(c ^ tt for c, tt in zip(C2, t))
    u = sm3_hash(x2.to_bytes(32, "big") + M + y2.to_bytes(32, "big"))
    return M, u == C3

if __name__ == "__main__":
    # GM/T 0003.5 Annex A signature example vectors
    dA = int("128B2FA8BD433C6C068C8D803DFF79792A519A55171B1B650C23661D15897263", 16)
    PA = pmul(dA, Gx, Gy)
    print("dA = %064X" % dA)
    print("PAx= %064X" % PA[0]); print("PAy= %064X" % PA[1])
    k = int("6CB28D99385C175C94F94E934817663FC176D925DD72B727260DBAAE1FB2F96F", 16)
    msg = b"message digest"
    r, s, e = sm2_sign(dA, msg, k)
    print("e  = %064X" % e)
    print("r  = %064X" % r); print("s  = %064X" % s)
    print("verify:", sm2_verify(PA[0], PA[1], msg, r, s))
    # encryption example (GM/T 0003.5)
    dB = int("1649AB77A00637BD5E2EFE283FBF353534AA7F7CB89463F208DDBC2920BB0DA0", 16)
    PB = pmul(dB, Gx, Gy)
    print("PBx= %064X" % PB[0]); print("PBy= %064X" % PB[1])
    ke = int("4C62EEFD6ECFC2B95B92FD6C3D9575148AFA17425546D49018E5388D49DD7B4F", 16)
    M = b"encryption standard"
    C1x, C1y, C2, C3 = sm2_encrypt(PB[0], PB[1], M, ke)
    print("C1x= %064X" % C1x); print("C1y= %064X" % C1y)
    print("C2 = %s" % C2.hex())
    print("C3 = %064X" % C3)
    M2, ok = sm2_decrypt(dB, C1x, C1y, C2, C3)
    print("dec:", M2, ok)
