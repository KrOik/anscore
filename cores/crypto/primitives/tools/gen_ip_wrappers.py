#!/usr/bin/env python3
# Generate standardized proprietary IP wrappers for the crypto_20k cores that
# passed GW2A-18C board validation (5/5 selftest units across two bitstreams,
# UART digest evidence in doc/board_uart_m01.txt / board_uart_m1e.txt).
#
# Wrapper conventions:
#   * module name  gw2a_crypto_<name>
#   * uniform ports first: clk, rst_n (active low async), clk_en
#   * all ports flat vectors (no packed arrays in these cores anyway)
#
# Output tree (under cores/crypto/primitives/ip/):
#   <ip>/gw2a_crypto_<ip>.v     wrapper RTL (instantiates the validated core)
#   <ip>/ip_manifest.json       metadata: params, ports, digest, evidence
#   <ip>/README.md              port map + timing/usage notes
#   MANIFEST.md                 index of all packaged IPs
import json
import os

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IP_ROOT = os.path.join(PROJ, "ip")

IPS = [
    dict(
        name="aes128", core="aes128_core", src="src/aes128_core.v",
        units="0 (AESB)", digest="61C7D1CF", board="m01",
        desc="AES-128 ECB single-block encryptor (FIPS-197), iterative "
             "1-round/clk_en datapath, on-the-fly key expansion, composite-field S-boxes.",
        params=[],
        ports=[
            ("start", "input", "1", "pulse 1 clk_en beat; key/din must be stable"),
            ("key", "input", "128", "cipher key, byte 0 = key[127:120]"),
            ("din", "input", "128", "plaintext block, byte 0 = din[127:120]"),
            ("dout", "output", "128", "ciphertext, valid when done pulses"),
            ("done", "output", "1", "1-beat pulse when dout is ready"),
            ("busy", "output", "1", "high while a block is being processed"),
        ]),
    dict(
        name="sha256", core="sha256_core", src="src/sha256_core.v",
        units="1 (SHAB)", digest="566ACEA2", board="m1e",
        desc="SHA-256 hash engine (FIPS-180-4), byte-serial streaming input "
             "with internal 0x80/zero/length padding, 64-round iterative "
             "compression, 16x32 message-schedule shift register.",
        params=[],
        ports=[
            ("init", "input", "1", "pulse 1 clk_en beat to start a new message"),
            ("din", "input", "8", "message byte"),
            ("din_valid", "input", "1", "byte valid; honored only while din_ready"),
            ("din_last", "input", "1", "marks the final message byte"),
            ("din_ready", "output", "1", "low during 64-round compression"),
            ("digest", "output", "256", "{H0..H7}, H0 at [255:224]"),
            ("digest_valid", "output", "1", "level: digest complete"),
        ]),
    dict(
        name="crc", core="crc_core", src="src/crc_core.v",
        units="2/3/4 (CRC8/CR16/CR32)", digest="FD957A4B/D0771E60/720D8B44",
        board="m1e",
        desc="Byte-serial CRC engine, runtime mode select: CRC-8/SMBUS(0x07), "
             "CRC-16/CCITT-FALSE(0x1021), CRC-32/ISO-HDLC(0x04C11DB7 refl).",
        params=[],
        ports=[
            ("mode", "input", "2", "0=CRC-8, 1=CRC-16, 2=CRC-32"),
            ("init", "input", "1", "pulse 1 clk_en beat: load per-mode init"),
            ("din", "input", "8", "message byte"),
            ("din_valid", "input", "1", "one byte consumed per beat"),
            ("crc_out", "output", "32", "running/final residue, xorout applied"),
        ]),
]

HEADER = """// ============================================================================
// gw2a_crypto_{name} -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: {core}  ({src})
// Board-validated: unit(s) {units}, digest {digest}, bitstream {board}
// Clock protocol: posedge clk + clk_en step enable (tie 1 for full rate),
// active-low asynchronous rst_n. No DSP, no BSRAM.
// ============================================================================
"""


