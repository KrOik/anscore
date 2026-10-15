#!/usr/bin/env python3
"""UART host clients for the sm2_aes_crypto_20k board images.

Two FPGA images exist because the monolithic design exceeds the GW2A-18C
LUT budget (the original src/top.v monolith mapped to ~306% of the
device's LUT4s in nextpnr):

  Image A (src/top_aes.v, top_aes.fs): aes_core + sm3_top
    'H' 0x48                ping          -> "OK"
    'S' 0x53                status        -> 1B {4'b0, aes_rvld, aes_rdy, 2'b0}
    'A' 0x41 klen k[32]     AES key: klen 0=128b(k[0:15]), 1=256b     -> 'a'
    'E' 0x45 ed blk[16]     AES run block, ed 1=enc 0=dec              -> 16B
    'M' 0x4D len[2] d[len]  SM3 hash (BE length, len bytes) -> 'D' + 32B digest

  Image B (src/top_sm2.v, top_sm2.fs): sm2_ecc(JAC_ONLY) + sm3_top
    'H' 0x48                ping          -> "OK"
    'S' 0x53                status        -> 1B {4'b0, err, inf, done, busy}
    'L' 0x4C sel d[32]      load 256b param 0:k 1:ax 2:ay 3:bx 4:by  -> 'l'
    'G' 0x47 op             run ECC op (0=PMUL_G 1=PMUL_P 2=PADD)
                                                        -> 'D' 1B {6'b0,err,inf}
    'Q' 0x51 sel            read result (0:x 1:y 2:z, Jacobian)        -> 32B
    'M' 0x4D len[2] d[len]  SM3 hash                          -> 'D' + 32B digest

Image B returns Jacobian coordinates; this client performs the affine
conversion (z^{-1} mod p) and all mod-n arithmetic / protocol sequencing
on the host, so the board still performs every scalar multiplication and
every SM3 hash for keygen/sign/verify/encrypt/decrypt.

usage: crypto_uart.py --image aes <COM-port> [--selftest]
       crypto_uart.py --image sm2 <COM-port> [--selftest]
"""

import argparse
import sys

import serial

P_K, P_AX, P_AY, P_BX, P_BY = range(5)
OP_PMUL_G, OP_PMUL_P, OP_PADD = range(3)
Q_X, Q_Y, Q_Z = range(3)


def _load_ref():
    import importlib.util
    import os
    spec = importlib.util.spec_from_file_location(
        'sm2_ref', os.path.join(os.path.dirname(__file__), 'sm2_ref.py'))
    ref = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ref)
    return ref


class BoardBase:
    def __init__(self, port, baud=115200, timeout=120):
        self.ser = serial.Serial(port, baud, timeout=timeout)

    def close(self):
        self.ser.close()

    def _cmd(self, data, nresp):
        self.ser.reset_input_buffer()
        self.ser.write(bytes(data))
        self.ser.flush()
        r = self.ser.read(nresp)
        if len(r) != nresp:
            raise TimeoutError("expected %d resp bytes, got %d (%s)"
                               % (nresp, len(r), r.hex()))
        return r

    def ping(self):
        return self._cmd([0x48], 2) == b'OK'

    def status(self):
        return self._cmd([0x53], 1)[0]

    def sm3(self, data: bytes) -> int:
        """On-board SM3 digest of `data` (len up to 65535)."""
        n = len(data)
        assert n <= 0xFFFF
        r = self._cmd([0x4D, n >> 8, n & 0xFF] + list(data), 33)
        assert r[0:1] == b'D', r[:1]
        return int.from_bytes(r[1:33], 'big')


class AesBoard(BoardBase):
    """Image A: AES-128/256 + SM3."""

    def aes_key(self, key: bytes):
        """key: 16B (AES-128) or 32B (AES-256)."""
        klen = 0 if len(key) == 16 else 1
        r = self._cmd([0x41, klen] + list(key) + [0] * (32 - len(key)), 1)
        assert r == b'a', r

    def aes_block(self, block: bytes, enc=True) -> bytes:
        assert len(block) == 16
        return bytes(self._cmd([0x45, 1 if enc else 0] + list(block), 16))


