# RSA UDP Tang 20K Endpoint

This project implements a board-visible RSA encryption request endpoint over
100M RMII Ethernet.

- FPGA IP: `192.168.137.15`
- MAC: `06:00:AA:BB:0C:DD`
- Transport: UDP only, request destination port `11451`
- Host convention: send and receive on the same UDP source port `P`
- RSA operation: fixed 256-bit demonstration public key, `c = m^65537 mod n`

The RSA size is intentionally a functional end-to-end demo for the GW2A-18C
resource budget plus Ethernet stack. It is not a production RSA security
strength claim.

Request payload:

```text
"RSA1" || 0x01 || 32-byte big-endian message
```

Response payload:

```text
"RSAR" || status || 16-bit cycle_count || 0x20 || 32-byte big-endian ciphertext
```

Commands from the repository root:

```powershell
.\scripts\test_rsa_udp_sim.ps1
.\scripts\build_rsa_udp_with_oss.ps1
.\scripts\program_rsa_udp.ps1
.\scripts\run_rsa_udp_request.ps1 -BindIp 192.168.137.1
```

The host Ethernet interface must be on the same subnet. The current lab
machine's wired interface is `192.168.137.1/24`, so this bitstream uses
`192.168.137.15`.