def gen_rtl(ip):
    out = [HEADER.format(**ip)]
    out.append(f"module gw2a_crypto_{ip['name']} (\n")
    pin = ["    input  wire clk,",
           "    input  wire rst_n,",
           "    input  wire clk_en,"]
    for p in ip["ports"]:
        w = "" if p[2] == "1" else f"[{int(p[2])-1}:0] "
        pin.append(f"    {p[1]}  wire {w}{p[0]},  // {p[3]}")
    pin[-1] = pin[-1].replace(",  //", "   //", 1).rstrip().rstrip(",")
    out.append("\n".join(pin))
    out.append("\n);\n\n")
    out.append(f"    {ip['core']} u_core (\n")
    conns = ["        .clk(clk)", "        .rst_n(rst_n)",
             "        .clk_en(clk_en)"]
    conns += [f"        .{p[0]}({p[0]})" for p in ip["ports"]]
    out.append(",\n".join(conns))
    out.append("\n    );\n\nendmodule\n")
    return "".join(out)


def gen_manifest(ip):
    return {
        "ip_name": f"gw2a_crypto_{ip['name']}",
        "core_module": ip["core"],
        "core_source": ip["src"],
        "description": ip["desc"],
        "clock_reset": {
            "clk": "single clock, posedge",
            "rst_n": "active-low asynchronous",
            "clk_en": "step enable; tie 1'b1 for full-rate operation",
        },
        "parameters": [],
        "ports": [dict(name=p[0], dir=p[1], width=int(p[2]), note=p[3])
                  for p in ip["ports"]],
        "validation": {
            "selftest_units": ip["units"],
            "golden_digest_fnv1a": ip["digest"],
            "sim": "iverilog PASS (per-core TB + selftest + UART report, "
                   "masks 0x1f/0x03/0x1c)",
            "board": {
                "board": "Sipeed Tang Primer 20K",
                "device": "GW2A-LV18PG256C8/I7",
                "bitstream_mask": ip["board"],
                "uart": "115200@COM24",
                "evidence": f"doc/board_uart_{ip['board']}.txt",
            },
            "golden_source": "tools/golden_model.py (FIPS-197 vectors + "
                             "pycryptodome / hashlib.sha256 / binascii.crc32 "
                             "+ bit models)",
        },
        "resources": {},
        "dsp": 0,
        "bsram": 0,
    }


def gen_readme(ip):
    lines = [f"# gw2a_crypto_{ip['name']}\n",
             f"{ip['desc']}\n",
             "## Ports\n",
             "| port | dir | width | note |",
             "|---|---|---|---|",
             "| clk | in | 1 | posedge clock |",
             "| rst_n | in | 1 | active-low async reset |",
             "| clk_en | in | 1 | step enable, tie 1 for full rate |"]
    for p in ip["ports"]:
        lines.append(f"| {p[0]} | {p[1]} | {p[2]} | {p[3]} |")
    lines += ["",
              "## Validation",
              f"- selftest unit(s): {ip['units']}, FNV-1a digest {ip['digest']}",
              f"- board bitstream mask: {ip['board']}",
              f"- UART evidence: `../../doc/board_uart_{ip['board']}.txt`",
              "- golden: `tools/golden_model.py` (independent models)",
              ""]
    return "\n".join(lines)


def main():
    os.makedirs(IP_ROOT, exist_ok=True)
    rows = []
    for ip in IPS:
        d = os.path.join(IP_ROOT, ip["name"])
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, f"gw2a_crypto_{ip['name']}.v"), "w") as f:
            f.write(gen_rtl(ip))
        with open(os.path.join(d, "ip_manifest.json"), "w") as f:
            json.dump(gen_manifest(ip), f, indent=2)
        with open(os.path.join(d, "README.md"), "w") as f:
            f.write(gen_readme(ip))
        rows.append((f"gw2a_crypto_{ip['name']}", ip["core"], ip["units"],
                     ip["digest"], ip["board"]))
        print("wrote", d)

    man = ["# GW2A-18C validated crypto IP package", "",
           "Cores: AES-128 ECB encrypt, SHA-256 streaming hash,",
           "multi-mode byte-serial CRC. All passed iverilog sims and on-board",
           "UART digest validation on GW2A-LV18PG256C8/I7 (27 MHz, COM24",
           "115200). Evidence: `../doc/board_uart_m01.txt`,",
           "`../doc/board_uart_m1e.txt`, `../doc/utilization.txt`.", "",
           "| IP | core | selftest unit | digest | board mask |",
           "|---|---|---|---|---|"]
    for r in rows:
        man.append("| `%s` | `%s` | %s | %s | %s |" % r)
    man.append("")
    with open(os.path.join(IP_ROOT, "MANIFEST.md"), "w") as f:
        f.write("\n".join(man))
    print("wrote MANIFEST.md")


if __name__ == "__main__":
    main()
