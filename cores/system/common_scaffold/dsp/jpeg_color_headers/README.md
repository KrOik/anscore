# Three-component baseline JPEG headers

`jpeg_color_headers.sv` emits complete baseline sequential JFIF headers for interleaved Y/Cb/Cr 4:4:4 or 4:2:0, plus explicit restart and EOI marker commands. It has two independently writable 8-bit quantization tables and four fixed JPEG Annex K Huffman tables. This is a header/marker core; entropy coding, MCU ordering, component sampling, byte stuffing and restart padding belong to the enclosing encoder.

## API

All ports use clk/rst_n/ce. Reset is synchronous active-low and overrides CE. table_valid/table_ready writes table_id (0=Y,1=chroma), table_index[5:0] in natural row-major frequency order, table_value[7:0]. Hardware emits the DQT entries in JPEG zigzag order. A shadow table entry may be patched after initialization. Both tables must have all 64 entries initialized since reset and all entries nonzero before commit.

cfg_valid/cfg_ready captures cfg_width/cfg_height/cfg_restart_interval (16 bits each) and cfg_sampling_420. Nonzero dimensions 1..65535 and all 16-bit restart intervals are accepted. A serial synchronous scan validates all 128 shadow entries before copying either active configuration. No table/config/command request is accepted during scan/copy/output. Valid commit updates both active tables, dimensions, sampling and interval together. Invalid geometry, incomplete tables or any zero entry rejects the complete request while preserving old active configuration. cfg_done pulses for every terminal configuration result; cfg_error additionally marks rejection. Pulses hold when CE=0 and clear on the next enabled clock.

Priority while idle is cfg, table, command. Ready signals are reset/CE gated and indicate which request may be accepted. As with the other CE-stream cores, output consumption requires both CE=1 and m_valid/m_ready. Request valid/data must remain stable until accepted.

cmd_valid/cmd_ready accepts cmd[1:0]: 0 emits the complete header; 1 emits FF D9 EOI; 2 emits FF D0+rst_index[2:0]. Command3 and every unconfigured command pulse cmd_error without bytes. cmd_done pulses after the last byte of a successful command is actually consumed. m_last marks the final byte of each command, so an enclosing file encoder must expose frame-last only for EOI. RST index sequencing is supplied by the caller; this core does not inspect or pad entropy bits. Commands are independent and no hidden file-open state restricts legal marker requests.

m_data[7:0],m_valid,m_last hold under backpressure and disabled CE. busy covers validation, table copy and byte emission. Reset aborts any operation, clears initialized-entry tracking/configured state and invalidates output; table RAM is not cleared because no table can be used until all entries are rewritten and committed.

## Header bytes

Each header is exactly 613 bytes:

| Segment | Bytes | Contents |
|---|---:|---|
| SOI | 2 | FF D8 |
| APP0 | 18 | JFIF1.01, units0, density1x1, no thumbnail |
| DQT | 134 | 8-bit tables0 and1, 64 entries each |
| SOF0 | 19 | 8-bit precision; Y id1/Q0 with sampling11 or22, Cb id2/Q1 and Cr id3/Q1 sampling11 |
| DHT | 420 | Annex K DC0/AC0 luminance, DC1/AC1 chrominance |
| DRI | 6 | Configured MCU interval; interval0 explicitly included |
| SOS | 14 | Y selector00,Cb/Cr11; Ss0,Se63,Ah/Al0 |

The four standard Huffman tables are static synthesizable numeric constants. The standalone RTL has no readmemh file, runtime generator or hidden module dependency. `annex_k.json` retains numeric reference data; tests independently obtain canonical Huffman tables from actual Pillow/libjpeg JPEG files rather than trusting this JSON or an RTL ROM dump.

## Evidence

Run from repository root:

```
python -B cores/system/common_scaffold/dsp/jpeg_color_headers/test_headers.py
python -B cores/system/common_scaffold/dsp/jpeg_color_headers/synth.py
```

Actual RTL simulation emits 120 complete commands /7572 bytes across 12 configurations. Independent parsing checks marker sequence/lengths, JFIF fields, both zigzag quantization tables, all four canonical Huffman tables, SOF sampling and component IDs, DRI and SOS selectors, plus all8 RST indexes and EOI. Cases cover dimensions1/odd dimensions/65535, both sampling modes, intervals0/1/2/3/7/65535, missing tables, zero table entries, zero geometry, configuration priority, conflicting busy requests, invalid opcode, CE stalls, output stalls, table patching and atomic invalid-commit retention, and reset during stalled output.

Ten actual color JPEG fixtures combine RTL-produced header/RST/EOI bytes with independently software-encoded constant coefficient entropy scans. Pillow decodes all ten to RGB with at most1 LSB difference from the intended color. Two fixtures use62 and19 restart markers and exercise RST index wrap. Software entropy is solely a header interoperability fixture; it does not validate a hardware color encoder. The two65535-square configurations are parsed only and not decoded into large images.

Isolated synth_gowin -noalu -nodsp and check pass with zero problems: 614 LUT1..4,41 MUX2_LUT5,4 MUX2_LUT6,283 FF,80 RAM16SDP4,1 SPX9,0 DSP. No routing, timing or board signoff is claimed. Temporary binaries, JPEG files and synthesis netlists are automatically removed; compact JSON evidence remains.

reference.json records actual successful retrieval of libjpeg-turbo Annex K tables and the W3C-hosted JFIF specification. Only standardized table numeric data and protocol layout were used; no encoder implementation was copied.