class Sm2Board(BoardBase):
    """Image B: SM2 ECC accelerator (Jacobian out) + SM3."""

    def load_param(self, sel, value):
        """value: int (256-bit) or bytes(32, big-endian)."""
        if isinstance(value, int):
            value = value.to_bytes(32, 'big')
        assert len(value) == 32
        r = self._cmd([0x4C, sel] + list(value), 1)
        assert r == b'l', r

    def run_ecc(self, op):
        """Returns dict(err=..., inf=...)."""
        r = self._cmd([0x47, op], 2)
        assert r[0:1] == b'D', r
        return dict(err=bool(r[1] & 2), inf=bool(r[1] & 1))

    def read_result(self, sel):
        return int.from_bytes(self._cmd([0x51, sel], 32), 'big')

    # ---- raw ECC primitives (Jacobian -> host affine) ---------------------
    def _point_op(self, op, k=None, ax=None, ay=None, bx=None, by=None):
        if k is not None:
            self.load_param(P_K, k)
        if ax is not None:
            self.load_param(P_AX, ax)
        if ay is not None:
            self.load_param(P_AY, ay)
        if bx is not None:
            self.load_param(P_BX, bx)
        if by is not None:
            self.load_param(P_BY, by)
        st = self.run_ecc(op)
        assert not st['err'], st
        if st['inf']:
            return None
        jx = self.read_result(Q_X)
        jy = self.read_result(Q_Y)
        jz = self.read_result(Q_Z)
        ref = _load_ref()
        return ref.jac_aff(jx, jy, jz)

    def pmul_g(self, k):
        """k*G, affine (x, y). All point work on board; affine conv on host."""
        return self._point_op(OP_PMUL_G, k=k)

    def pmul_p(self, k, x, y):
        """k*(x,y), affine."""
        return self._point_op(OP_PMUL_P, k=k, ax=x, ay=y)

    def padd(self, ax, ay, bx, by):
        """(ax,ay)+(bx,by), affine."""
        return self._point_op(OP_PADD, ax=ax, ay=ay, bx=bx, by=by)

    # ---- SM2 protocol orchestration (ECC + SM3 on board, modn on host) ----
    def _za(self, Px, Py, uid=b"ALICE123@YAHOO.COM"):
        ref = _load_ref()
        pre = (len(uid) * 8).to_bytes(2, "big") + uid \
            + bytes.fromhex(ref.A_HEX + ref.B_HEX + ref.GX_HEX + ref.GY_HEX) \
            + Px.to_bytes(32, "big") + Py.to_bytes(32, "big")
        return self.sm3(pre)

    def _kdf(self, z: bytes, klen: int) -> bytes:
        out = b""
        ct = 1
        while len(out) < klen:
            out += self.sm3(z + ct.to_bytes(4, "big")).to_bytes(32, "big")
            ct += 1
        return out[:klen]

    def keygen(self, d):
        """P_A = d*G. Returns (x, y)."""
        return self.pmul_g(d)

    def sign(self, d, msg: bytes, k, uid=b"ALICE123@YAHOO.COM"):
        """Returns (r, s, e) or None if r==0/s==0 (retry with new k)."""
        ref = _load_ref()
        Px, Py = self.pmul_g(d)
        e = self.sm3(self._za(Px, Py, uid).to_bytes(32, "big") + msg)
        pt = self.pmul_g(k)
        if pt is None:
            return None
        r = (e + pt[0]) % ref.n
        if r == 0 or (r + k) % ref.n == 0:
            return None
        s = ref.inv(1 + d, ref.n) * (k - r * d) % ref.n
        return (r, s, e) if s else None

    def verify(self, Px, Py, msg: bytes, r, s, uid=b"ALICE123@YAHOO.COM"):
        ref = _load_ref()
        if not (1 <= r < ref.n and 1 <= s < ref.n):
            return False
        e = self.sm3(self._za(Px, Py, uid).to_bytes(32, "big") + msg)
        t = (r + s) % ref.n
        sG = self.pmul_g(s)
        tP = self.pmul_p(t, Px, Py)
        if sG is None or tP is None:
            return False
        pt = self.padd(sG[0], sG[1], tP[0], tP[1])
        if pt is None:
            return False
        return (e + pt[0]) % ref.n == r

    def encrypt(self, Pbx, Pby, msg: bytes, k):
        """Returns (C1x, C1y, C2 bytes, C3 int)."""
        C1 = self.pmul_g(k)
        pt2 = self.pmul_p(k, Pbx, Pby)
        if C1 is None or pt2 is None:
            raise ValueError("point at infinity")
        x2, y2 = pt2
        zb = x2.to_bytes(32, "big") + y2.to_bytes(32, "big")
        t = self._kdf(zb, len(msg))
        if not any(t):
            raise ValueError("all-zero KDF output; retry with new k")
        C2 = bytes(m ^ tt for m, tt in zip(msg, t))
        C3 = self.sm3(x2.to_bytes(32, "big") + msg + y2.to_bytes(32, "big"))
        return C1[0], C1[1], C2, C3

    def decrypt(self, d, C1x, C1y, C2: bytes, C3):
        """Returns plaintext bytes, or None on C3 mismatch."""
        pt2 = self.pmul_p(d, C1x, C1y)
        if pt2 is None:
            return None
        x2, y2 = pt2
        zb = x2.to_bytes(32, "big") + y2.to_bytes(32, "big")
        t = self._kdf(zb, len(C2))
        M = bytes(c ^ tt for c, tt in zip(C2, t))
        u = self.sm3(x2.to_bytes(32, "big") + M + y2.to_bytes(32, "big"))
        return M if u == C3 else None


