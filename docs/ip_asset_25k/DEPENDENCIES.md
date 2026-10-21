# Planned product dependencies

These are integration requirements, not claims of completed integration.
Canonical implementation identities and declared RTL dependencies are in
`ip_catalog.yaml`. Adapter and interface compatibility remains to be tested.

```mermaid
graph TD
  IP00[IP-00 catalog and provenance] --> IP04[IP-04 runtime test shell]
  IP04 --> IP01[IP-01 stream and CSR fabric]
  IP01 --> IP02[IP-02 BSRAM DMA]
  IP02 --> IP03[IP-03 streaming ISP]
  IP02 --> IP05[IP-05 INT8 network]
  IP01 --> IP06[IP-06 synchronous DSP]
  IP01 --> IP07[IP-07 UDP]
  IP03 --> IP08[IP-08 OSD and video routing]
  IP04 --> IP09[IP-09 motor control]
  IP04 --> IP10[IP-10 integrity and recovery]
```

Stream fabric candidates: frame_switch4, width_converter, packet_async_fifo,
backpressure_isolator, axi_lite_interconnect, atomic_config, register_snapshot,
stream_credit32. Test-shell candidates: capture_replay, stream_metrics,
fault_injector, march_controller, register_snapshot, timestamp64.

Licensing release gate: existing provenance states local authorship for 72 RTL
cores but does not provide an explicit redistribution license. Preserve this
distinction. Third-party DVI netlists and Gowin primitives require separate
dependency/license entries if incorporated; neither is counted as authored IP.
