# OneWire Search ROM hardware enumerator

This module adds SearchROM(F0) triplet-bit discrepancy-tree enumeration. Existing ips_one_wire_master supports reset/read-byte/write-byte only and cannot issue a selected branch between each pair of read bits. This IP does not replace that byte master.

The pin interface is open-drain: ow_drive_low enables an external low driver, never a high driver. ow_in has two synchronizer registers. Integration must provide pull-up and compatible voltage/tri-state buffers. Search only: no temperature conversion, scratchpad, parasite strong pull-up or overdrive functionality.

START is accepted with ce/start_valid/start_ready. Each CRC8-validated64-bit ROM is held under rom_valid until ce/rom_ready. rom_last marks a tree leaf with no remaining discrepancy; device_count counts accepted outputs. DONE/error stays until ce/done_ready. No device on first reset gives successful DONE/count0/no_devices1. Later disappearance is explicit error8. More devices than MAX_DEVICES gives error5 after MAX_DEVICES results have been accepted. Duplicate physical ROM codes are indistinguishable on a wired-AND bus and are returned once.

CE gates only host handshakes and abort. Physical timers, sampling and timeout run without CE. Abort and timeout release an active bus transaction; an already exposed ROM token is never withdrawn, and pending failure completes after host accepts it. Reset releases drive immediately and clears held results. START configuration is entirely static parameters.

Timing uses integer-MHz CLK_HZ only (1MHz..250MHz); fractional MHz is rejected. A1us divider advances reset/slot phases independently of CE. Reset480us low plus480us released; presence is decided551us after initial falling edge. Two-flop latency gives an effective physical presence sample69us after release at1MHz and70.992us at250MHz, within DS18B20 guaranteed presence intersection60..75us. Slots70us: write0 low60us, write1 low6us, read-init low3us. On every slot end, stuck-low is explicit error2. Physical phase entry resets divider where needed, preserving complete pulse lengths.

Read sampling follows the fetched DS18B20 datasheet: master samples within15us of slot start. A system-clock counter compensates the two-flop pipeline, giving effective physical pin sample at14us; internal decision occurs two clocks later. The model drives responses from exact physical falling edges and includes data valid at13.9us and released at15us. A device only beginning to drive at15us violates this receiver's timing contract and is rejected, not claimed compatible. Synchronizer metastability, analog rise time and actual board IO constraints require board validation.

CRC uses reflected Dallas polynomial8C, full64-bit residue0. The discrepancy algorithm retains previous ROM and last discrepancy1..64 using7bits. Search outputs never include a failed CRC ROM. Previously accepted valid ROMs remain counted if a later pass fails.

Errors:1 parameter;2 stuck-low (before reset, after presence recovery or slot end);3 invalid id/complement11;4 Dallas CRC8;5 device limit;6 total elapsed timeout;7 CE-qualified abort;8 presence lost on a later search pass. TOTAL_TIMEOUT_US valid1000..100000000; MAX_DEVICES1..65535. Timeout includes held outputs and completes after an exposed result is consumed.

Run from repository root:

    python -B cores/system/common_scaffold/peripherals/onewire_rom_search/run_tests.py
    python -B cores/system/common_scaffold/peripherals/onewire_rom_search/test_branches.py
    python -B cores/system/common_scaffold/peripherals/onewire_rom_search/test_protocol.py
    python -B cores/system/common_scaffold/peripherals/onewire_rom_search/test_numeric_limits.py
    python -B cores/system/common_scaffold/peripherals/onewire_rom_search/synth.py

Independent wired-AND multidrop device model interprets physical low durations and commandF0, supplies ROM/complement reads and filters its own active device set on branch writes. It does not inspect internal DUT state to generate device data. Error injection uses DUT state only to target abort/reset phase tests. Assertions check exact physical low durations, unique expected ROMs, final marker, held output and DONE. Every64-bit first-discrepancy position is tested: valid CRC pairs at bits0..55, intentionally bad CRC pairs at56..63, including last_discrepancy64. MAX_DEVICES1/2/16 and integer clock endpoints covered. Real network references include mature OneWire algorithm and DS18B20 datasheet hashes/excerpts. All temporary binaries/downloads live on C: and are removed. No board claim.

Verification status: allPASS, main3scenarios (0/1/4devices),64branch positions,25protocol scenarios and15numeric/parameter profiles, including2/27/250MHz physical timing at13.9us response and15us release. Isolated Gowin synthesis MAX_DEVICES1/16/65535:735/754/738 LUT-class respectively, all0DSP/0BRAM9. LUT-class includes ALU and MUX; each block RAM would conservatively count2BRAM9. No routing or hardware verification performed.
