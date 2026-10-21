# Narrow RAM mapping warning review

The installed brams_map_gw5a.v uses generic x8 packing macros,even when a port
is only4bits. Its references to data[7:0] and higher byte slices produce width
warnings for the two narrow fmap DPBs. The low4 data bits survive truncation;
all referenced high output bits are unused in the synthesized netlist. The
read-only B ports have unknown input data,but their write enables are tied low.

`audit_ram_mapping.py` checks those actual netlist conditions,including constant
GND resolution,live write data,and all high-output consumers (including top
ports). It rejects unexpected DPB geometry or count. This explains the narrow
warning cone; it is not a full primitive equivalence or physical memory test.

```powershell
python cores/acceleration/cnn_infer_25k/tools/audit_ram_mapping.py artifacts/cnn_infer_25k/engine_synth_20261020T190239082611Z --output artifacts/cnn_infer_25k/ram_audit_new
```

`ram_audit_20261020_initial` PASS. Negative checks also reject enabling an
unknown-data B write port or connecting a high output bit to a consumer.
The10score registers and22biases are small control/state arrays,not full tensor
arrays. The score register-replacement warning is expected. The ABC carry-box
fanout warning still does not establish physical timing; P&R remains required.