def _selftest_aes(board):
    board.aes_key(bytes.fromhex('000102030405060708090a0b0c0d0e0f'))
    ct = board.aes_block(bytes.fromhex('00112233445566778899aabbccddeeff'))
    print("aes128 enc:", ct.hex())
    assert ct.hex() == '69c4e0d86a7b0430d8cdb78070b4c55a'
    pt = board.aes_block(ct, enc=False)
    assert pt.hex() == '00112233445566778899aabbccddeeff'
    print("aes128 dec:", pt.hex())

    board.aes_key(bytes.fromhex(
        '603deb1015ca71be2b73aef0857d7781'
        '1f352c073b6108d72d9810a30914dff4'))
    ct = board.aes_block(bytes.fromhex('6bc1bee22e409f96e93d7e117393172a'))
    print("aes256 enc:", ct.hex())
    assert ct.hex() == 'f3eed1bdb5d2a03c064b5a7e3db181f8'

    d = board.sm3(b'abc')
    print("sm3(abc): %064x" % d)
    assert d == 0x66C7F0F462EEEDD9D1F2D46BDC10E4E24167C4875CF2F7A2297DA02B8F4BA8E0


def _selftest_sm2(board):
    ref = _load_ref()
    dA = int("128B2FA8BD433C6C068C8D803DFF79792A519A55171B1B650C23661D15897263", 16)
    PAX = int("D5548C7825CBB56150A3506CD57464AF8A1AE0519DFAF3C58221DC810CAF28DD", 16)
    PAY = int("921073768FE3D59CE54E79A49445CF73FED23086537027264D168946D479533E", 16)

    d = board.sm3(b'abc')
    print("sm3(abc): %064x" % d)
    assert d == 0x66C7F0F462EEEDD9D1F2D46BDC10E4E24167C4875CF2F7A2297DA02B8F4BA8E0

    PA = board.keygen(dA)
    print("keygen PA = %064x\n            %064x" % PA)
    assert PA == (PAX, PAY) == ref.pmul(dA, ref.Gx, ref.Gy)

    k = int("6CB28D99385C175C94F94E934817663FC176D925DD72B727260DBAAE1FB2F96F", 16)
    msg = b"message digest"
    r, s, e = board.sign(dA, msg, k)
    print("sign r = %064x\n     s = %064x" % (r, s))
    er, es, _ = ref.sm2_sign(dA, msg, k)
    assert (r, s) == (er, es)
    assert board.verify(PAX, PAY, msg, r, s)
    assert not board.verify(PAX, PAY, msg, r, s ^ 1)
    print("sign/verify round-trip OK (incl. bad-sig rejection)")

    dB = int("1649AB77A00637BD5E2EFE283FBF353534AA7F7CB89463F208DDBC2920BB0DA0", 16)
    PB = board.keygen(dB)
    ke = int("4C62EEFD6ECFC2B95B92FD6C3D9575148AFA17425546D49018E5388D49DD7B4F", 16)
    M = b"encryption standard"
    C1x, C1y, C2, C3 = board.encrypt(PB[0], PB[1], M, ke)
    print("enc C1 = %064x %064x\n    C2 = %s\n    C3 = %064x" % (C1x, C1y, C2.hex(), C3))
    M2 = board.decrypt(dB, C1x, C1y, C2, C3)
    print("dec:", M2)
    assert M2 == M
    assert board.decrypt(dB, C1x, C1y, C2, C3 ^ 1) is None
    print("enc/dec round-trip OK (incl. bad-C3 rejection)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--image', choices=['aes', 'sm2'], required=True)
    ap.add_argument('port')
    ap.add_argument('--selftest', action='store_true')
    args = ap.parse_args()

    board = AesBoard(args.port) if args.image == 'aes' else Sm2Board(args.port)
    print("ping:", board.ping())
    if args.selftest:
        (_selftest_aes if args.image == 'aes' else _selftest_sm2)(board)
        print("ALL BOARD TESTS PASS")
    board.close()


if __name__ == '__main__':
    main()
